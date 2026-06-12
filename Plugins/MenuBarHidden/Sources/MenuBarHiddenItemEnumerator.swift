import AppKit
import CoreGraphics
import Foundation

// MARK: - EnumeratorResult

struct MenuBarHiddenEnumeratorResult {
    /// All menu bar items found on the active Space
    /// (excludes the plugin's own section dividers).
    var items: [MenuBarItem]
    /// The hidden-section divider's on-screen bounds, when installed.
    var hiddenDividerBounds: CGRect?
    /// The always-hidden-section divider's on-screen bounds, when installed.
    var alwaysHiddenDividerBounds: CGRect?
    var displayID: CGDirectDisplayID
}

// MARK: - MenuBarHiddenItemEnumerator
//
// Enumerates real menu bar items with the same WindowServer list that Thaw uses:
// CGSGetProcessMenuBarWindowList. CGWindowListCopyWindowInfo with
// .optionOnScreenOnly misses hidden items after the divider pushes them to
// negative X positions, so the layout settings list drifts from the real menu
// bar. The CGS list still contains those menu-bar windows, including their
// off-screen bounds.

@MainActor
final class MenuBarHiddenItemEnumerator {
    private let sourcePIDResolver = MenuBarHiddenSourcePIDResolver()

    func enumerate(hiddenDividerWindowID: CGWindowID?, hiddenDividerFrame: NSRect?) -> MenuBarHiddenEnumeratorResult {
        enumerate(
            hiddenDividerWindowID: hiddenDividerWindowID,
            hiddenDividerFrame: hiddenDividerFrame,
            alwaysHiddenDividerWindowID: nil,
            alwaysHiddenDividerFrame: nil,
            excludedWindowIDs: Set([hiddenDividerWindowID].compactMap { $0 })
        )
    }

    func enumerate(
        hiddenDividerWindowID: CGWindowID?,
        hiddenDividerFrame: NSRect?,
        alwaysHiddenDividerWindowID: CGWindowID?,
        alwaysHiddenDividerFrame: NSRect?,
        excludedWindowIDs: Set<CGWindowID>
    ) -> MenuBarHiddenEnumeratorResult {
        let displayID = NSScreen.menuBarScreenDisplayID
        let windows = fetchMenuBarItemWindows()
        guard !windows.isEmpty else {
            return MenuBarHiddenEnumeratorResult(
                items: [],
                hiddenDividerBounds: nil,
                alwaysHiddenDividerBounds: nil,
                displayID: displayID
            )
        }

        let sourcePIDs = sourcePIDResolver.resolveSourcePIDs(for: windows)
        var items = windows.map { makeItem(from: $0, sourcePID: sourcePIDs[$0.windowID]) }

        let hiddenDividerItem = Self.findControlItem(
            in: &items,
            kind: .hidden,
            dividerWindowID: hiddenDividerWindowID,
            dividerFrame: hiddenDividerFrame
        )
        let alwaysHiddenDividerItem = Self.findControlItem(
            in: &items,
            kind: .alwaysHidden,
            dividerWindowID: alwaysHiddenDividerWindowID,
            dividerFrame: alwaysHiddenDividerFrame
        )
        let hiddenDividerBounds = hiddenDividerItem.flatMap { item in
            Self.validBounds(MenuBarHiddenWindowServer.screenRect(for: item.windowID))
                ?? Self.validBounds(item.bounds)
        }
        let alwaysHiddenDividerBounds = alwaysHiddenDividerItem.flatMap { item in
            Self.validBounds(MenuBarHiddenWindowServer.screenRect(for: item.windowID))
                ?? Self.validBounds(item.bounds)
        }
        if (hiddenDividerWindowID != nil || hiddenDividerFrame != nil), hiddenDividerItem == nil {
            MenuBarHiddenLog.plugin.warning(
                "Menu bar hidden divider item was not found; items=\(items.count), dividerWindowID=\(hiddenDividerWindowID ?? 0), dividerFrame=\(String(describing: hiddenDividerFrame))"
            )
        }
        if (alwaysHiddenDividerWindowID != nil || alwaysHiddenDividerFrame != nil), alwaysHiddenDividerItem == nil {
            MenuBarHiddenLog.plugin.warning(
                "Menu bar always-hidden divider item was not found; items=\(items.count), dividerWindowID=\(alwaysHiddenDividerWindowID ?? 0), dividerFrame=\(String(describing: alwaysHiddenDividerFrame))"
            )
        }

        items.removeAll { excludedWindowIDs.contains($0.windowID) }
        assignInstanceIndices(to: &items)

        return MenuBarHiddenEnumeratorResult(
            items: items,
            hiddenDividerBounds: hiddenDividerBounds,
            alwaysHiddenDividerBounds: alwaysHiddenDividerBounds,
            displayID: displayID
        )
    }

