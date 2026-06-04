import AppKit
import OSLog
import SwiftUI

/// A borderless overlay window cannot become key/main by default, which would stop
/// the search field and keyboard navigation from working. Override both.
final class LaunchpadOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Holds the AppKit monitor/observer tokens. Kept in a separate, non–actor-isolated
/// class so its `deinit` can remove them as a backstop (Codex P2 #5) without tripping
/// Swift 6's "non-Sendable access from nonisolated deinit" rule. `removeMonitor` /
/// `removeObserver` are safe to call from any thread.
private final class DismissHandlerTokens {
    var keyMonitor: Any?
    var screenObserver: NSObjectProtocol?
    var resignObserver: NSObjectProtocol?

    func removeAll() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for observer in [screenObserver, resignObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        screenObserver = nil
        resignObserver = nil
    }

    deinit { removeAll() }
}

/// Owns the fullscreen grid overlay window: creation, multi-display placement,
/// dismissal and clean teardown. Mirrors the repo's `PhysicalCleanModeSession`
/// teardown discipline; window config follows the LaunchNext-proven recipe.
@MainActor
final class LaunchpadOverlayController: NSObject, NSWindowDelegate {
    private var window: LaunchpadOverlayWindow?
    private let tokens = DismissHandlerTokens()
    private var isTearingDown = false
    /// App that was frontmost before we activated, so dismissal can hand focus back
    /// (Codex P1 #3). Cleared on launch (the launched app should win focus).
    private var previousApp: NSRunningApplication?

