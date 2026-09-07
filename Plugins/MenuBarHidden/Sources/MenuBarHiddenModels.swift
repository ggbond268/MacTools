// SPDX-License-Identifier: GPL-3.0-only
// Copyright (Ice) © 2023–2025 Jordan Baird
// Copyright (Thaw) © 2026 Toni Förster
// Licensed under the GNU GPLv3.
// Adapted from Thaw / Ice; see Sources/Resources/ThirdPartyNotices/manifest.json.
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Foundation
import MacToolsPluginKit

// MARK: - Constants

enum MenuBarHiddenConstants {
    static let pluginID = "menu-bar-hidden"
    static let hiddenControlItemTitle = "MacTools.ControlItem.Hidden"
    static let alwaysHiddenControlItemTitle = "MacTools.ControlItem.AlwaysHidden"
    static let visibleControlItemTitle = "MacTools.ControlItem.Visible"
    /// Pasteboard type for layout-bar drag/drop.
    static let itemPasteboardType = "cc.ggbond.mactools.menu-bar-hidden.item"
    /// CoreGraphics window layer for menu bar status items.
    static let statusMenuWindowLevel: Int = 25
    /// Divider length when expanded (pushes items to its left off-screen).
    static let dividerExpandedLength: CGFloat = 10000
    /// Visible section-divider width used while the hidden section is shown.
    static let dividerVisibleLength: CGFloat = 16
}

// MARK: - MenuBarItemTag

/// Stable identity for a menu bar item across window-ID recycling and app restarts.
struct MenuBarItemTag: Hashable, Equatable, CustomStringConvertible {
    let namespace: String
    let title: String
    let windowID: CGWindowID?
    let instanceIndex: Int

    var description: String { stableKey }
    var stableKey: String {
        if instanceIndex > 0 {
            return "\(namespace):\(title):\(instanceIndex)"
        }
        return "\(namespace):\(title)"
    }

    func matchesIgnoringWindowID(_ other: MenuBarItemTag) -> Bool {
        namespace == other.namespace
            && title == other.title
            && instanceIndex == other.instanceIndex
    }

    var isMovable: Bool {
        !Self.immovableItems.contains { matchesIgnoringWindowID($0) }
    }

    var canBeHidden: Bool {
        !Self.nonHideableItems.contains { matchesIgnoringWindowID($0) }
    }

    var isControlCenterGenericItem: Bool {
        namespace == Self.controlCenterNamespace
            && title.range(of: #"^Item-\d+$"#, options: .regularExpression) != nil
    }

    var isTransientSystemIndicator: Bool {
        Self.transientSystemIndicators.contains { matchesIgnoringWindowID($0) }
    }

    private static let controlCenterNamespace = "com.apple.controlcenter"
    private static let screenCaptureNamespace = "com.apple.screencaptureui"
    private static let ssMenuAgentNamespace = "com.apple.SSMenuAgent"
    private static let gamePolicyAgentNamespace = "GamePolicyAgent"

    private static let clock = MenuBarItemTag(namespace: controlCenterNamespace, title: "Clock", windowID: nil, instanceIndex: 0)
    private static let controlCenter = MenuBarItemTag(namespace: controlCenterNamespace, title: "BentoBox-0", windowID: nil, instanceIndex: 0)
    private static let ssMenuAgent = MenuBarItemTag(namespace: ssMenuAgentNamespace, title: "Item-0", windowID: nil, instanceIndex: 0)
    private static let audioVideoModule = MenuBarItemTag(namespace: controlCenterNamespace, title: "AudioVideoModule", windowID: nil, instanceIndex: 0)
    private static let faceTime = MenuBarItemTag(namespace: controlCenterNamespace, title: "FaceTime", windowID: nil, instanceIndex: 0)
    private static let screenCaptureUI = MenuBarItemTag(namespace: screenCaptureNamespace, title: "Item-0", windowID: nil, instanceIndex: 0)
    private static let gameMode = MenuBarItemTag(namespace: gamePolicyAgentNamespace, title: "Item-0", windowID: nil, instanceIndex: 0)

    private static let immovableItems = [clock, controlCenter, ssMenuAgent]
    private static let nonHideableItems = [audioVideoModule, faceTime, screenCaptureUI, gameMode]
    private static let transientSystemIndicators = [audioVideoModule, faceTime, screenCaptureUI, gameMode]
}

// MARK: - MenuBarItem

struct MenuBarItem: Identifiable, Equatable, Hashable {
    let tag: MenuBarItemTag
    /// Transient CGWindowID — changes between app restarts.
    let windowID: CGWindowID
    let ownerPID: pid_t
    /// The process that created the menu-bar item, when known. On newer macOS
    /// releases WindowServer may report Control Center as the owner for
    /// third-party status items, so this mirrors Thaw's source-process model.
    let sourcePID: pid_t?
    /// Screen-space bounds (CG coordinates, Y-down).
    let bounds: CGRect
    let title: String?
    let isOnScreen: Bool