    // MARK: - Private helpers

    private func fetchMenuBarItemWindows() -> [WindowInfo] {
        let windowIDs = MenuBarHiddenWindowServer.menuBarWindowIDs(itemsOnly: true, activeSpaceOnly: true)
        return WindowInfo.createWindows(from: windowIDs.reversed())
    }

    private static func validBounds(_ bounds: CGRect?) -> CGRect? {
        guard
            let bounds,
            !bounds.isNull,
            !bounds.isEmpty,
            bounds.minX.isFinite,
            bounds.maxX.isFinite
        else {
            return nil
        }
        return bounds
    }

    private static func findControlItem(
        in items: inout [MenuBarItem],
        kind: MenuBarHiddenDivider.Kind,
        dividerWindowID: CGWindowID?,
        dividerFrame: NSRect?
    ) -> MenuBarItem? {
        if let index = items.firstIndex(where: { item in
            switch kind {
            case .hidden:
                item.isHiddenControlItem
            case .alwaysHidden:
                item.isAlwaysHiddenControlItem
            }
        }) {
            return items.remove(at: index)
        }

        if let dividerWindowID,
           let index = items.firstIndex(where: { $0.windowID == dividerWindowID })
        {
            return items.remove(at: index)
        }

        if let index = spatiallyMatchedDividerIndex(in: items, dividerFrame: dividerFrame) {
            return items.remove(at: index)
        }

        return nil
    }

    private static func spatiallyMatchedDividerIndex(in items: [MenuBarItem], dividerFrame: NSRect?) -> Int? {
        guard
            let dividerFrame,
            let dividerBounds = cgBounds(forAppKitScreenFrame: dividerFrame),
            let dividerCenter = Self.validBounds(dividerBounds)?.center
        else {
            return nil
        }

        let matches = items.indices.compactMap { index -> (index: Int, score: CGFloat)? in
            let item = items[index]
            guard let bounds = Self.validBounds(MenuBarHiddenWindowServer.screenRect(for: item.windowID))
                ?? Self.validBounds(item.bounds)
            else {
                return nil
            }

            let dx = abs(bounds.midX - dividerCenter.x)
            let dy = abs(bounds.midY - dividerCenter.y)
            let horizontalLimit = max(12, min(bounds.width, dividerBounds.width) / 2 + 12)
            let verticalLimit = max(12, max(bounds.height, dividerBounds.height) / 2)
            guard dx <= horizontalLimit, dy <= verticalLimit else {
                return nil
            }

            return (index, dx * 4 + dy)
        }

        return matches.min { $0.score < $1.score }?.index
    }

