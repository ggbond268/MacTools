import AppKit
import Combine
import OSLog
import SwiftUI
import MacToolsPluginKit

enum MenuBarStatusItemInvocation: Hashable {
    case featurePanel
    case componentPanel

    static func invocation(
        for event: NSEvent?,
        swapped: Bool = false,
        liveModifierFlags: NSEvent.ModifierFlags = []
    ) -> MenuBarStatusItemInvocation {
        // A secondary click is a right-click, a Control-click or an
        // Option-click; everything else (including a nil event for
        // programmatic fallback) is a primary click.
        //
        // Option+left exists for macOS 27 beta reachability: the new
        // single-window menu bar host does not route right mouse events to
        // third-party status items at all, so Option+left is the only
        // pointer channel left for the secondary panel there. It is enabled
        // on every OS as a general enhancement.
        //
        // `liveModifierFlags` is the caller-sampled current keyboard state
        // (`NSEvent.modifierFlags` class property). The rehosted menu bar
        // SYNTHESIZES the action's leftMouseUp and strips its modifiers
        // (observed live on 26A5353q: modifiers always 0 even for physical
        // Option-clicks), so the event alone cannot carry the user's intent
        // there — the live keyboard state still can. It is only consulted
        // for user-initiated invocations (non-nil event).
        let isSecondary: Bool = {
            guard let event else { return false }
            return event.type == .rightMouseDown
                || event.type == .rightMouseUp
                || event.modifierFlags.contains(.control)
                || event.modifierFlags.contains(.option)
                || liveModifierFlags.contains(.control)
                || liveModifierFlags.contains(.option)
        }()

        let primary: MenuBarStatusItemInvocation = swapped ? .featurePanel : .componentPanel
        let secondary: MenuBarStatusItemInvocation = swapped ? .componentPanel : .featurePanel
        return isSecondary ? secondary : primary
    }

    /// macOS 27 expanded-interface entry. The didBegin delegate callback
    /// carries no NSEvent, so left vs. right click cannot be distinguished
    /// there at all; the caller-sampled live keyboard state
    /// (`NSEvent.modifierFlags` class property) is the only modifier channel.
    /// Control or Option held at session begin selects the secondary panel,
    /// mirroring the event-based rules above.
    static func invocationForExpandedSession(
        swapped: Bool,
        liveModifierFlags: NSEvent.ModifierFlags
    ) -> MenuBarStatusItemInvocation {
        let isSecondary = liveModifierFlags.contains(.control)
            || liveModifierFlags.contains(.option)
        let primary: MenuBarStatusItemInvocation = swapped ? .featurePanel : .componentPanel
        let secondary: MenuBarStatusItemInvocation = swapped ? .componentPanel : .featurePanel
        return isSecondary ? secondary : primary
    }

    /// macOS 27 secondary-click event-tap entry. A right-click reaches the app
    /// only through the listen-only CGEvent tap there; that path is
    /// unconditionally a secondary gesture, so it always selects the secondary
    /// panel (feature panel by default, dashboard when the click behavior is
    /// swapped).
    static func invocationForSecondaryClickTap(swapped: Bool) -> MenuBarStatusItemInvocation {
        swapped ? .componentPanel : .featurePanel
    }
}