    init(
        tag: MenuBarItemTag,
        windowID: CGWindowID,
        ownerPID: pid_t,
        sourcePID: pid_t? = nil,
        bounds: CGRect,
        title: String?,
        isOnScreen: Bool
    ) {
        self.tag = tag
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.sourcePID = sourcePID
        self.bounds = bounds
        self.title = title
        self.isOnScreen = isOnScreen
    }

    var id: MenuBarItemTag { tag }

    /// `true` when the item's left edge is on a real display.
    /// Hidden items get pushed to large negative X values by macOS.
    var isHostApplicationIcon: Bool {
        ownerPID == ProcessInfo.processInfo.processIdentifier || isVisibleControlItem
    }

    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    var sourceApplication: NSRunningApplication? {
        sourcePID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    var displayName: String {
        if let app = sourceApplication ?? owningApplication {
            return app.localizedName ?? app.bundleIdentifier ?? title ?? "Menu Bar Item"
        }
        return title ?? "Menu Bar Item"
    }

    var isHiddenControlItem: Bool {
        title == MenuBarHiddenConstants.hiddenControlItemTitle
            || tag.title == MenuBarHiddenConstants.hiddenControlItemTitle
    }

    var isAlwaysHiddenControlItem: Bool {
        title == MenuBarHiddenConstants.alwaysHiddenControlItemTitle
            || tag.title == MenuBarHiddenConstants.alwaysHiddenControlItemTitle
    }

    var isVisibleControlItem: Bool {
        title == MenuBarHiddenConstants.visibleControlItemTitle
            || tag.title == MenuBarHiddenConstants.visibleControlItemTitle
    }

    var isMovable: Bool {
        tag.isMovable
    }

    var isTransientControlCenterItem: Bool {
        tag.isControlCenterGenericItem && sourcePID != nil
    }

    var usesSystemMenuBarInterface: Bool {
        let bundleID = sourceApplication?.bundleIdentifier
            ?? owningApplication?.bundleIdentifier
            ?? tag.namespace
        return MenuBarHiddenTemporaryInterfacePolicy.isSystemMenuBarBundleIdentifier(bundleID)
            || MenuBarHiddenTemporaryInterfacePolicy.isSystemMenuBarOwnerName(title)
            || MenuBarHiddenTemporaryInterfacePolicy.isSystemMenuBarBundleIdentifier(tag.namespace)
    }

    var canBeHidden: Bool {
        tag.canBeHidden && !isHostApplicationIcon && !isTransientControlCenterItem
    }

    var shouldAppearInLayoutEditor: Bool {
        if isHostApplicationIcon { return true }
        return !tag.isTransientSystemIndicator && !isTransientControlCenterItem
    }
}

// MARK: - Section / placement

enum MenuBarHiddenSection: String, Codable, CaseIterable, Equatable {
    case visible
    case hidden
    case alwaysHidden

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .visible:
            localization.string("section.visible", defaultValue: "显示")
        case .hidden:
            localization.string("section.hidden", defaultValue: "隐藏")
        case .alwaysHidden:
            localization.string("section.alwaysHidden", defaultValue: "永久隐藏")
        }
    }
}

enum MenuBarHiddenMovePlacement: Equatable {
    case end
    case before(MenuBarItemTag)
    case after(MenuBarItemTag)
}

