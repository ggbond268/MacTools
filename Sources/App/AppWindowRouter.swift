import AppKit
import Carbon
import Combine
import SwiftUI
import MacToolsPluginKit

enum MacToolsLocalKeyboardCommand: Equatable {
    case showSettings
    case focusSearch
    case showUnifiedSearch
    case selectNumber(Int)
    case goBack
    case goForward
    case moveSidebarSelection(SettingsSidebarMoveDirection)

    static func resolve(for event: NSEvent) -> MacToolsLocalKeyboardCommand? {
        guard event.type == .keyDown else {
            return nil
        }

        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let modifiers = event.modifierFlags.intersection(relevantModifiers)

        if modifiers == [.control, .command] {
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                return .moveSidebarSelection(.previous)
            case kVK_DownArrow:
                return .moveSidebarSelection(.next)
            default:
                return nil
            }
        }

        guard modifiers == .command else {
            return nil
        }

        if let selectionNumber = physicalNumberRowSelection(for: event.keyCode) {
            return .selectNumber(selectionNumber)
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_LeftBracket:
            return .goBack
        case kVK_ANSI_RightBracket:
            return .goForward
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            return .showSettings
        case "f":
            return .focusSearch
        case "k":
            return .showUnifiedSearch
        default:
            return nil
        }
    }

    private static func physicalNumberRowSelection(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1):
            1
        case UInt16(kVK_ANSI_2):
            2
        case UInt16(kVK_ANSI_3):
            3
        case UInt16(kVK_ANSI_4):
            4
        case UInt16(kVK_ANSI_5):
            5
        case UInt16(kVK_ANSI_6):
            6
        case UInt16(kVK_ANSI_7):
            7
        case UInt16(kVK_ANSI_8):
            8
        case UInt16(kVK_ANSI_9):
            9
        default:
            nil
        }
    }
}

@MainActor
final class MacToolsCommandWindow: NSWindow {
    var onLocalKeyboardCommand: ((MacToolsLocalKeyboardCommand) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard
            let command = MacToolsLocalKeyboardCommand.resolve(for: event),
            let onLocalKeyboardCommand
        else {
            return super.performKeyEquivalent(with: event)
        }

        guard onLocalKeyboardCommand(command) else {
            return super.performKeyEquivalent(with: event)
        }

        return true
    }
}

enum StandaloneCommandPaletteLayout {
    static let contentSize = NSSize(width: 720, height: 710)

    static func frame(
        contentSize: NSSize = contentSize,
        pointerLocation: NSPoint,
        visibleFrames: [NSRect]
    ) -> NSRect {
        guard let visibleFrame = visibleFrames.first(where: { $0.contains(pointerLocation) })
            ?? visibleFrames.first
        else {
            return NSRect(origin: .zero, size: contentSize)
        }

        let size = NSSize(
            width: min(contentSize.width, visibleFrame.width),
            height: min(contentSize.height, visibleFrame.height)
        )
        let proposedOrigin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
        let origin = NSPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        return NSRect(origin: origin, size: size)
    }
}

enum CommandPaletteTogglePolicy {
    static func settingsPaletteIsVisible(
        isPresented: Bool,
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isWindowOnActiveSpace: Bool
    ) -> Bool {
        isPresented
            && isWindowVisible
            && !isWindowMiniaturized
            && isWindowOnActiveSpace
    }
}

enum AppWindowPresentation {
    static func perform(
        isMiniaturized: Bool,
        activate: () -> Void,
        deminiaturize: () -> Void,
        orderFront: () -> Void
    ) {
        activate()
        if isMiniaturized {
            deminiaturize()
        }
        orderFront()
    }
}

enum AppDockVisibilityPolicy {
    static func activationPolicy(
        hasVisibleSettingsWindow: Bool
    ) -> NSApplication.ActivationPolicy {
        hasVisibleSettingsWindow ? .regular : .accessory
    }
}

@MainActor
enum AppDockVisibilityController {
    static func update(hasVisibleSettingsWindow: Bool) {
        update(
            hasVisibleSettingsWindow: hasVisibleSettingsWindow,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            setActivationPolicy: NSApplication.shared.setActivationPolicy
        )
    }

    static func update(
        hasVisibleSettingsWindow: Bool,
        isRunningTests: Bool,
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool
    ) {
        guard !isRunningTests else { return }
        _ = setActivationPolicy(
            AppDockVisibilityPolicy.activationPolicy(
                hasVisibleSettingsWindow: hasVisibleSettingsWindow
            )
        )
    }
}

