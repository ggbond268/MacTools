import AppKit
import Combine
import Foundation
import ApplicationServices
import MacToolsPluginKit

// MARK: - MenuBarHiddenController
//
// View-model layer. Forwards published state from the manager to SwiftUI and
// owns panel visibility hooks. Business logic lives in `MenuBarHiddenManager`.

@MainActor
final class MenuBarHiddenController: ObservableObject {
    @Published private(set) var snapshot: MenuBarHiddenSnapshot = .empty
    @Published private(set) var permissions = MenuBarHiddenPermissionsStatus(
        hasAccessibility: false,
        hasScreenRecording: false
    )

    let localization: PluginLocalization
    let manager: MenuBarHiddenManager
    private let observer: MenuBarHiddenObserver
    private var cancellables = Set<AnyCancellable>()
    private var popupPanel: MenuBarHiddenPopupPanel?
    private var isSettingsVisible = false
    private var isHiddenIconsPanelVisible = false

    var onStateChange: (() -> Void)?

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        permissionProvider: @escaping () -> MenuBarHiddenPermissionsStatus = {
            MenuBarHiddenPermissionsStatus(
                hasAccessibility: AXIsProcessTrusted(),
                hasScreenRecording: MenuBarHiddenScreenRecordingPermission.isGranted()
            )
        },
        hostSupportProbe: @escaping () -> MenuBarHiddenHostProbe.Outcome = {
            MenuBarHiddenHostProbe.hostMenuBarSupport()
        }
    ) {
        self.localization = localization
        let store = MenuBarHiddenStore(storage: context.storage)
        self.manager = MenuBarHiddenManager(
            store: store,
            localization: localization,
            permissionProvider: permissionProvider,
            hostSupportProbe: hostSupportProbe
        )
        self.observer = MenuBarHiddenObserver()

        observer.onRefresh = { [weak self] reason in
            self?.manager.refresh(reason: reason)
        }
        observer.onDraggingChanged = { [weak self] isDragging, startLocation in
            self?.manager.setDraggingMenuBarItem(isDragging, startLocation: startLocation)
        }

        manager.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.snapshot = snap
                self?.onStateChange?()
            }
            .store(in: &cancellables)

        manager.$permissions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] perms in
                self?.permissions = perms
                self?.onStateChange?()
            }
            .store(in: &cancellables)

        manager.$isHostMenuBarSupported
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.onStateChange?()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func activate() {
        manager.activate()
        // Unsupported host (macOS 27 single-window menu bar): the manager is
        // fail-closed and inert, so the global event observer would only burn
        // cycles — don't start it.
        if manager.isHostMenuBarSupported {
            observer.start()
        }
    }

    func deactivate() {
        observer.stop()
        manager.deactivate()
        popupPanel?.orderOut(nil)
        popupPanel = nil
    }

    #if DEBUG
    func replaceSnapshotForTesting(
        visibleItems: [MenuBarItem] = [],
        hiddenItems: [MenuBarItem] = [],
        alwaysHiddenItems: [MenuBarItem] = []
    ) {
        let permissions = MenuBarHiddenPermissionsStatus(
            hasAccessibility: true,
            hasScreenRecording: true
        )
        manager.replaceSnapshotForTesting(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            alwaysHiddenItems: alwaysHiddenItems,
            permissions: permissions
        )
        snapshot = MenuBarHiddenSnapshot(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            alwaysHiddenItems: alwaysHiddenItems,
            permissions: permissions
        )
        self.permissions = permissions
    }
    #endif

    // MARK: - Forwarded state / actions

    /// Synchronous read of the manager's fail-closed host gate (probed at
    /// activation; indeterminate probes re-run on a later activation). False
    /// on hosts where the menu bar window list is unavailable (macOS 27 beta
    /// single-window menu bar).
    var isHostSupported: Bool {
        manager.isHostMenuBarSupported
    }

    var isEnabled: Bool {
        get { manager.isEnabled }
        set { manager.isEnabled = newValue }
    }

    var isAlwaysHiddenEnabled: Bool {
        get { manager.isAlwaysHiddenEnabled }
        set {
            manager.isAlwaysHiddenEnabled = newValue
            objectWillChange.send()
            onStateChange?()
        }
    }

    var showsHiddenIconsInPanel: Bool {
        get { manager.showsHiddenIconsInPanel }
        set {
            manager.showsHiddenIconsInPanel = newValue
            objectWillChange.send()
            onStateChange?()
        }
    }

    var canShowHiddenIconsInPanel: Bool {
        manager.canShowHiddenIconsInPanel
    }

    func setSettingsVisible(_ visible: Bool) {
        isSettingsVisible = visible
        manager.setSettingsVisible(visible)
        if visible {
            manager.refreshPermissions()
        }
        updateUIPolling()
    }

    func setHiddenIconsPanelVisible(_ visible: Bool) {
        isHiddenIconsPanelVisible = visible
        manager.setHiddenIconsPanelVisible(visible)
        if visible {
            manager.refreshPermissions()
        }
        updateUIPolling()
    }

    func refreshPermissions() {
        manager.refreshPermissions()
    }

    func currentPermissions() -> MenuBarHiddenPermissionsStatus {
        manager.currentPermissions()
    }

    func moveItem(
        id: MenuBarItemTag,
        to section: MenuBarHiddenSection,
        placement: MenuBarHiddenMovePlacement
    ) {
        manager.moveItem(id: id, to: section, placement: placement)
    }

    func clickItem(_ item: MenuBarItem, button: CGMouseButton) {
        manager.clickItem(item, button: button)
    }

    func clickItemAfterPopupCloses(_ item: MenuBarItem, button: CGMouseButton) {
        let panel = popupPanel
        closePopup()
        Task { @MainActor [weak self] in
            await panel?.waitUntilClosed(timeout: .milliseconds(200))
            self?.manager.clickItem(item, button: button)
        }
    }

    // MARK: - Popup

    func showPopup(anchor: NSRect?) {
        guard isHostSupported, permissions.canManageItems else { return }
        let panel = popupPanel ?? MenuBarHiddenPopupPanel(controller: self)
        popupPanel = panel
        panel.show(anchor: anchor)
        setHiddenIconsPanelVisible(true)
    }

    func closePopup() {
        popupPanel?.orderOut(nil)
        setHiddenIconsPanelVisible(false)
        if popupPanel != nil {
            updateUIPolling()
        }
    }

    private func updateUIPolling() {
        if isSettingsVisible || isHiddenIconsPanelVisible {
            observer.startPolling()
        } else {
            observer.stopPolling()
        }
    }

    // MARK: - Derived display strings

    var componentSubtitle: String {
        guard permissions.canManageItems else { return "" }
        let count = snapshot.hiddenItems.count + snapshot.alwaysHiddenItems.count
        switch count {
        case 0:
            return localization.string("component.subtitle.empty", defaultValue: "暂无隐藏图标")
        case 1:
            return localization.format("component.subtitle.count.singular", defaultValue: "%d 个隐藏图标", count)
        default:
            return localization.format("component.subtitle.count", defaultValue: "%d 个隐藏图标", count)
        }
    }

    var panelSubtitle: String {
        if isEnabled {
            return localization.string("panel.subtitle.enabled", defaultValue: "已启用")
        }
        return localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
    }
}