enum MenuBarHiddenMenuBarDragTarget: Equatable {
    case hostIcon
    case divider
    case unknown
}

struct MenuBarHiddenResolvedMoveTarget: Equatable {
    let point: CGPoint
    let windowID: CGWindowID?
}

struct MenuBarHiddenReturnDestination: Equatable {
    let placement: MenuBarHiddenMovePlacement
    let fallbackPlacement: MenuBarHiddenMovePlacement?
    let section: MenuBarHiddenSection
}

struct MenuBarHiddenReturnAnchor: Equatable {
    let tag: MenuBarItemTag
    let sourcePID: pid_t?
}

struct MenuBarHiddenTemporaryItemIdentity: Equatable {
    let tag: MenuBarItemTag
    let windowID: CGWindowID
    let sourcePID: pid_t?
    let eventPID: pid_t

    init(item: MenuBarItem) {
        self.tag = item.tag
        self.windowID = item.windowID
        self.sourcePID = item.sourcePID
        self.eventPID = item.sourcePID ?? item.ownerPID
    }

    func matches(_ item: MenuBarItem) -> Bool {
        if item.windowID == windowID {
            return true
        }
        guard item.tag.matchesIgnoringWindowID(tag) else {
            return false
        }
        if let sourcePID {
            return item.sourcePID == sourcePID
                || (item.sourcePID ?? item.ownerPID) == sourcePID
        }
        return (item.sourcePID ?? item.ownerPID) == eventPID
    }
}

enum MenuBarHiddenTemporaryInterfacePolicy {
    static func popupDetectionPID(
        sourcePID: pid_t?,
        ownerPID: pid_t
    ) -> pid_t {
        sourcePID ?? ownerPID
    }

    static func isStandardMenuWindow(_ window: WindowInfo) -> Bool {
        window.isPopupMenuWindow && window.isOnScreen
    }

    static func isSystemMenuBarBundleIdentifier(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "com.apple.controlcenter"
            || bundleID == "com.apple.systemuiserver"
            || bundleID == "com.apple.SystemUIServer"
            || bundleID == "com.apple.SSMenuAgent"
            || bundleID.hasPrefix("com.apple.controlcenter.")
    }

    static func isSystemMenuBarOwnerName(_ ownerName: String?) -> Bool {
        guard let ownerName else { return false }
        return ownerName == "Control Center"
            || ownerName == "SystemUIServer"
            || ownerName == "Window Server"
            || ownerName == "SSMenuAgent"
    }

    static func isSystemMenuBarInterfaceWindow(_ window: WindowInfo) -> Bool {
        guard window.isOnScreen else { return false }
        if window.isPopupMenuWindow || window.isStatusOrMainMenuWindow {
            return true
        }
        guard window.layer > CGWindowLevelForKey(.normalWindow) else {
            return false
        }
        return isSystemMenuBarBundleIdentifier(window.owningApplication?.bundleIdentifier)
            || isSystemMenuBarOwnerName(window.ownerName)
    }

    static func isTemporaryInterfaceWindow(
        _ window: WindowInfo,
        for item: MenuBarItem
    ) -> Bool {
        if isStandardMenuWindow(window) {
            return true
        }
        guard item.usesSystemMenuBarInterface else {
            return false
        }
        return isSystemMenuBarInterfaceWindow(window)
    }

    static func isNewTemporaryInterfaceWindow(
        _ window: WindowInfo,
        item: MenuBarItem,
        contextWindowID: CGWindowID,
        baselineWindowIDs: Set<CGWindowID>
    ) -> Bool {
        guard window.windowID != contextWindowID else {
            return false
        }
        guard !baselineWindowIDs.contains(window.windowID) else {
            return false
        }
        guard isTemporaryInterfaceWindow(window, for: item) else {
            return false
        }
        return true
    }

}

// MARK: - Permissions

struct MenuBarHiddenPermissionsStatus: Equatable {
    var hasAccessibility: Bool
    var hasScreenRecording: Bool

