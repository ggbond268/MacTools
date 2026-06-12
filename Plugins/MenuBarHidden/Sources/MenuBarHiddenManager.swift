import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import MacToolsPluginKit

// MARK: - MenuBarHiddenManager
//
// Central coordinator. Owns the divider, item enumerator, event synthesiser
// and icon cache. Three concerns:
//
//   1. `isEnabled` — toggles the divider; permission-free. The hide mechanism
//      is purely the expanding NSStatusItem (Thaw / Ice approach).
//   2. Layout drag — moves items between sections by synthesising Cmd+drag
//      events. Requires accessibility + screen recording.
//   3. Click forwarding — temporarily moves one hidden item into the visible
//      section, clicks it, then returns it after its interface closes.
//      Requires accessibility + screen recording.

@MainActor
final class MenuBarHiddenManager: ObservableObject {
    @Published private(set) var snapshot: MenuBarHiddenSnapshot = .empty
    @Published private(set) var permissions = MenuBarHiddenPermissionsStatus(
        hasAccessibility: false,
        hasScreenRecording: false
    )
    /// Fail-closed host compatibility gate. On macOS 27 beta the menu bar was
    /// composited into a single WindowServer window and the CGS per-item
    /// window list comes back empty (a future seed might instead return
    /// implausibly shaped data — `MenuBarHiddenHostProbe` rejects both) —
    /// every mechanism of this plugin (10000pt
    /// expanding divider, item enumeration, synthesised drags/clicks) then
    /// either silently spins or risks swallowing menu bar clicks. Probed at
    /// first activation; determinate verdicts are cached for the manager's
    /// lifetime, while indeterminate ones (no active displays, transient
    /// CGWindow lookup failure) stay fail-closed but re-probe on a later
    /// activation. When unsupported the plugin installs nothing and surfaces
    /// an explicit incompatibility message instead.
    @Published private(set) var isHostMenuBarSupported = true

    let iconCache: MenuBarHiddenIconCache

    private let store: MenuBarHiddenStore
    private let divider: MenuBarHiddenDivider
    private let alwaysHiddenDivider: MenuBarHiddenDivider
    private let enumerator: MenuBarHiddenItemEnumerator
    private let events: MenuBarHiddenEventSynthesis
    private let localization: PluginLocalization
    private let permissionProvider: () -> MenuBarHiddenPermissionsStatus
    private let hostSupportProbe: () -> MenuBarHiddenHostProbe.Outcome
    private var hasProbedHostSupport = false

    private struct PendingClickRequest {
        let item: MenuBarItem
        let button: CGMouseButton
    }

    private var isActive = false
    private var settingsVisible = false
    private var hiddenIconsPanelVisible = false
    private var isDraggingMenuBarItem = false
    private var currentDragTarget: MenuBarHiddenMenuBarDragTarget = .unknown
    private var isRecoveringControlItemOrder = false
    private var shouldRestoreHiddenAfterDrag = false
    private var dragSessionID = 0
    private var currentDisplayID = CGMainDisplayID()
    private var moveTask: Task<Void, Never>?
    private var clickTask: Task<Void, Never>?
    private var pendingClickRequests: [PendingClickRequest] = []
    private var controlItemRecoveryTask: Task<Void, Never>?
    private var controlItemRecoveryPollTask: Task<Void, Never>?
    private var hiddenRestoreTask: Task<Void, Never>?
    private var alwaysHiddenRestoreTask: Task<Void, Never>?
    private var layoutRestoreTask: Task<Void, Never>?
    private var menuBarDragCommitTask: Task<Void, Never>?
    private var menuBarDragCommitSessionID: Int?
    private var settingsSettleRefreshTask: Task<Void, Never>?
    private var temporaryRehideTask: Task<Void, Never>?
    private var temporaryRehideCancellable: AnyCancellable?
    private var temporarilyShownItemContexts: [TemporarilyShownItemContext] = []
    var hostStatusItemFrameProvider: (() -> NSRect?)?
    var resetHostStatusItemPosition: (() -> Void)?

    init(
        store: MenuBarHiddenStore,
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
        self.store = store
        self.hostSupportProbe = hostSupportProbe
        self.divider = MenuBarHiddenDivider(kind: .hidden)
        self.alwaysHiddenDivider = MenuBarHiddenDivider(kind: .alwaysHidden)
        self.enumerator = MenuBarHiddenItemEnumerator()
        self.events = MenuBarHiddenEventSynthesis()
        self.iconCache = MenuBarHiddenIconCache()
        self.localization = localization
        self.permissionProvider = permissionProvider

        divider.onFrameChange = { [weak self] in
            self?.refresh(reason: .dividerMoved)
        }
        alwaysHiddenDivider.onFrameChange = { [weak self] in
            self?.refresh(reason: .dividerMoved)
        }
    }

    #if DEBUG
    func replaceSnapshotForTesting(
        visibleItems: [MenuBarItem] = [],
        hiddenItems: [MenuBarItem] = [],
        alwaysHiddenItems: [MenuBarItem] = [],
        permissions: MenuBarHiddenPermissionsStatus = MenuBarHiddenPermissionsStatus(
            hasAccessibility: true,
            hasScreenRecording: true
        )
    ) {
        snapshot = MenuBarHiddenSnapshot(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            alwaysHiddenItems: alwaysHiddenItems,
            permissions: permissions
        )
    }
    #endif

    // MARK: - Lifecycle

    func activate() {
        guard !isActive else { return }
        probeHostSupportIfNeeded()
        guard isHostMenuBarSupported else {
            // Fail closed: never install the dividers (no 10000pt expansion),
            // never enumerate, never synthesise events. `isActive` stays
            // false so every refresh/drag/recovery entry point is inert.
            refreshPermissions()
            return
        }
        isActive = true
        refreshPermissions()
        if store.isEnabled {
            installAndExpand()
        } else {
            installAndShow()
        }
        updateAlwaysHiddenDividerVisibility()
        rebuildSnapshot()
        recoverControlItemOrderIfNeeded(sessionID: nil)
        scheduleStoredLayoutRestoreIfNeeded(delay: .milliseconds(700))
        scheduleAlwaysHiddenItemsRestoreIfNeeded(delay: .milliseconds(600))
    }

    private func probeHostSupportIfNeeded() {
        guard !hasProbedHostSupport else { return }
        switch hostSupportProbe() {
        case .supported:
            hasProbedHostSupport = true
            isHostMenuBarSupported = true
        case .unsupported:
            hasProbedHostSupport = true
            isHostMenuBarSupported = false
            // The probe logs the specific rejection reason (empty vs
            // implausibly shaped enumeration) before returning.
            MenuBarHiddenLog.plugin.error(
                "Menu bar host support probe failed; entering fail-closed unsupported mode (incompatible menu bar host)"
            )
        case .indeterminate:
            // No positive evidence either way: stay fail-closed for this
            // activation, but leave the verdict uncached so a later
            // activate() re-probes once the environment recovers.
            isHostMenuBarSupported = false
            MenuBarHiddenLog.plugin.error(
                "Menu bar host support probe was indeterminate; staying fail-closed until a later activation re-probes"
            )
        }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        moveTask?.cancel(); moveTask = nil
        clickTask?.cancel(); clickTask = nil
        pendingClickRequests.removeAll()
        controlItemRecoveryTask?.cancel(); controlItemRecoveryTask = nil
        controlItemRecoveryPollTask?.cancel(); controlItemRecoveryPollTask = nil
        hiddenRestoreTask?.cancel(); hiddenRestoreTask = nil
        alwaysHiddenRestoreTask?.cancel(); alwaysHiddenRestoreTask = nil
        layoutRestoreTask?.cancel(); layoutRestoreTask = nil
        cancelMenuBarDragCommit()
        settingsSettleRefreshTask?.cancel(); settingsSettleRefreshTask = nil
        temporaryRehideTask?.cancel(); temporaryRehideTask = nil
        temporaryRehideCancellable?.cancel(); temporaryRehideCancellable = nil
        temporarilyShownItemContexts.removeAll()
        isDraggingMenuBarItem = false
        currentDragTarget = .unknown
        isRecoveringControlItemOrder = false
        shouldRestoreHiddenAfterDrag = false
        invalidateDragSession()
        divider.uninstall()
        alwaysHiddenDivider.uninstall()
    }

    // MARK: - Toggle (Function 1, no permissions required)

    var isEnabled: Bool {
        get { store.isEnabled }
        set {
            guard isHostMenuBarSupported else { return }
            guard store.isEnabled != newValue else { return }
            hiddenRestoreTask?.cancel()
            hiddenRestoreTask = nil
            layoutRestoreTask?.cancel()
            layoutRestoreTask = nil
            shouldRestoreHiddenAfterDrag = false
            store.isEnabled = newValue
            if newValue {
                installAndExpand()
            } else {
                if !divider.isInstalled { divider.install() }
                divider.showSection(isDragging: false)
            }
            rebuildSnapshot()
            scheduleStoredLayoutRestoreIfNeeded(delay: .milliseconds(500))
        }
    }

