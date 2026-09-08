import AppKit
import Carbon
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarPanelPresentationAction: Equatable {
    case open
    case switchPanel
    case focus

    static func resolve(
        isPanelShown: Bool,
        selectedTab: MenuBarPanelTab,
        requestedTab: MenuBarPanelTab
    ) -> MenuBarPanelPresentationAction {
        guard isPanelShown else {
            return .open
        }

        return selectedTab == requestedTab ? .focus : .switchPanel
    }
}

enum MenuBarPanelToggleAction: Equatable {
    case open
    case close
    case switchPanel

    static func resolve(
        isPanelShown: Bool,
        selectedTab: MenuBarPanelTab,
        requestedTab: MenuBarPanelTab
    ) -> MenuBarPanelToggleAction {
        guard isPanelShown else {
            return .open
        }

        return selectedTab == requestedTab ? .close : .switchPanel
    }
}

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

enum MenuBarPanelKeyboardAction: Equatable {
    case dismissPanel
    case showSettings
    case showUnifiedSearch
    case selectTab(MenuBarPanelTab)

    @MainActor
    static func resolve(for event: NSEvent) -> MenuBarPanelKeyboardAction? {
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection(relevantModifiers).isEmpty {
            return .dismissPanel
        }

        if MacToolsLocalKeyboardCommand.resolve(for: event) == .showSettings {
            return .showSettings
        }

        if MacToolsLocalKeyboardCommand.resolve(for: event) == .showUnifiedSearch {
            return .showUnifiedSearch
        }

        guard let tab = MenuBarPanelPresenter.keyboardShortcutTab(for: event) else {
            return nil
        }

        return .selectTab(tab)
    }
}

@MainActor
final class MenuBarPanelHostingController<Content: View>: NSHostingController<Content> {
    private let onUnhandledEscape: () -> Void

    init(
        rootView: Content,
        onUnhandledEscape: @escaping () -> Void
    ) {
        self.onUnhandledEscape = onUnhandledEscape
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        guard MenuBarPanelKeyboardAction.resolve(for: event) == .dismissPanel else {
            super.keyDown(with: event)
            return
        }

        onUnhandledEscape()
    }

    override func cancelOperation(_ sender: Any?) {
        onUnhandledEscape()
    }
}

@MainActor
final class MenuBarPanelContainerController<Content: View>: NSViewController {
    private let hostingController: MenuBarPanelHostingController<Content>
    private let themeStore: MenuBarPanelThemeStore
    private let onUnhandledEscape: () -> Void

    init(
        hostingController: MenuBarPanelHostingController<Content>,
        themeStore: MenuBarPanelThemeStore,
        onUnhandledEscape: @escaping () -> Void
    ) {
        self.hostingController = hostingController
        self.themeStore = themeStore
        self.onUnhandledEscape = onUnhandledEscape
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = MenuBarPanelBackgroundView(themeStore: themeStore)
    }

    func refreshBackground() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedView)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }

    override func keyDown(with event: NSEvent) {
        guard MenuBarPanelKeyboardAction.resolve(for: event) == .dismissPanel else {
            super.keyDown(with: event)
            return
        }

        onUnhandledEscape()
    }

    override func cancelOperation(_ sender: Any?) {
        onUnhandledEscape()
    }
}

private final class MenuBarPanelBackgroundView: NSView {
    private let themeStore: MenuBarPanelThemeStore

