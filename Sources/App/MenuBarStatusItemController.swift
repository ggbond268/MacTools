import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarStatusItemInvocation: Hashable {
    case featurePanel
    case componentPanel

    static func invocation(
        for event: NSEvent?,
        swapped: Bool = false
    ) -> MenuBarStatusItemInvocation {
        // A secondary click is a right-click, a Control-click or an
        // Option-click; everything else (including a nil event for
        // programmatic fallback) is a primary click.
        //
        // Option+left exists for macOS 27 beta reachability: the new
        // single-window menu bar host does not route right mouse events to
        // third-party status items at all (verified on 26A5353q), so
        // Option+left is the only pointer channel left for the secondary
        // panel there. It is enabled on every OS as a general enhancement.
        let isSecondary: Bool = {
            guard let event else { return false }
            return event.type == .rightMouseDown
                || event.type == .rightMouseUp
                || event.modifierFlags.contains(.control)
                || event.modifierFlags.contains(.option)
        }()

        let primary: MenuBarStatusItemInvocation = swapped ? .featurePanel : .componentPanel
        let secondary: MenuBarStatusItemInvocation = swapped ? .componentPanel : .featurePanel
        return isSecondary ? secondary : primary
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
                self?.dismissPanels()
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
        }
    }

    func dismissPanels() {
        panelPresenter.dismissPanels()
        removeDismissMonitorsIfNeeded()
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
                self?.dismissPanels()
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
        dismissPanels()

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
        let invocation = MenuBarStatusItemInvocation.invocation(for: currentEvent, swapped: swapped)

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
                    self?.dismissPanels()
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
        dismissPanels()
        return event
    }

    private func dismissPanelsForOutsideClick(
        _ click: MenuBarStatusItemClickIdentity,
        screenLocation: NSPoint
    ) {
        armToggleSuppressionIfNeeded(for: click, screenLocation: screenLocation)
        dismissPanels()
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
