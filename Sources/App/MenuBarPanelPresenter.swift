import AppKit
import SwiftUI

enum MenuBarPanelWindowRegistry {
    private static let secondaryPanelIdentifier = NSUserInterfaceItemIdentifier(
        "MacTools.MenuBarSecondaryPanel"
    )

    @MainActor
    static func markSecondaryPanel(_ window: NSWindow) {
        window.identifier = secondaryPanelIdentifier
    }

    @MainActor
    static func containsAuxiliaryPanelWindow(_ window: NSWindow) -> Bool {
        window.identifier == secondaryPanelIdentifier
    }
}

// Closing fade configuration for the menu bar panel popovers.
//
// `NSPopover.animates` is deliberately NOT used: it is a single switch for
// both open and close. Opening must stay instant — the macOS 26/27 menu bar
// host already adds noticeable latency before forwarding status item clicks,
// and an open animation would stack on top of it. The dismiss path instead
// fades the popover's window manually and calls `performClose` afterwards.
private enum PanelDismissAnimation {
    static let duration: TimeInterval = 0.15
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeOut)
    }
}

/// Pure state machine for a popover's fade-out lifecycle.
///
/// NSPopover reuses its window across presentations, so a fade that leaves
/// `alphaValue` below 1 would make the next presentation translucent. This
/// type tracks whether a fade-out is in flight and hands out generation
/// tokens so a stale animation completion (cancelled by a reopen, or
/// superseded by an external close) never finishes a close it no longer
/// owns. Kept free of AppKit so the reopen-during-fade rules are testable
/// headlessly.
@MainActor
final class MenuBarPanelFadeCoordinator {
    private(set) var isFadingOut = false
    private var generation = 0

    /// Starts a fade-out. Returns its generation token, or `nil` when a fade
    /// is already in flight (the earlier fade keeps ownership of the close).
    func beginFadeOut() -> Int? {
        guard !isFadingOut else {
            return nil
        }

        isFadingOut = true
        generation += 1
        return generation
    }

    /// Called from the animation completion. Returns `true` only when the
    /// token is still current, i.e. the fade was neither cancelled by a
    /// reopen nor superseded by another close path.
    func finishFadeOut(token: Int) -> Bool {
        guard isFadingOut, token == generation else {
            return false
        }

        isFadingOut = false
        return true
    }

    /// Called before every presentation. Returns `true` when an in-flight
    /// fade must be cancelled first (alpha restored, pending close finished
    /// immediately). Always invalidates outstanding tokens so the stale
    /// animation completion becomes a no-op.
    func prepareForPresentation() -> Bool {
        let hadFadeInFlight = isFadingOut
        isFadingOut = false
        generation += 1
        return hadFadeInFlight
    }

    /// Called whenever the popover actually closed, from any path, so an
    /// externally closed popover cannot leave the coordinator stuck in
    /// `isFadingOut` with a live token.
    func notePopoverClosed() {
        isFadingOut = false
        generation += 1
    }
}

@MainActor
final class MenuBarPanelPresenter: NSObject {
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    private let pluginHost: PluginHost
    private let onDismiss: () -> Void
    private let onOpenSettings: () -> Void
    private let onPresentDiskCleanConfiguration: () -> Void
    private let onPresentLaunchControlConfiguration: () -> Void
    private let onAllPanelsClosed: () -> Void

    private let featurePopover = NSPopover()
    private let componentPopover = NSPopover()
    private let featureFadeCoordinator = MenuBarPanelFadeCoordinator()
    private let componentFadeCoordinator = MenuBarPanelFadeCoordinator()
    private let featureHostingController: NSHostingController<MenuBarContent>
    private let componentHostingController: NSHostingController<ComponentPanelContent>
    private var appearanceObserver: NSObjectProtocol?

    init(
        pluginHost: PluginHost,
        onDismiss: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onPresentDiskCleanConfiguration: @escaping () -> Void,
        onPresentLaunchControlConfiguration: @escaping () -> Void,
        onAllPanelsClosed: @escaping () -> Void
    ) {
        self.pluginHost = pluginHost
        self.onDismiss = onDismiss
        self.onOpenSettings = onOpenSettings
        self.onPresentDiskCleanConfiguration = onPresentDiskCleanConfiguration
        self.onPresentLaunchControlConfiguration = onPresentLaunchControlConfiguration
        self.onAllPanelsClosed = onAllPanelsClosed

        self.featureHostingController = NSHostingController(
            rootView: MenuBarContent(
                pluginHost: pluginHost,
                maximumFeatureListHeight: MenuBarPanelLayout.maximumFeatureListHeight(for: nil),
                onPreferredHeightChange: { _ in },
                onDismiss: onDismiss,
                onOpenSettings: onOpenSettings,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            )
        )
        self.componentHostingController = NSHostingController(
            rootView: ComponentPanelContent(
                pluginHost: pluginHost,
                panelHeight: ComponentPanelLayout.minimumPanelHeight,
                isPanelVisible: false,
                onPreferredHeightChange: {},
                onDismiss: onDismiss
            )
        )

        super.init()

        configure(featurePopover, contentViewController: featureHostingController)
        configure(componentPopover, contentViewController: componentHostingController)
        observeAppearancePreference()
        applyCurrentAppearance()
        prewarm()
    }