    init(themeStore: MenuBarPanelThemeStore) {
        self.themeStore = themeStore
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance: MenuBarPanelThemeAppearance = isDark ? .dark : .light
        let style = MenuBarPanelThemeResolver.resolve(
            definition: themeStore.selectedDefinition(for: appearance),
            colorScheme: isDark ? .dark : .light,
            contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? .increased
                : .standard
        )
        NSColor(style.surfaces.panel).setFill()
        NSBezierPath.fill(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

enum MenuBarPopoverGeometry {
    /// `hasFullSizeContent` makes `contentSize` describe the complete popover
    /// window instead of the unobscured content rect. The supported systems
    /// currently report 13 points on each edge. This is only a first-frame
    /// fallback; the live AppKit safe-area insets replace it after presentation.
    static let fallbackSafeAreaInsets = NSEdgeInsets(
        top: 13,
        left: 13,
        bottom: 13,
        right: 13
    )

    static func popoverSize(
        preserving contentSize: NSSize,
        safeAreaInsets: NSEdgeInsets
    ) -> NSSize {
        NSSize(
            width: contentSize.width + safeAreaInsets.left + safeAreaInsets.right,
            height: contentSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
    }

    static func hasUsableInsets(_ insets: NSEdgeInsets) -> Bool {
        insets.top > 0 || insets.left > 0 || insets.bottom > 0 || insets.right > 0
    }
}

@MainActor
final class MenuBarPanelPresenter: NSObject {
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    private enum PanelKind: Equatable {
        case features
        case components
    }

    private let pluginHost: PluginHost
    private let appUpdater: AppUpdater
    private let menuBarPanelThemeStore: MenuBarPanelThemeStore
    private let onDismiss: () -> Void
    private let onOpenUpdate: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenUnifiedSearch: () -> Void
    private let onPresentDiskCleanConfiguration: () -> Void
    private let onPresentLaunchControlConfiguration: () -> Void
    private let onAllPanelsClosed: () -> Void

    private let popover = NSPopover()
    private let panelModel: MenuBarUnifiedPanelModel
    private let hostingController: MenuBarPanelHostingController<MenuBarUnifiedPanelContent>
    private let containerController: MenuBarPanelContainerController<MenuBarUnifiedPanelContent>
    private var appearanceObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var heightRefreshCancellables: Set<AnyCancellable> = []
    private var keyboardShortcutMonitor: Any?
    private var selectedPanel: PanelKind = .components
    private var panelContentSize = NSSize(
        width: MenuBarPanelLayout.baseWidth,
        height: MenuBarPanelLayout.minimumPanelHeight
    )
    private var popoverSafeAreaInsets = MenuBarPopoverGeometry.fallbackSafeAreaInsets

    init(
        pluginHost: PluginHost,
        appUpdater: AppUpdater,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        onDismiss: @escaping () -> Void,
        onOpenUpdate: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenUnifiedSearch: @escaping () -> Void,
        onPresentDiskCleanConfiguration: @escaping () -> Void,
        onPresentLaunchControlConfiguration: @escaping () -> Void,
        onAllPanelsClosed: @escaping () -> Void
    ) {
        self.pluginHost = pluginHost
        self.appUpdater = appUpdater
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        self.onDismiss = onDismiss
        self.onOpenUpdate = onOpenUpdate
        self.onOpenSettings = onOpenSettings
        self.onOpenUnifiedSearch = onOpenUnifiedSearch
        self.onPresentDiskCleanConfiguration = onPresentDiskCleanConfiguration
        self.onPresentLaunchControlConfiguration = onPresentLaunchControlConfiguration
        self.onAllPanelsClosed = onAllPanelsClosed

        let panelModel = MenuBarUnifiedPanelModel(
            selectedTab: .components,
            contentHeight: MenuBarPanelLayout.minimumContentHeight,
            maximumFeatureListHeight: MenuBarPanelLayout.maximumFeatureListHeight(for: nil),
            isPanelVisible: false
        )
        self.panelModel = panelModel
        let hostingController = MenuBarPanelHostingController(
            rootView: MenuBarUnifiedPanelContent(
                pluginHost: pluginHost,
                appUpdater: appUpdater,
                menuBarPanelThemeStore: menuBarPanelThemeStore,
                model: panelModel,
                onDismiss: onDismiss,
                onOpenUpdate: onOpenUpdate,
                onOpenSettings: onOpenSettings,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            ),
            onUnhandledEscape: onDismiss
        )
        self.hostingController = hostingController
        self.containerController = MenuBarPanelContainerController(
            hostingController: hostingController,
            themeStore: menuBarPanelThemeStore,
            onUnhandledEscape: onDismiss
        )

        super.init()

        panelModel.onTabSelection = { [weak self] tab in
            self?.select(tab)
        }
        configure(popover)
        observeAppearancePreference()
        observeThemePreference()
        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshLocalization()
                }
            }
        observePanelItemChanges()
        applyCurrentAppearance()
        prewarm()
        scheduleComponentViewPrewarm()
    }

    isolated deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        removeKeyboardShortcutMonitorIfNeeded()
        runtimeLocaleCancellable?.cancel()
    }

    var isAnyPanelShown: Bool {
        popover.isShown
    }

    private func refreshLocalization() {
        hostingController.rootView = MenuBarUnifiedPanelContent(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarPanelThemeStore: menuBarPanelThemeStore,
            model: panelModel,
            onDismiss: onDismiss,
            onOpenUpdate: onOpenUpdate,
            onOpenSettings: onOpenSettings,
            onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
            onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
        )
        scheduleHeightRefresh(for: tab(for: selectedPanel))
    }

    #if DEBUG
    var debugPopoverForTests: NSPopover {
        popover
    }

    var debugHasKeyboardShortcutMonitorForTests: Bool {
        keyboardShortcutMonitor != nil
    }

    var debugSelectedTabForTests: MenuBarPanelTab {
        tab(for: selectedPanel)
    }
    #endif

    func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        toggle(.features, relativeTo: button)
    }

