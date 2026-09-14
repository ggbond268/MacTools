import AppKit

/// Owns temporary application focus for the chooser and restores its origin on cancellation.
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
        activateHost: @escaping () -> Void = {
            // Cooperative activation can leave an accessory app inactive when
            // invoked from a global shortcut. Request actual foreground ownership
            // through AppKit's public accessibility setter so gestures reach it.
            NSApp.setAccessibilityFrontmost(true)
        },
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
        // The caller orders the panel before requesting activation. Do not
        // activate all host windows or recapture the origin on retry.
        activateHost()
    }

    func release(restoring: Bool) {
        defer { acquired = false; originalPID = nil }
        guard acquired, restoring, frontmostPID() == hostPID,
              let originalPID, originalPID != hostPID else { return }
        activateApplication(originalPID)
    }
}