@MainActor
final class StandaloneCommandPaletteState: ObservableObject {
    @Published private(set) var presentationOrigin: UnifiedSearchPresentationOrigin?
    @Published private(set) var shortcutHint: String?
    @Published private(set) var focusRequestID: UInt = 0
    @Published private(set) var resetRequestID: UInt = 0
    @Published private(set) var quickSelectionRequest: UnifiedSearchQuickSelectionRequest?
    @Published private(set) var localizationRevision: UInt = 0

    private var nextQuickSelectionRequestID: UInt = 0
    private var pendingExecutionCancellation: (() -> Void)?

    func prepareForPresentation(shortcutLabel: String) {
        presentationOrigin = .globalShortcut(shortcutLabel)
        shortcutHint = shortcutLabel
        quickSelectionRequest = nil
        resetRequestID &+= 1
        focusRequestID &+= 1
    }

    func prepareForDismissal() {
        let cancellation = pendingExecutionCancellation
        pendingExecutionCancellation = nil
        cancellation?()
    }

    func setPendingExecutionCancellation(_ cancellation: (() -> Void)?) {
        pendingExecutionCancellation = cancellation
    }

    @discardableResult
    func requestQuickSelection(number: Int) -> Bool {
        guard (1...MacToolsSearchPresentation.quickSelectionLimit).contains(number) else {
            return false
        }

        nextQuickSelectionRequestID &+= 1
        quickSelectionRequest = UnifiedSearchQuickSelectionRequest(
            id: nextQuickSelectionRequestID,
            number: number
        )
        return true
    }

    @discardableResult
    func consumeQuickSelectionRequest(_ request: UnifiedSearchQuickSelectionRequest) -> Bool {
        guard quickSelectionRequest == request else {
            return false
        }

        quickSelectionRequest = nil
        return true
    }

    func refreshLocalization() {
        localizationRevision &+= 1
    }
}

@MainActor
final class MacToolsCommandPalettePanel: NSPanel {
    var onQuickSelection: ((Int) -> Bool)?
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if case let .selectNumber(number) = MacToolsLocalKeyboardCommand.resolve(for: event),
           onQuickSelection?(number) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

struct StandaloneCommandPaletteRootView: View {
    let pluginHost: PluginHost
    let launchAtLoginController: LaunchAtLoginController
    let appearanceUserDefaults: UserDefaults
    let commandPaletteRecentStore: CommandPaletteRecentStore
    @ObservedObject var state: StandaloneCommandPaletteState
    let actions: UnifiedSearchPaletteActions