    func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        toggle(.components, relativeTo: button)
    }

    func showFeaturePanel(relativeTo button: NSStatusBarButton) {
        present(.features, relativeTo: button)
    }

    func showDashboard(relativeTo button: NSStatusBarButton) {
        present(.components, relativeTo: button)
    }

    func dismissPanels() {
        popover.performClose(nil)
    }

    func containsPresentedWindow(_ window: NSWindow) -> Bool {
        window === popover.contentViewController?.view.window
            || MenuBarPanelWindowRegistry.containsAuxiliaryPanelWindow(window)
    }

    private func toggle(_ panel: PanelKind, relativeTo button: NSStatusBarButton) {
        let action = MenuBarPanelToggleAction.resolve(
            isPanelShown: popover.isShown,
            selectedTab: tab(for: selectedPanel),
            requestedTab: tab(for: panel)
        )

        if action == .close {
            popover.performClose(nil)
            return
        }

        present(panel, relativeTo: button)
    }

    private func present(_ panel: PanelKind, relativeTo button: NSStatusBarButton) {
        let action = MenuBarPanelPresentationAction.resolve(
            isPanelShown: popover.isShown,
            selectedTab: tab(for: selectedPanel),
            requestedTab: tab(for: panel)
        )
        selectedPanel = panel
        updateContent(
            selectedTab: tab(for: panel),
            screen: button.window?.screen ?? NSScreen.main,
            isPanelVisible: true
        )
        updatePanelSurfaceVisibility(for: tab(for: panel), isPanelVisible: true)

        if action != .open {
            focus(popover)
            scheduleHeightRefresh(for: tab(for: panel))
            return
        }

        show(popover, relativeTo: button)
        scheduleHeightRefresh(for: tab(for: panel))
    }

    private func configure(_ popover: NSPopover) {
        // Dismissal is coordinated by MenuBarStatusItemController so sibling
        // panels can receive clicks without AppKit closing the popover first.
        popover.behavior = Self.popoverBehavior
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = containerController
        // Keep popover sizing single-sourced from MenuBarPanelLayout.
        // Letting SwiftUI also publish preferredContentSize can make AppKit
        // resize the shown popover a second time during tab switches.
        if #available(macOS 14.0, *) {
            // Extend the app-owned background into AppKit's attachment arrow
            // so it uses the same adaptive color as the panel body.
            popover.hasFullSizeContent = true
            hostingController.sizingOptions = []
        }
        AppAppearancePreference.stored().apply(to: containerController.view)
    }

    private func prewarm() {
        applyPopoverSize()
        containerController.loadViewIfNeeded()
        containerController.view.setFrameSize(popover.contentSize)
    }

    private func scheduleComponentViewPrewarm() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.pluginHost.prewarmComponentViews(dismiss: self.onDismiss)
        }
    }

    private func show(_ popover: NSPopover, relativeTo button: NSStatusBarButton) {
        applyCurrentAppearance()
        PluginPresentationSafety.prepareForWindowOrdering()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        applyCurrentAppearance()
        focus(popover)
    }

    private func installKeyboardShortcutMonitorIfNeeded() {
        guard keyboardShortcutMonitor == nil else {
            return
        }

        // Panel navigation and Settings presentation are local key equivalents.
        // Escape is intentionally handled later by the hosting controller's
        // responder-chain cancelOperation fallback.
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleKeyboardShortcut(event) ?? event
        }
    }

    private func removeKeyboardShortcutMonitorIfNeeded() {
        guard let keyboardShortcutMonitor else {
            return
        }

        NSEvent.removeMonitor(keyboardShortcutMonitor)
        self.keyboardShortcutMonitor = nil
    }

    private func handleKeyboardShortcut(_ event: NSEvent) -> NSEvent? {
        guard
            popover.isShown,
            let eventWindow = event.window,
            containsPresentedWindow(eventWindow),
            let action = MenuBarPanelKeyboardAction.resolve(for: event)
        else {
            return event
        }

        if case .selectTab = action,
           eventWindow !== popover.contentViewController?.view.window {
            return event
        }

        if action == .dismissPanel,
           let firstResponder = eventWindow.firstResponder,
           firstResponder !== eventWindow {
            return event
        }

        performKeyboardAction(action)
        return nil
    }

    func performKeyboardAction(_ action: MenuBarPanelKeyboardAction) {
        switch action {
        case .dismissPanel:
            onDismiss()
        case .showSettings:
            onOpenSettings()
        case .showUnifiedSearch:
            onOpenUnifiedSearch()
        case let .selectTab(tab):
            select(tab)
        }
    }

    // Internal so focused tests can validate layout-independent key matching.
    static func keyboardShortcutTab(for event: NSEvent) -> MenuBarPanelTab? {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let modifiers = event.modifierFlags.intersection(shortcutModifiers)
        guard modifiers == .command else {
            return nil
        }

        switch event.keyCode {
        case UInt16(kVK_ANSI_1):
            return .components
        case UInt16(kVK_ANSI_2):
            return .features
        default:
            return nil
        }
    }

    private func focus(_ popover: NSPopover) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        DispatchQueue.main.async { [weak popover] in
            guard let popover, popover.isShown else {
                return
            }

            guard let window = popover.contentViewController?.view.window else {
                return
            }

            window.makeKey()
            Self.clearAutomaticInitialFocus(in: window)
        }
    }

    /// Prevent SwiftUI from leaving the first toolbar button focused when the
    /// popover becomes key. Keyboard navigation can still focus controls
    /// normally after the popover opens.
    static func clearAutomaticInitialFocus(in window: NSWindow) {
        window.makeFirstResponder(nil)
    }

    private func observeAppearancePreference() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppAppearancePreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.applyCurrentAppearance()
            }
        }
    }

    private func observeThemePreference() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: MenuBarPanelThemeStore.didChangeNotification,
            object: menuBarPanelThemeStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.containerController.refreshBackground()
            }
        }
    }

    private func observePanelItemChanges() {
        pluginHost.$panelItems
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshHeightForVisiblePanel()
                }
            }
            .store(in: &heightRefreshCancellables)

        pluginHost.$componentItems
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshHeightForVisiblePanel()
                }
            }
            .store(in: &heightRefreshCancellables)
    }

    private func applyCurrentAppearance() {
        let preference = AppAppearancePreference.stored()
        preference.apply(to: hostingController.view)
        preference.apply(to: popover)
        containerController.refreshBackground()
    }

    private func setPopoverHeight(_ height: CGFloat) {
        let width = MenuBarPanelLayout.baseWidth
        let currentSize = panelContentSize
        guard
            abs(currentSize.width - width) > 0.5
                || abs(currentSize.height - height) > 0.5
        else {
            return
        }

        panelContentSize = NSSize(width: width, height: height)
        applyPopoverSize()
    }

    private func applyPopoverSize() {
        let resolvedSize = MenuBarPopoverGeometry.popoverSize(
            preserving: panelContentSize,
            safeAreaInsets: popoverSafeAreaInsets
        )
        let currentSize = popover.contentSize
        guard
            abs(currentSize.width - resolvedSize.width) > 0.5
                || abs(currentSize.height - resolvedSize.height) > 0.5
        else {
            return
        }

        popover.contentSize = resolvedSize
    }

    private func synchronizePopoverSafeAreaInsets() {
        containerController.view.layoutSubtreeIfNeeded()
        let resolvedInsets = containerController.view.safeAreaInsets
        guard MenuBarPopoverGeometry.hasUsableInsets(resolvedInsets) else {
            return
        }

        guard
            abs(popoverSafeAreaInsets.top - resolvedInsets.top) > 0.5
                || abs(popoverSafeAreaInsets.left - resolvedInsets.left) > 0.5
                || abs(popoverSafeAreaInsets.bottom - resolvedInsets.bottom) > 0.5
                || abs(popoverSafeAreaInsets.right - resolvedInsets.right) > 0.5
        else {
            return
        }

        popoverSafeAreaInsets = resolvedInsets
        applyPopoverSize()
    }

    private func updateContent(
        selectedTab: MenuBarPanelTab,
        screen: NSScreen?,
        isPanelVisible: Bool
    ) {
        let heightResolution = resolveContentHeight(
            for: selectedTab,
            screen: screen
        )
        panelModel.update(
            selectedTab: selectedTab,
            contentHeight: heightResolution.contentHeight,
            maximumFeatureListHeight: heightResolution.maximumFeatureListHeight,
            isPanelVisible: isPanelVisible
        )
        setPopoverHeight(MenuBarPanelLayout.panelHeight(forContentHeight: heightResolution.contentHeight))
    }

    private func select(_ tab: MenuBarPanelTab) {
        guard tab != panelModel.selectedTab else {
            return
        }

        selectedPanel = panelKind(for: tab)
        updateContent(
            selectedTab: tab,
            screen: popover.contentViewController?.view.window?.screen ?? NSScreen.main,
            isPanelVisible: popover.isShown
        )
        updatePanelSurfaceVisibility(for: tab, isPanelVisible: popover.isShown)
        scheduleHeightRefresh(for: tab)
    }

    private func scheduleHeightRefresh(for tab: MenuBarPanelTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else {
                return
            }

            self.refreshHeight(for: tab)
        }
    }

    private func refreshHeight(for tab: MenuBarPanelTab) {
        guard tab == self.tab(for: selectedPanel) else {
            return
        }

        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        let heightResolution = resolveContentHeight(
            for: tab,
            screen: screen
        )
        panelModel.update(
            selectedTab: tab,
            contentHeight: heightResolution.contentHeight,
            maximumFeatureListHeight: heightResolution.maximumFeatureListHeight,
            isPanelVisible: popover.isShown
        )
        setPopoverHeight(MenuBarPanelLayout.panelHeight(forContentHeight: heightResolution.contentHeight))
    }

    private func refreshHeightForVisiblePanel() {
        guard popover.isShown else {
            return
        }

        refreshHeight(for: tab(for: selectedPanel))
    }

    private func resolveContentHeight(
        for tab: MenuBarPanelTab,
        screen: NSScreen?
    ) -> MenuBarPanelHeightResolution {
        let maximumFeatureListHeight = MenuBarPanelLayout.maximumFeatureListHeight(for: screen)

        switch tab {
        case .components:
            return MenuBarPanelHeightResolution(
                contentHeight: ComponentPanelLayout.preferredContentHeight(
                    for: pluginHost.componentItems,
                    screen: screen
                ),
                maximumFeatureListHeight: maximumFeatureListHeight
            )
        case .features:
            return MenuBarPanelHeightResolution(
                contentHeight: MenuBarPanelLayout.preferredFeatureContentHeight(
                    featureContentHeight: MenuBarPanelLayout.featureContentHeight(
                        for: pluginHost.panelItems
                    ),
                    maximumFeatureListHeight: maximumFeatureListHeight
                ),
                maximumFeatureListHeight: maximumFeatureListHeight
            )
        }
    }

    private func tab(for panel: PanelKind) -> MenuBarPanelTab {
        switch panel {
        case .features:
            return .features
        case .components:
            return .components
        }
    }

    private func panelKind(for tab: MenuBarPanelTab) -> PanelKind {
        switch tab {
        case .features:
            return .features
        case .components:
            return .components
        }
    }

    private func updatePanelSurfaceVisibility(for tab: MenuBarPanelTab, isPanelVisible: Bool) {
        pluginHost.setPanelSurface(.component, visible: isPanelVisible && tab == .components)
        pluginHost.setPanelSurface(.primary, visible: isPanelVisible && tab == .features)
    }

}

