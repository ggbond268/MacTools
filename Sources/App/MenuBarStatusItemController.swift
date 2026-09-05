import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarStatusItemInvocation: Equatable {
    case featurePanel
    case componentPanel

    static func invocation(
        for event: NSEvent?,
        swapped: Bool = false
    ) -> MenuBarStatusItemInvocation {
        // Option+left-click always triggers the right-click action.
        let isSecondary: Bool = {
            guard let event else { return false }
            let isLeftClick = event.type == .leftMouseDown || event.type == .leftMouseUp
            if isLeftClick, event.modifierFlags.contains(.option) {
                return true
            }
            return event.type == .rightMouseDown || event.type == .rightMouseUp
        }()

        let primary: MenuBarStatusItemInvocation = swapped ? .featurePanel : .componentPanel
        let secondary: MenuBarStatusItemInvocation = swapped ? .componentPanel : .featurePanel
        return isSecondary ? secondary : primary
    }
}

enum MenuBarStatusItemPresentationAction: Equatable {
    case presentSettings(SettingsPresentationRequest)
    case toggleCommandPalette
    case toggleComponentPanel
    case toggleFeaturePanel
    case showComponentPanel
    case showFeaturePanel
    case showUnifiedSearch

    init(request: AppPresentationRequest) {
        switch request {
        case let .settings(settingsRequest):
            self = .presentSettings(settingsRequest)
        case .toggleCommandPalette:
            self = .toggleCommandPalette
        case .toggleDashboard:
            self = .toggleComponentPanel
        case .toggleFeaturePanel:
            self = .toggleFeaturePanel
        case .showDashboard:
            self = .showComponentPanel
        case .showFeaturePanel:
            self = .showFeaturePanel
        case .showUnifiedSearch:
            self = .showUnifiedSearch
        }
    }
}

struct MenuBarGlobalMouseEvent: Equatable, Sendable {
    let screenX: Double
    let screenY: Double
}