    /// Both permissions are required to drag-reorder items and to forward clicks
    /// from the popup. The hide/show toggle itself works without any permissions.
    var canManageItems: Bool { hasAccessibility && hasScreenRecording }
}

enum MenuBarHiddenSourcePIDResolutionPolicy {
    static func canResolve(permissions: MenuBarHiddenPermissionsStatus) -> Bool {
        permissions.canManageItems
    }
}

enum MenuBarHiddenRunningApplicationPolicy {
    static func uniqueByProcessIdentifier<Value>(
        _ values: [Value],
        processIdentifier: (Value) -> pid_t
    ) -> [Value] {
        var seen = Set<pid_t>()
        return values.compactMap { value in
            let pid = processIdentifier(value)
            guard seen.insert(pid).inserted else { return nil }
            return value
        }
    }
}

// MARK: - Snapshot

struct MenuBarHiddenSnapshot: Equatable {
    var visibleItems: [MenuBarItem]
    var hiddenItems: [MenuBarItem]
    var alwaysHiddenItems: [MenuBarItem]
    var permissions: MenuBarHiddenPermissionsStatus

    static let empty = MenuBarHiddenSnapshot(
        visibleItems: [],
        hiddenItems: [],
        alwaysHiddenItems: [],
        permissions: MenuBarHiddenPermissionsStatus(hasAccessibility: false, hasScreenRecording: false)
    )

    var hiddenCount: Int { hiddenItems.count }
    var allItems: [MenuBarItem] { visibleItems + hiddenItems + alwaysHiddenItems }
}

enum MenuBarHiddenAlwaysHiddenRestorePolicy {
    static func restoreCandidates(
        snapshot: MenuBarHiddenSnapshot,
        recordedStableKeys: Set<String>
    ) -> [MenuBarItem] {
        guard !recordedStableKeys.isEmpty else { return [] }

        let alreadyRestored = Set(snapshot.alwaysHiddenItems.map(\.tag.stableKey))
        return (snapshot.visibleItems + snapshot.hiddenItems).filter { item in
            recordedStableKeys.contains(item.tag.stableKey)
                && !alreadyRestored.contains(item.tag.stableKey)
                && item.canBeHidden
        }
    }
}

struct MenuBarHiddenStoredLayout: Equatable {
    var visibleItemStableKeys: [String]
    var hiddenItemStableKeys: [String]
    var alwaysHiddenItemStableKeys: Set<String>
    var isAlwaysHiddenEnabled: Bool
}

enum MenuBarHiddenStoredLayoutPolicy {
    static func desiredSection(
        for item: MenuBarItem,
        storedLayout: MenuBarHiddenStoredLayout
    ) -> MenuBarHiddenSection {
        guard item.canBeHidden else {
            return .visible
        }

        let key = item.tag.stableKey
        if storedLayout.isAlwaysHiddenEnabled,
           storedLayout.alwaysHiddenItemStableKeys.contains(key)
        {
            return .alwaysHidden
        }
        if storedLayout.visibleItemStableKeys.contains(key) {
            return .visible
        }
        if storedLayout.hiddenItemStableKeys.contains(key) {
            return .hidden
        }
        return .hidden
    }

    static func visibleHiddenLayout(
        visibleItems: [MenuBarItem],
        hiddenItems: [MenuBarItem],
        alwaysHiddenItems: [MenuBarItem],
        previousVisibleItemStableKeys: [String],
        previousHiddenItemStableKeys: [String]
    ) -> (visibleItemStableKeys: [String], hiddenItemStableKeys: [String]) {
        let currentVisibleKeys = stableKeys(for: visibleItems)
        let currentHiddenKeys = stableKeys(for: hiddenItems.filter(\.canBeHidden))
        let currentAlwaysHiddenKeys = stableKeys(for: alwaysHiddenItems.filter(\.canBeHidden))
        let currentKeys = Set(currentVisibleKeys + currentHiddenKeys + currentAlwaysHiddenKeys)

        let missingVisibleKeys = previousVisibleItemStableKeys.filter { !currentKeys.contains($0) }
        let missingHiddenKeys = previousHiddenItemStableKeys.filter { !currentKeys.contains($0) }

        return (
            visibleItemStableKeys: normalizedStableKeys(missingVisibleKeys + currentVisibleKeys),
            hiddenItemStableKeys: normalizedStableKeys(missingHiddenKeys + currentHiddenKeys)
        )
    }