extension MenuBarPanelPresenter: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        guard let openingPopover = notification.object as? NSPopover, openingPopover === popover else {
            return
        }

        installKeyboardShortcutMonitorIfNeeded()
    }

    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover, shownPopover === popover else {
            return
        }

        synchronizePopoverSafeAreaInsets()
    }

    func popoverDidClose(_ notification: Notification) {
        if let closedPopover = notification.object as? NSPopover, closedPopover === popover {
            removeKeyboardShortcutMonitorIfNeeded()
            updateContent(
                selectedTab: tab(for: selectedPanel),
                screen: NSScreen.main,
                isPanelVisible: false
            )
            updatePanelSurfaceVisibility(
                for: tab(for: selectedPanel),
                isPanelVisible: false
            )
            onAllPanelsClosed()
        }
    }
}

enum MenuBarPanelTab: CaseIterable, Equatable {
    case components
    case features

    var systemImage: String {
        switch self {
        case .components:
            return "square.grid.2x2"
        case .features:
            return "switch.2"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .components:
            return AppL10n.plugins("plugin.panel.components", defaultValue: "组件面板")
        case .features:
            return AppL10n.plugins("plugin.panel.features", defaultValue: "功能面板")
        }
    }
}

struct MenuBarPanelHeightResolution: Equatable {
    let contentHeight: CGFloat
    let maximumFeatureListHeight: CGFloat
}