enum MenuBarStatusIconAppearanceRefreshPolicy {
    /// The icon payload depends only on the button's effective appearance, so
    /// when the doubled change channels (undocumented theme notification +
    /// effectiveAppearance KVO fallback) both deliver for one theme switch,
    /// the callback that sees an unchanged name skips the image rebuild.
    static func shouldRefresh(
        currentAppearanceName: NSAppearance.Name?,
        lastAppliedAppearanceName: NSAppearance.Name?
    ) -> Bool {
        currentAppearanceName != lastAppliedAppearanceName
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject {
    private let pluginHost: PluginHost
    private let windowRouter: AppWindowRouter
    private let iconSettings: MenuBarIconSettings
    private var statusItem: NSStatusItem
    private var panelPresenter: MenuBarPanelPresenter!
    private var cancellables: Set<AnyCancellable> = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var statusItemWindowMoveObserver: NSObjectProtocol?
    private var appearanceKVOObservation: NSKeyValueObservation?
    private var lastAppliedAppearanceName: NSAppearance.Name?
    private var toggleSuppressor = MenuBarStatusItemToggleSuppressor()
    // The status item holds its expanded-interface delegate weakly; the
    // controller must own the adapter strongly or callbacks silently stop.
    private let expandedInterfaceAdapter = MenuBarStatusItemExpandedInterfaceAdapter()
    private let expandedSessionCoordinator = MenuBarExpandedSessionCoordinator()
    // macOS 27 only: revives the right-click on our icon (the rehosted menu bar
    // routes it nowhere high-level). nil when uninstalled — no Accessibility
    // trust or tap-create failure — in which case Option+left-click remains the
    // secondary path. Owns its own permission observer so granting/revoking
    // Accessibility at runtime installs/tears down the tap without a relaunch.
    private var secondaryClickTap: MenuBarSecondaryClickTap?
    private var secondaryClickAccessibilityObserver: AccessibilityPermissionObserver?
    // True for the whole lifetime of a panel opened by the right-click tap.
    // While set, the macOS 27 host's expandedInterfaceSession events for that
    // panel are neutralized: a didBegin is adopted (so a later close can cancel
    // the host session) but never re-resolved into a second panel, and a
    // host-initiated didEnd does NOT dismiss — the panel is owned by the tap and
    // the outside-click monitors, not by the host's jittery session lifecycle.
    // Cleared when the panel is actually closed (requestPanelClose/dismissPanels).
    private var secondaryClickPanelActive = false
    private var animationTimer: DispatchSourceTimer?
    private var animationLoadSampleTimer: Timer?
    private let animationLoadMonitor = MenuBarIconAnimationLoadMonitor()
    private var animationFrames: [NSImage] = []
    private var animationFrameIndex = 0
    private var animationBaseFrameDuration: TimeInterval = 1.0 / MenuBarIconProcessing.animationFramesPerSecond
    private var animationSpeedMode: MenuBarIconAnimationSpeedMode = .manual
    private var manualAnimationSpeedMultiplier: Double = MenuBarIconAnimationSpeedPolicy.defaultManualMultiplier
    private var currentAnimationSystemLoad: MenuBarIconAnimationSystemLoad?

    init(
        pluginHost: PluginHost,
        windowRouter: AppWindowRouter,
        iconSettings: MenuBarIconSettings
    ) {
        self.pluginHost = pluginHost
        self.windowRouter = windowRouter
        self.iconSettings = iconSettings
        // Adopt upstream's position-preserving preflight (no longer force-resets the
        // saved icon position on every relaunch — bdd26bb). Keep the beta-27 hit-region
        // fix: create with variableLength (not 0) so the rehosted menu bar host never
        // registers a zero-width hit region; the icon is set right after configuration.
        MenuBarControlItemDefaults.prepareVisibleControlItem()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        super.init()
        panelPresenter = MenuBarPanelPresenter(
            pluginHost: pluginHost,
            onDismiss: { [weak self] in
                self?.requestPanelClose()
            },
            onOpenSettings: { [weak self] in
                self?.windowRouter.showSettings()
            },
            onPresentDiskCleanConfiguration: { [weak self] in
                self?.pluginHost.presentPluginConfiguration(pluginID: "disk-clean")
            },
            onPresentLaunchControlConfiguration: { [weak self] in
                self?.pluginHost.presentPluginConfiguration(pluginID: "launch-control")
            },
            onAllPanelsClosed: { [weak self] in
                self?.removeDismissMonitorsIfNeeded()
            }
        )
        observeStatusItemPositionPersistence()
        configureStatusItem()
        updateStatusIcon()
        observePluginHost()
        observeIconSettings()
        pluginHost.resetStatusItemPosition = { [weak self] in
            self?.resetStatusItemPosition()
        }
        pluginHost.statusItemButtonFrameProvider = { [weak self] in
            self?.statusItemButtonScreenRect()
        }
        MenuBarStatusItemDiagnostics.trace(
            "launch \(MenuBarStatusItemDiagnostics.describeButtonWindow(statusItem.button))"
        )
    }

    private func statusItemButtonScreenRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else {
            MenuBarStatusItemDiagnostics.trace(
                "buttonScreenRect DEGRADED→nil \(MenuBarStatusItemDiagnostics.describeButtonWindow(statusItem.button))"
            )
            return nil
        }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(frameInWindow)
        // macOS 27 beta: the stub backing window still yields a non-nil but
        // degenerate screen rect that drops plugin windows off-screen. Collapse
        // to nil here so DropZoneAnchorProviding consumers reach their
        // centered / default fallback. On macOS 14…26 this never trips (real
        // window, positive-height frame), so the genuine rect is returned.
        if MenuBarStatusItemHostCompatibility.anchorRectDegeneratesToNil(
            screenRectHeight: screenRect.height,
            windowIsStub: MenuBarStatusItemHostCompatibility.isStubBackingWindow(window)
        ) {
            MenuBarStatusItemDiagnostics.trace(
                "buttonScreenRect DEGENERATE→nil rect=\(NSStringFromRect(screenRect)) "
                    + MenuBarStatusItemDiagnostics.describeButtonWindow(button)
            )
            return nil
        }
        return screenRect
    }

    deinit {
        MainActor.assumeIsolated {
            animationTimer?.cancel()
            animationLoadSampleTimer?.invalidate()
            appearanceKVOObservation?.invalidate()
            if let appearanceObserver {
                DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            }
            if let appTerminationObserver {
                NotificationCenter.default.removeObserver(appTerminationObserver)
            }
            if let statusItemWindowMoveObserver {
                NotificationCenter.default.removeObserver(statusItemWindowMoveObserver)
            }
            secondaryClickTap?.stop()
        }
    }

    func dismissPanels() {
        // Backstop: any final close clears the right-click ownership flag, even
        // on paths that reach dismissPanels without going through requestPanelClose.
        secondaryClickPanelActive = false
        panelPresenter.dismissPanels()
        removeDismissMonitorsIfNeeded()
    }

    /// Single close gate for user-driven dismissals. While an expanded
    /// interface session is active the panels must close THROUGH the session:
    /// the macOS 27 host never ends a session on its own (outside clicks do
    /// not produce didEnd), `cancel()` is the only termination, and it fires
    /// didEnd synchronously, which then performs the actual dismissal. With
    /// no active session this is a plain `dismissPanels()`, identical to the
    /// macOS ≤26 behavior.
    private func requestPanelClose() {
        // The panel is closing; from here the host session lifecycle is handled
        // normally again. Cleared BEFORE cancel so the synchronous didEnd it
        // triggers takes the normal dismissing path rather than being ignored.
        secondaryClickPanelActive = false
        expandedSessionCoordinator.requestClose(
            cancel: { session in
                MenuBarStatusItemExpandedInterfaceAdapter.cancel(session: session)
            },
            directDismiss: { [weak self] in
                self?.dismissPanels()
            }
        )
    }

    /// Expanded-interface session begin (macOS 27 host). No NSEvent exists on
    /// this path; the target panel comes from the click-behavior preference
    /// plus the live keyboard state. Presentation reuses the existing toggle
    /// paths so `installDismissMonitorsIfNeeded` keeps owning the close side.
    private func handleExpandedSessionBegin(_ session: NSObject) {
        if secondaryClickPanelActive {
            // While our right-click panel is up the host keeps emitting session
            // begins for it (the initial present side-effect, plus re-begins
            // after its own jittery didEnd). Adopt the session so a later close
            // can cancel it, but never re-resolve the invocation or re-toggle —
            // a host-resolved begin would open a conflicting primary panel.
            if let replaced = expandedSessionCoordinator.sessionDidBegin(session) {
                MenuBarStatusItemExpandedInterfaceAdapter.cancel(session: replaced)
                _ = expandedSessionCoordinator.sessionDidBegin(session)
            }
            MenuBarStatusItemDiagnostics.trace(
                "expanded session adopted by active right-click panel (no re-toggle)"
            )
            return
        }

        if let replacedSession = expandedSessionCoordinator.sessionDidBegin(session) {
            // A superseded session must not stay alive host-side; cancelling
            // fires its didEnd synchronously on this same delegate. didEnd
            // carries no session argument, so that re-entry clears the just
            // stored NEW session from the coordinator — re-begin it once the
            // cancel returns (a re-begin of the identical object is a no-op
            // returning nil, so nothing further gets cancelled).
            MenuBarStatusItemExpandedInterfaceAdapter.cancel(session: replacedSession)
            _ = expandedSessionCoordinator.sessionDidBegin(session)
        }

        if panelPresenter.isAnyPanelShown {
            // Desync guard: a fresh session means the host considers nothing
            // presented, so settle our stale panels before reopening.
            panelPresenter.dismissPanels()
        }

        let swapped = MenuBarClickBehaviorPreference.current().isSwapped
        let invocation = MenuBarStatusItemInvocation.invocationForExpandedSession(
            swapped: swapped,
            liveModifierFlags: NSEvent.modifierFlags
        )
        MenuBarStatusItemDiagnostics.trace(
            "expanded session begin invocation=\(String(describing: invocation)) "
                + MenuBarStatusItemDiagnostics.describeButtonWindow(statusItem.button)
        )

        guard let button = statusItem.button else {
            // Nothing to anchor to. Leaving the session open would make the
            // item permanently inert (no further didBegin until it ends), so
            // close it instead of failing silently.
            AppLog.pluginHost.error(
                "Expanded session began but the status item button is unavailable; cancelling the session"
            )
            requestPanelClose()
            return
        }

        switch invocation {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: button)
        case .componentPanel:
            toggleComponentPanel(relativeTo: button)
        }

        if !panelPresenter.isAnyPanelShown {
            // Presentation failed (the desync guard above closed everything,
            // so the toggle can only have tried to open). A session left open
            // with nothing shown keeps the item inert — no further didBegin
            // arrives until the session ends — so cancel it.
            AppLog.pluginHost.error(
                "Expanded session began but no panel was presented; cancelling the session"
            )
            requestPanelClose()
        }
    }