    static func appendNewItemsToHiddenByDefault(
        items: [MenuBarItem],
        storedLayout: MenuBarHiddenStoredLayout
    ) -> (visibleItemStableKeys: [String], hiddenItemStableKeys: [String]) {
        var visibleKeys = storedLayout.visibleItemStableKeys
        var hiddenKeys = storedLayout.hiddenItemStableKeys
        var knownKeys = Set(visibleKeys + hiddenKeys)
        knownKeys.formUnion(storedLayout.alwaysHiddenItemStableKeys)

        for item in items {
            let key = item.tag.stableKey
            guard !knownKeys.contains(key) else { continue }
            knownKeys.insert(key)

            if item.canBeHidden {
                hiddenKeys.append(key)
            } else {
                visibleKeys.append(key)
            }
        }

        return (
            visibleItemStableKeys: normalizedStableKeys(visibleKeys),
            hiddenItemStableKeys: normalizedStableKeys(hiddenKeys)
        )
    }

    private static func stableKeys(for items: [MenuBarItem]) -> [String] {
        normalizedStableKeys(items.map(\.tag.stableKey))
    }

    private static func normalizedStableKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys where !key.isEmpty {
            guard seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }
}

enum MenuBarHiddenLayoutPolicy {
    static func sectionItems(
        _ section: MenuBarHiddenSection,
        from items: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect? = nil
    ) -> [MenuBarItem] {
        items.filter {
            self.section(
                for: $0,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
            ) == section
        }
    }

    static func layoutEditorItems(from items: [MenuBarItem]) -> [MenuBarItem] {
        items.filter(\.shouldAppearInLayoutEditor)
    }

    /// Mirrors Thaw's neighbor-based temporary-show return destination.
    /// Prefer the neighbor on the right, then the neighbor on the left; this
    /// preserves the item's original order when it is moved back after click.
    static func returnDestination(
        for item: MenuBarItem,
        in sectionItems: [MenuBarItem],
        section: MenuBarHiddenSection
    ) -> MenuBarHiddenReturnDestination? {
        guard let index = sectionItems.firstIndex(where: { $0.tag == item.tag }) else {
            return nil
        }

        if sectionItems.indices.contains(index + 1) {
            let neighbor = sectionItems[index + 1]
            let fallback = sectionItems.indices.contains(index - 1)
                ? MenuBarHiddenMovePlacement.after(sectionItems[index - 1].tag)
                : nil
            return MenuBarHiddenReturnDestination(
                placement: .before(neighbor.tag),
                fallbackPlacement: fallback,
                section: section
            )
        }

        if sectionItems.indices.contains(index - 1) {
            return MenuBarHiddenReturnDestination(
                placement: .after(sectionItems[index - 1].tag),
                fallbackPlacement: nil,
                section: section
            )
        }

        return MenuBarHiddenReturnDestination(
            placement: .end,
            fallbackPlacement: nil,
            section: section
        )
    }

    static func visibleItems(
        from items: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect? = nil
    ) -> [MenuBarItem] {
        items.filter {
            section(
                for: $0,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
            ) == .visible
        }
    }

    static func hiddenItems(
        from items: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect? = nil
    ) -> [MenuBarItem] {
        items.filter {
            section(
                for: $0,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
            ) == .hidden
        }
    }

    static func alwaysHiddenItems(
        from items: [MenuBarItem],
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect?
    ) -> [MenuBarItem] {
        guard alwaysHiddenDividerBounds != nil else { return [] }
        return items.filter {
            section(
                for: $0,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
            ) == .alwaysHidden
        }
    }

    static func shouldRejectMoveToSection(item: MenuBarItem, section: MenuBarHiddenSection) -> Bool {
        switch section {
        case .visible:
            false
        case .hidden, .alwaysHidden:
            !item.canBeHidden
        }
    }