    private static func cgBounds(forAppKitScreenFrame frame: NSRect) -> CGRect? {
        let rect = CGRect(origin: frame.origin, size: frame.size)
        guard !rect.isNull, !rect.isEmpty else { return nil }

        let screen = NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, rect) < intersectionArea(rhs.frame, rect)
        }

        guard
            let screen,
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
        let y = displayBounds.minY + (screen.frame.maxY - rect.maxY)
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func makeItem(from window: WindowInfo, sourcePID: pid_t?) -> MenuBarItem {
        let title = window.title ?? ""
        let bounds = Self.validBounds(MenuBarHiddenWindowServer.screenRect(for: window.windowID))
            ?? window.bounds
        let namespace = Self.namespace(for: window, sourcePID: sourcePID)
        let tag = MenuBarItemTag(
            namespace: namespace,
            title: title,
            windowID: Self.namespaceIsStable(for: window, sourcePID: sourcePID) ? nil : window.windowID,
            instanceIndex: 0
        )
        return MenuBarItem(
            tag: tag,
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            sourcePID: sourcePID,
            bounds: bounds,
            title: window.title,
            isOnScreen: MenuBarHiddenWindowServer.isWindowOnScreen(window.windowID)
        )
    }

    private static func namespace(for window: WindowInfo, sourcePID: pid_t?) -> String {
        if window.title?.hasPrefix("MacTools.ControlItem.") == true,
           (
               window.ownerPID == ProcessInfo.processInfo.processIdentifier
                   || window.owningApplication?.bundleIdentifier == "com.apple.controlcenter"
           )
        {
            return Bundle.main.bundleIdentifier ?? "MacTools"
        }
        if let sourcePID,
           let app = NSRunningApplication(processIdentifier: sourcePID)
        {
            return app.bundleIdentifier ?? app.localizedName ?? "\(sourcePID)"
        }
        return window.itemNamespace
    }

    private static func namespaceIsStable(for window: WindowInfo, sourcePID: pid_t?) -> Bool {
        if sourcePID != nil { return true }
        return window.namespaceIsStable
    }

    private func assignInstanceIndices(to items: inout [MenuBarItem]) {
        var groups: [String: [Int]] = [:]
        for i in items.indices {
            let key = "\(items[i].tag.namespace):\(items[i].tag.title)"
            groups[key, default: []].append(i)
        }
        for (_, indices) in groups where indices.count > 1 {
            // Sort by windowID for deterministic instance indices regardless of
            // item position changes (e.g. dragging between sections).
            let sorted = indices.sorted { items[$0].windowID < items[$1].windowID }
            for (instanceIndex, itemIndex) in sorted.enumerated() where instanceIndex > 0 {
                let old = items[itemIndex]
                let newTag = MenuBarItemTag(
                    namespace: old.tag.namespace,
                    title: old.tag.title,
                    windowID: old.tag.windowID,
                    instanceIndex: instanceIndex
                )
                items[itemIndex] = MenuBarItem(
                    tag: newTag,
                    windowID: old.windowID,
                    ownerPID: old.ownerPID,
                    sourcePID: old.sourcePID,
                    bounds: old.bounds,
                    title: old.title,
                    isOnScreen: old.isOnScreen
                )
            }
        }
    }
}

// MARK: - WindowInfo

struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
    let title: String?
    let ownerName: String?
    let isOnScreen: Bool

    init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        bounds: CGRect = .zero,
        layer: Int,
        title: String? = nil,
        ownerName: String? = nil,
        isOnScreen: Bool = true
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.title = title
        self.ownerName = ownerName
        self.isOnScreen = isOnScreen
    }

    init?(windowID: CGWindowID) {
        guard let window = WindowInfo.createWindows(from: [windowID]).first
        else {
            return nil
        }
        self = window
    }

    static func createWindows(from windowIDs: some Collection<CGWindowID>) -> [WindowInfo] {
        guard let array = MenuBarHiddenWindowServer.cgWindowArray(with: Array(windowIDs)) else {
            return []
        }
        guard let list = CGWindowListCreateDescriptionFromArray(array) as? [CFDictionary] else {
            MenuBarHiddenLog.plugin.debug(
                "CGWindowListCreateDescriptionFromArray returned no descriptions for \(windowIDs.count) menu bar windows"
            )
            return []
        }

        let windows = list.compactMap { WindowInfo(dictionary: $0) }
        if windows.count != list.count {
            MenuBarHiddenLog.plugin.debug(
                "Created \(windows.count) WindowInfo values from \(list.count) CGWindow descriptions"
            )
        }
        return windows
    }

    static func createOnScreenWindows(excludeDesktopElements: Bool = false) -> [WindowInfo] {
        let windows = createWindows(from: MenuBarHiddenWindowServer.onScreenWindowIDs())
        guard excludeDesktopElements else { return windows }
        return windows.filter { window in
            window.owningApplication?.bundleIdentifier != "com.apple.dock"
        }
    }

    private init?(dictionary: CFDictionary) {
        guard let info = dictionary as? [CFString: Any] else {
            return nil
        }
        guard
            let windowID = info[kCGWindowNumber] as? CGWindowID,
            let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
            let boundsDict = info[kCGWindowBounds] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            let layer = info[kCGWindowLayer] as? Int
        else {
            return nil
        }

        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.title = info[kCGWindowName] as? String
        self.ownerName = info[kCGWindowOwnerName] as? String
        self.isOnScreen = info[kCGWindowIsOnscreen] as? Bool ?? false
    }

    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    var isWindowServerWindow: Bool {
        ownerName == "Window Server"
    }

    var isPopupMenuWindow: Bool {
        let popupLevel = CGWindowLevelForKey(.popUpMenuWindow)
        return layer == popupLevel || layer == popupLevel - 1
    }

    var isStatusOrMainMenuWindow: Bool {
        layer == CGWindowLevelForKey(.statusWindow)
            || layer == CGWindowLevelForKey(.mainMenuWindow)
    }

    var isMenuInterfaceWindow: Bool {
        isPopupMenuWindow || isStatusOrMainMenuWindow
    }

    var isMenuRelated: Bool {
        isMenuInterfaceWindow || isWindowServerWindow
    }

    var itemNamespace: String {
        if let bundleIdentifier = owningApplication?.bundleIdentifier {
            return bundleIdentifier
        }
        if let ownerName, !ownerName.isEmpty {
            return ownerName
        }
        return "\(ownerPID)"
    }

    var namespaceIsStable: Bool {
        owningApplication?.bundleIdentifier != nil || ownerName?.isEmpty == false
    }
}