@MainActor
final class MenuBarUnifiedPanelModel: ObservableObject {
    private(set) var selectedTab: MenuBarPanelTab
    private(set) var contentHeight: CGFloat
    private(set) var maximumFeatureListHeight: CGFloat
    private(set) var isPanelVisible: Bool
    var onTabSelection: ((MenuBarPanelTab) -> Void)?

    init(
        selectedTab: MenuBarPanelTab,
        contentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat,
        isPanelVisible: Bool
    ) {
        self.selectedTab = selectedTab
        self.contentHeight = contentHeight
        self.maximumFeatureListHeight = maximumFeatureListHeight
        self.isPanelVisible = isPanelVisible
    }

    func update(
        selectedTab: MenuBarPanelTab,
        contentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat,
        isPanelVisible: Bool
    ) {
        guard
            self.selectedTab != selectedTab
                || abs(self.contentHeight - contentHeight) > 0.5
                || abs(self.maximumFeatureListHeight - maximumFeatureListHeight) > 0.5
                || self.isPanelVisible != isPanelVisible
        else {
            return
        }

        objectWillChange.send()
        self.selectedTab = selectedTab
        self.contentHeight = contentHeight
        self.maximumFeatureListHeight = maximumFeatureListHeight
        self.isPanelVisible = isPanelVisible
    }