    deinit {
        MainActor.assumeIsolated {
            if let appearanceObserver {
                NotificationCenter.default.removeObserver(appearanceObserver)
            }
        }
    }

    var isFeaturePanelShown: Bool {
        featurePopover.isShown
    }

    var isComponentPanelShown: Bool {
        componentPopover.isShown
    }

    var isAnyPanelShown: Bool {
        isFeaturePanelShown || isComponentPanelShown
    }

    func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        if featurePopover.isShown, !featureFadeCoordinator.isFadingOut {
            closeWithFade(featurePopover)
            return
        }

        // A reopen during the fade-out lands here: settle the pending close
        // first so `popoverDidClose` runs before fresh content is configured.
        cancelFadeAndFinishCloseIfNeeded(featurePopover)
        closeWithFade(componentPopover)
        pluginHost.refreshAll()
        let screen = button.window?.screen ?? NSScreen.main
        let maximumFeatureListHeight = MenuBarPanelLayout.maximumFeatureListHeight(
            for: screen
        )
        let initialPanelHeight = MenuBarPanelLayout.preferredPanelHeight(
            for: pluginHost.panelItems,
            screen: screen
        )
        featurePopover.contentSize = NSSize(
            width: MenuBarPanelLayout.width(for: pluginHost.panelItems),
            height: initialPanelHeight
        )
        featureHostingController.rootView = MenuBarContent(
            pluginHost: pluginHost,
            maximumFeatureListHeight: maximumFeatureListHeight,
            onPreferredHeightChange: { [weak self] preferredHeight in
                self?.setFeaturePopoverHeight(preferredHeight)
            },
            onDismiss: onDismiss,
            onOpenSettings: onOpenSettings,
            onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
            onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
        )
        applyCurrentAppearance()
        show(featurePopover, relativeTo: button)
    }

    func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        if componentPopover.isShown, !componentFadeCoordinator.isFadingOut {
            closeWithFade(componentPopover)
            return
        }

        // A reopen during the fade-out lands here: settle the pending close
        // first so `popoverDidClose` resets the root view *before* the fresh
        // content below is configured, not after.
        cancelFadeAndFinishCloseIfNeeded(componentPopover)
        closeWithFade(featurePopover)
        let panelHeight = ComponentPanelLayout.preferredPanelHeight(
            for: pluginHost.componentItems,
            screen: button.window?.screen ?? NSScreen.main
        )
        componentHostingController.rootView = makeComponentPanelContent(
            panelHeight: panelHeight,
            isPanelVisible: true
        )
        applyCurrentAppearance()
        componentPopover.contentSize = NSSize(
            width: ComponentPanelLayout.panelWidth,
            height: panelHeight
        )
        show(componentPopover, relativeTo: button)
        updateComponentPopoverHeight()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.updateComponentPopoverHeight()
        }
    }

    func dismissPanels() {
        closeWithFade(featurePopover)
        closeWithFade(componentPopover)
    }

    func containsPresentedWindow(_ window: NSWindow) -> Bool {
        window === featurePopover.contentViewController?.view.window
            || window === componentPopover.contentViewController?.view.window
            || MenuBarPanelWindowRegistry.containsAuxiliaryPanelWindow(window)
    }

    private func configure(
        _ popover: NSPopover,
        contentViewController: NSViewController
    ) {
        // Dismissal is coordinated by MenuBarStatusItemController so sibling
        // panels can receive clicks without AppKit closing the popover first.
        popover.behavior = Self.popoverBehavior
        // Keep `animates` off so opening stays instant; the closing fade is
        // applied manually in `closeWithFade` (see PanelDismissAnimation).
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = contentViewController
        AppAppearancePreference.stored().apply(to: contentViewController.view)
    }

    private func prewarm() {
        featurePopover.contentSize = NSSize(
            width: MenuBarPanelLayout.width(for: pluginHost.panelItems),
            height: MenuBarPanelLayout.preferredPanelHeight(
                for: pluginHost.panelItems,
                screen: NSScreen.main
            )
        )
        componentPopover.contentSize = NSSize(
            width: ComponentPanelLayout.panelWidth,
            height: ComponentPanelLayout.preferredPanelHeight(
                for: pluginHost.componentItems,
                screen: NSScreen.main
            )
        )
    }

    private func show(_ popover: NSPopover, relativeTo button: NSStatusBarButton) {
        cancelFadeAndFinishCloseIfNeeded(popover)
        applyCurrentAppearance()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `show` may have produced a fresh window; never present transparent.
        popover.contentViewController?.view.window?.alphaValue = 1
        applyCurrentAppearance()
        focus(popover)
    }

    /// Single funnel for every close path (toggle close branch,
    /// `dismissPanels`, sibling close on panel switch): fade the popover's
    /// window out, then `performClose`. Idempotent while a fade is in flight.
    private func closeWithFade(_ popover: NSPopover) {
        guard popover.isShown else {
            return
        }

        guard let window = popover.contentViewController?.view.window else {
            // Nothing to fade; close immediately.
            popover.performClose(nil)
            return
        }

        guard let fadeToken = fadeCoordinator(for: popover).beginFadeOut() else {
            // A fade is already in flight and owns this close.
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = PanelDismissAnimation.duration
            context.timingFunction = PanelDismissAnimation.timingFunction
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak popover] in
            // NSAnimationContext invokes the completion on the main thread;
            // re-enter the main actor explicitly because the SDK marks the
            // handler @Sendable (same pattern as LaunchpadDragCoordinator).
            MainActor.assumeIsolated {
                guard let self, let popover else {
                    return
                }

                self.finishFadeOutIfCurrent(popover, fadeToken: fadeToken)
            }
        })
    }

    private func finishFadeOutIfCurrent(_ popover: NSPopover, fadeToken: Int) {
        guard fadeCoordinator(for: popover).finishFadeOut(token: fadeToken) else {
            // The fade was cancelled by a reopen or superseded by another
            // close path; that path owns the window state now.
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        }
        // The popover window is reused across presentations; never leave it
        // transparent after the close.
        popover.contentViewController?.view.window?.alphaValue = 1
    }

    /// Settles any in-flight fade before a presentation: restores the
    /// window's alpha and finishes the pending close immediately, so the
    /// upcoming `show` starts from a clean, fully opaque state.
    private func cancelFadeAndFinishCloseIfNeeded(_ popover: NSPopover) {
        let hadFadeInFlight = fadeCoordinator(for: popover).prepareForPresentation()
        guard let window = popover.contentViewController?.view.window else {
            return
        }

        // Restore alpha through a zero-duration animation group rather than
        // assigning `alphaValue` directly: a direct assignment would keep
        // being overwritten by a still-running fade animation until it ends.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }

        if hadFadeInFlight, popover.isShown {
            popover.performClose(nil)
        }
    }

    private func fadeCoordinator(for popover: NSPopover) -> MenuBarPanelFadeCoordinator {
        popover === featurePopover ? featureFadeCoordinator : componentFadeCoordinator
    }

    private func focus(_ popover: NSPopover) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        Task { @MainActor [weak popover] in
            await Task.yield()
            guard let popover, popover.isShown else {
                return
            }

            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func observeAppearancePreference() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppAppearancePreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentAppearance()
            }
        }
    }

    private func applyCurrentAppearance() {
        let preference = AppAppearancePreference.stored()
        preference.apply(to: featureHostingController.view)
        preference.apply(to: componentHostingController.view)
        preference.apply(to: featurePopover)
        preference.apply(to: componentPopover)
    }

    private func setFeaturePopoverHeight(_ height: CGFloat) {
        let width = MenuBarPanelLayout.width(for: pluginHost.panelItems)
        let currentSize = featurePopover.contentSize
        guard
            abs(currentSize.width - width) > 0.5
                || abs(currentSize.height - height) > 0.5
        else {
            return
        }

        featurePopover.contentSize = NSSize(width: width, height: height)
    }

    private func makeComponentPanelContent(
        panelHeight: CGFloat,
        isPanelVisible: Bool
    ) -> ComponentPanelContent {
        ComponentPanelContent(
            pluginHost: pluginHost,
            panelHeight: panelHeight,
            isPanelVisible: isPanelVisible,
            onPreferredHeightChange: { [weak self] in
                self?.updateComponentPopoverHeight()
            },
            onDismiss: onDismiss
        )
    }

    private func updateComponentPopoverHeight() {
        guard componentPopover.isShown else {
            return
        }

        let screen = componentPopover.contentViewController?.view.window?.screen ?? NSScreen.main
        let height = ComponentPanelLayout.preferredPanelHeight(
            for: pluginHost.componentItems,
            screen: screen
        )
        setComponentPopoverHeight(height)
    }

    private func setComponentPopoverHeight(_ height: CGFloat) {
        let width = ComponentPanelLayout.panelWidth
        let currentSize = componentPopover.contentSize
        guard
            abs(currentSize.width - width) > 0.5
                || abs(currentSize.height - height) > 0.5
        else {
            return
        }

        componentPopover.contentSize = NSSize(width: width, height: height)
        componentHostingController.rootView = makeComponentPanelContent(
            panelHeight: height,
            isPanelVisible: true
        )
        applyCurrentAppearance()
    }
}

extension MenuBarPanelPresenter: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover {
            // Settle fade bookkeeping for closes from any path (fade
            // completion, reopen cancellation, external close) so a stale
            // animation completion can never re-close the popover.
            fadeCoordinator(for: popover).notePopoverClosed()
        }

        if let popover = notification.object as? NSPopover, popover === componentPopover {
            componentHostingController.rootView = ComponentPanelContent(
                pluginHost: pluginHost,
                panelHeight: ComponentPanelLayout.minimumPanelHeight,
                isPanelVisible: false,
                onPreferredHeightChange: {},
                onDismiss: onDismiss
            )
            pluginHost.discardComponentViews()
        }

        guard !featurePopover.isShown, !componentPopover.isShown else {
            return
        }

        onAllPanelsClosed()
    }
}