enum MenuBarGlobalMouseEventPolicy {
    static func isStatusItemClick(
        for event: MenuBarGlobalMouseEvent,
        buttonFrame: NSRect?
    ) -> Bool {
        let location = NSPoint(x: event.screenX, y: event.screenY)
        guard let buttonFrame, !buttonFrame.isEmpty else { return false }
        return buttonFrame.contains(location)
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
    private var animationTimer: DispatchSourceTimer?
    private var animationFrames: [NSImage] = []
    private var animationFrameIndex = 0
    private var animationFrameDuration: TimeInterval = 1.0 / MenuBarIconProcessing.animationFramesPerSecond

    init(
        pluginHost: PluginHost,
        windowRouter: AppWindowRouter,
        appUpdater: AppUpdater,
        iconSettings: MenuBarIconSettings,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared
    ) {
        self.pluginHost = pluginHost
        self.windowRouter = windowRouter
        self.iconSettings = iconSettings
        MenuBarControlItemDefaults.prepareVisibleControlItem()
        PluginPresentationSafety.prepareForWindowOrdering()
        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        super.init()
        panelPresenter = MenuBarPanelPresenter(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarPanelThemeStore: menuBarPanelThemeStore,
            onDismiss: { [weak self] in
                self?.requestPanelClose()
            },
            onOpenUpdate: { [weak self] in
                self?.windowRouter.presentSettings(.appUpdate)
            },
            onOpenSettings: { [weak self] in
                self?.windowRouter.showSettings()
            },
            onOpenUnifiedSearch: { [weak self] in
                self?.windowRouter.showUnifiedSearch()
            },
            onPresentDiskCleanConfiguration: { [weak self] in
                self?.pluginHost.presentPluginSettings(pluginID: "disk-clean")
            },
            onPresentLaunchControlConfiguration: { [weak self] in
                self?.pluginHost.presentPluginSettings(pluginID: "launch-control")
            },
            onAllPanelsClosed: { [weak self] in
                self?.removeDismissMonitorsIfNeeded()
            }
        )
        observeStatusItemPositionPersistence()
        configureStatusItem()
        observePluginHost()
        observeIconSettings()
        updateStatusIcon()
        pluginHost.resetStatusItemPosition = { [weak self] in
            self?.resetStatusItemPosition()
        }
        pluginHost.statusItemButtonFrameProvider = { [weak self] in
            self?.statusItemButtonScreenRect()
        }
        windowRouter.setPanelPresentationActions(
            showDashboard: { [weak self] in self?.showDashboard() },
            showFeaturePanel: { [weak self] in self?.showFeaturePanel() }
        )
        windowRouter.setProgrammaticSettingsPresentationAction { [weak self] in
            self?.requestPanelClose()
        }
        // This controller is the sole production owner of app-level presentation routing.
        pluginHost.appPresentationHandler = { [weak self, weak windowRouter] request in
            switch MenuBarStatusItemPresentationAction(request: request) {
            case let .presentSettings(settingsRequest):
                windowRouter?.presentSettings(settingsRequest)
            case .toggleCommandPalette:
                windowRouter?.toggleCommandPalette()
            case .toggleComponentPanel:
                self?.toggleDashboard()
            case .toggleFeaturePanel:
                self?.toggleFeaturePanel()
            case .showComponentPanel:
                self?.showDashboard()
            case .showFeaturePanel:
                self?.showFeaturePanel()
            case .showUnifiedSearch:
                windowRouter?.showUnifiedSearch()
            }
        }
    }

    private func statusItemButtonScreenRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    isolated deinit {
        animationTimer?.cancel()
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        if let appTerminationObserver {
            NotificationCenter.default.removeObserver(appTerminationObserver)
        }
        if let statusItemWindowMoveObserver {
            NotificationCenter.default.removeObserver(statusItemWindowMoveObserver)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    func dismissPanels() {
        panelPresenter.dismissPanels()
        removeDismissMonitorsIfNeeded()
    }

    func showDashboard() {
        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot show Dashboard because the status item button is unavailable")
            return
        }

        panelPresenter.showDashboard(relativeTo: button)
        handlePresentationResult()
    }

    func showFeaturePanel() {
        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot show Feature Panel because the status item button is unavailable")
            return
        }

        panelPresenter.showFeaturePanel(relativeTo: button)
        handlePresentationResult()
    }

    func toggleDashboard() {
        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot toggle Dashboard because the status item button is unavailable")
            return
        }

        toggleComponentPanel(relativeTo: button)
    }

    func toggleFeaturePanel() {
        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot toggle Feature Panel because the status item button is unavailable")
            return
        }