    var body: some View {
        GeometryReader { geometry in
            UnifiedSearchPaletteView(
                pluginHost: pluginHost,
                launchAtLoginController: launchAtLoginController,
                appearanceUserDefaults: appearanceUserDefaults,
                recentStore: commandPaletteRecentStore,
                availableSize: geometry.size,
                presentationOrigin: state.presentationOrigin,
                shortcutHint: state.shortcutHint,
                focusRequestID: state.focusRequestID,
                resetRequestID: state.resetRequestID,
                quickSelectionRequest: state.quickSelectionRequest,
                showsCustomShadow: false,
                actions: actions
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(state.localizationRevision)
        .background(Color.clear)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(
            \.layoutDirection,
            Self.layoutDirection(for: PluginRuntimeLocalization.locale)
        )
    }

    static func layoutDirection(for locale: Locale) -> LayoutDirection {
        locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }
}

enum SettingsPanelPresentationTarget {
    case dashboard
    case featurePanel
}

struct SettingsPanelPresentationActions {
    var showDashboard: () -> Void = {}
    var showFeaturePanel: () -> Void = {}

    func present(_ target: SettingsPanelPresentationTarget) {
        switch target {
        case .dashboard:
            showDashboard()
        case .featurePanel:
            showFeaturePanel()
        }
    }
}

enum SettingsWindowLayout {
    static let defaultContentSize = NSSize(width: 1040, height: 720)
    static let minimumContentSize = NSSize(width: 860, height: 560)
}

@MainActor
final class StandaloneCommandPaletteFocusRestoration {
    typealias Restoration = () -> Void

    private let captureRestoration: () -> Restoration?
    private let canRestore: () -> Bool
    private var pendingRestoration: Restoration?

    init(
        captureRestoration: @escaping () -> Restoration? = {
            guard let application = NSWorkspace.shared.frontmostApplication,
                  application != .current else {
                return nil
            }
            return { application.activate() }
        },
        canRestore: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.captureRestoration = captureRestoration
        self.canRestore = canRestore
    }

    func prepareForPresentation() {
        pendingRestoration = captureRestoration()
    }

    func dismiss(wasVisible: Bool, restoringFocus: Bool) {
        let restoration = pendingRestoration
        pendingRestoration = nil
        guard wasVisible, restoringFocus, canRestore() else { return }
        restoration?()
    }
}

enum StandaloneCommandPaletteSuccessfulExecutionFocusPolicy {
    static func shouldRestorePreviousApplication(
        paletteIsKey: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        paletteIsKey && applicationIsActive
    }
}

@MainActor
final class AppWindowRouter: NSObject, NSWindowDelegate {
    private let pluginHost: PluginHost
    private let appUpdater: AppUpdater
    private let menuBarIconSettings: MenuBarIconSettings
    private let menuBarIconGallery: MenuBarIconGalleryLibrary
    private let launchAtLoginController: LaunchAtLoginController
    private let menuBarPanelThemeStore: MenuBarPanelThemeStore
    private let appearanceUserDefaults: UserDefaults
    let commandPaletteRecentStore: CommandPaletteRecentStore
    private let settingsSidebarPreferences: SettingsSidebarPreferencesStore
    private let commandPaletteFocusRestoration: StandaloneCommandPaletteFocusRestoration
    private(set) var settingsWindow: NSWindow?
    private(set) var settingsNavigationCoordinator: SettingsNavigationCoordinator?
    private(set) var commandPalettePanel: NSPanel?
    private(set) var commandPaletteState: StandaloneCommandPaletteState?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var appDeactivationObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var panelPresentationActions = SettingsPanelPresentationActions()
    private var onProgrammaticSettingsPresentation: () -> Void = {}

    static var settingsWindowTitle: String {
        AppL10n.settings("settings.window.title", defaultValue: "设置")
    }

    static var commandPaletteWindowTitle: String {
        AppL10n.search("search.title", defaultValue: "搜索 MacTools")
    }

    var focusedWindowLayoutTarget: NSWindow? {
        guard let settingsWindow,
              Self.isEligibleFocusedWindowLayoutTarget(
                  isKeyWindow: settingsWindow.isKeyWindow,
                  isVisible: settingsWindow.isVisible,
                  isUnifiedSearchPresented: settingsNavigationCoordinator?.isUnifiedSearchPresented == true
              )
        else {
            return nil
        }
        return settingsWindow
    }

    static func isEligibleFocusedWindowLayoutTarget(
        isKeyWindow: Bool,
        isVisible: Bool,
        isUnifiedSearchPresented: Bool
    ) -> Bool {
        isKeyWindow && isVisible && !isUnifiedSearchPresented
    }

    init(
        pluginHost: PluginHost,
        appUpdater: AppUpdater,
        menuBarIconSettings: MenuBarIconSettings,
        menuBarIconGallery: MenuBarIconGalleryLibrary,
        launchAtLoginController: LaunchAtLoginController,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        appearanceUserDefaults: UserDefaults = .standard,
        commandPaletteFocusRestoration: StandaloneCommandPaletteFocusRestoration = .init()
    ) {
        self.pluginHost = pluginHost
        self.appUpdater = appUpdater
        self.menuBarIconSettings = menuBarIconSettings
        self.menuBarIconGallery = menuBarIconGallery
        self.launchAtLoginController = launchAtLoginController
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        self.appearanceUserDefaults = appearanceUserDefaults
        self.commandPaletteRecentStore = CommandPaletteRecentStore(
            userDefaults: appearanceUserDefaults
        )
        self.settingsSidebarPreferences = SettingsSidebarPreferencesStore(
            userDefaults: appearanceUserDefaults,
            preferencesBackupChangeReporter: pluginHost.preferencesBackupChangeReporter
        )
        self.commandPaletteFocusRestoration = commandPaletteFocusRestoration
        super.init()
        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.settingsWindow?.title = Self.settingsWindowTitle
                    self?.commandPalettePanel?.setAccessibilityTitle(Self.commandPaletteWindowTitle)
                    self?.commandPaletteState?.refreshLocalization()
                }
            }
        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.dismissCommandPalette(restoringFocus: false)
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppAppearancePreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let preference = notification.object as? AppAppearancePreference else {
                return
            }
            Task { @MainActor [weak self] in
                preference.apply(to: self?.settingsWindow)
                self?.applyCommandPaletteAppearance()
            }
        }
    }