    var isAlwaysHiddenEnabled: Bool {
        get { store.isAlwaysHiddenEnabled }
        set {
            guard isHostMenuBarSupported else { return }
            guard store.isAlwaysHiddenEnabled != newValue else { return }
            alwaysHiddenRestoreTask?.cancel()
            alwaysHiddenRestoreTask = nil
            guard permissions.canManageItems || !newValue else {
                store.isAlwaysHiddenEnabled = false
                updateAlwaysHiddenDividerVisibility()
                rebuildSnapshot()
                refreshIconsIfUIVisible()
                return
            }
            store.isAlwaysHiddenEnabled = newValue
            updateAlwaysHiddenDividerVisibility()
            rebuildSnapshot()
            if newValue {
                scheduleAlwaysHiddenItemsRestoreIfNeeded(delay: .milliseconds(500))
            }
            scheduleStoredLayoutRestoreIfNeeded(delay: .milliseconds(500))
            refreshIconsIfUIVisible()
        }
    }

    var showsHiddenIconsInPanel: Bool {
        get { store.showsHiddenIconsInPanel }
        set {
            guard store.showsHiddenIconsInPanel != newValue else { return }
            guard permissions.canManageItems || !newValue else {
                store.showsHiddenIconsInPanel = false
                return
            }
            store.showsHiddenIconsInPanel = newValue
        }
    }

    var canShowHiddenIconsInPanel: Bool {
        permissions.canManageItems && store.showsHiddenIconsInPanel
    }

    // MARK: - Refresh

    func refresh(reason: MenuBarHiddenRefreshReason) {
        guard isActive else { return }
        MenuBarHiddenLog.plugin.debug("refresh: \(reason.description)")
        refreshPermissions()
        rebuildSnapshot()
        if !isMenuBarDragCommitPending {
            scheduleAlwaysHiddenItemsRestoreIfNeeded()
            scheduleStoredLayoutRestoreIfNeeded()
        }
        refreshIconsIfUIVisible()
    }