// MARK: - Source PID resolver

@MainActor
private final class MenuBarHiddenSourcePIDResolver {
    private static let negativeCacheResetInterval: TimeInterval = 300

    private var cachedPIDs: [CGWindowID: pid_t] = [:]
    private var cachedApps: [CachedApplication] = []
    private var lastNegativeCacheReset = Date.distantPast

    func resolveSourcePIDs(for windows: [WindowInfo]) -> [CGWindowID: pid_t] {
        guard AXIsProcessTrusted() else {
            return [:]
        }

        refreshRunningApplications()

        var result = cachedPIDs.filter { cached in
            windows.contains { $0.windowID == cached.key }
        }

        var unresolved = Set(windows.map(\.windowID))
        unresolved.subtract(result.keys)

        for app in cachedApps {
            guard !unresolved.isEmpty else { break }
            guard let menuBar = app.extrasMenuBar() else { continue }

            for child in menuBar.children where child.isEnabled {
                guard let frame = child.frame else { continue }
                guard let match = windows.first(where: {
                    unresolved.contains($0.windowID)
                        && hypot($0.bounds.center.x - frame.center.x, $0.bounds.center.y - frame.center.y) <= 1
                }) else {
                    continue
                }
                result[match.windowID] = app.processIdentifier
                unresolved.remove(match.windowID)
            }
        }

        if !unresolved.isEmpty {
            let markerResolutions = Self.resolveMarkerPairs(
                unresolvedWindows: windows.filter { unresolved.contains($0.windowID) },
                allWindows: windows
            )
            for (windowID, pid) in markerResolutions {
                result[windowID] = pid
                unresolved.remove(windowID)
            }
        }

        cachedPIDs = result
        return result
    }

    private func refreshRunningApplications() {
        let runningApps = NSWorkspace.shared.runningApplications
        let currentPIDs = Set(runningApps.map(\.processIdentifier))
        let shouldResetNegativeCaches = Date().timeIntervalSince(lastNegativeCacheReset) >= Self.negativeCacheResetInterval
        if shouldResetNegativeCaches {
            lastNegativeCacheReset = Date()
        }

        cachedPIDs = cachedPIDs.filter { currentPIDs.contains($0.value) }

        let cachedByPID = Dictionary(uniqueKeysWithValues: cachedApps.map { ($0.processIdentifier, $0) })
        cachedApps = runningApps.map { runningApp in
            if let cached = cachedByPID[runningApp.processIdentifier] {
                if shouldResetNegativeCaches {
                    cached.resetNegativeCache()
                }
                return cached
            }
            return CachedApplication(runningApp)
        }
        cachedApps.sort {
            if $0.hasExtrasMenuBar != $1.hasExtrasMenuBar {
                return $0.hasExtrasMenuBar
            }
            return $0.processIdentifier < $1.processIdentifier
        }
    }

