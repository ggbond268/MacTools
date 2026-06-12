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
        if featurePopover.isShown {
            featurePopover.performClose(nil)
            return
        }

        componentPopover.performClose(nil)
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
        if componentPopover.isShown {
            componentPopover.performClose(nil)
            return
        }

        featurePopover.performClose(nil)
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
        featurePopover.performClose(nil)
        componentPopover.performClose(nil)
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
        applyCurrentAppearance()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        applyCurrentAppearance()
        focus(popover)
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
