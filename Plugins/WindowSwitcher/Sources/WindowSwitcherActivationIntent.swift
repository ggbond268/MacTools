import AppKit

/// Tracks one selection before any asynchronous work or chooser dismissal.
/// An unrelated app activation permanently supersedes this selection, even if
/// the user returns before validation completes. No polling or delay is added.
@MainActor
final class WindowSwitcherActivationIntent {
    let cancellation = WindowSwitcherActionCancellation()
    private let targetPID: pid_t
    private let startingPID: pid_t?
    private let foregroundPID: () -> pid_t?
    private final class Observation {
        let center: NotificationCenter
        let token: NSObjectProtocol
        init(center: NotificationCenter, token: NSObjectProtocol) {
            self.center = center; self.token = token
        }
        deinit { center.removeObserver(token) }
    }
    private var observer: Observation?
    private var reachedTarget = false

    init(targetPID: pid_t,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         foregroundPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.targetPID = targetPID
        self.foregroundPID = foregroundPID
        startingPID = foregroundPID()
        reachedTarget = startingPID == targetPID
        let token = notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.observe(app.processIdentifier) }
            }
        observer = Observation(center: notificationCenter, token: token)
    }

    func finish() {
        observer = nil
    }

    /// Also sample immediately before actions in case notification delivery lags.
    func shouldContinue() -> Bool {
        if Task.isCancelled { cancellation.cancel() }
        if let foreground = foregroundPID() { observe(foreground) }
        return !cancellation.isCancelled
    }

    private func observe(_ pid: pid_t) {
        if pid == targetPID {
            reachedTarget = true
        } else if reachedTarget || pid != startingPID {
            cancellation.cancel()
        }
    }
}
