import AppKit
import QuartzCore

// MARK: - MenuBarStatusItemDiagnostics
//
// DEBUG-only file trace for the status item backing window state. On this
// development setup OSLog from the dev app is not capturable, so this reuses
// the same lightweight /tmp append channel the Launchpad carry trace uses —
// but lives in the App layer (the status item is host infrastructure, not a
// plugin). Used to observe how the macOS 27 beta single-window menu bar host
// evolves across betas: window number / frame / nil at launch and on every
// action delivery.

enum MenuBarStatusItemDiagnostics {
    #if DEBUG
    private static let queue = DispatchQueue(label: "mactools.statusitem-diag", qos: .utility)
    private static let path = "/tmp/mactools-statusitem-diag.log"

    /// Safe to call from `@MainActor` code: the closure is evaluated on the
    /// caller (so it may capture main-actor state), only the resulting string
    /// hops to the utility queue for the file append.
    static func trace(_ line: @autoclosure () -> String) {
        let stamped = "\(String(format: "%.3f", CACurrentMediaTime())) \(line())\n"
        queue.async {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard
                let handle = FileHandle(forWritingAtPath: path),
                let data = stamped.data(using: .utf8)
            else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    @MainActor
    static func describeButtonWindow(_ button: NSStatusBarButton?) -> String {
        guard let button else { return "button=nil" }
        guard let window = button.window else { return "window=nil" }
        let stub = MenuBarStatusItemHostCompatibility.isStubBackingWindow(window)
        return "windowNumber=\(window.windowNumber) frame=\(NSStringFromRect(window.frame)) stub=\(stub)"
    }
    #else
    static func trace(_ line: @autoclosure () -> String) {}

    @MainActor
    static func describeButtonWindow(_ button: NSStatusBarButton?) -> String { "" }
    #endif
}