    private let catalog = LaunchpadAppCatalog()
    private let preferences: LaunchpadPreferences
    /// Window mode captured at `open()`. The grid content is rendered against this
    /// snapshot, so frame recomputation (screen changes) must use it too — not live
    /// `preferences`, which could drift mid-session and desync frame vs. content (Codex P2).
    private var sessionMode: LaunchpadPreferences.WindowMode = .fullscreen
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadOverlay"
    )

    init(preferences: LaunchpadPreferences) {
        self.preferences = preferences
        super.init()
    }

    var isShown: Bool { window != nil }

    func toggle() {
        isShown ? close() : open()
    }

    func open() {
        guard window == nil else { return }
        // Restore the *user's* app on dismiss, not ourselves. When triggered from the
        // menu bar, frontmost may already be MacTools; capturing that would make
        // dismissal a no-op (Codex P2). The global-hotkey path captures the real app.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front == .current) ? nil : front
        catalog.reload()
        sessionMode = preferences.windowMode      // snapshot for this session
        let screen = activeScreen()
        let isCompact = sessionMode == .compact
        let frame = targetFrame(on: screen)

        let win = LaunchpadOverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.delegate = self
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = isCompact                  // a floating panel reads better with a shadow
        win.isMovable = false
        win.isReleasedWhenClosed = false          // don't dealloc mid-session
        // Cover the menu bar + Dock + the current (possibly fullscreen) Space, but stay
        // a *launcher*, not a screen-saver shroud. `.popUpMenu` (101) sits above the
        // menu bar (24) and Dock (20) yet well below `.screenSaver` (1000), which Codex
        // (P1 #1) flagged as too heavy for this semantic. `.canJoinAllApplications +
        // .fullScreenAuxiliary` is what lets it join another app's fullscreen Space.
        // Verified on Tahoe covering the full active display (menu bar + Dock) without
        // shrouding the other screen. Coverage over a *fullscreen-app* Space (Safari /
        // video / Metal games) and Stage Manager warrants a wider device sweep; raise the
        // level only if a real fullscreen Space is found to peek through.
        win.level = .popUpMenu
        win.collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.setFrame(frame, display: true)
        let host = NSHostingView(rootView: LaunchpadGridView(
            catalog: catalog,
            columns: preferences.columns,
            isCompact: isCompact,
            hiddenAppIDs: preferences.hiddenAppIDs,
            onActivate: { [weak self] app in self?.launch(app) },
            onReveal: { [weak self] app in self?.reveal(app) },
            onHide: { [weak self] app in self?.preferences.hide(app.id) },
            onDismiss: { [weak self] in self?.close() }
        ))
        win.contentView = host
        if isCompact {
            // Round the floating panel; the material fills the host and is clipped to it.
            host.wantsLayer = true
            host.layer?.cornerRadius = 22
            host.layer?.masksToBounds = true
        }

        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = win
        installDismissHandlers(for: win)
    }

    /// - Parameter restoringFocus: hand focus back to the previously frontmost app.
    ///   `true` for user dismissal (Esc / background / app switch); `false` when an app
    ///   was just launched (it should come forward instead).
    func close(restoringFocus: Bool = true) {
        guard !isTearingDown, let win = window else { return }
        isTearingDown = true
        removeDismissHandlers()
        win.delegate = nil
        win.orderOut(nil)
        win.close()
        window = nil
        if restoringFocus, let previousApp, previousApp != .current {
            previousApp.activate()
        }
        previousApp = nil
        isTearingDown = false
    }

    private func launch(_ app: LaunchpadAppItem) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let logger = logger
        // Dismiss immediately for a Launchpad-snappy feel (we only ever list validated
        // bundles, so failures are rare). On the rare failure, beep + log so the click
        // isn't silent (Codex P1) — the launched app, on success, wins focus itself.
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error {
                // Privacy: never log the full path (it can contain ~/<user>); the bundle
                // name is enough, and the error may itself embed the path so keep it private.
                logger.error("launch failed for \(app.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
                NSSound.beep()
            }
        }
        close(restoringFocus: false)
    }

    private func reveal(_ app: LaunchpadAppItem) {
        // Reveal brings Finder forward, so close without restoring focus (Finder wins).
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
        close(restoringFocus: false)
    }

    /// v1 decision: open on the screen under the mouse (NOT NSScreen.main, NOT all
    /// screens). Documented single-display behavior.
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        // `NSScreen.main` is nil ONLY when no displays are attached, which is exactly when
        // `NSScreen.screens` is empty — so `screens[0]` as a terminal fallback would trap
        // precisely in the state it's meant to cover (e.g. all displays unplugged while the
        // launcher is open → fires via the screen-change observer). End with a degenerate
        // `NSScreen()` instead of an out-of-bounds index (workflow QA).
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen()
    }

    /// Window frame for the current mode: the whole screen (fullscreen) or a centered
    /// floating panel (compact). Used for both initial placement and screen changes.
    private func targetFrame(on screen: NSScreen) -> NSRect {
        guard sessionMode == .compact else { return screen.frame }
        let visible = screen.visibleFrame
        let width = min(960, visible.width * 0.72)
        let height = min(680, visible.height * 0.82)
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Dismissal (Codex P0 #4)

    /// Close on Esc / app deactivation only — NOT on every key/main loss. IME candidate
    /// windows, permission dialogs and Space switches steal key status and must not
    /// dismiss the launcher. Background clicks are handled inside the SwiftUI content.
    ///
    /// Both observers are bound to `session` (the window live when they were installed):
    /// if the user closes and instantly reopens, a queued notification from the old
    /// session no longer matches `self.window` and is dropped (Codex P1 #2). The search
    /// field's own `cancelOperation` is a second Esc path when the field is first
    /// responder, covering activation-failure cases (Codex P2 #4).
    private func installDismissHandlers(for session: LaunchpadOverlayWindow) {
        tokens.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Esc — but not while the search field is mid-IME-composition: there Esc must
            // cancel the candidate window, so let the event through to the field editor
            // (Codex P1). The field editor's own `cancelOperation` still closes us when
            // there's no marked text.
            if event.keyCode == 53 {
                if let editor = self?.window?.firstResponder as? NSTextView, editor.hasMarkedText() {
                    return event
                }
                self?.close()
                return nil
            }
            return event
        }
        tokens.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let win = self.window, win === session else { return }
                win.setFrame(self.targetFrame(on: self.activeScreen()), display: true)
            }
        }
        tokens.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window === session else { return }
                // The user switched away (Cmd+Tab / clicked another app): don't yank focus
                // back to the previously-frontmost app and fight their intent. Only the
                // explicit Esc / background-click paths restore focus.
                self.close(restoringFocus: false)
            }
        }
    }

    private func removeDismissHandlers() {
        tokens.removeAll()
    }
}