    static func hostIconNeedsRecovery(items: [MenuBarItem], hiddenDividerBounds: CGRect?) -> Bool {
        guard let hiddenDividerBounds else { return false }
        return items.contains {
            $0.isHostApplicationIcon && rawSection(
                for: $0,
                hiddenDividerBounds: hiddenDividerBounds,
                alwaysHiddenDividerBounds: nil
            ) != .visible
        }
    }

    static func alwaysHiddenDividerNeedsRecovery(
        hiddenDividerBounds: CGRect?,
        alwaysHiddenDividerBounds: CGRect?
    ) -> Bool {
        guard let hiddenDividerBounds, let alwaysHiddenDividerBounds else {
            return false
        }
        return hiddenDividerBounds.maxX <= alwaysHiddenDividerBounds.minX
    }

    static func section(
        for item: MenuBarItem,
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect? = nil
    ) -> MenuBarHiddenSection {
        if item.isHostApplicationIcon {
            return .visible
        }
        return rawSection(
            for: item,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds
        )
    }

    private static func rawSection(
        for item: MenuBarItem,
        hiddenDividerBounds: CGRect,
        alwaysHiddenDividerBounds: CGRect? = nil
    ) -> MenuBarHiddenSection {
        // Mirrors Thaw's CacheContext.findSection. The hidden divider separates
        // visible from hidden; when present, the always-hidden divider sits to
        // the left of it and separates hidden from permanently hidden.
        if item.bounds.minX >= hiddenDividerBounds.maxX {
            return .visible
        }
        if item.bounds.maxX <= hiddenDividerBounds.minX {
            if let alwaysHiddenDividerBounds {
                if item.bounds.minX >= alwaysHiddenDividerBounds.maxX {
                    return .hidden
                }
                if item.bounds.maxX <= alwaysHiddenDividerBounds.minX {
                    return .alwaysHidden
                }
            } else {
                return .hidden
            }
        }

        let itemMidX = (item.bounds.minX + item.bounds.maxX) / 2
        let hiddenMidX = (hiddenDividerBounds.minX + hiddenDividerBounds.maxX) / 2
        if itemMidX >= hiddenMidX {
            return .visible
        }
        if let alwaysHiddenDividerBounds {
            let alwaysHiddenMidX = (alwaysHiddenDividerBounds.minX + alwaysHiddenDividerBounds.maxX) / 2
            return itemMidX >= alwaysHiddenMidX ? .hidden : .alwaysHidden
        }
        return .hidden
    }
}

enum MenuBarHiddenMenuBarDragCommitPolicy {
    enum Decision: Equatable {
        case commit
        case recoverThenCommit
        case recoverOnly
    }

    static func decision(
        target: MenuBarHiddenMenuBarDragTarget,
        dividerNeedsRecovery: Bool
    ) -> Decision {
        switch target {
        case .hostIcon:
            return .recoverOnly
        case .divider, .unknown:
            return dividerNeedsRecovery ? .recoverThenCommit : .commit
        }
    }
}

enum MenuBarHiddenScreenRecordingPermission {
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

// MARK: - Refresh reason (for diagnostic logs)

enum MenuBarHiddenRefreshReason: CustomStringConvertible {
    case initial
    case settingsAppeared
    case hiddenIconsPanelAppeared
    case appLaunched
    case appTerminated
    case screenChanged
    case spaceChanged
    case dividerMoved
    case dragStarted
    case dragEnded
    case hostIconRecovered
    case permissionChanged
    case afterMove

    var description: String {
        switch self {
        case .initial: "initial"
        case .settingsAppeared: "settingsAppeared"
        case .hiddenIconsPanelAppeared: "hiddenIconsPanelAppeared"
        case .appLaunched: "appLaunched"
        case .appTerminated: "appTerminated"
        case .screenChanged: "screenChanged"
        case .spaceChanged: "spaceChanged"
        case .dividerMoved: "dividerMoved"
        case .dragStarted: "dragStarted"
        case .dragEnded: "dragEnded"
        case .hostIconRecovered: "hostIconRecovered"
        case .permissionChanged: "permissionChanged"
        case .afterMove: "afterMove"
        }
    }
}