    isolated deinit {
        runtimeLocaleCancellable?.cancel()
        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    func showSettings() {
        presentSettings(.settings)
    }

    func showUnifiedSearch() {
        pluginHost.captureCurrentFocusedWindowTarget()
        launchAtLoginController.refreshStatus()
        pluginHost.refreshActionPresentations(providerIDs: ["apple-shortcuts"])
        presentSettings(.settings)
        settingsNavigationCoordinator?.presentUnifiedSearch(origin: .keyboard)
    }

    func windowForActionConfirmation() -> NSWindow? {
        pluginHost.captureCurrentFocusedWindowTarget()
        presentSettings(.settings)
        return settingsWindow
    }

    func toggleCommandPalette() {
        if settingsNavigationCoordinator?.isUnifiedSearchPresented == true {
            if CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: settingsWindow?.isVisible == true,
                isWindowMiniaturized: settingsWindow?.isMiniaturized == true,
                isWindowOnActiveSpace: settingsWindow?.isOnActiveSpace == true
            ) {
                settingsNavigationCoordinator?.dismissUnifiedSearch()
                return
            }

            settingsNavigationCoordinator?.dismissUnifiedSearch()
        }

        if commandPalettePanel?.isVisible == true {
            dismissCommandPalette()
            return
        }

        pluginHost.captureCurrentFocusedWindowTarget()
        launchAtLoginController.refreshStatus()
        pluginHost.refreshActionPresentations(providerIDs: ["apple-shortcuts"])
        onProgrammaticSettingsPresentation()
        let state = commandPaletteState ?? StandaloneCommandPaletteState()
        let panel = commandPalettePanel ?? makeCommandPalettePanel(state: state)
        commandPaletteState = state
        commandPalettePanel = panel

        let shortcutLabel = pluginHost.appShortcutItems.first {
            $0.action == .openCommandPalette
        }?.bindingText ?? ""
        state.prepareForPresentation(shortcutLabel: shortcutLabel)
        applyCommandPaletteAppearance()

        let screens = NSScreen.screens
        let pointerLocation = NSEvent.mouseLocation
        let orderedVisibleFrames = screens
            .filter { $0.frame.contains(pointerLocation) }
            .map(\.visibleFrame)
            + [NSScreen.main?.visibleFrame].compactMap { $0 }
            + screens.map(\.visibleFrame)
        panel.setFrame(
            StandaloneCommandPaletteLayout.frame(
                pointerLocation: pointerLocation,
                visibleFrames: orderedVisibleFrames
            ),
            display: true
        )
        commandPaletteFocusRestoration.prepareForPresentation()
        NSApplication.shared.activate(ignoringOtherApps: true)
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissCommandPalette(restoringFocus: Bool = true) {
        let wasVisible = commandPalettePanel?.isVisible == true
        if wasVisible {
            commandPaletteState?.prepareForDismissal()
        }
        commandPalettePanel?.orderOut(nil)
        commandPaletteFocusRestoration.dismiss(
            wasVisible: wasVisible,
            restoringFocus: restoringFocus
        )
    }

    private func applyCommandPaletteAppearance() {
        let preference = AppAppearancePreference.stored(in: appearanceUserDefaults)
        preference.apply(to: commandPalettePanel)
        preference.apply(to: commandPalettePanel?.contentView)
    }

    func setPanelPresentationActions(
        showDashboard: @escaping () -> Void,
        showFeaturePanel: @escaping () -> Void
    ) {
        panelPresentationActions = SettingsPanelPresentationActions(
            showDashboard: showDashboard,
            showFeaturePanel: showFeaturePanel
        )
    }

    func setProgrammaticSettingsPresentationAction(_ action: @escaping () -> Void) {
        onProgrammaticSettingsPresentation = action
    }

    private func show(_ window: NSWindow) {
        AppWindowPresentation.perform(
            isMiniaturized: window.isMiniaturized,
            activate: {
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            deminiaturize: {
                window.deminiaturize(nil)
            },
            orderFront: {
                PluginPresentationSafety.prepareForWindowOrdering(window)
                window.makeKeyAndOrderFront(nil)
            }
        )
    }

    private func configureSettingsInitialResponder(
        in window: NSWindow,
        hostingView: NSView
    ) {
        window.layoutIfNeeded()

        let listViews = descendantViews(of: hostingView)
            .compactMap { $0 as? NSScrollView }
            .compactMap(\.documentView)
            .compactMap { $0 as? NSTableView }

        let sidebarList: NSTableView?
        if hostingView.userInterfaceLayoutDirection == .rightToLeft {
            sidebarList = listViews.max { lhs, rhs in
                lhs.convert(lhs.bounds, to: hostingView).maxX
                    < rhs.convert(rhs.bounds, to: hostingView).maxX
            }
        } else {
            sidebarList = listViews.min { lhs, rhs in
                lhs.convert(lhs.bounds, to: hostingView).minX
                    < rhs.convert(rhs.bounds, to: hostingView).minX
            }
        }

        if sidebarList?.acceptsFirstResponder == true {
            window.initialFirstResponder = sidebarList
        }
    }

    private func descendantViews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { subview in
            [subview] + descendantViews(of: subview)
        }
    }

    private func makeSettingsWindow() -> NSWindow {
        let navigationCoordinator = SettingsNavigationCoordinator(
            pluginHost: pluginHost,
            sidebarPreferences: settingsSidebarPreferences
        )
        let window = MacToolsCommandWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = Self.settingsWindowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        AppAppearancePreference.stored(in: appearanceUserDefaults).apply(to: window)
        let hostingView = NSHostingView(
            rootView: SettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                appUpdater: appUpdater,
                menuBarIconSettings: menuBarIconSettings,
                menuBarIconGallery: menuBarIconGallery,
                launchAtLoginController: launchAtLoginController,
                menuBarPanelThemeStore: menuBarPanelThemeStore,
                sidebarPreferences: settingsSidebarPreferences,
                appearanceUserDefaults: appearanceUserDefaults,
                commandPaletteRecentStore: commandPaletteRecentStore,
                showDashboard: { [weak self] in
                    self?.panelPresentationActions.present(.dashboard)
                },
                showFeaturePanel: { [weak self] in
                    self?.panelPresentationActions.present(.featurePanel)
                }
            )
        )
        hostingView.sizingOptions = []
        window.contentView = hostingView
        configureSettingsInitialResponder(in: window, hostingView: hostingView)
        window.toolbarStyle = .unified
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.onLocalKeyboardCommand = { [weak self] command in
            self?.handleLocalKeyboardCommand(command) ?? false
        }
        window.center()
        settingsNavigationCoordinator = navigationCoordinator
        return window
    }