    private static func resolveMarkerPairs(
        unresolvedWindows: [WindowInfo],
        allWindows: [WindowInfo]
    ) -> [CGWindowID: pid_t] {
        let hostBundleID = Bundle.main.bundleIdentifier ?? "MacTools"
        let controlCenterBundleID = "com.apple.controlcenter"
        let markers = allWindows.compactMap { window -> Marker? in
            guard let title = window.title, title.contains(".") else { return nil }
            guard !title.hasPrefix("MacTools.ControlItem."), title != hostBundleID else { return nil }
            return Marker(
                windowID: window.windowID,
                title: title,
                width: window.bounds.width,
                owningPID: window.ownerPID
            )
        }

        var result: [CGWindowID: pid_t] = [:]
        for icon in unresolvedWindows {
            if icon.title?.contains(".") == true { continue }

            let matches = markers.filter {
                $0.windowID != icon.windowID && $0.width == icon.bounds.width
            }
            guard matches.count == 1, let marker = matches.first else { continue }

            let resolvedPID: pid_t? = {
                if let bundleID = NSRunningApplication(processIdentifier: marker.owningPID)?.bundleIdentifier,
                   bundleID != controlCenterBundleID,
                   bundleID != hostBundleID
                {
                    return marker.owningPID
                }
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: marker.title).first,
                   app.bundleIdentifier != hostBundleID
                {
                    return app.processIdentifier
                }
                return nil
            }()

            if let resolvedPID {
                result[icon.windowID] = resolvedPID
            }
        }
        return result
    }

    private struct Marker {
        let windowID: CGWindowID
        let title: String
        let width: CGFloat
        let owningPID: pid_t
    }

    private final class CachedApplication {
        private let runningApp: NSRunningApplication
        private var menuBar: AXUIElement?
        private var checkedWithNoResult = false

        var processIdentifier: pid_t {
            runningApp.processIdentifier
        }

        var hasExtrasMenuBar: Bool {
            menuBar != nil
        }

        init(_ runningApp: NSRunningApplication) {
            self.runningApp = runningApp
        }

        func extrasMenuBar() -> AXUIElement? {
            if let menuBar { return menuBar }
            if checkedWithNoResult { return nil }
            guard runningApp.isFinishedLaunching, !runningApp.isTerminated else { return nil }

            let app = AXUIElementCreateApplication(runningApp.processIdentifier)
            guard let bar = app.copyAttribute(named: kAXExtrasMenuBarAttribute as CFString) else {
                checkedWithNoResult = true
                return nil
            }
            menuBar = bar
            return bar
        }

        func resetNegativeCache() {
            if menuBar == nil {
                checkedWithNoResult = false
            }
        }
    }
}

// MARK: - NSScreen helper

extension NSScreen {
    /// The display showing the active menu bar (always `NSScreen.main` on macOS).
    static var menuBarScreenDisplayID: CGDirectDisplayID {
        MenuBarHiddenWindowServer.activeMenuBarDisplayID() ?? CGMainDisplayID()
    }
}

private extension AXUIElement {
    func copyAttribute(named name: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, name, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    var children: [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, kAXChildrenAttribute as CFString, &value)
        guard result == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    var isEnabled: Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, kAXEnabledAttribute as CFString, &value)
        guard result == .success else { return false }
        return value as? Bool ?? false
    }

    var frame: CGRect? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, "AXFrame" as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue

        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else { return nil }
        return frame
    }
}

// MARK: - WindowServer bridge

enum MenuBarHiddenWindowServer {
    private static let nullConnection: CGSConnectionID = 0