    /// Expanded-interface session end. Reached synchronously from `cancel()`
    /// inside `requestPanelClose()` (coordinator re-entry guard absorbs the
    /// loop) or directly should the host ever end a session itself.
    private func handleExpandedSessionEnd(animated: Bool) {
        if secondaryClickPanelActive {
            // Host ended the session on its own (lifecycle jitter) while our
            // right-click panel is still up. Clear the coordinator's session
            // WITHOUT dismissing — the panel stays until the user closes it
            // (re-right-click or outside click, both via requestPanelClose).
            expandedSessionCoordinator.sessionDidEnd(dismiss: {})
            MenuBarStatusItemDiagnostics.trace(
                "expanded session end ignored; right-click panel stays"
            )
            return
        }
        expandedSessionCoordinator.sessionDidEnd { [weak self] in
            self?.dismissPanels()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        // OS-gated mask: the macOS 27 beta menu bar host only delivers
        // leftMouseUp (down never arrives → a down-only mask is completely
        // dead there); on older systems the down-mask must stay byte-for-byte
        // identical, because registering down+up would double-trigger.
        let buttonWindowIsStub = MenuBarStatusItemHostCompatibility.isStubBackingWindow(button.window)
        button.sendAction(
            on: MenuBarStatusItemHostCompatibility.sendActionMask(
                buttonWindowIsStub: buttonWindowIsStub,
                isMacOS27OrLater: MenuBarStatusItemHostCompatibility.isMacOS27OrLater
            )
        )
        button.toolTip = AppMetadata.appName

        // macOS 27+ expanded-interface route. Once the delegate is attached
        // the host never invokes the button target/action again (the
        // delegate REPLACES the action channel, it does not augment it), so
        // the action wiring above only serves macOS ≤26 and the
        // attach-failure fallback. On macOS ≤26 the delegate setter selector
        // does not exist, `isSupported` is false, and the action route stays
        // byte-for-byte unchanged. Closures are installed before attaching
        // so no early didBegin can slip through unhandled.
        if MenuBarStatusItemExpandedInterfaceAdapter.isSupported(by: statusItem) {
            expandedInterfaceAdapter.onSessionBegin = { [weak self] session in
                self?.handleExpandedSessionBegin(session)
            }
            expandedInterfaceAdapter.onSessionEnd = { [weak self] animated in
                self?.handleExpandedSessionEnd(animated: animated)
            }
            let attached = expandedInterfaceAdapter.attach(to: statusItem)
            MenuBarStatusItemDiagnostics.trace(
                "expandedInterface attach=\(attached) "
                    + MenuBarStatusItemDiagnostics.describeButtonWindow(statusItem.button)
            )
            if !attached {
                AppLog.pluginHost.warning(
                    "Expanded-interface delegate attach failed; status item falls back to the action route"
                )
            }
        }

        configureSecondaryClickTapIfNeeded()
    }

    /// macOS 27 only: install the listen-only right-click event tap. On macOS
    /// ≤26 the right-click already reaches the action route, so the tap is
    /// never installed and host behavior is byte-for-byte unchanged.
    private func configureSecondaryClickTapIfNeeded() {
        guard #available(macOS 27.0, *) else { return }
        guard secondaryClickTap == nil else { return }

        let tap = MenuBarSecondaryClickTap(
            onSecondaryClick: { [weak self] appKitLocation in
                self?.handleSecondaryClickFromTap(at: appKitLocation)
            },
            // Live frame, never cached: read the button's backing-window frame
            // on every event. NOT statusItemButtonScreenRect() — that collapses
            // to nil under the stub host by design.
            //
            // IMPORTANT (recorded device fact, 26A5353q): on the macOS 27 stub
            // host this raw window frame is degenerate — `(0,0,51,0)`, zero
            // height, origin at (0,0), NOT tracking the icon (see
            // MenuBarStatusItemCompatibility.swift header and
            // docs/superpowers/specs/2026-06-12-macos27-beta-impact.md probe
            // `probe_dropzone_anchor_degradation`). A zero-height frame is
            // rejected by MenuBarSecondaryClickHitTest.isUsableFrame, so the
            // tap fails closed (no hit) and Option+left-click stays the actual
            // secondary path on that seed. The frame source is kept because it
            // is the only API that would yield a real icon rect if a future
            // seed restores a non-stub backing window; the path is fail-safe
            // either way (listen-only, never a false trigger).
            buttonFrameProvider: { [weak self] in
                self?.statusItem.button?.window?.frame
            }
        )

        // Try once now; success depends on Accessibility trust. Whether or not
        // it installs, observe permission changes so a later grant installs the
        // tap (and a revoke tears it down) without relaunching.
        secondaryClickTap = tap
        let started = tap.start()
        MenuBarStatusItemDiagnostics.trace("secondary-click tap configure: start()=\(started) axTrusted=\(AccessibilityCheck.isTrusted())")
        observeAccessibilityForSecondaryClickTap()
    }

    private func observeAccessibilityForSecondaryClickTap() {
        guard secondaryClickAccessibilityObserver == nil else { return }
        let observer = AccessibilityPermissionObserver()
        observer.onPermissionChange = { [weak self] in
            self?.refreshSecondaryClickTapForPermissionChange()
        }
        secondaryClickAccessibilityObserver = observer
    }

    private func refreshSecondaryClickTapForPermissionChange() {
        guard let tap = secondaryClickTap else { return }
        if AccessibilityCheck.isTrusted() {
            tap.start()
        } else {
            tap.stop()
        }
    }

    /// Secondary-click tap fired (macOS 27 right-click on our icon, AppKit
    /// global coordinates). The tap is listen-only and the host gives this path
    /// no expanded-interface session (that is the left-click delegate channel
    /// only), so present directly and close through the same `requestPanelClose`
    /// directDismiss route the outside-click monitors use. The session desync
    /// guard already keeps a later left-click session and this sessionless
    /// present/dismiss from conflicting.
    private func handleSecondaryClickFromTap(at screenLocation: CGPoint) {
        let swapped = MenuBarClickBehaviorPreference.current().isSwapped
        let invocation = MenuBarStatusItemInvocation.invocationForSecondaryClickTap(swapped: swapped)
        MenuBarStatusItemDiagnostics.trace(
            "secondary-click tap invocation=\(String(describing: invocation)) "
                + MenuBarStatusItemDiagnostics.describeButtonWindow(statusItem.button)
        )

        // Stub-host de-dup, mirroring the action route. One physical right-click
        // can reach BOTH this tap and, after it, the async global outside-click
        // monitor or the workspace-activation observer — each can fire
        // `requestPanelClose()` for the SAME click. If one of those closed the
        // panel first, the suppressor (armed on the close, keyed by screen
        // location + time) marks this click's toggle-off as already done so the
        // tap does not re-open it. On healthy hosts nothing is ever armed, so
        // this never matches and behavior is unchanged.
        let identity = MenuBarStatusItemClickIdentity(
            eventNumber: 0,
            timestamp: ProcessInfo.processInfo.systemUptime,
            screenLocation: screenLocation
        )
        if toggleSuppressor.shouldSuppressToggle(for: identity, target: invocation) {
            MenuBarStatusItemDiagnostics.trace(
                "secondary-click tap suppressed: same click already dismissed its target panel"
            )
            return
        }

        if panelPresenter.isAnyPanelShown {
            // Arm suppression for this click before closing so a later
            // monitor/activation close for the same physical right-click is
            // absorbed instead of bouncing the panel back open.
            armToggleSuppressionIfNeeded(for: identity, screenLocation: screenLocation)
            requestPanelClose()
            return
        }

        guard let button = statusItem.button else {
            AppLog.menuBarSecondaryClickTap.error(
                "Secondary-click tap fired but the status item button is unavailable"
            )
            return
        }

        switch invocation {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: button)
        case .componentPanel:
            toggleComponentPanel(relativeTo: button)
        }

        // The panel now belongs to the right-click tap for its whole lifetime;
        // neutralize the host session events it will emit for it (adopted
        // begins, ignored ends) — see secondaryClickPanelActive.
        secondaryClickPanelActive = true
    }