        toggleFeaturePanel(relativeTo: button)
    }

    private func requestPanelClose() {
        dismissPanels()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = AppMetadata.appName

        // MacTools intentionally uses one target/action route on every OS.
        // AppKit's expanded-interface delegate models one undifferentiated
        // interface and carries no NSEvent, so it cannot represent the app's
        // distinct left- and right-click panels without a competing owner.
    }

    private func observePluginHost() {
        pluginHost.$hasActivePlugin
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        pluginHost.automationController.$activeRunIDs
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
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
            DispatchQueue.main.async {
                self?.updateStatusIcon()
            }
        }
    }

    private func updateStatusIcon() {
        let payload = iconSettings.imagePayload(for: statusItem.button?.effectiveAppearance)
        payload.image.isTemplate = payload.isTemplate

        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.image = statusImage(payload.image, isTemplate: payload.isTemplate)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = automationActivityTooltip
        configureAnimationIfNeeded(payload)
    }

    private var automationActivityTooltip: String {
        guard !pluginHost.automationController.activeRunIDs.isEmpty else {
            return AppMetadata.appName
        }
        return "\(AppMetadata.appName) · \(FeatureL10n.string("运行中"))"
    }

    private func statusImage(_ source: NSImage, isTemplate: Bool? = nil) -> NSImage {
        guard !pluginHost.automationController.activeRunIDs.isEmpty else {
            return source
        }

        let size = source.size
        let image = NSImage(size: size, flipped: false) { bounds in
            source.draw(in: bounds)
            let diameter = max(4, min(7, min(bounds.width, bounds.height) * 0.34))
            let badgeRect = NSRect(
                x: bounds.maxX - diameter,
                y: bounds.minY,
                width: diameter,
                height: diameter
            )
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
        image.isTemplate = isTemplate ?? source.isTemplate
        return image
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
            DispatchQueue.main.async {
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
        // Dismiss panels while their owning status item is still alive.
        requestPanelClose()

        let oldItem = statusItem
        PluginPresentationSafety.prepareForWindowOrdering()
        NSStatusBar.system.removeStatusItem(oldItem)
        MenuBarControlItemDefaults.resetVisibleControlItemPosition()
        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()

        PluginPresentationSafety.prepareForWindowOrdering()
        let newItem = NSStatusBar.system.statusItem(withLength: 0)
        newItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        statusItem = newItem

        configureStatusItem()
        updateStatusIcon()
    }

    private func configureAnimationIfNeeded(_ payload: MenuBarIconImagePayload) {
        animationTimer?.cancel()
        animationTimer = nil
        animationFrames = []
        animationFrameIndex = 0
        animationFrameDuration = max(payload.frameDuration, 0.04)

        guard payload.isAnimated else {
            return
        }

        animationFrames = payload.animationFrames
        scheduleAnimationTimer()
    }

    private func scheduleAnimationTimer() {
        animationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + animationFrameDuration,
            repeating: animationFrameDuration,
            leeway: .milliseconds(Int((animationFrameDuration * 500).rounded()))
        )
        timer.setEventHandler { [weak self] in
            self?.advanceAnimationFrame()
        }
        animationTimer = timer
        timer.resume()
    }

    private func advanceAnimationFrame() {
        guard
            !animationFrames.isEmpty,
            let button = statusItem.button
        else {
            animationTimer?.cancel()
            animationTimer = nil
            return
        }

        animationFrameIndex = (animationFrameIndex + 1) % animationFrames.count
        let frame = animationFrames[animationFrameIndex]
        button.image = statusImage(frame, isTemplate: frame.isTemplate)
        button.needsDisplay = true
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        // Read the preference live on each click so a settings change takes
        // effect immediately without re-observing.
        let swapped = MenuBarClickBehaviorPreference.current().isSwapped
        switch MenuBarStatusItemInvocation.invocation(for: NSApp.currentEvent, swapped: swapped) {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: sender)
        case .componentPanel:
            toggleComponentPanel(relativeTo: sender)
        }
    }

    private func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        panelPresenter.toggleFeaturePanel(relativeTo: button)
        handlePresentationResult()
    }

    private func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        panelPresenter.toggleComponentPanel(relativeTo: button)
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

        installGlobalMouseMonitorIfNeeded()

        if appActivationObserver == nil {
            appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard !Self.isCurrentApplicationActivationNotification(notification) else {
                    return
                }

                DispatchQueue.main.async {
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

        requestPanelClose()
        return event
    }

    private func installGlobalMouseMonitorIfNeeded() {
        guard globalEventMonitor == nil else { return }
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            let location = event.locationInWindow
            let snapshot = MenuBarGlobalMouseEvent(
                screenX: Double(location.x),
                screenY: Double(location.y)
            )
            DispatchQueue.main.async { [weak self] in
                self?.handleGlobalMouseEvent(snapshot)
            }
        }
    }

    private func handleGlobalMouseEvent(_ event: MenuBarGlobalMouseEvent) {
        if MenuBarGlobalMouseEventPolicy.isStatusItemClick(
            for: event,
            buttonFrame: statusItemButtonScreenRect()
        ) {
            return
        }

        guard panelPresenter.isAnyPanelShown else { return }
        requestPanelClose()
    }

    private func isEventInsidePresentedPanel(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else {
            return false
        }

        return panelPresenter.containsPresentedWindow(eventWindow)
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard
            let button = statusItem.button,
            event.window === button.window
        else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
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