    static func activeMenuBarDisplayID() -> CGDirectDisplayID? {
        guard
            let string = cgsCopyActiveMenuBarDisplayIdentifier(cgsMainConnectionID()),
            let uuid = CFUUIDCreateFromString(nil, string.takeRetainedValue()),
            let displayID = activeDisplayIDs().first(where: { displayID in
                guard let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
                    return false
                }
                return CFEqual(displayUUID, uuid)
            })
        else {
            return CGMainDisplayID()
        }
        return displayID
    }

    static func menuBarWindowIDs(itemsOnly: Bool, activeSpaceOnly: Bool) -> [CGWindowID] {
        guard var count = windowCount() else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        let result = cgsGetProcessMenuBarWindowList(
            cgsMainConnectionID(),
            nullConnection,
            count,
            &list,
            &count
        )
        guard result == .success else {
            MenuBarHiddenLog.plugin.error(
                "CGSGetProcessMenuBarWindowList failed: \(String(describing: result))"
            )
            return []
        }

        var ids = [CGWindowID](list[..<Int(count)])
        if itemsOnly {
            ids = ids.filter { windowID in
                windowLevel(for: windowID).map { $0 != kCGMainMenuWindowLevel } ?? true
            }
        }
        if activeSpaceOnly {
            let activeSpace = cgsGetActiveSpace(cgsMainConnectionID())
            ids = ids.filter { windowID in
                spaces(for: windowID).contains(activeSpace)
            }
        }
        return ids
    }

    static func isWindowOnScreen(_ windowID: CGWindowID) -> Bool {
        guard onScreenWindowIDs().contains(windowID), let bounds = screenRect(for: windowID) else {
            return false
        }
        return activeDisplayIDs().contains { CGDisplayBounds($0).intersects(bounds) }
    }

    static func screenRect(for windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        let result = cgsGetScreenRectForWindow(cgsDefaultConnectionForThread(), windowID, &rect)
        guard result == .success else { return nil }
        return rect
    }

    static func cgWindowArray(with windowIDs: [CGWindowID]) -> CFArray? {
        var pointers: [UnsafeRawPointer?] = windowIDs.compactMap { windowID in
            UnsafeRawPointer(bitPattern: UInt(windowID))
        }
        guard !pointers.isEmpty else {
            return nil
        }

        var callbacks = CFArrayCallBacks(
            version: 0,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil
        )
        return CFArrayCreate(nil, &pointers, pointers.count, &callbacks)
    }

    private static func windowCount() -> Int32? {
        var count: Int32 = 0
        let result = cgsGetWindowCount(cgsMainConnectionID(), nullConnection, &count)
        return result == .success ? count : nil
    }

    private static func onScreenWindowCount() -> Int32? {
        var count: Int32 = 0
        let result = cgsGetOnScreenWindowCount(cgsMainConnectionID(), nullConnection, &count)
        return result == .success ? count : nil
    }

    static func onScreenWindowIDs() -> [CGWindowID] {
        guard var count = onScreenWindowCount() else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        let result = cgsGetOnScreenWindowList(cgsMainConnectionID(), nullConnection, count, &list, &count)
        guard result == .success else { return [] }
        return Array(list[..<Int(count)])
    }

    private static func windowLevel(for windowID: CGWindowID) -> CGWindowLevel? {
        var level: CGWindowLevel = 0
        let result = cgsGetWindowLevel(cgsMainConnectionID(), windowID, &level)
        guard result == .success else { return nil }
        return level
    }

    private static func spaces(for windowID: CGWindowID) -> [CGSSpaceID] {
        guard let spaces = cgsCopySpacesForWindows(
            cgsMainConnectionID(),
            .allSpacesMask,
            [windowID] as CFArray
        ) else {
            return []
        }
        return spaces.takeRetainedValue() as? [CGSSpaceID] ?? []
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &list, nil) == .success else { return [] }
        return list
    }
}

// MARK: - CGS shims

private typealias CGSConnectionID = Int32
private typealias CGSSpaceID = Int

private struct CGSSpaceMask: OptionSet {
    let rawValue: UInt32

    static let includesCurrent = CGSSpaceMask(rawValue: 1 << 0)
    static let includesOthers = CGSSpaceMask(rawValue: 1 << 1)
    static let includesUser = CGSSpaceMask(rawValue: 1 << 2)
    static let allSpacesMask: CGSSpaceMask = [.includesUser, .includesOthers, .includesCurrent]
}

@_silgen_name("CGSMainConnectionID")
private func cgsMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSDefaultConnectionForThread")
private func cgsDefaultConnectionForThread() -> CGSConnectionID

@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier")
private func cgsCopyActiveMenuBarDisplayIdentifier(_ cid: CGSConnectionID) -> Unmanaged<CFString>?

@_silgen_name("CGSGetActiveSpace")
private func cgsGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSCopySpacesForWindows")
private func cgsCopySpacesForWindows(
    _ cid: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windowIDs: CFArray
) -> Unmanaged<CFArray>?

@_silgen_name("CGSGetWindowCount")
private func cgsGetWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowCount")
private func cgsGetOnScreenWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowList")
private func cgsGetOnScreenWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func cgsGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func cgsGetScreenRectForWindow(
    _ cid: CGSConnectionID,
    _ wid: CGWindowID,
    _ outRect: inout CGRect
) -> CGError

@_silgen_name("CGSGetWindowLevel")
private func cgsGetWindowLevel(
    _ cid: CGSConnectionID,
    _ wid: CGWindowID,
    _ outLevel: inout CGWindowLevel
) -> CGError