    private func makeCommandPalettePanel(
        state: StandaloneCommandPaletteState
    ) -> MacToolsCommandPalettePanel {
        let panel = MacToolsCommandPalettePanel(
            contentRect: NSRect(origin: .zero, size: StandaloneCommandPaletteLayout.contentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let actions = UnifiedSearchPaletteActions(
            dismiss: { [weak self] in
                self?.dismissCommandPalette()
            },
            dismissAfterSuccessfulExecution: { [weak self] in
                self?.dismissCommandPaletteAfterSuccessfulExecution()
            },
            navigate: { [weak self] destination, target in
                self?.navigateFromStandaloneSearch(to: destination, target: target) ?? false
            },
            consumeQuickSelection: state.consumeQuickSelectionRequest,
            setPendingExecutionCancellation: { [weak state] cancellation in
                state?.setPendingExecutionCancellation(cancellation)
            }
        )
        let hostingView = NSHostingView(
            rootView: StandaloneCommandPaletteRootView(
                pluginHost: pluginHost,
                launchAtLoginController: launchAtLoginController,
                appearanceUserDefaults: appearanceUserDefaults,
                commandPaletteRecentStore: commandPaletteRecentStore,
                state: state,
                actions: actions
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let preference = AppAppearancePreference.stored(in: appearanceUserDefaults)
        preference.apply(to: panel)
        preference.apply(to: hostingView)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityTitle(Self.commandPaletteWindowTitle)
        panel.onQuickSelection = state.requestQuickSelection
        panel.onDismiss = { [weak self] in
            self?.dismissCommandPalette()
        }
        return panel
    }

    private func dismissCommandPaletteAfterSuccessfulExecution() {
        let shouldRestoreFocus = StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
            .shouldRestorePreviousApplication(
                paletteIsKey: commandPalettePanel?.isKeyWindow == true,
                applicationIsActive: NSApp.isActive
            )
        dismissCommandPalette(restoringFocus: shouldRestoreFocus)
    }

    @discardableResult
    func navigateFromStandaloneSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        let validator = settingsNavigationCoordinator
            ?? SettingsNavigationCoordinator(
                pluginHost: pluginHost,
                sidebarPreferences: settingsSidebarPreferences
            )
        guard validator.canNavigateFromSearch(to: destination, target: target) else {
            return false
        }

        dismissCommandPalette(restoringFocus: false)
        presentSettings(.settings)
        return settingsNavigationCoordinator?.navigateFromSearch(
            to: destination,
            target: target
        ) ?? false
    }

    func presentSettings(_ request: SettingsPresentationRequest) {
        dismissCommandPalette(restoringFocus: false)
        let window = settingsWindow ?? makeSettingsWindow()
        let pendingAppUpdateVersion: String?

        settingsNavigationCoordinator?.dismissUnifiedSearch()

        switch request {
        case .settings:
            pendingAppUpdateVersion = nil
        case .general:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .general)
        case .about:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .about)
        case .appUpdate:
            pendingAppUpdateVersion = appUpdater.availableUpdateVersion
            settingsNavigationCoordinator?.navigate(to: .about)
        case .pluginMarketplace:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(.marketplace))
        case let .pluginMarketplaceDetail(target):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .marketplaceDetail(target))
        case let .pluginConfiguration(pluginID):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(.configuration(pluginID)))
        case let .automationWorkflow(workflowID):
            pendingAppUpdateVersion = nil
            _ = settingsNavigationCoordinator?.navigateFromSearch(
                to: .plugins(.automation),
                target: .automation(.init(workflowID: workflowID))
            )
        case let .feature(pane):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(pane))
        }

        let contentSize = window.contentView?.bounds.size ?? SettingsWindowLayout.defaultContentSize
        settingsWindow = window
        AppDockVisibilityController.update(hasVisibleSettingsWindow: true)
        show(window)
        // SwiftUI installs its toolbar when the window becomes visible. Finish that
        // layout before restoring the content size.
        window.layoutIfNeeded()
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        onProgrammaticSettingsPresentation()

        if let pendingAppUpdateVersion {
            settingsNavigationCoordinator?.requestAboutUpdateAction(
                version: pendingAppUpdateVersion
            )
        }

    }

    private func handleLocalKeyboardCommand(_ command: MacToolsLocalKeyboardCommand) -> Bool {
        switch command {
        case .showSettings:
            showSettings()
            return true
        case .focusSearch:
            return settingsNavigationCoordinator?.requestSearch() ?? false
        case .showUnifiedSearch:
            showUnifiedSearch()
            return true
        case let .selectNumber(number):
            guard let settingsNavigationCoordinator else {
                return false
            }

            if settingsNavigationCoordinator.requestUnifiedSearchQuickSelection(number: number) {
                return true
            }

            return settingsNavigationCoordinator.selectSidebarDestination(number: number)
        case .goBack:
            guard
                let settingsNavigationCoordinator,
                !settingsNavigationCoordinator.isUnifiedSearchPresented,
                settingsNavigationCoordinator.canGoBack
            else {
                return false
            }
            settingsNavigationCoordinator.goBack()
            return true
        case .goForward:
            guard
                let settingsNavigationCoordinator,
                !settingsNavigationCoordinator.isUnifiedSearchPresented,
                settingsNavigationCoordinator.canGoForward
            else {
                return false
            }
            settingsNavigationCoordinator.goForward()
            return true
        case let .moveSidebarSelection(direction):
            guard
                let settingsNavigationCoordinator,
                !settingsNavigationCoordinator.isUnifiedSearchPresented
            else {
                return false
            }
            return settingsNavigationCoordinator.moveSidebarSelection(direction)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === settingsWindow else {
            return frameSize
        }

        let minimumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: SettingsWindowLayout.minimumContentSize)
        ).size
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else {
            return
        }

        window.delegate = nil
        window.contentView = nil
        settingsWindow = nil
        settingsNavigationCoordinator = nil
        AppDockVisibilityController.update(hasVisibleSettingsWindow: false)
    }
}
