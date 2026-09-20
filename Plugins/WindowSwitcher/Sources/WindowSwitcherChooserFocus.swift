import AppKit
import MacToolsPluginKit

/// Owns temporary application focus for the chooser and restores its origin on cancellation.
@MainActor
final class WindowSwitcherChooserFocus {
    private let activateHost: () -> Void
    private let restoration: PluginPanelFocusRestoration
    private var isPrepared = false

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
        self.activateHost = activateHost
        restoration = PluginPanelFocusRestoration(
            captureRestoration: {
                guard let pid = frontmostPID(), pid != hostPID else { return nil }
                return { activateApplication(pid) }
            },
            canRestore: { frontmostPID() == hostPID }
        )
    }

    func prepare() {
        isPrepared = true
        restoration.prepareForPresentation()
    }

    func acquire() {
        prepare()
        activateHost()
    }

    func release(restoring: Bool) {
        restoration.dismiss(wasVisible: isPrepared, restoringFocus: restoring)
        isPrepared = false
    }
}