    private func observePluginHost() {
        pluginHost.$hasActivePlugin
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        pluginHost.$settingsPresentationRequestCount
            .dropFirst()
            .sink { [weak self] _ in
                self?.windowRouter.showSettings()
                // Must route through the session gate: this fires while a
                // panel is open (panel gear buttons → presentPluginConfiguration),
                // and a direct dismiss would leave an expanded-interface
                // session active — the host keeps the item inert until that
                // session is cancelled. Without a session this is exactly
                // `dismissPanels()`.
                self?.requestPanelClose()
            }
            .store(in: &cancellables)
    }

    private func observeIconSettings() {
        iconSettings.$settingsRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIconForAppearanceChange()
            }
        }

        // Supported-API fallback for the undocumented notification above:
        // should an OS rename or throttle it, the app-level appearance KVO
        // still reports theme flips. It stays silent when the user pinned the
        // app appearance (effectiveAppearance then never changes), in which
        // case the notification path keeps working as before. Both channels
        // funnel into the same deduplicated refresh.
        appearanceKVOObservation = NSApplication.shared.observe(
            \.effectiveAppearance
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                self?.refreshStatusIconForAppearanceChange()
            }
        }
    }

    private func refreshStatusIconForAppearanceChange() {
        guard MenuBarStatusIconAppearanceRefreshPolicy.shouldRefresh(
            currentAppearanceName: statusItem.button?.effectiveAppearance.name,
            lastAppliedAppearanceName: lastAppliedAppearanceName
        ) else {
            return
        }

        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let appearance = statusItem.button?.effectiveAppearance
        lastAppliedAppearanceName = appearance?.name
        let payload = iconSettings.imagePayload(for: appearance)
        payload.image.isTemplate = payload.isTemplate

        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.image = payload.image
        statusItem.button?.imagePosition = .imageOnly
        configureAnimationIfNeeded(payload)
    }

    private func observeStatusItemPositionPersistence() {
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()
        }

        statusItemWindowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let movedWindowIdentifier = (notification.object as? NSWindow).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                self?.snapshotVisibleControlItemPreferredPositionIfNeeded(
                    forMovedWindowIdentifier: movedWindowIdentifier
                )
            }
        }
    }

    private func snapshotVisibleControlItemPreferredPositionIfNeeded(
        forMovedWindowIdentifier movedWindowIdentifier: ObjectIdentifier?
    ) {
        guard
            let movedWindowIdentifier,
            let statusItemWindow = statusItem.button?.window,
            movedWindowIdentifier == ObjectIdentifier(statusItemWindow)
        else {
            return
        }

        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()
    }

    private func resetStatusItemPosition() {
        // Through the session gate: an active expanded-interface session must
        // be cancelled while its owning item is still alive — cancel's didEnd
        // is synchronous, so the session is fully settled before
        // removeStatusItem below. Without a session this is `dismissPanels()`.
        // (Position reset below uses upstream's resetVisibleControlItemPosition;
        // the old recover-both helper was removed in bdd26bb.)
        requestPanelClose()

        let oldItem = statusItem
        NSStatusBar.system.removeStatusItem(oldItem)
        MenuBarControlItemDefaults.resetVisibleControlItemPosition()
        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()

        // Same as init: variableLength at creation so the registered hit
        // region is never zero width (macOS 27 single-window host).
        let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        newItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        statusItem = newItem

        configureStatusItem()
        updateStatusIcon()
    }

    private func configureAnimationIfNeeded(_ payload: MenuBarIconImagePayload) {
        animationTimer?.cancel()
        animationTimer = nil
        animationLoadSampleTimer?.invalidate()
        animationLoadSampleTimer = nil
        animationFrames = []
        animationFrameIndex = 0
        animationBaseFrameDuration = payload.frameDuration
        animationSpeedMode = payload.speedMode
        manualAnimationSpeedMultiplier = payload.manualSpeedMultiplier
        currentAnimationSystemLoad = nil

        guard payload.isAnimated else {
            return
        }

        animationFrames = payload.animationFrames
        refreshAnimationLoadIfNeeded()
        scheduleAnimationTimer()
        scheduleAnimationLoadSamplingIfNeeded()
    }

    private func scheduleAnimationTimer() {
        animationTimer?.cancel()
        let frameDuration = effectiveAnimationFrameDuration()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + frameDuration,
            repeating: frameDuration,
            leeway: .milliseconds(Int((frameDuration * 500).rounded()))
        )
        timer.setEventHandler { [weak self] in
            self?.advanceAnimationFrame()
        }
        animationTimer = timer
        timer.resume()
    }

    private func scheduleAnimationLoadSamplingIfNeeded() {
        guard animationSpeedMode == .adaptiveSystemLoad else {
            return
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAnimationLoadIfNeeded()
                self?.scheduleAnimationTimer()
            }
        }
        timer.tolerance = 2
        animationLoadSampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshAnimationLoadIfNeeded() {
        guard animationSpeedMode == .adaptiveSystemLoad else {
            return
        }

        currentAnimationSystemLoad = animationLoadMonitor.sample()
    }

    private func effectiveAnimationFrameDuration() -> TimeInterval {
        let multiplier = MenuBarIconAnimationSpeedPolicy.multiplier(
            mode: animationSpeedMode,
            manualMultiplier: manualAnimationSpeedMultiplier,
            systemLoad: currentAnimationSystemLoad
        )
        let normalizedMultiplier = max(multiplier, MenuBarIconAnimationSpeedPolicy.minimumMultiplier)
        return max(animationBaseFrameDuration / normalizedMultiplier, 0.04)
    }

    private func advanceAnimationFrame() {
        guard
            !animationFrames.isEmpty,
            let button = statusItem.button
        else {
            animationTimer?.cancel()
            animationTimer = nil
            animationLoadSampleTimer?.invalidate()
            animationLoadSampleTimer = nil
            return
        }

        animationFrameIndex = (animationFrameIndex + 1) % animationFrames.count
        button.image = animationFrames[animationFrameIndex]
        button.needsDisplay = true
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        let currentEvent = NSApp.currentEvent
        MenuBarStatusItemDiagnostics.trace(
            "action event=\(currentEvent.map { String(describing: $0.type) } ?? "nil") "
                + "modifiers=\(currentEvent?.modifierFlags.rawValue ?? 0) "
                + MenuBarStatusItemDiagnostics.describeButtonWindow(sender)
        )
        // Read the preference live on each click so a settings change takes
        // effect immediately without re-observing.
        let swapped = MenuBarClickBehaviorPreference.current().isSwapped
        let invocation = MenuBarStatusItemInvocation.invocation(
            for: currentEvent,
            swapped: swapped,
            liveModifierFlags: NSEvent.modifierFlags
        )

        // Stub host only: the outside-click monitor may have just dismissed
        // the panels for this same physical click — without button geometry
        // an icon click is indistinguishable from an outside click there.
        // Toggling again would reopen them, making the icon unable to close
        // the panel, so treat this click's toggle-off as already done.
        // Suppression is scoped to the panels that were actually dismissed:
        // a click targeting the other panel is a switch and proceeds. The
        // suppressor is armed exclusively on the geometry-less path, so
        // healthy hosts never match.
        if let currentEvent,
           toggleSuppressor.shouldSuppressToggle(
               for: Self.clickIdentity(of: currentEvent, at: Self.screenLocation(of: currentEvent)),
               target: invocation
           ) {
            MenuBarStatusItemDiagnostics.trace(
                "action suppressed: same click already dismissed its target panel "
                    + "eventNumber=\(currentEvent.eventNumber)"
            )
            return
        }

        // TODO(macOS 27 beta): when the button's backing window is the stub
        // (windowNumber 2^32, zero-height frame), NSPopover anchoring via
        // `show(relativeTo:of:)` may misplace or fail — deliberately NOT
        // reworked yet. Revisit on device once the real popover behavior is
        // observable.
        switch invocation {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: sender)
        case .componentPanel:
            toggleComponentPanel(relativeTo: sender)
        }
    }

    private func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        MenuBarStatusItemDiagnostics.trace(
            "toggleFeaturePanel pre: feature=\(panelPresenter.isFeaturePanelShown) component=\(panelPresenter.isComponentPanelShown)"
        )
        panelPresenter.toggleFeaturePanel(relativeTo: button)
        MenuBarStatusItemDiagnostics.trace(
            "toggleFeaturePanel post: feature=\(panelPresenter.isFeaturePanelShown) component=\(panelPresenter.isComponentPanelShown)"
        )
        handlePresentationResult()
    }

    private func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        MenuBarStatusItemDiagnostics.trace(
            "toggleComponentPanel pre: feature=\(panelPresenter.isFeaturePanelShown) component=\(panelPresenter.isComponentPanelShown)"
        )
        panelPresenter.toggleComponentPanel(relativeTo: button)
        MenuBarStatusItemDiagnostics.trace(
            "toggleComponentPanel post: feature=\(panelPresenter.isFeaturePanelShown) component=\(panelPresenter.isComponentPanelShown)"
        )
        handlePresentationResult()
    }

    private func handlePresentationResult() {
        guard panelPresenter.isAnyPanelShown else {
            return
        }

        installDismissMonitorsIfNeeded()
    }

    private func installDismissMonitorsIfNeeded() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                self?.handleLocalMouseEvent(event) ?? event
            }
        }

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                // Global-monitor events carry no window, so locationInWindow
                // is already in screen coordinates. Reduce the event to
                // Sendable values here; NSEvent must not hop actors.
                let screenLocation = event.locationInWindow
                let click = Self.clickIdentity(of: event, at: screenLocation)
                Task { @MainActor in
                    self?.dismissPanelsForOutsideClick(click, screenLocation: screenLocation)
                }
            }
        }

        if appActivationObserver == nil {
            appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard !Self.isCurrentApplicationActivationNotification(notification) else {
                    return
                }

                Task { @MainActor in
                    self?.armSuppressionForActivationDismissal()
                    self?.requestPanelClose()
                }
            }
        }
    }

    private func removeDismissMonitorsIfNeeded() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent {
        guard panelPresenter.isAnyPanelShown else {
            removeDismissMonitorsIfNeeded()
            return event
        }

        guard !isEventInsidePresentedPanel(event), !isEventInsideStatusButton(event) else {
            return event
        }

        let screenLocation = Self.screenLocation(of: event)
        armToggleSuppressionIfNeeded(
            for: Self.clickIdentity(of: event, at: screenLocation),
            screenLocation: screenLocation
        )
        requestPanelClose()
        return event
    }

    /// Stub host: clicking our own icon can activate the rehosted menu bar's
    /// owning process, so the panels die through this workspace observer
    /// without our event monitors ever seeing the click (observed live on
    /// 26A5353q: silent close, then the forwarded action reopened the panel —
    /// the bounce through a side door). No NSEvent is available here; the
    /// cursor position stands in for the click location — it is still at the
    /// click point when the activation lands, and the suppressor's location
    /// match then decides exactly like the monitored path. Activations not
    /// caused by a menu-bar-band click (Cmd-Tab, desktop click) fail the band
    /// guard or never produce a matching action, so nothing is eaten.
    private func armSuppressionForActivationDismissal() {
        let identity = MenuBarStatusItemClickIdentity(
            eventNumber: 0,
            timestamp: ProcessInfo.processInfo.systemUptime,
            screenLocation: NSEvent.mouseLocation
        )
        armToggleSuppressionIfNeeded(for: identity, screenLocation: identity.screenLocation)
    }

    private func dismissPanelsForOutsideClick(
        _ click: MenuBarStatusItemClickIdentity,
        screenLocation: NSPoint
    ) {
        // A click on our own icon is NOT an outside click — the right-click tap
        // and the action route own it. The global monitor sees the physical
        // right-up of the very click that opened the panel; without this guard
        // it lands here and closes the panel a moment after it opened. The
        // button's backing-window frame is live and valid even on the macOS 27
        // stub (only its windowNumber is fake), unlike statusItemButtonScreenRect()
        // which is deliberately nil there, so the geometry test works here.
        // Event location for a windowless global-monitor event is already in
        // AppKit screen coordinates, matching the window frame.
        if let frame = statusItem.button?.window?.frame,
           !frame.isEmpty, frame.contains(screenLocation) {
            return
        }
        armToggleSuppressionIfNeeded(for: click, screenLocation: screenLocation)
        requestPanelClose()
    }

    /// Stub host only: with no button geometry an icon click is judged an
    /// outside click and dismisses the panels, so the matching action that
    /// follows must not toggle them back open. With a healthy rect the
    /// geometry test already tells icon clicks apart, nothing is armed, and
    /// healthy-host dismissal behavior is untouched.
    private func armToggleSuppressionIfNeeded(
        for click: MenuBarStatusItemClickIdentity,
        screenLocation: NSPoint
    ) {
        guard statusItemButtonScreenRect() == nil else { return }
        guard isScreenLocationInMenuBarBand(screenLocation) else { return }

        // Capture which panels this dismissal is about to close (the caller
        // dismisses right after arming) so the matching action can tell a
        // toggle-off from a switch to the other panel.
        var dismissedPanels = Set<MenuBarStatusItemInvocation>()
        if panelPresenter.isFeaturePanelShown {
            dismissedPanels.insert(.featurePanel)
        }
        if panelPresenter.isComponentPanelShown {
            dismissedPanels.insert(.componentPanel)
        }
        guard !dismissedPanels.isEmpty else { return }

        toggleSuppressor.recordOutsideDismissal(click, dismissedPanels: dismissedPanels)
        MenuBarStatusItemDiagnostics.trace(
            "outside dismissal armed toggle suppression eventNumber=\(click.eventNumber) "
                + "panels=\(dismissedPanels.count)"
        )
    }

    private func isScreenLocationInMenuBarBand(_ screenLocation: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            MenuBarStatusItemClickGeometry.isLocationInMenuBarBand(
                screenLocation,
                screenFrame: screen.frame,
                bandHeight: MenuBarStatusItemClickGeometry.menuBarBandHeight(
                    screenFrameMaxY: screen.frame.maxY,
                    visibleFrameMaxY: screen.visibleFrame.maxY,
                    statusBarThickness: NSStatusBar.system.thickness
                )
            )
        }
    }

    private func isEventInsidePresentedPanel(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else {
            return false
        }

        return panelPresenter.containsPresentedWindow(eventWindow)
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        // Geometry first: the screen-rect containment works regardless of
        // which window the event was routed through. The window-identity
        // comparison remains only as the last resort for a healthy host
        // whose rect is unexpectedly unavailable; on the stub host both
        // signals are gone (rect collapses to nil, identity chain
        // untrustworthy), so this returns false there and the toggle
        // suppressor absorbs the resulting icon-click bounce.
        if let geometricallyInside = MenuBarStatusItemClickGeometry.isLocationInsideButton(
            Self.screenLocation(of: event),
            buttonScreenRect: statusItemButtonScreenRect()
        ) {
            return geometricallyInside
        }

        guard
            let button = statusItem.button,
            event.window === button.window
        else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    nonisolated private static func clickIdentity(
        of event: NSEvent,
        at screenLocation: NSPoint
    ) -> MenuBarStatusItemClickIdentity {
        MenuBarStatusItemClickIdentity(
            eventNumber: event.eventNumber,
            timestamp: event.timestamp,
            screenLocation: screenLocation
        )
    }

    /// `NSEvent.mouseLocation` reads the cursor position at call time, which
    /// may have drifted since the event was generated; deriving the location
    /// from the event itself keeps the judgment tied to the click being
    /// processed. Windowless events (global monitors, some synthesized
    /// events) already carry screen coordinates in `locationInWindow`.
    private static func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else {
            return event.locationInWindow
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    nonisolated private static func isCurrentApplicationActivationNotification(_ notification: Notification) -> Bool {
        guard
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return false
        }

        return activatedApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

}
