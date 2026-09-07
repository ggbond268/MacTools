// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

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
    private var isActivated = false
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
        }
    ) {
        self.localization = localization
        let store = MenuBarHiddenStore(storage: context.storage)
        self.manager = MenuBarHiddenManager(
            store: store,
            localization: localization,
            permissionProvider: permissionProvider
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
    }

    // MARK: - Lifecycle

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        manager.activate()
        updateObservation()
    }

    func deactivate() {
        isActivated = false
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

    var isEnabled: Bool {
        get { manager.isEnabled }
        set { _ = setEnabled(newValue) }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> MenuBarHiddenPersistenceMutationResult {
        let result = manager.setEnabled(enabled)
        updateObservation()
        return result
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
        updateObservation()
    }

    func setHiddenIconsPanelVisible(_ visible: Bool) {
        isHiddenIconsPanelVisible = visible
        manager.setHiddenIconsPanelVisible(visible)
        if visible {
            manager.refreshPermissions()
        }
        updateObservation()
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
        guard permissions.canManageItems else { return }
        let panel = popupPanel ?? MenuBarHiddenPopupPanel(controller: self)
        popupPanel = panel
        panel.show(anchor: anchor)
        setHiddenIconsPanelVisible(true)
    }

    func closePopup() {
        popupPanel?.orderOut(nil)
        setHiddenIconsPanelVisible(false)
        if popupPanel != nil {
            updateObservation()
        }
    }

    private func updateObservation() {
        guard isActivated else {
            observer.stop()
            return
        }

        let uiVisible = isSettingsVisible || isHiddenIconsPanelVisible
        observer.start()

        if uiVisible {
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