    func selectTab(_ tab: MenuBarPanelTab) {
        onTabSelection?(tab)
    }

}

struct MenuBarUnifiedPanelContent: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: MenuBarUnifiedPanelModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let onDismiss: () -> Void
    let onOpenUpdate: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void

    var body: some View {
        let _ = runtimeLocale.revision
        let appearance = MenuBarPanelThemeResolver.appearance(for: colorScheme)
        let theme = MenuBarPanelThemeResolver.resolve(
            definition: menuBarPanelThemeStore.selectedDefinition(for: appearance),
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        let contentBodyHeight = MenuBarPanelLayout.contentBodyHeight(
            forContentHeight: model.contentHeight
        )

        VStack(spacing: MenuBarPanelLayout.rootSpacing) {
            MenuBarPanelToolbar(
                selectedTab: model.selectedTab,
                availableUpdateVersion: appUpdater.availableUpdateVersion,
                onTabSelection: handleTabSelection,
                onOpenUpdate: presentUpdate,
                onOpenSettings: presentSettings,
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .frame(height: MenuBarPanelLayout.toolbarHeight)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)

            MenuBarPanelContentSurface(contentBodyHeight: contentBodyHeight) {
                panelContent(contentBodyHeight: contentBodyHeight)
            }
        }
        .padding(.top, MenuBarPanelLayout.outerPadding)
        .frame(
            width: MenuBarPanelLayout.baseWidth,
            height: MenuBarPanelLayout.panelHeight(forContentHeight: model.contentHeight),
            alignment: .topLeading
        )
        .background {
            theme.surfaces.panel
        }
        .foregroundStyle(theme.text.primary)
        .tint(theme.accent)
        .id(runtimeLocale.revision)
        .environment(\.menuBarPanelTheme, theme)
        .environment(\.pluginComponentTheme, theme.componentTheme)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
    }

    private var layoutDirection: LayoutDirection {
        PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private func panelContent(contentBodyHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ComponentPanelContent(
                pluginHost: pluginHost,
                contentBodyHeight: contentBodyHeight,
                isPanelVisible: model.isPanelVisible && model.selectedTab == .components,
                onDismiss: onDismiss
            )
            .opacity(model.selectedTab == .components ? 1 : 0)
            .allowsHitTesting(model.isPanelVisible && model.selectedTab == .components)
            .accessibilityHidden(model.selectedTab != .components)

            MenuBarContent(
                pluginHost: pluginHost,
                contentBodyHeight: contentBodyHeight,
                maximumFeatureListHeight: model.maximumFeatureListHeight,
                isPanelVisible: model.isPanelVisible && model.selectedTab == .features,
                onDismiss: onDismiss,
                onOpenSettings: onOpenSettings,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            )
            .opacity(model.selectedTab == .features ? 1 : 0)
            .allowsHitTesting(model.isPanelVisible && model.selectedTab == .features)
            .accessibilityHidden(model.selectedTab != .features)
        }
    }

    private func presentSettings() {
        onOpenSettings()
        onDismiss()
    }

    private func presentUpdate() {
        onOpenUpdate()
        onDismiss()
    }

    private func handleTabSelection(_ tab: MenuBarPanelTab) {
        guard model.selectedTab != tab else {
            return
        }

        model.selectTab(tab)
    }

}

