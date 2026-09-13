import AppKit

/// Owns the temporary application focus needed for native preview gestures.
@MainActor
final class WindowSwitcherChooserFocus {
    private let hostPID: pid_t
    private let frontmostPID: () -> pid_t?
    private let activateHost: () -> Void
    private let activateApplication: (pid_t) -> Void
    private var originalPID: pid_t?
    private var acquired = false

    init(
        hostPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        activateHost: @escaping () -> Void = { NSApp.activate() },
        activateApplication: @escaping (pid_t) -> Void = { pid in
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    ) {
        self.hostPID = hostPID
        self.frontmostPID = frontmostPID
        self.activateHost = activateHost
        self.activateApplication = activateApplication
    }

    func prepare() {
        if !acquired {
            originalPID = frontmostPID()
            acquired = true
        }
    }

    func acquire() {
        prepare()
        // AppKit's active/key flags alone do not establish gesture delivery
        // after a nonactivating panel steals keyboard focus.
        activateHost()
    }

    func release(restoring: Bool) {
        defer { acquired = false; originalPID = nil }
        guard acquired, restoring, frontmostPID() == hostPID,
              let originalPID, originalPID != hostPID else { return }
        activateApplication(originalPID)
    }
}
