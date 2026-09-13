import AppKit
import MacToolsPluginKit

/// The host's windows are directly accessible. Avoid self-directed AX requests
/// and never let compositor fallbacks reintroduce our chooser or guide panels.
@MainActor
final class WindowSwitcherHostWindows {
    private struct Record {
        weak var window: NSWindow?
        let id: String
    }
    private var records: [ObjectIdentifier: Record] = [:]
    private let windows: () -> [NSWindow]

    init(windows: @escaping () -> [NSWindow] = { NSApp.windows }) {
        self.windows = windows
    }

    static func isEligible(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
            && window.canBecomeMain && (window.isVisible || window.isMiniaturized)
            && window.windowNumber > 0
    }

    func reset() { records.removeAll() }

    func entries() -> [WindowSwitcherAppEntry] {
        let app = NSRunningApplication.current
        let eligible = windows().filter(Self.isEligible)
        let live = Set(eligible.map(ObjectIdentifier.init))
        records = records.filter { live.contains($0.key) && $0.value.window != nil }
        return eligible.map { window in
            let key = ObjectIdentifier(window)
            let record = records[key] ?? Record(window: window, id: "window:host:\(UUID())")
            records[key] = record
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let bounds = CGRect(x: window.frame.minX, y: top - window.frame.maxY,
                                width: window.frame.width, height: window.frame.height)
            let screen = window.screen
            return WindowSwitcherAppEntry(id: record.id, processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "MacTools",
                windowTitle: window.title, icon: app.icon, windowElement: nil,
                isMinimized: window.isMiniaturized, windowNumber: CGWindowID(window.windowNumber),
                applicationLaunchDate: app.launchDate, shortcutToken: nil, bounds: bounds,
                isHidden: app.isHidden, displayNameContext: screen?.localizedName,
                displayID: (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
        }
    }

    var focusedID: String? {
        records.values.first { $0.window?.isKeyWindow == true }?.id
    }

    func window(for entry: WindowSwitcherAppEntry) -> NSWindow? {
        guard entry.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let record = records.values.first(where: { $0.id == entry.id }),
              let window = record.window, Self.isEligible(window),
              windows().contains(where: { $0 === window }) else { return nil }
        return window
    }

    func activate(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let window = window(for: entry) else { return .unavailable }
        let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        PluginPresentationSafety.prepareForWindowOrdering(window)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Activation settles asynchronously, particularly for accessory apps.
        // Observe one request; never repeatedly raise a window over new user intent.
        let deadline = ContinuousClock.now + .milliseconds(400)
        repeat {
            guard !Task.isCancelled else { return .cancelled }
            guard self.window(for: entry) === window else { return .unavailable }
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard foreground == originalForeground || foreground == entry.processIdentifier || foreground == nil else {
                return .cancelled
            }
            if window.isKeyWindow && NSApp.isActive { return .succeeded }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return .cancelled }
        } while ContinuousClock.now < deadline
        return .failed
    }

    func close(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult {
        guard let window = window(for: entry) else { return .unavailable }
        guard window.styleMask.contains(.closable) else { return .unavailable }
        window.performClose(nil)
        return .requested
    }
}