private struct MenuBarPanelContentSurface<Content: View>: View {
    let contentBodyHeight: CGFloat
    private let content: Content

    init(contentBodyHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentBodyHeight = contentBodyHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: MenuBarPanelLayout.surfaceWidth,
                height: contentBodyHeight,
                alignment: .topLeading
            )
            .padding(.top, MenuBarPanelLayout.contentTopPadding)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)
            .padding(.bottom, MenuBarPanelLayout.contentBottomPadding)
            .frame(
                width: MenuBarPanelLayout.baseWidth,
                height: contentBodyHeight + MenuBarPanelLayout.contentVerticalPadding,
                alignment: .topLeading
            )
    }
}

private struct MenuBarPanelToolbar: View {
    let selectedTab: MenuBarPanelTab
    let availableUpdateVersion: String?
    let onTabSelection: (MenuBarPanelTab) -> Void
    let onOpenUpdate: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            MenuBarPanelTabSwitcher(
                selectedTab: selectedTab,
                onTabSelection: onTabSelection
            )

            HStack(spacing: 4) {
                if let availableUpdateVersion {
                    MenuBarPanelIconButton(
                        systemImage: "arrow.triangle.2.circlepath",
                        accessibilityTitle: updateAccessibilityTitle(
                            version: availableUpdateVersion
                        ),
                        showsNotificationDot: true,
                        action: onOpenUpdate
                    )
                }

                MenuBarPanelIconButton(
                    systemImage: "gearshape",
                    accessibilityTitle: AppL10n.settings("settings.window.title", defaultValue: "设置"),
                    action: onOpenSettings
                )

                MenuBarPanelIconButton(
                    systemImage: "power",
                    accessibilityTitle: AppL10n.settings("app.quit", defaultValue: "退出"),
                    action: onQuit
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func updateAccessibilityTitle(version: String) -> String {
        let action = AppL10n.settings(
            "about.update.installNow",
            defaultValue: "立即更新"
        )
        let availability = AppL10n.settingsFormat(
            "about.update.headline.availableFormat",
            defaultValue: "检测到新版本 %@",
            version
        )
        return "\(action)：\(availability)"
    }
}

private struct MenuBarPanelTabSwitcher: View {
    let selectedTab: MenuBarPanelTab
    let onTabSelection: (MenuBarPanelTab) -> Void
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarPanelTab.allCases, id: \.self) { tab in
                Button {
                    guard selectedTab != tab else {
                        return
                    }

                    onTabSelection(tab)
                } label: {
                    Image(systemName: PluginSystemImage.resolvedName(tab.systemImage))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? theme.text.primary : theme.text.secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.accessibilityTitle)
                .accessibilityLabel(tab.accessibilityTitle)
                .background {
                    Capsule()
                        .fill(selectedTab == tab ? theme.surfaces.tabSelection : Color.clear)
                }
            }
        }
        .padding(3)
        .background {
            Capsule()
                .fill(theme.surfaces.control)
        }
    }
}

private struct MenuBarPanelIconButton: View {
    let systemImage: String
    let accessibilityTitle: String
    var showsNotificationDot = false
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: PluginSystemImage.resolvedName(systemImage))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text.secondary)
                .overlay(alignment: .bottomTrailing) {
                    if showsNotificationDot {
                        Circle()
                            .fill(theme.status.warning)
                            .frame(width: 6, height: 6)
                            .overlay {
                                Circle()
                                    .stroke(theme.surfaces.panel, lineWidth: 1)
                            }
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: 28, height: 24)
                .background {
                    Capsule()
                        .fill(isHovered ? theme.surfaces.hover : Color.clear)
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .onHover { isHovered = $0 }
    }
}