    func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        settingsSettleRefreshTask?.cancel()
        settingsSettleRefreshTask = nil
        if visible {
            refresh(reason: .settingsAppeared)
            recoverControlItemOrderIfNeeded(sessionID: nil)
            settingsSettleRefreshTask = Task { [weak self] in
                // Matches Thaw's settling delay before cache refresh: freshly
                // shown NSStatusItem windows can report stale bounds briefly.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.refresh(reason: .settingsAppeared)
                }
            }
        }
    }

    func setHiddenIconsPanelVisible(_ visible: Bool) {
        hiddenIconsPanelVisible = visible
        if visible { refresh(reason: .hiddenIconsPanelAppeared) }
    }

    func setDraggingMenuBarItem(_ dragging: Bool, startLocation: NSPoint?) {
        guard isActive else { return }
        guard isDraggingMenuBarItem != dragging else { return }
        isDraggingMenuBarItem = dragging

        if dragging {
            let shouldRestoreHidden = shouldRestoreHiddenAfterDrag || store.isEnabled
            invalidateDragSession()
            let sessionID = dragSessionID
            currentDragTarget = dragTarget(at: startLocation)
            cancelMenuBarDragCommit()
            hiddenRestoreTask?.cancel()
            hiddenRestoreTask = nil
            layoutRestoreTask?.cancel()
            layoutRestoreTask = nil
            controlItemRecoveryTask?.cancel()
            controlItemRecoveryTask = nil
            isRecoveringControlItemOrder = false
            shouldRestoreHiddenAfterDrag = shouldRestoreHidden
            if store.isEnabled {
                store.isEnabled = false
            }
            installAndShow()
            divider.showSection(isDragging: true)
            updateAlwaysHiddenDividerVisibility()
            refresh(reason: .dragStarted)
            rebuildSnapshot()
            startControlItemOrderRecoveryPolling(sessionID: sessionID)
        } else {
            let sessionID = dragSessionID
            stopControlItemOrderRecoveryPolling()
            scheduleMenuBarDragCommit(target: currentDragTarget, sessionID: sessionID)
            currentDragTarget = .unknown
        }
    }

    // MARK: - Move item (Function 2, requires both permissions)

    func moveItem(
        id: MenuBarItemTag,
        to section: MenuBarHiddenSection,
        placement: MenuBarHiddenMovePlacement
    ) {
        guard isActive else { return }
        guard permissions.canManageItems else {
            MenuBarHiddenLog.plugin.debug("moveItem ignored — missing permissions")
            return
        }
        guard let item = snapshot.allItems.first(where: { $0.tag == id }) else { return }
        guard !MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: item, section: section) else {
            recoverHostIconIfNeeded()
            MenuBarHiddenLog.plugin.debug("moveItem ignored — item cannot move to \(section.rawValue)")
            return
        }

        alwaysHiddenRestoreTask?.cancel()
        alwaysHiddenRestoreTask = nil
        layoutRestoreTask?.cancel()
        layoutRestoreTask = nil
        moveTask?.cancel()
        moveTask = Task { [weak self] in
            guard let self else { return }
            let moved = await self.performMove(item: item, toSection: section, placement: placement)
            guard moved else { return }
            self.updateStoredLayoutAfterMove(
                for: item,
                movedItem: self.snapshotItem(matching: item, in: section),
                destination: section
            )
        }
    }

    // MARK: - Click forwarding (Function 3, requires both permissions)

    func clickItem(_ item: MenuBarItem, button: CGMouseButton) {
        guard isActive else { return }
        guard permissions.canManageItems else { return }
        pendingClickRequests.append(PendingClickRequest(item: item, button: button))
        startClickProcessingIfNeeded()
    }

    private func startClickProcessingIfNeeded() {
        guard clickTask == nil else { return }
        clickTask = Task { [weak self] in
            await self?.processPendingClickRequests()
        }
    }

    private func processPendingClickRequests() async {
        while !Task.isCancelled {
            guard !pendingClickRequests.isEmpty else {
                clickTask = nil
                return
            }

            let request = pendingClickRequests.removeFirst()
            await performClick(item: request.item, button: request.button)
        }

        pendingClickRequests.removeAll()
        clickTask = nil
    }

    // MARK: - Permissions

    func refreshPermissions() {
        let current = currentPermissions()
        guard permissions != current else { return }
        permissions = current
        if !current.canManageItems {
            if store.isAlwaysHiddenEnabled {
                store.isAlwaysHiddenEnabled = false
                updateAlwaysHiddenDividerVisibility()
                rebuildSnapshot()
            }
            if store.showsHiddenIconsInPanel {
                store.showsHiddenIconsInPanel = false
            }
        }
    }

    func currentPermissions() -> MenuBarHiddenPermissionsStatus {
        permissionProvider()
    }

    // MARK: - Private

    private func installAndExpand() {
        if !divider.isInstalled { divider.install() }
        if visibleControlItemStoredPositionNeedsRecovery() {
            divider.showSection(isDragging: false)
            scheduleHostIconRecovery(sessionID: nil)
            return
        }
        if isDraggingMenuBarItem {
            divider.showSection(isDragging: true)
        } else {
            divider.hideSection()
        }
        updateAlwaysHiddenDividerVisibility()
    }

    private func installAndShow() {
        if !divider.isInstalled { divider.install() }
        divider.showSection(isDragging: false)
        updateAlwaysHiddenDividerVisibility()
    }

    private func updateAlwaysHiddenDividerVisibility() {
        guard isActive else { return }
        if store.isAlwaysHiddenEnabled {
            if !alwaysHiddenDivider.isInstalled {
                alwaysHiddenDivider.install()
            }
            alwaysHiddenDivider.hideSection()
            recoverAlwaysHiddenDividerIfNeeded(sessionID: nil)
        } else {
            alwaysHiddenDivider.uninstall()
        }
    }

    private func invalidateDragSession() {
        dragSessionID &+= 1
    }

    private func rebuildSnapshot() {
        guard isHostMenuBarSupported else {
            // No CGS churn in unsupported mode; the empty snapshot is the
            // explicit "nothing works here" state the UI layers key off.
            snapshot = MenuBarHiddenSnapshot(
                visibleItems: [],
                hiddenItems: [],
                alwaysHiddenItems: [],
                permissions: permissions
            )
            return
        }
        divider.refreshWindowID()
        alwaysHiddenDivider.refreshWindowID()
        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.isInstalled ? divider.windowID : nil,
            hiddenDividerFrame: divider.isInstalled ? divider.screenFrame : nil,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        let allItems = result.items
        currentDisplayID = result.displayID
        guard let hiddenDividerBounds = result.hiddenDividerBounds else {
            snapshot = MenuBarHiddenSnapshot(
                visibleItems: [],
                hiddenItems: [],
                alwaysHiddenItems: [],
                permissions: permissions
            )
            return
        }

        let layoutItems = MenuBarHiddenLayoutPolicy.layoutEditorItems(from: allItems)
        let alwaysHiddenDividerBounds = store.isAlwaysHiddenEnabled ? result.alwaysHiddenDividerBounds : nil
        let visibleItems = MenuBarHiddenLayoutPolicy.visibleItems(
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        let hiddenItems = MenuBarHiddenLayoutPolicy.hiddenItems(
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        let alwaysHiddenItems = MenuBarHiddenLayoutPolicy.alwaysHiddenItems(
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        snapshot = MenuBarHiddenSnapshot(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            alwaysHiddenItems: alwaysHiddenItems,
            permissions: permissions
        )
    }

    private func refreshIconsIfUIVisible() {
        guard settingsVisible || hiddenIconsPanelVisible else { return }
        guard permissions.canManageItems else { return }
        iconCache.refresh(
            groups: [snapshot.visibleItems, snapshot.hiddenItems, snapshot.alwaysHiddenItems],
            displayID: currentDisplayID
        )
    }

    private func excludedControlWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        if divider.isInstalled {
            ids.formUnion(divider.hiddenControlWindowIDs)
        }
        if alwaysHiddenDivider.isInstalled {
            ids.formUnion(alwaysHiddenDivider.hiddenControlWindowIDs)
        }
        return ids
    }

    private func localizedDescription(for error: Error) -> String {
        if let eventError = error as? MenuBarHiddenEventError {
            return eventError.localizedDescription(localization: localization)
        }
        return error.localizedDescription
    }

    // MARK: - Move

    private func performMove(
        item: MenuBarItem,
        toSection: MenuBarHiddenSection,
        placement: MenuBarHiddenMovePlacement
    ) async -> Bool {
        await events.waitForUserInputPause()

        let live = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        guard
            let liveItem = live.items.first(where: { $0.tag == item.tag }),
            let target = computeMoveTarget(
                section: toSection,
                placement: placement,
                items: live.items,
                hiddenDividerBounds: live.hiddenDividerBounds,
                alwaysHiddenDividerBounds: live.alwaysHiddenDividerBounds
            )
        else {
            MenuBarHiddenLog.plugin.warning("performMove: could not resolve live item or target X")
            return false
        }

        do {
            try await events.move(item: liveItem, to: target)
        } catch {
            MenuBarHiddenLog.plugin.error("performMove failed: \(self.localizedDescription(for: error))")
            return false
        }

        try? await Task.sleep(for: .milliseconds(300))
        rebuildSnapshot()
        recoverHostIconIfNeeded()
        refreshIconsIfUIVisible()
        return snapshotItem(matching: item, in: toSection) != nil
    }

    private func snapshotItem(matching item: MenuBarItem, in section: MenuBarHiddenSection) -> MenuBarItem? {
        let items: [MenuBarItem]
        switch section {
        case .visible:
            items = snapshot.visibleItems
        case .hidden:
            items = snapshot.hiddenItems
        case .alwaysHidden:
            items = snapshot.alwaysHiddenItems
        }

        return items.first {
            $0.windowID == item.windowID
        } ?? items.first {
            $0.tag.matchesIgnoringWindowID(item.tag)
                && ($0.sourcePID ?? $0.ownerPID) == (item.sourcePID ?? item.ownerPID)
        }
    }

    private func updateStoredLayoutAfterMove(
        for originalItem: MenuBarItem,
        movedItem: MenuBarItem?,
        destination: MenuBarHiddenSection
    ) {
        switch destination {
        case .alwaysHidden:
            store.recordAlwaysHiddenItem((movedItem ?? originalItem).tag)
        case .visible, .hidden:
            if store.isAlwaysHiddenEnabled {
                store.removeAlwaysHiddenItem(originalItem.tag)
                if let movedItem {
                    store.removeAlwaysHiddenItem(movedItem.tag)
                }
            }
        }
        recordCurrentVisibleHiddenLayout()
        scheduleStoredLayoutRestoreIfNeeded(delay: .milliseconds(500))
    }

    private func prepareStoredVisibleHiddenLayoutIfNeeded() {
        guard permissions.canManageItems else { return }
        guard !snapshot.allItems.isEmpty else { return }
        guard !isDraggingMenuBarItem, !isRecoveringControlItemOrder else { return }
        guard temporarilyShownItemContexts.isEmpty else { return }

        if store.hasVisibleHiddenLayout {
            appendNewItemsToStoredVisibleHiddenLayout()
        } else {
            recordCurrentVisibleHiddenLayout()
        }
    }

    private func appendNewItemsToStoredVisibleHiddenLayout() {
        let layout = storedLayout()
        let next = MenuBarHiddenStoredLayoutPolicy.appendNewItemsToHiddenByDefault(
            items: snapshot.allItems,
            storedLayout: layout
        )
        guard next.visibleItemStableKeys != store.visibleItemStableKeys
            || next.hiddenItemStableKeys != store.hiddenItemStableKeys
        else {
            return
        }
        store.recordVisibleHiddenLayout(
            visibleKeys: next.visibleItemStableKeys,
            hiddenKeys: next.hiddenItemStableKeys
        )
    }

    private func recordCurrentVisibleHiddenLayout() {
        let next = MenuBarHiddenStoredLayoutPolicy.visibleHiddenLayout(
            visibleItems: snapshot.visibleItems,
            hiddenItems: snapshot.hiddenItems,
            alwaysHiddenItems: snapshot.alwaysHiddenItems,
            previousVisibleItemStableKeys: store.visibleItemStableKeys,
            previousHiddenItemStableKeys: store.hiddenItemStableKeys
        )
        store.recordVisibleHiddenLayout(
            visibleKeys: next.visibleItemStableKeys,
            hiddenKeys: next.hiddenItemStableKeys
        )
    }

    private func storedLayout() -> MenuBarHiddenStoredLayout {
        MenuBarHiddenStoredLayout(
            visibleItemStableKeys: store.visibleItemStableKeys,
            hiddenItemStableKeys: store.hiddenItemStableKeys,
            alwaysHiddenItemStableKeys: store.alwaysHiddenItemStableKeys,
            isAlwaysHiddenEnabled: store.isAlwaysHiddenEnabled
        )
    }

    private func scheduleStoredLayoutRestoreIfNeeded(delay: Duration = .milliseconds(300)) {
        prepareStoredVisibleHiddenLayoutIfNeeded()
        guard canRestoreStoredVisibleHiddenLayout else {
            layoutRestoreTask?.cancel()
            layoutRestoreTask = nil
            return
        }
        guard !storedVisibleHiddenRestoreCandidates().isEmpty else {
            layoutRestoreTask?.cancel()
            layoutRestoreTask = nil
            return
        }

        layoutRestoreTask?.cancel()
        layoutRestoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.restoreStoredVisibleHiddenLayout()
        }
    }

    private func restoreStoredVisibleHiddenLayout() async {
        guard canRestoreStoredVisibleHiddenLayout else {
            layoutRestoreTask = nil
            return
        }

        let candidates = storedVisibleHiddenRestoreCandidates()
        guard !candidates.isEmpty else {
            layoutRestoreTask = nil
            return
        }

        var restoredCount = 0
        for candidate in candidates {
            guard !Task.isCancelled else {
                layoutRestoreTask = nil
                return
            }
            guard canRestoreStoredVisibleHiddenLayout else {
                scheduleStoredLayoutRestoreIfNeeded(delay: .milliseconds(600))
                return
            }

            let placement = storedVisibleHiddenPlacement(
                for: candidate.item,
                in: candidate.section
            )
            if await performMove(item: candidate.item, toSection: candidate.section, placement: placement) {
                restoredCount += 1
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        layoutRestoreTask = nil
        if restoredCount > 0, !storedVisibleHiddenRestoreCandidates().isEmpty {
            scheduleStoredLayoutRestoreIfNeeded(delay: .milliseconds(900))
        }
    }

    private var canRestoreStoredVisibleHiddenLayout: Bool {
        isActive
            && store.hasVisibleHiddenLayout
            && permissions.canManageItems
            && divider.isInstalled
            && !isDraggingMenuBarItem
            && !isRecoveringControlItemOrder
            && temporarilyShownItemContexts.isEmpty
    }

    private struct StoredVisibleHiddenRestoreCandidate {
        let item: MenuBarItem
        let section: MenuBarHiddenSection
    }

    private func storedVisibleHiddenRestoreCandidates() -> [StoredVisibleHiddenRestoreCandidate] {
        let layout = storedLayout()
        let currentSections = currentVisibleHiddenSectionsByStableKey()
        let keyedItems = Dictionary(grouping: snapshot.allItems, by: { $0.tag.stableKey })
            .compactMapValues(\.first)

        return (layout.hiddenItemStableKeys + layout.visibleItemStableKeys).compactMap { key in
            guard let item = keyedItems[key] else { return nil }
            let desiredSection = MenuBarHiddenStoredLayoutPolicy.desiredSection(
                for: item,
                storedLayout: layout
            )
            guard desiredSection != .alwaysHidden else { return nil }
            guard currentSections[key] != desiredSection else { return nil }
            guard !MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: item, section: desiredSection) else {
                return nil
            }
            return StoredVisibleHiddenRestoreCandidate(item: item, section: desiredSection)
        }
    }

    private func currentVisibleHiddenSectionsByStableKey() -> [String: MenuBarHiddenSection] {
        var sections: [String: MenuBarHiddenSection] = [:]
        for item in snapshot.visibleItems {
            sections[item.tag.stableKey] = .visible
        }
        for item in snapshot.hiddenItems {
            sections[item.tag.stableKey] = .hidden
        }
        for item in snapshot.alwaysHiddenItems {
            sections[item.tag.stableKey] = .alwaysHidden
        }
        return sections
    }

    private func storedVisibleHiddenPlacement(
        for item: MenuBarItem,
        in section: MenuBarHiddenSection
    ) -> MenuBarHiddenMovePlacement {
        let sectionKeys: [String]
        let sectionItems: [MenuBarItem]
        switch section {
        case .visible:
            sectionKeys = store.visibleItemStableKeys
            sectionItems = snapshot.visibleItems
        case .hidden:
            sectionKeys = store.hiddenItemStableKeys
            sectionItems = snapshot.hiddenItems
        case .alwaysHidden:
            return .end
        }

        guard let index = sectionKeys.firstIndex(of: item.tag.stableKey) else {
            return .end
        }
        let itemsByKey = Dictionary(grouping: sectionItems, by: { $0.tag.stableKey })
            .compactMapValues(\.first)

        for nextKey in sectionKeys.dropFirst(index + 1) {
            if let nextItem = itemsByKey[nextKey] {
                return .before(nextItem.tag)
            }
        }
        for previousKey in sectionKeys[..<index].reversed() {
            if let previousItem = itemsByKey[previousKey] {
                return .after(previousItem.tag)
            }
        }
        return .end
    }

    private func scheduleAlwaysHiddenItemsRestoreIfNeeded(delay: Duration = .milliseconds(250)) {
        guard canRestoreAlwaysHiddenItems else {
            alwaysHiddenRestoreTask?.cancel()
            alwaysHiddenRestoreTask = nil
            return
        }

        guard !alwaysHiddenRestoreCandidates().isEmpty else { return }
        alwaysHiddenRestoreTask?.cancel()
        alwaysHiddenRestoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.restoreRecordedAlwaysHiddenItems()
        }
    }

    private func restoreRecordedAlwaysHiddenItems() async {
        guard canRestoreAlwaysHiddenItems else {
            alwaysHiddenRestoreTask = nil
            return
        }

        let candidates = alwaysHiddenRestoreCandidates()
        guard !candidates.isEmpty else {
            alwaysHiddenRestoreTask = nil
            return
        }

        var restoredCount = 0
        for item in candidates {
            guard !Task.isCancelled else { return }
            guard canRestoreAlwaysHiddenItems else {
                scheduleAlwaysHiddenItemsRestoreIfNeeded(delay: .milliseconds(500))
                return
            }

            if await performMove(item: item, toSection: .alwaysHidden, placement: .end) {
                restoredCount += 1
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        alwaysHiddenRestoreTask = nil
        if restoredCount > 0, !alwaysHiddenRestoreCandidates().isEmpty {
            scheduleAlwaysHiddenItemsRestoreIfNeeded(delay: .milliseconds(750))
        }
    }

    private var canRestoreAlwaysHiddenItems: Bool {
        isActive
            && store.isAlwaysHiddenEnabled
            && permissions.canManageItems
            && alwaysHiddenDivider.isInstalled
            && !isDraggingMenuBarItem
            && !isRecoveringControlItemOrder
            && temporarilyShownItemContexts.isEmpty
    }

    private func alwaysHiddenRestoreCandidates() -> [MenuBarItem] {
        MenuBarHiddenAlwaysHiddenRestorePolicy.restoreCandidates(
            snapshot: snapshot,
            recordedStableKeys: store.alwaysHiddenItemStableKeys
        )
    }

    private func computeMoveTarget(
        section: MenuBarHiddenSection,
        placement: MenuBarHiddenMovePlacement,
        items: [MenuBarItem],
        hiddenDividerBounds: CGRect?,
        alwaysHiddenDividerBounds: CGRect?
    ) -> MenuBarHiddenResolvedMoveTarget? {
        guard let hiddenDivider = hiddenDividerBounds else { return nil }

        func target(_ item: MenuBarItem, x: CGFloat) -> MenuBarHiddenResolvedMoveTarget {
            MenuBarHiddenResolvedMoveTarget(
                point: CGPoint(x: x, y: item.bounds.minY),
                windowID: item.windowID
            )
        }

        func target(x: CGFloat, y: CGFloat, windowID: CGWindowID?) -> MenuBarHiddenResolvedMoveTarget {
            MenuBarHiddenResolvedMoveTarget(
                point: CGPoint(x: x, y: y),
                windowID: windowID
            )
        }

        switch (section, placement) {
        case (.hidden, .end):
            if let alwaysHiddenDividerBounds {
                return target(
                    x: alwaysHiddenDividerBounds.maxX,
                    y: alwaysHiddenDividerBounds.minY,
                    windowID: alwaysHiddenDivider.windowID
                )
            }
            return target(x: hiddenDivider.minX, y: hiddenDivider.minY, windowID: divider.windowID)
        case (.hidden, .before(let tag)):
            guard let item = items.first(where: { $0.tag == tag }) else { return nil }
            return target(item, x: item.bounds.minX)
        case (.hidden, .after(let tag)):
            guard let item = items.first(where: { $0.tag == tag }) else { return nil }
            return target(item, x: item.bounds.maxX)
        case (.alwaysHidden, .end):
            if let alwaysHiddenDividerBounds {
                return target(
                    x: alwaysHiddenDividerBounds.minX,
                    y: alwaysHiddenDividerBounds.minY,
                    windowID: alwaysHiddenDivider.windowID
                )
            }
            return target(x: hiddenDivider.minX, y: hiddenDivider.minY, windowID: divider.windowID)
        case (.alwaysHidden, .before(let tag)):
            guard let item = items.first(where: { $0.tag == tag }) else { return nil }
            return target(item, x: item.bounds.minX)
        case (.alwaysHidden, .after(let tag)):
            guard let item = items.first(where: { $0.tag == tag }) else { return nil }
            return target(item, x: item.bounds.maxX)
        case (.visible, .end):
            return target(x: hiddenDivider.maxX, y: hiddenDivider.minY, windowID: divider.windowID)
        case (.visible, .before(let tag)):
            guard let item = items.first(where: { $0.tag == tag }) else { return nil }
            return target(item, x: item.bounds.minX)
        case (.visible, .after(let tag)):
            guard let item = items.first(where: { $0.tag == tag }) else { return nil }
            return target(item, x: item.bounds.maxX)
        }
    }

    // MARK: - Click forwarding

    private final class TemporarilyShownItemContext {
        let identity: MenuBarHiddenTemporaryItemIdentity
        let ownerPID: pid_t
        let returnDestination: MenuBarHiddenReturnDestination
        let primaryReturnAnchor: MenuBarHiddenReturnAnchor?
        let fallbackReturnAnchor: MenuBarHiddenReturnAnchor?
        let interfaceOwner: MenuBarItem
        var interfaceWindowID: CGWindowID?
        private var resolvedPopupDetectionPID: pid_t
        let firstShownDate = Date()
        var interfaceDiscoveryDeadline: Date {
            firstShownDate.addingTimeInterval(1)
        }
        var popupDetectionPID: pid_t {
            resolvedPopupDetectionPID
        }
        var rehideAttempts = 0
        var notFoundAttempts = 0
        var nextReturnAttemptDate = Date.distantPast

        init(
            item: MenuBarItem,
            returnDestination: MenuBarHiddenReturnDestination,
            primaryReturnAnchor: MenuBarHiddenReturnAnchor?,
            fallbackReturnAnchor: MenuBarHiddenReturnAnchor?
        ) {
            self.identity = MenuBarHiddenTemporaryItemIdentity(item: item)
            self.ownerPID = item.ownerPID
            self.interfaceOwner = item
            self.returnDestination = returnDestination
            self.primaryReturnAnchor = primaryReturnAnchor
            self.fallbackReturnAnchor = fallbackReturnAnchor
            self.resolvedPopupDetectionPID = MenuBarHiddenTemporaryInterfacePolicy.popupDetectionPID(
                sourcePID: item.sourcePID,
                ownerPID: item.ownerPID
            )
        }

        func updatePopupDetectionPID(from item: MenuBarItem) {
            guard let sourcePID = item.sourcePID else { return }
            resolvedPopupDetectionPID = sourcePID
        }

        func scheduleReturnRetry(after delay: TimeInterval) {
            nextReturnAttemptDate = Date().addingTimeInterval(delay)
        }
    }

    private enum TemporaryRehideResult {
        case returned
        case notFound
        case retryLater
    }

    private enum TemporaryRehideReadiness {
        case ready
        case waitingForInterface
        case waitingForUserInput
        case waitingForRetry
    }

    private struct LiveClickResolution {
        let result: MenuBarHiddenEnumeratorResult
        let layoutItems: [MenuBarItem]
        let item: MenuBarItem
    }

    private func performClick(item: MenuBarItem, button: CGMouseButton) async {
        var shouldRunTemporaryRehideLoopOnExit = false
        defer {
            if shouldRunTemporaryRehideLoopOnExit, !temporarilyShownItemContexts.isEmpty {
                startTemporaryRehideLoop()
            }
        }

        guard var resolution = liveClickResolution(matching: item) else {
            MenuBarHiddenLog.plugin.warning("performClick: missing live item \(item.tag.stableKey)")
            return
        }

        if resolution.item.isOnScreen {
            shouldRunTemporaryRehideLoopOnExit = await clickOnScreenItem(
                resolution.item,
                button: button
            )
            return
        }

        if !temporarilyShownItemContexts.isEmpty {
            guard await prepareForTemporaryShow(replacingExistingContextsUsing: resolution.result) else {
                MenuBarHiddenLog.plugin.warning(
                    "performClick: previous temporary item is still pending; skipping temporary show for \(item.tag.stableKey)"
                )
                return
            }

            guard let refreshedResolution = liveClickResolution(matching: item) else {
                MenuBarHiddenLog.plugin.warning("performClick: missing live item after temporary cleanup \(item.tag.stableKey)")
                return
            }
            resolution = refreshedResolution

            if resolution.item.isOnScreen {
                shouldRunTemporaryRehideLoopOnExit = await clickOnScreenItem(
                    resolution.item,
                    button: button
                )
                return
            }
        }

        guard
            let hiddenDividerBounds = resolution.result.hiddenDividerBounds,
            let originalSection = originalSection(
                for: resolution.item,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: resolution.result.alwaysHiddenDividerBounds
            ),
            let returnDestination = returnDestination(
                for: resolution.item,
                section: originalSection,
                items: resolution.layoutItems,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: resolution.result.alwaysHiddenDividerBounds
            ),
            let showTarget = temporaryShowTarget(
                items: resolution.result.items,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: resolution.result.alwaysHiddenDividerBounds
            )
        else {
            MenuBarHiddenLog.plugin.warning("performClick: could not resolve temporary show target")
            return
        }

        let temporaryContext = TemporarilyShownItemContext(
            item: resolution.item,
            returnDestination: returnDestination.destination,
            primaryReturnAnchor: returnDestination.primaryAnchor,
            fallbackReturnAnchor: returnDestination.fallbackAnchor
        )

        do {
            try await events.move(item: resolution.item, to: showTarget)
        } catch {
            MenuBarHiddenLog.plugin.error("temporary show failed: \(self.localizedDescription(for: error))")
            return
        }

        temporarilyShownItemContexts = [temporaryContext]
        shouldRunTemporaryRehideLoopOnExit = true

        let clickItem = await refreshedClickItem(
            matching: resolution.item,
            previousBounds: resolution.item.bounds
        )
        temporaryContext.updatePopupDetectionPID(from: clickItem)
        try? await Task.sleep(for: .milliseconds(25))
        guard MenuBarHiddenWindowServer.isWindowOnScreen(clickItem.windowID) else {
            MenuBarHiddenLog.plugin.warning("performClick: temporary show did not make item visible \(resolution.item.tag.stableKey)")
            return
        }

        let baselineWindowIDs = Set(MenuBarHiddenWindowServer.onScreenWindowIDs())

        do {
            try await events.click(item: clickItem, button: button)
            temporaryContext.interfaceWindowID = await openedTemporaryInterfaceWindowID(
                afterClickBy: clickItem,
                baselineWindowIDs: baselineWindowIDs
            )
        } catch {
            MenuBarHiddenLog.plugin.error("click failed: \(self.localizedDescription(for: error))")
        }

        rebuildSnapshot()
        refreshIconsIfUIVisible()
    }

    private func liveClickResolution(matching item: MenuBarItem) -> LiveClickResolution? {
        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        let layoutItems = MenuBarHiddenLayoutPolicy.layoutEditorItems(from: result.items)
        guard let liveItem = resolvedLiveItem(matching: item, in: layoutItems) else {
            return nil
        }
        return LiveClickResolution(
            result: result,
            layoutItems: layoutItems,
            item: liveItem
        )
    }

    private func clickOnScreenItem(_ item: MenuBarItem, button: CGMouseButton) async -> Bool {
        let baselineWindowIDs = Set(MenuBarHiddenWindowServer.onScreenWindowIDs())
        do {
            try await events.click(item: item, button: button)
            guard let context = temporarilyShownItemContexts.first(where: {
                contextMatchesItem($0, item: item)
            }) else {
                return false
            }
            context.updatePopupDetectionPID(from: item)
            context.interfaceWindowID = await openedTemporaryInterfaceWindowID(
                afterClickBy: item,
                baselineWindowIDs: baselineWindowIDs
            )
            return true
        } catch {
            MenuBarHiddenLog.plugin.error("click failed: \(self.localizedDescription(for: error))")
            return false
        }
    }

    private func prepareForTemporaryShow(
        replacingExistingContextsUsing result: MenuBarHiddenEnumeratorResult
    ) async -> Bool {
        guard !temporarilyShownItemContexts.isEmpty else { return true }

        stopTemporaryRehideLoop()
        discardReturnedOrMissingTemporaryContexts(using: result)
        guard !temporarilyShownItemContexts.isEmpty else { return true }

        await rehideTemporarilyShownItems(
            force: true,
            isCalledFromTemporarilyShow: true,
            discardsMissingItems: true
        )
        return temporarilyShownItemContexts.isEmpty
    }

    private func discardReturnedOrMissingTemporaryContexts(using result: MenuBarHiddenEnumeratorResult) {
        guard !temporarilyShownItemContexts.isEmpty else { return }
        guard let hiddenDividerBounds = result.hiddenDividerBounds else { return }

        temporarilyShownItemContexts.removeAll { context in
            guard let liveItem = result.items.first(where: {
                contextMatchesItem(context, item: $0)
            }) else {
                return !temporaryContextWindowIsVisible(context)
            }

            return MenuBarHiddenLayoutPolicy.section(
                for: liveItem,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: result.alwaysHiddenDividerBounds
            ) == context.returnDestination.section
        }
    }

    private func resolvedLiveItem(matching item: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItem? {
        if let exact = items.first(where: { $0.windowID == item.windowID }) {
            return exact
        }

        let sourcePID = item.sourcePID ?? item.ownerPID
        return items.first {
            $0.tag.matchesIgnoringWindowID(item.tag)
                && ($0.sourcePID ?? $0.ownerPID) == sourcePID
        }
    }

    private func contextMatchesItem(
        _ context: TemporarilyShownItemContext,
        item: MenuBarItem
    ) -> Bool {
        if context.identity.matches(item) {
            return true
        }
        return item.tag.matchesIgnoringWindowID(context.identity.tag)
            && (item.sourcePID ?? item.ownerPID) == context.popupDetectionPID
    }

    private func originalSection(
        for item: MenuBarItem,
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect?
    ) -> MenuBarHiddenSection? {
        let section = MenuBarHiddenLayoutPolicy.section(
            for: item,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        return section == .visible ? nil : section
    }

    private func returnDestination(
        for item: MenuBarItem,
        section: MenuBarHiddenSection,
        items: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect?
    ) -> (
        destination: MenuBarHiddenReturnDestination,
        primaryAnchor: MenuBarHiddenReturnAnchor?,
        fallbackAnchor: MenuBarHiddenReturnAnchor?
    )? {
        let sectionItems = MenuBarHiddenLayoutPolicy.sectionItems(
            section,
            from: items,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        guard let destination = MenuBarHiddenLayoutPolicy.returnDestination(
            for: item,
            in: sectionItems,
            section: section
        ) else {
            return nil
        }

        let primaryAnchor = anchor(for: destination.placement, in: sectionItems)
        let fallbackAnchor = destination.fallbackPlacement.flatMap { anchor(for: $0, in: sectionItems) }
        return (destination, primaryAnchor, fallbackAnchor)
    }

    private func anchor(
        for placement: MenuBarHiddenMovePlacement,
        in items: [MenuBarItem]
    ) -> MenuBarHiddenReturnAnchor? {
        switch placement {
        case .end:
            return nil
        case .before(let tag), .after(let tag):
            guard let item = items.first(where: { $0.tag.matchesIgnoringWindowID(tag) }) else {
                return nil
            }
            return MenuBarHiddenReturnAnchor(tag: item.tag, sourcePID: item.sourcePID ?? item.ownerPID)
        }
    }

    private func temporaryShowTarget(
        items: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect?
    ) -> MenuBarHiddenResolvedMoveTarget? {
        let visibleAnchor = items.first(where: \.isVisibleControlItem)
            ?? items.first(where: \.isHostApplicationIcon)
        if let visibleAnchor,
           let target = computeMoveTarget(
               section: .visible,
               placement: .before(visibleAnchor.tag),
               items: items,
               hiddenDividerBounds: hiddenDividerBounds,
               alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
           )
        {
            return target
        }

        return computeMoveTarget(
            section: .visible,
            placement: .end,
            items: items,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
    }

    private func refreshedClickItem(
        matching item: MenuBarItem,
        previousBounds: CGRect?
    ) async -> MenuBarItem {
        await waitForItemToLeavePreviousBounds(item, previousBounds: previousBounds)
        await waitForItemPositionToSettle(item)
        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        let sourcePID = item.sourcePID ?? item.ownerPID
        return result.items.first {
            $0.windowID == item.windowID && $0.isOnScreen
        } ?? result.items.first {
            $0.tag.matchesIgnoringWindowID(item.tag)
                && ($0.sourcePID ?? $0.ownerPID) == sourcePID
                && $0.isOnScreen
        } ?? item
    }

    private func waitForItemToLeavePreviousBounds(_ item: MenuBarItem, previousBounds: CGRect?) async {
        guard let previousBounds else {
            try? await Task.sleep(for: .milliseconds(150))
            return
        }

        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            if let bounds = MenuBarHiddenWindowServer.screenRect(for: item.windowID),
               bounds.origin != previousBounds.origin
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func waitForItemPositionToSettle(_ item: MenuBarItem) async {
        let deadline = Date().addingTimeInterval(0.25)
        var previousBounds = MenuBarHiddenWindowServer.screenRect(for: item.windowID)
        var stableReads = 0

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            guard let currentBounds = MenuBarHiddenWindowServer.screenRect(for: item.windowID) else {
                previousBounds = nil
                stableReads = 0
                continue
            }

            if currentBounds == previousBounds {
                stableReads += 1
                if stableReads >= 2 {
                    return
                }
            } else {
                stableReads = 0
            }
            previousBounds = currentBounds
        }
    }

    private func openedTemporaryInterfaceWindowID(
        afterClickBy item: MenuBarItem,
        baselineWindowIDs: Set<CGWindowID>
    ) async -> CGWindowID? {
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            let windowsAfterClick = WindowInfo.createOnScreenWindows()
            if let window = windowsAfterClick.first(where: {
                MenuBarHiddenTemporaryInterfacePolicy.isNewTemporaryInterfaceWindow(
                    $0,
                    item: item,
                    contextWindowID: item.windowID,
                    baselineWindowIDs: baselineWindowIDs
                )
            }) {
                return window.windowID
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }

    private func startTemporaryRehideLoop() {
        guard !temporarilyShownItemContexts.isEmpty else { return }
        temporaryRehideTask?.cancel()
        temporaryRehideTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let isFinished = await self.rehideTemporarilyShownItemsIfReady()
                if isFinished { return }
            }
        }
        temporaryRehideCancellable?.cancel()
        temporaryRehideCancellable = NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.rehideTemporarilyShownItemsIfReady()
                }
            }
    }

    private func stopTemporaryRehideLoop() {
        temporaryRehideTask?.cancel()
        temporaryRehideTask = nil
        temporaryRehideCancellable?.cancel()
        temporaryRehideCancellable = nil
    }

    private func rehideTemporarilyShownItemsIfReady() async -> Bool {
        guard !temporarilyShownItemContexts.isEmpty else {
            stopTemporaryRehideLoop()
            return true
        }

        guard temporaryRehideReadiness() == .ready else {
            return false
        }

        await rehideTemporarilyShownItems()
        return temporarilyShownItemContexts.isEmpty
    }

    private func rehideTemporarilyShownItems(
        force: Bool = false,
        isCalledFromTemporarilyShow: Bool = false,
        discardsMissingItems: Bool = false
    ) async {
        guard !temporarilyShownItemContexts.isEmpty else { return }

        if !force {
            guard temporaryRehideReadiness() == .ready else {
                startTemporaryRehideLoop()
                return
            }
        }

        var pending = temporarilyShownItemContexts
        temporarilyShownItemContexts.removeAll()
        var failed: [TemporarilyShownItemContext] = []

        try? await Task.sleep(
            for: isCalledFromTemporarilyShow ? .milliseconds(50) : .milliseconds(250)
        )

        while let context = pending.popLast() {
            switch await returnTemporarilyShownItem(context) {
            case .returned:
                continue
            case .notFound:
                if discardsMissingItems, !temporaryContextWindowIsVisible(context) {
                    continue
                }
                context.scheduleReturnRetry(after: min(5, 0.5 * Double(max(1, context.notFoundAttempts))))
                failed.append(context)
            case .retryLater:
                if context.rehideAttempts < 3 {
                    pending.append(context)
                } else {
                    context.rehideAttempts = 0
                    context.scheduleReturnRetry(after: 1)
                    failed.append(context)
                }
            }
        }

        temporarilyShownItemContexts = failed.reversed()
        if temporarilyShownItemContexts.isEmpty {
            stopTemporaryRehideLoop()
            updateAlwaysHiddenDividerVisibility()
            try? await Task.sleep(for: .milliseconds(200))
            rebuildSnapshot()
            scheduleAlwaysHiddenItemsRestoreIfNeeded()
            scheduleStoredLayoutRestoreIfNeeded()
            refreshIconsIfUIVisible()
        } else {
            startTemporaryRehideLoop()
        }
    }

    private func temporaryContextWindowIsVisible(_ context: TemporarilyShownItemContext) -> Bool {
        MenuBarHiddenWindowServer.isWindowOnScreen(context.identity.windowID)
    }

    private func hasUserPausedInput() -> Bool {
        NSEvent.modifierFlags.isEmpty
            && !MouseCursorHelper.lastMovementOccurred(within: 0.25)
            && !MouseCursorHelper.lastScrollWheelOccurred(within: 0.25)
            && !MouseCursorHelper.isButtonPressed()
    }

    private func temporaryRehideReadiness() -> TemporaryRehideReadiness {
        if temporarilyShownItemContexts.contains(where: isTemporaryItemInterfaceActive) {
            return .waitingForInterface
        }
        if temporarilyShownItemContexts.contains(where: { $0.nextReturnAttemptDate > Date() }) {
            return .waitingForRetry
        }
        if !hasUserPausedInput() {
            return .waitingForUserInput
        }
        return .ready
    }

    private func isTemporaryItemInterfaceActive(_ context: TemporarilyShownItemContext) -> Bool {
        if let interfaceWindowID = context.interfaceWindowID {
            return isTemporaryInterfaceWindowActive(interfaceWindowID, item: context.interfaceOwner)
        }

        if Date() < context.interfaceDiscoveryDeadline {
            return true
        }

        return false
    }

    private func isTemporaryInterfaceWindowActive(_ windowID: CGWindowID, item: MenuBarItem) -> Bool {
        guard let window = WindowInfo(windowID: windowID) else {
            return false
        }
        return MenuBarHiddenTemporaryInterfacePolicy.isTemporaryInterfaceWindow(window, for: item)
    }

    private func returnTemporarilyShownItem(_ context: TemporarilyShownItemContext) async -> TemporaryRehideResult {
        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        guard let hiddenDividerBounds = result.hiddenDividerBounds else {
            context.rehideAttempts += 1
            return .retryLater
        }
        let layoutItems = MenuBarHiddenLayoutPolicy.layoutEditorItems(from: result.items)
        guard let liveItem = result.items.first(where: {
            contextMatchesItem(context, item: $0)
        }) else {
            context.notFoundAttempts += 1
            return .notFound
        }
        guard let target = returnMoveTarget(
            for: context,
            items: result.items,
            layoutItems: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: result.alwaysHiddenDividerBounds
        ) else {
            context.rehideAttempts += 1
            return .retryLater
        }

        do {
            try await events.move(item: liveItem, to: target)
            if await waitForTemporaryItemReturn(context) {
                context.rehideAttempts = 0
                context.notFoundAttempts = 0
                return .returned
            }
            context.rehideAttempts += 1
            MenuBarHiddenLog.plugin.warning("temporary rehide did not reach target section for \(context.identity.tag.stableKey)")
            return .retryLater
        } catch {
            context.rehideAttempts += 1
            MenuBarHiddenLog.plugin.error("temporary rehide failed: \(self.localizedDescription(for: error))")
            return .retryLater
        }
    }

    private func waitForTemporaryItemReturn(_ context: TemporarilyShownItemContext) async -> Bool {
        let deadline = Date().addingTimeInterval(0.25)
        while true {
            if temporaryItemHasReturned(context) {
                return true
            }
            guard Date() < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func temporaryItemHasReturned(_ context: TemporarilyShownItemContext) -> Bool {
        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        guard let hiddenDividerBounds = result.hiddenDividerBounds else {
            return false
        }
        guard let liveItem = result.items.first(where: {
            contextMatchesItem(context, item: $0)
        }) else {
            return false
        }
        return MenuBarHiddenLayoutPolicy.section(
            for: liveItem,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: result.alwaysHiddenDividerBounds
        ) == context.returnDestination.section
    }

    private func returnMoveTarget(
        for context: TemporarilyShownItemContext,
        items: [MenuBarItem],
        layoutItems: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect?
    ) -> MenuBarHiddenResolvedMoveTarget? {
        let destination = context.returnDestination
        if let target = computeMoveTarget(
            section: destination.section,
            placement: resolvedPlacement(
                destination.placement,
                anchor: context.primaryReturnAnchor,
                items: items
            ),
            items: items,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        ) {
            return target
        }

        if let fallbackPlacement = destination.fallbackPlacement,
           let target = computeMoveTarget(
               section: destination.section,
               placement: resolvedPlacement(
                   fallbackPlacement,
                   anchor: context.fallbackReturnAnchor,
                   items: items
               ),
               items: items,
               hiddenDividerBounds: hiddenDividerBounds,
               alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
           )
        {
            return target
        }

        let sectionItems = MenuBarHiddenLayoutPolicy.sectionItems(
            destination.section,
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        if let anchor = sectionItems.first {
            return computeMoveTarget(
                section: destination.section,
                placement: .before(anchor.tag),
                items: items,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
            )
        }

        return computeMoveTarget(
            section: destination.section,
            placement: .end,
            items: items,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
    }

    private func resolvedPlacement(
        _ placement: MenuBarHiddenMovePlacement,
        anchor: MenuBarHiddenReturnAnchor?,
        items: [MenuBarItem]
    ) -> MenuBarHiddenMovePlacement {
        guard let anchor else {
            return placement
        }

        guard let freshItem = items.first(where: {
            $0.tag.matchesIgnoringWindowID(anchor.tag)
                && ($0.sourcePID ?? $0.ownerPID) == anchor.sourcePID
        }) else {
            return placement
        }

        switch placement {
        case .end:
            return .end
        case .before:
            return .before(freshItem.tag)
        case .after:
            return .after(freshItem.tag)
        }
    }

    // MARK: - Host icon recovery

    private func recoverControlItemOrderIfNeeded(sessionID: Int?) {
        recoverControlItemOrderIfNeeded(target: currentDragTarget, sessionID: sessionID)
    }

    private func recoverControlItemOrderIfNeeded(
        target: MenuBarHiddenMenuBarDragTarget,
        sessionID: Int?
    ) {
        switch target {
        case .hostIcon:
            recoverHostIconIfNeeded(sessionID: sessionID)
        case .divider:
            recoverDividerIfNeeded(sessionID: sessionID)
            recoverAlwaysHiddenDividerIfNeeded(sessionID: sessionID)
        case .unknown:
            recoverHostIconIfNeeded(sessionID: sessionID)
            recoverDividerIfNeeded(sessionID: sessionID)
            recoverAlwaysHiddenDividerIfNeeded(sessionID: sessionID)
        }
    }

    private func recoverHostIconIfNeeded(sessionID: Int? = nil) {
        guard divider.isInstalled else { return }
        if visibleControlItemStoredPositionNeedsRecovery() || hostStatusItemNeedsRecovery() {
            scheduleHostIconRecovery(sessionID: sessionID)
            return
        }

        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        recoverHostIconIfNeeded(items: result.items, hiddenDividerBounds: result.hiddenDividerBounds)
    }

    private func recoverHostIconIfNeeded(items: [MenuBarItem], hiddenDividerBounds: CGRect?) {
        guard
            divider.isInstalled,
            !isDraggingMenuBarItem,
            !isRecoveringControlItemOrder,
            MenuBarHiddenLayoutPolicy.hostIconNeedsRecovery(items: items, hiddenDividerBounds: hiddenDividerBounds)
        else {
            return
        }

        scheduleHostIconRecovery(sessionID: nil)
    }

    private func hostStatusItemNeedsRecovery() -> Bool {
        guard
            divider.isInstalled,
            let dividerFrame = divider.screenFrame,
            let hostFrame = hostStatusItemFrameProvider?()
        else {
            return false
        }

        let verticalOverlap = hostFrame.maxY > dividerFrame.minY && hostFrame.minY < dividerFrame.maxY
        return verticalOverlap && hostFrame.maxX <= dividerFrame.minX
    }

    private func visibleControlItemStoredPositionNeedsRecovery() -> Bool {
        MenuBarControlItemDefaults.visibleControlItemNeedsRecovery()
    }

    private func recoverDividerIfNeeded(sessionID: Int?) {
        guard dividerNeedsRecovery() else { return }
        scheduleDividerRecovery(sessionID: sessionID)
    }

    private func recoverAlwaysHiddenDividerIfNeeded(sessionID: Int?) {
        guard
            store.isAlwaysHiddenEnabled,
            alwaysHiddenDivider.isInstalled,
            !isDraggingMenuBarItem,
            !isRecoveringControlItemOrder
        else {
            return
        }

        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.windowID,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.screenFrame,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        guard MenuBarHiddenLayoutPolicy.alwaysHiddenDividerNeedsRecovery(
            hiddenDividerBounds: result.hiddenDividerBounds,
            alwaysHiddenDividerBounds: result.alwaysHiddenDividerBounds
        ) else {
            return
        }

        scheduleAlwaysHiddenDividerRecovery(sessionID: sessionID)
    }

    private func dividerNeedsRecovery() -> Bool {
        guard
            divider.isInstalled,
            let dividerFrame = divider.screenFrame,
            let hostFrame = hostStatusItemFrameProvider?()
        else {
            return false
        }

        let verticalOverlap = hostFrame.maxY > dividerFrame.minY && hostFrame.minY < dividerFrame.maxY
        return verticalOverlap && dividerFrame.minX >= hostFrame.maxX
    }

    private func dragTarget(at point: NSPoint?) -> MenuBarHiddenMenuBarDragTarget {
        guard let point else { return .unknown }
        if hostStatusItemFrameProvider?().map({ $0.insetBy(dx: -6, dy: -6).contains(point) }) == true {
            return .hostIcon
        }
        if divider.screenFrame.map({ $0.insetBy(dx: -6, dy: -6).contains(point) }) == true {
            return .divider
        }
        return .unknown
    }

    private func startControlItemOrderRecoveryPolling(sessionID: Int) {
        controlItemRecoveryPollTask?.cancel()
        controlItemRecoveryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard self.dragSessionID == sessionID else {
                        self.stopControlItemOrderRecoveryPolling()
                        return
                    }
                    guard self.isDraggingMenuBarItem else {
                        self.stopControlItemOrderRecoveryPolling()
                        return
                    }
                    guard !Self.isLeftMouseButtonPressed else { return }

                    self.isDraggingMenuBarItem = false
                    self.stopControlItemOrderRecoveryPolling()
                    self.scheduleMenuBarDragCommit(
                        target: self.currentDragTarget,
                        sessionID: sessionID
                    )
                    self.currentDragTarget = .unknown
                }
            }
        }
    }

    private func stopControlItemOrderRecoveryPolling() {
        controlItemRecoveryPollTask?.cancel()
        controlItemRecoveryPollTask = nil
    }

    private static var isLeftMouseButtonPressed: Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    private func waitForMenuBarFramesToSettle() async {
        var previousSignature = menuBarFrameSignature()
        var stableReads = 0
        let deadline = Date().addingTimeInterval(0.45)

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }
            let currentSignature = menuBarFrameSignature()
            if currentSignature == previousSignature {
                stableReads += 1
                if stableReads >= 2 {
                    return
                }
            } else {
                stableReads = 0
                previousSignature = currentSignature
            }
        }
    }

    private func menuBarFrameSignature() -> [String] {
        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        return result.items.map { item in
            let bounds = item.bounds.integral
            return "\(item.tag.stableKey):\(Int(bounds.minX)):\(Int(bounds.maxX))"
        }
    }

    private var isMenuBarDragCommitPending: Bool {
        menuBarDragCommitSessionID != nil
    }

    private func scheduleMenuBarDragCommit(target: MenuBarHiddenMenuBarDragTarget, sessionID: Int) {
        cancelMenuBarDragCommit()
        menuBarDragCommitSessionID = sessionID
        menuBarDragCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.waitForMenuBarFramesToSettle()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard
                    self.dragSessionID == sessionID,
                    !self.isDraggingMenuBarItem
                else {
                    self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                    return
                }
                self.commitMenuBarDragLayout(target: target, sessionID: sessionID)
            }
        }
    }

    private func commitMenuBarDragLayout(
        target: MenuBarHiddenMenuBarDragTarget,
        sessionID: Int
    ) {
        let decision = MenuBarHiddenMenuBarDragCommitPolicy.decision(
            target: target,
            dividerNeedsRecovery: dividerNeedsRecovery()
        )

        switch decision {
        case .commit:
            recordStoredLayoutAfterMenuBarDrag()
            finishMenuBarDragCommit(sessionID: sessionID)
        case .recoverThenCommit:
            recoverDividerThenCommitMenuBarDrag(sessionID: sessionID)
        case .recoverOnly:
            recoverControlItemOrderIfNeeded(target: target, sessionID: sessionID)
            if !isRecoveringControlItemOrder {
                finishMenuBarDragCommit(sessionID: sessionID)
            }
        }
    }

    private func cancelMenuBarDragCommit() {
        menuBarDragCommitTask?.cancel()
        menuBarDragCommitTask = nil
        menuBarDragCommitSessionID = nil
    }

    private func isMenuBarDragCommitCurrent(sessionID: Int) -> Bool {
        menuBarDragCommitSessionID == sessionID
    }

    private func clearMenuBarDragCommitIfCurrent(sessionID: Int) {
        guard menuBarDragCommitSessionID == sessionID else { return }
        menuBarDragCommitTask = nil
        menuBarDragCommitSessionID = nil
    }

    private func scheduleHostIconRecovery(sessionID: Int?) {
        guard !isRecoveringControlItemOrder else { return }

        isRecoveringControlItemOrder = true
        controlItemRecoveryTask?.cancel()
        controlItemRecoveryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else {
                        self.isRecoveringControlItemOrder = false
                        self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                        return
                    }
                }
                self.divider.showSection(isDragging: false)
                self.resetHostStatusItemPosition?()
            }

            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else {
                        self.isRecoveringControlItemOrder = false
                        self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                        return
                    }
                }
                self.isRecoveringControlItemOrder = false
                if let sessionID, self.isMenuBarDragCommitCurrent(sessionID: sessionID) {
                    self.finishMenuBarDragCommit(sessionID: sessionID)
                    return
                }
                self.refresh(reason: .hostIconRecovered)
                if self.shouldRestoreHiddenAfterDrag {
                    self.scheduleHiddenRestoreAfterDrag(delay: .milliseconds(250), sessionID: sessionID)
                } else if self.store.isEnabled, self.divider.isInstalled, !self.isDraggingMenuBarItem {
                    self.installAndExpand()
                }
                self.updateAlwaysHiddenDividerVisibility()
            }
        }
    }

    private func scheduleDividerRecovery(sessionID: Int?) {
        guard !isRecoveringControlItemOrder else { return }

        isRecoveringControlItemOrder = true
        controlItemRecoveryTask?.cancel()
        controlItemRecoveryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else {
                        self.isRecoveringControlItemOrder = false
                        self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                        return
                    }
                }
                self.divider.showSection(isDragging: false)
                self.divider.reinstall()
            }

            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else {
                        self.isRecoveringControlItemOrder = false
                        self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                        return
                    }
                }
                self.isRecoveringControlItemOrder = false
                self.refresh(reason: .hostIconRecovered)
                if self.shouldRestoreHiddenAfterDrag {
                    self.scheduleHiddenRestoreAfterDrag(delay: .milliseconds(250), sessionID: sessionID)
                } else if self.store.isEnabled, self.divider.isInstalled, !self.isDraggingMenuBarItem {
                    self.divider.hideSection()
                }
                self.updateAlwaysHiddenDividerVisibility()
            }
        }
    }

    private func recoverDividerThenCommitMenuBarDrag(sessionID: Int) {
        guard !isRecoveringControlItemOrder else { return }

        isRecoveringControlItemOrder = true
        controlItemRecoveryTask?.cancel()
        controlItemRecoveryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.dragSessionID == sessionID else {
                    self.isRecoveringControlItemOrder = false
                    self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                    return
                }
                self.divider.showSection(isDragging: false)
                self.divider.reinstall()
            }

            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.waitForMenuBarFramesToSettle()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard self.dragSessionID == sessionID else {
                    self.isRecoveringControlItemOrder = false
                    self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                    return
                }
                self.isRecoveringControlItemOrder = false
                self.recordStoredLayoutAfterMenuBarDrag()
                self.finishMenuBarDragCommit(sessionID: sessionID)
            }
        }
    }

    private func scheduleAlwaysHiddenDividerRecovery(sessionID: Int?) {
        guard !isRecoveringControlItemOrder else { return }

        isRecoveringControlItemOrder = true
        controlItemRecoveryTask?.cancel()
        controlItemRecoveryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else {
                        self.isRecoveringControlItemOrder = false
                        self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                        return
                    }
                }
                self.alwaysHiddenDivider.showSection(isDragging: false)
                self.divider.showSection(isDragging: false)
            }

            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else {
                        self.isRecoveringControlItemOrder = false
                        self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                        return
                    }
                }

                let result = self.enumerator.enumerate(
                    hiddenDividerWindowID: self.divider.windowID,
                    hiddenDividerFrame: self.divider.screenFrame,
                    alwaysHiddenDividerWindowID: self.alwaysHiddenDivider.windowID,
                    alwaysHiddenDividerFrame: self.alwaysHiddenDivider.screenFrame,
                    excludedWindowIDs: self.excludedControlWindowIDs()
                )
                guard
                    let alwaysHiddenDividerWindowID = self.alwaysHiddenDivider.windowID,
                    let hiddenDividerBounds = result.hiddenDividerBounds,
                    MenuBarHiddenLayoutPolicy.alwaysHiddenDividerNeedsRecovery(
                        hiddenDividerBounds: result.hiddenDividerBounds,
                        alwaysHiddenDividerBounds: result.alwaysHiddenDividerBounds
                    )
                else {
                    self.isRecoveringControlItemOrder = false
                    self.restoreControlItemsAfterAlwaysHiddenRecovery()
                    self.rebuildSnapshot()
                    return
                }

                let controlItem = MenuBarItem(
                    tag: MenuBarItemTag(
                        namespace: "\(ProcessInfo.processInfo.processIdentifier)",
                        title: MenuBarHiddenConstants.alwaysHiddenControlItemTitle,
                        windowID: alwaysHiddenDividerWindowID,
                        instanceIndex: 0
                    ),
                    windowID: alwaysHiddenDividerWindowID,
                    ownerPID: ProcessInfo.processInfo.processIdentifier,
                    bounds: result.alwaysHiddenDividerBounds ?? .zero,
                    title: MenuBarHiddenConstants.alwaysHiddenControlItemTitle,
                    isOnScreen: true
                )
                let target = MenuBarHiddenResolvedMoveTarget(
                    point: CGPoint(x: hiddenDividerBounds.minX, y: hiddenDividerBounds.minY),
                    windowID: self.divider.windowID
                )
                self.controlItemRecoveryTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.events.move(item: controlItem, to: target)
                    } catch {
                        MenuBarHiddenLog.plugin.error(
                            "always-hidden divider recovery failed: \(self.localizedDescription(for: error))"
                        )
                    }

                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        if let sessionID {
                            guard self.dragSessionID == sessionID else {
                                self.isRecoveringControlItemOrder = false
                                self.clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
                                return
                            }
                        }
                        self.isRecoveringControlItemOrder = false
                        self.restoreControlItemsAfterAlwaysHiddenRecovery()
                        self.rebuildSnapshot()
                        self.refreshIconsIfUIVisible()
                    }
                }
            }
        }
    }

    private func recordStoredLayoutAfterMenuBarDrag() {
        guard permissions.canManageItems else { return }

        let result = enumerator.enumerate(
            hiddenDividerWindowID: divider.windowID,
            hiddenDividerFrame: divider.screenFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.windowID : nil,
            alwaysHiddenDividerFrame: alwaysHiddenDivider.isInstalled ? alwaysHiddenDivider.screenFrame : nil,
            excludedWindowIDs: excludedControlWindowIDs()
        )
        guard let hiddenDividerBounds = result.hiddenDividerBounds else {
            return
        }

        let layoutItems = MenuBarHiddenLayoutPolicy.layoutEditorItems(from: result.items)
        let alwaysHiddenDividerBounds: CGRect?
        if store.isAlwaysHiddenEnabled {
            guard let bounds = result.alwaysHiddenDividerBounds else { return }
            alwaysHiddenDividerBounds = bounds
        } else {
            alwaysHiddenDividerBounds = nil
        }
        let visibleItems = MenuBarHiddenLayoutPolicy.visibleItems(
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        let hiddenItems = MenuBarHiddenLayoutPolicy.hiddenItems(
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        let alwaysHiddenItems = MenuBarHiddenLayoutPolicy.alwaysHiddenItems(
            from: layoutItems,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
        let nextVisibleHidden = MenuBarHiddenStoredLayoutPolicy.visibleHiddenLayout(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            alwaysHiddenItems: alwaysHiddenItems,
            previousVisibleItemStableKeys: store.visibleItemStableKeys,
            previousHiddenItemStableKeys: store.hiddenItemStableKeys
        )
        store.recordVisibleHiddenLayout(
            visibleKeys: nextVisibleHidden.visibleItemStableKeys,
            hiddenKeys: nextVisibleHidden.hiddenItemStableKeys
        )

        guard store.isAlwaysHiddenEnabled else { return }

        let currentAlwaysHiddenKeys = Set(alwaysHiddenItems.filter(\.canBeHidden).map(\.tag.stableKey))
        let currentItemKeys = Set(layoutItems.map(\.tag.stableKey))
        let previousKeys = store.alwaysHiddenItemStableKeys
        let keysStillMissing = previousKeys.subtracting(currentItemKeys)
        let nextKeys = keysStillMissing.union(currentAlwaysHiddenKeys)

        guard nextKeys != previousKeys else { return }
        store.alwaysHiddenItemStableKeys = nextKeys
    }

    private func finishMenuBarDragCommit(sessionID: Int) {
        guard dragSessionID == sessionID else {
            clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
            return
        }
        clearMenuBarDragCommitIfCurrent(sessionID: sessionID)
        rebuildSnapshot()
        refreshIconsIfUIVisible()
        if shouldRestoreHiddenAfterDrag {
            scheduleHiddenRestoreAfterDrag(delay: .milliseconds(80), sessionID: sessionID)
        }
        scheduleAlwaysHiddenItemsRestoreIfNeeded(delay: .milliseconds(400))
    }

    private func restoreControlItemsAfterAlwaysHiddenRecovery() {
        if store.isEnabled, divider.isInstalled, !isDraggingMenuBarItem {
            divider.hideSection()
        } else if divider.isInstalled {
            divider.showSection(isDragging: isDraggingMenuBarItem)
        }

        if store.isAlwaysHiddenEnabled {
            if alwaysHiddenDivider.isInstalled {
                alwaysHiddenDivider.hideSection()
            }
        } else {
            alwaysHiddenDivider.uninstall()
        }
    }

    private func scheduleHiddenRestoreAfterDrag(delay: Duration, sessionID: Int?) {
        guard shouldRestoreHiddenAfterDrag else { return }
        hiddenRestoreTask?.cancel()
        hiddenRestoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let sessionID {
                    guard self.dragSessionID == sessionID else { return }
                }
                guard self.shouldRestoreHiddenAfterDrag else { return }
                guard !self.isDraggingMenuBarItem, !self.isRecoveringControlItemOrder else {
                    self.scheduleHiddenRestoreAfterDrag(delay: .milliseconds(250), sessionID: sessionID)
                    return
                }

                self.shouldRestoreHiddenAfterDrag = false
                self.store.isEnabled = true
                self.installAndExpand()
                self.rebuildSnapshot()
                self.scheduleAlwaysHiddenItemsRestoreIfNeeded()
            }
        }
    }

}
