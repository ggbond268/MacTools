import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

enum GeneralSettingsCardLayout {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let iconSize: CGFloat = 30
    static let iconCornerRadius: CGFloat = 8
    static let headerSpacing: CGFloat = 16
    static let minRowHeight: CGFloat = 38
}

private enum SettingsSplitViewLayout {
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 232
    static let sidebarMaxWidth: CGFloat = 280
    static let detailMinWidth: CGFloat = 560
}

private func settingsNavigationTitle(
    for destination: SettingsNavigationDestination,
    configurationItems: [PluginSettingsPageItem]
) -> String {
    switch destination {
    case .general:
        AppL10n.settings("tab.general", defaultValue: "通用")
    case .about:
        AppL10n.settings("tab.about", defaultValue: "关于")
    case .plugins(.actionsAndShortcuts):
        FeatureL10n.string("操作与快捷键")
    case .plugins(.automation):
        FeatureL10n.string("自动化")
    case .plugins(.dashboardLayout):
        AppL10n.settings("plugins.sidebar.dashboard", defaultValue: "仪表盘")
    case .plugins(.featurePanelLayout):
        AppL10n.settings("plugins.sidebar.featurePanel", defaultValue: "功能面板")
    case .plugins(.marketplace):
        AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "市场")
    case let .plugins(.configuration(pluginID)):
        configurationItems.first { $0.id == pluginID }?.title
            ?? AppL10n.settings("tab.plugins", defaultValue: "插件")
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    @ObservedObject var sidebarPreferences: SettingsSidebarPreferencesStore
    let appearanceUserDefaults: UserDefaults
    let commandPaletteRecentStore: CommandPaletteRecentStore
    @StateObject private var uninstallConfirmationSession = PluginUninstallConfirmationSession()
    var showDashboard: () -> Void = {}
    var showFeaturePanel: () -> Void = {}

    var body: some View {
        // Recreate native AppKit-backed controls when the shared locale changes.
        let _ = runtimeLocale.revision
        let configurationItems = pluginHost.pluginSettingsItems
        let orderItems = configurationItems.map {
            SettingsSidebarPluginOrderItem(
                id: $0.id,
                title: $0.title,
                installedAt: $0.installedAt
            )
        }
        let orderedConfigurationIDs = sidebarPreferences.orderedPluginIDs(for: orderItems)
        let orderedSidebarDestinations = SettingsNavigationDestination.settingsSidebarOrder(
            configurationIDs: orderedConfigurationIDs
        )
        let detailTitle = settingsNavigationTitle(
            for: navigationCoordinator.destination,
            configurationItems: pluginHost.pluginSettingsItems
        )

        return NavigationSplitView {
            SettingsSidebarColumn {
                SettingsSidebar(
                    configurationItems: configurationItems,
                    orderedDestinations: orderedSidebarDestinations,
                    sidebarPreferences: sidebarPreferences,
                    selection: settingsSelection,
                    onSearch: {
                        navigationCoordinator.presentUnifiedSearch(origin: .settingsSidebar)
                    }
                )
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(
                min: SettingsSplitViewLayout.sidebarMinWidth,
                ideal: SettingsSplitViewLayout.sidebarIdealWidth,
                max: SettingsSplitViewLayout.sidebarMaxWidth
            )
        } detail: {
            SettingsDetailColumn {
                SettingsDetailPane(
                    pluginHost: pluginHost,
                    navigationCoordinator: navigationCoordinator,
                    destination: navigationCoordinator.destination,
                    uninstallConfirmationSession: uninstallConfirmationSession,
                    appUpdater: appUpdater,
                    menuBarIconSettings: menuBarIconSettings,
                    menuBarIconGallery: menuBarIconGallery,
                    launchAtLoginController: launchAtLoginController,
                    menuBarPanelThemeStore: menuBarPanelThemeStore,
                    appearanceUserDefaults: appearanceUserDefaults,
                    showDashboard: showDashboard,
                    showFeaturePanel: showFeaturePanel
                )
            }
            .frame(
                minWidth: SettingsSplitViewLayout.detailMinWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        historyNavigationControls
                    }
                    .sharedBackgroundVisibility(
                        navigationCoordinator.isUnifiedSearchPresented ? .hidden : .automatic
                    )

                    ToolbarItem(placement: .navigation) {
                        SettingsDetailToolbarTitle(
                            title: detailTitle,
                            isHidden: navigationCoordinator.isUnifiedSearchPresented
                        )
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        historyNavigationControls
                    }

                    ToolbarItem(placement: .navigation) {
                        SettingsDetailToolbarTitle(
                            title: detailTitle,
                            isHidden: navigationCoordinator.isUnifiedSearchPresented
                        )
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: pluginHost.pluginSettingsItems.map(\.id)) {
            navigationCoordinator.reconcileCurrentDestinationAvailability()
        }
        .blur(
            radius: navigationCoordinator.isUnifiedSearchPresented
                && !accessibilityReduceTransparency
                ? 2.5
                : 0
        )
        .allowsHitTesting(!navigationCoordinator.isUnifiedSearchPresented)
        .accessibilityHidden(navigationCoordinator.isUnifiedSearchPresented)
        .overlay {
            Group {
                if navigationCoordinator.isUnifiedSearchPresented {
                    UnifiedSearchPresentationView(
                        pluginHost: pluginHost,
                        launchAtLoginController: launchAtLoginController,
                        appearanceUserDefaults: appearanceUserDefaults,
                        recentStore: commandPaletteRecentStore,
                        navigationCoordinator: navigationCoordinator
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeOut(duration: 0.14), value: navigationCoordinator.isUnifiedSearchPresented)
        }
        .id(runtimeLocale.revision)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
    }

    private var settingsSelection: Binding<SettingsNavigationDestination> {
        Binding {
            navigationCoordinator.destination
        } set: { destination in
            navigationCoordinator.navigate(to: destination)
        }
    }

    private var historyNavigationControls: some View {
        SettingsHistoryNavigationControls(
            coordinator: navigationCoordinator
        )
        .opacity(navigationCoordinator.isUnifiedSearchPresented ? 0 : 1)
        .allowsHitTesting(!navigationCoordinator.isUnifiedSearchPresented)
        .accessibilityHidden(navigationCoordinator.isUnifiedSearchPresented)
        .accessibilityIdentifier("mactools.settings.history-navigation")
    }

    private var layoutDirection: LayoutDirection {
        PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

}

struct SettingsHistoryNavigationControls: View {
    @ObservedObject var coordinator: SettingsNavigationCoordinator

    var body: some View {
        ControlGroup {
            Button {
                coordinator.goBack()
            } label: {
                Label(backTitle, systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!coordinator.canGoBack)
            .help(backTitle)

            Button {
                coordinator.goForward()
            } label: {
                Label(forwardTitle, systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!coordinator.canGoForward)
            .help(forwardTitle)
        }
        .controlGroupStyle(.navigation)
    }

    private var backTitle: String {
        AppL10n.settings("navigation.back", defaultValue: "后退")
    }

    private var forwardTitle: String {
        AppL10n.settings("navigation.forward", defaultValue: "前进")
    }
}

private struct PermissionSettingsRow: View {
    let card: PluginPermissionCard
    let statusColor: Color
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: card.iconSystemImage)
                .pluginSettingsRowIconStyle(visualScale: card.iconVisualScale)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(card.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Label {
                        Text(card.statusText)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: card.statusSystemImage)
                    }
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(statusColor)
                }

                Text(card.description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote = card.footnote {
                    Text(footnote)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(card.buttonTitle, action: onAction)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    @ObservedObject private var cliService = CLIBrokerServiceController.shared
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appearancePreferenceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var languagePreferenceRawValue = AppLanguagePreference.system.rawValue
    @AppStorage(MenuBarClickBehaviorPreference.userDefaultsKey) private var clickBehaviorRawValue = MenuBarClickBehaviorPreference.standard.rawValue
    @State private var activeSearchTarget: GeneralSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    init(
        pluginHost: PluginHost,
        navigationCoordinator: SettingsNavigationCoordinator,
        menuBarIconSettings: MenuBarIconSettings,
        menuBarIconGallery: MenuBarIconGalleryLibrary,
        launchAtLoginController: LaunchAtLoginController,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        appearanceUserDefaults: UserDefaults
    ) {
        self.pluginHost = pluginHost
        self.navigationCoordinator = navigationCoordinator
        self.menuBarIconSettings = menuBarIconSettings
        self.menuBarIconGallery = menuBarIconGallery
        self.launchAtLoginController = launchAtLoginController
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        _appearancePreferenceRawValue = AppStorage(
            wrappedValue: AppAppearancePreference.system.rawValue,
            AppAppearancePreference.userDefaultsKey,
            store: appearanceUserDefaults
        )
        _languagePreferenceRawValue = AppStorage(
            wrappedValue: AppLanguagePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey,
            store: appearanceUserDefaults
        )
        _clickBehaviorRawValue = AppStorage(
            wrappedValue: MenuBarClickBehaviorPreference.standard.rawValue,
            MenuBarClickBehaviorPreference.userDefaultsKey,
            store: appearanceUserDefaults
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsGroupedFormLayout(widthPolicy: .general) { widths in
                Section {
                    LaunchAtLoginSettingsRow(controller: launchAtLoginController)
                        .generalSettingsSearchAnchor(
                            target: .launchAtLogin,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.startup", defaultValue: "启动"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    CLISettingsRow(service: cliService)
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.commandLine", defaultValue: "命令行"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    AppearanceSettingsRow(
                        selectionRawValue: appearancePreferenceBinding
                    )
                        .generalSettingsSearchAnchor(
                            target: .appearance,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    MenuBarPanelThemeSettingsRow(
                        themeStore: menuBarPanelThemeStore,
                        appearancePreference: AppAppearancePreference(
                            rawValue: appearancePreferenceRawValue
                        ) ?? .system
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                    LanguageSettingsRow(selectionRawValue: languagePreferenceBinding)
                        .generalSettingsSearchAnchor(
                            target: .language,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.appearance", defaultValue: "外观"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    MenuBarIconSettingsView(
                        iconSettings: menuBarIconSettings,
                        gallery: menuBarIconGallery
                    )
                    .generalSettingsSearchAnchor(
                        target: .menuBarIcon,
                        activeTarget: activeSearchTarget
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                    MenuBarClickBehaviorSettingsRow(selectionRawValue: clickBehaviorPreferenceBinding)
                        .generalSettingsSearchAnchor(
                            target: .menuBarClickBehavior,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.menuBarIcon", defaultValue: "状态栏图标"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    AppShortcutSettingsRows(pluginHost: pluginHost)
                        .generalSettingsSearchAnchor(
                            target: .appShortcuts,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    PreferencesBackupSettingsRow(pluginHost: pluginHost)
                        .generalSettingsSearchAnchor(
                            target: .preferencesBackup,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.preferencesBackup(
                            "general.section.preferencesBackup",
                            defaultValue: "偏好设置备份"
                        ),
                        layoutWidth: widths.readableContent
                    )
                }
            }
            .onAppear {
                applySearchRevealRequest(
                    navigationCoordinator.searchRevealRequest,
                    proxy: proxy
                )
            }
            .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                applySearchRevealRequest(request, proxy: proxy)
            }
            .onDisappear {
                clearSearchTargetTask?.cancel()
                clearSearchTargetTask = nil
                if let activeSearchTarget {
                    navigationCoordinator.clearSearchRevealRequest(
                        matching: .general(activeSearchTarget)
                    )
                }
                activeSearchTarget = nil
            }
        }
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        proxy: ScrollViewProxy
    ) {
        guard
            let request,
            case let .general(target) = request.target
        else {
            return
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID, anchor: .center)
            }
        }

        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
    }

    private var appearancePreferenceBinding: Binding<String> {
        Binding(
            get: { appearancePreferenceRawValue },
            set: { rawValue in
                guard pluginHost.setApplicationAppearancePreference(rawValue: rawValue) else {
                    return
                }
                appearancePreferenceRawValue = rawValue
            }
        )
    }

    private var languagePreferenceBinding: Binding<String> {
        Binding(
            get: { languagePreferenceRawValue },
            set: { rawValue in
                guard pluginHost.setApplicationLanguagePreference(rawValue: rawValue) else {
                    return
                }
                languagePreferenceRawValue = rawValue
            }
        )
    }

    private var clickBehaviorPreferenceBinding: Binding<String> {
        Binding(
            get: { clickBehaviorRawValue },
            set: { rawValue in
                guard pluginHost.setMenuBarClickBehaviorPreference(rawValue: rawValue) else {
                    return
                }
                clickBehaviorRawValue = rawValue
            }
        )
    }
}

private struct CLISettingsRow: View {
    @ObservedObject var service: CLIBrokerServiceController

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: GeneralSettingsCardLayout.iconCornerRadius,
                    style: .continuous
                )
                .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "terminal")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(
                width: GeneralSettingsCardLayout.iconSize,
                height: GeneralSettingsCardLayout.iconSize
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("commandLine.title", defaultValue: "MacTools 命令行"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(service.lastError == nil ? .secondary : Color.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if service.status == .requiresApproval {
                Button(AppL10n.settings("commandLine.approve", defaultValue: "允许后台运行")) {
                    service.openApprovalSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Toggle(
                AppL10n.settings("commandLine.enable", defaultValue: "启用"),
                isOn: Binding(
                    get: { service.isRegistered },
                    set: { enabled in
                        if enabled {
                            _ = service.ensureRegistered()
                        } else {
                            _ = service.unregister()
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeneralSettingsCardLayout.minRowHeight,
            alignment: .leading
        )
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .onAppear { service.refresh() }
    }

    private var subtitle: String {
        if let error = service.lastError { return error }
        switch service.status {
        case .enabled:
            return AppL10n.settings(
                "commandLine.enabled",
                defaultValue: "已允许单独安装的 mactools-cli 连接到 MacTools。"
            )
        case .requiresApproval:
            return AppL10n.settings(
                "commandLine.requiresApproval",
                defaultValue: "请在系统设置中允许 MacTools 命令行代理后台运行。"
            )
        case .notRegistered, .notFound, .registrationFailed:
            return AppL10n.settings(
                "commandLine.description",
                defaultValue: "单独安装 mactools-cli 后，在此启用本机命令行集成。"
            )
        }
    }
}

private struct GeneralSettingsSearchAnchorModifier: ViewModifier {
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    let target: GeneralSettingsSearchTarget
    let activeTarget: GeneralSettingsSearchTarget?

    func body(content: Content) -> some View {
        content
            .id(target.scrollID)
            .accessibilityFocused($isAccessibilityFocused)
            .overlay {
                if activeTarget == target {
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.card,
                        style: .continuous
                    )
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                focusIfNeeded(activeTarget)
            }
            .onChange(of: activeTarget) { _, newValue in
                focusIfNeeded(newValue)
            }
    }

    private func focusIfNeeded(_ activeTarget: GeneralSettingsSearchTarget?) {
        guard activeTarget == target else {
            return
        }

        isAccessibilityFocused = true
    }
}

private extension View {
    func generalSettingsSearchAnchor(
        target: GeneralSettingsSearchTarget,
        activeTarget: GeneralSettingsSearchTarget?
    ) -> some View {
        modifier(
            GeneralSettingsSearchAnchorModifier(
                target: target,
                activeTarget: activeTarget
            )
        )
    }
}

private struct AppShortcutSettingsRows: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(pluginHost.appShortcutItems.enumerated()), id: \.element.id) { index, item in
                AppShortcutSettingsRow(pluginHost: pluginHost, item: item)

                if index < pluginHost.appShortcutItems.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
    }
}

private struct AppShortcutSettingsRow: View {
    private enum Layout {
        static let recorderWidth = PluginSettingsTheme.Size.shortcutRecorderWidth
        static let actionButtonSize: CGFloat = 22
        static let controlSpacing = PluginSettingsTheme.Spacing.controlCluster
        static let controlClusterWidth = recorderWidth + controlSpacing + actionButtonSize
        static let summaryMinWidth: CGFloat = 220
    }

    @ObservedObject var pluginHost: PluginHost
    let item: AppShortcutSettingsItem
    @State private var pendingWarning: CommonShortcutBindingWarning?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                appIcon
                summary
                    .frame(minWidth: Layout.summaryMinWidth)
                shortcutControl
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                    appIcon
                    summary
                }

                shortcutControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .alert(item: $pendingWarning) { warning in
            commonShortcutBindingWarningAlert(warning) {
                _ = save(warning.binding)
            }
        }
    }

    private func record(_ binding: ShortcutBinding) -> PluginShortcutRecordingResult {
        if MacToolsReservedShortcutBindings.requiresConflictWarning(for: binding) {
            pendingWarning = CommonShortcutBindingWarning(shortcutID: item.id, binding: binding)
            return .accepted
        }

        return PluginShortcutRecordingResult.from(errorMessage: save(binding))
    }

    private func save(_ binding: ShortcutBinding) -> String? {
        pluginHost.setAppShortcutBindingAndReturnError(
            binding,
            for: item.action,
            assignmentID: item.assignmentID
        )
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))

            Image(systemName: item.systemImage)
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(item.errorMessage ?? item.description)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(item.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var shortcutControl: some View {
        HStack(spacing: Layout.controlSpacing) {
            PluginShortcutRecorder(
                title: item.title,
                displayText: item.bindingText,
                minWidth: Layout.recorderWidth,
                onRecord: { binding in
                    record(binding)
                },
                onBeginRecording: {
                    pluginHost.clearAppShortcutError(item.action)
                }
            )
            .frame(width: Layout.recorderWidth)

            if item.canClear {
                Button {
                    pluginHost.clearAppShortcut(
                        item.action,
                        assignmentID: item.assignmentID
                    )
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PluginSettingsTheme.Typography.rowIcon)
                        .symbolRenderingMode(.monochrome)
                        .frame(
                            width: Layout.actionButtonSize,
                            height: Layout.actionButtonSize
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                .help(AppL10n.settings("shortcuts.clearHelp", defaultValue: "清除快捷键"))
            } else {
                Color.clear
                    .frame(width: Layout.actionButtonSize, height: Layout.actionButtonSize)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Layout.controlClusterWidth, alignment: .trailing)
    }
}

private struct PendingPreferencesImport: Identifiable {
    let id = UUID()
    let backup: PreferencesBackup
    let preview: PreferencesImportPreview
}

private struct PreferencesBackupSettingsRow: View {
    private enum ManualBackupFeedback {
        case created
        case unchanged
    }

    @ObservedObject var pluginHost: PluginHost
    @State private var pendingImport: PendingPreferencesImport?
    @State private var isChoosingExport = false
    @State private var exportSelection = PreferencesBackupSelection.all(pluginPreferenceIDs: [])
    @State private var exportPluginOptions: [PreferencesPluginOption] = []
    @State private var deviceLocalAutomationRuleCount = 0
    @State private var alertMessage: String?
    @State private var isPreparingImport = false
    @State private var isImporting = false
    @State private var isBackingUp = false
    @State private var manualBackupFeedback: ManualBackupFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))

                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup("preferencesBackup.title", defaultValue: "偏好设置备份"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.description",
                        defaultValue: "自动备份保存在本机，包含可移植的应用与插件设置；不包含权限、缓存、凭证或其他私密数据。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)

            backupRowDivider

            Toggle(
                isOn: Binding(
                    get: { pluginHost.automaticPreferencesBackupEnabled },
                    set: { enabled in
                        pluginHost.setAutomaticPreferencesBackupEnabled(enabled)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        AppL10n.preferencesBackup(
                            "preferencesBackup.automatic.enabled",
                            defaultValue: "自动备份设置"
                        )
                    )
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    automaticBackupSummaryView
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            backupRowDivider

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.manual.title",
                        defaultValue: "手动备份"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    if let manualBackupFeedback {
                        Text(manualBackupFeedbackText(manualBackupFeedback))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button(
                    AppL10n.preferencesBackup(
                        "preferencesBackup.automatic.backUpNow",
                        defaultValue: "立即备份"
                    ),
                    action: backUpNow
                )
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting || isBackingUp)

                Button(
                    AppL10n.preferencesBackup(
                        "preferencesBackup.automatic.openFolder",
                        defaultValue: "打开备份文件夹"
                    ),
                    action: openBackupFolder
                )
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting)
            }
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            backupRowDivider

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.transfer.title",
                    defaultValue: "迁移偏好设置"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button(AppL10n.preferencesBackup("preferencesBackup.export", defaultValue: "导出偏好设置…"), action: exportPreferences)
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting || isBackingUp)

                Button(AppL10n.preferencesBackup("preferencesBackup.import", defaultValue: "导入偏好设置…"), action: choosePreferencesImport)
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting || isBackingUp)
            }
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .sheet(item: $pendingImport) { pending in
            PreferencesImportPreviewSheet(
                preview: pending.preview,
                previewProvider: { selection in
                    try pluginHost.preferencesImportPreview(
                        for: pending.backup,
                        selection: selection
                    )
                },
                pluginOptions: pluginOptions(for: Set(pending.backup.pluginPreferences.keys)),
                isImporting: isImporting,
                onCancel: { pendingImport = nil },
                onImport: { selectedPluginIDs, selection in
                    importPreferences(
                        pending.backup,
                        installingMissingPluginIDs: selectedPluginIDs,
                        selection: selection
                    )
                }
            )
        }
        .sheet(isPresented: $isChoosingExport) {
            PreferencesExportSelectionSheet(
                selection: $exportSelection,
                pluginOptions: exportPluginOptions,
                deviceLocalAutomationRuleCount: deviceLocalAutomationRuleCount,
                onCancel: { isChoosingExport = false },
                onExport: {
                    isChoosingExport = false
                    savePreferences(selection: exportSelection)
                }
            )
        }
        .alert(
            AppL10n.preferencesBackup("preferencesBackup.alert.title", defaultValue: "偏好设置备份"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var backupRowDivider: some View {
        PluginSettingsListDivider(
            leadingInset: GeneralSettingsCardLayout.horizontalPadding,
            trailingInset: GeneralSettingsCardLayout.horizontalPadding
        )
    }

    @ViewBuilder
    private var automaticBackupSummaryView: some View {
        let summary = pluginHost.automaticPreferencesBackupSummary
        if let latestBackupDate = summary.latestBackupDate {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 1) {
                    Text(automaticBackupRelativeText(
                        latestBackupDate,
                        relativeTo: context.date
                    ))
                    Text(automaticBackupDetailsText(
                        summary,
                        latestBackupDate: latestBackupDate
                    ))
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text(AppL10n.preferencesBackup(
                "preferencesBackup.automatic.noBackups",
                defaultValue: "还没有备份"
            ))
        }
    }

    private func automaticBackupRelativeText(
        _ latestBackupDate: Date,
        relativeTo referenceDate: Date
    ) -> String {
        let locale = PluginRuntimeLocalization.locale
        let relativeDate = PreferencesBackupStatusFormatter.relativeDate(
            latestBackupDate,
            relativeTo: referenceDate,
            locale: locale,
            justNow: AppL10n.preferencesBackup(
                "preferencesBackup.automatic.justNow",
                defaultValue: "刚刚"
            )
        )
        return String(
            format: AppL10n.preferencesBackup(
                "preferencesBackup.automatic.lastBackup",
                defaultValue: "上次备份：%@"
            ),
            locale: locale,
            relativeDate
        )
    }

    private func automaticBackupDetailsText(
        _ summary: AutomaticPreferencesBackupSummary,
        latestBackupDate: Date
    ) -> String {
        let locale = PluginRuntimeLocalization.locale
        let date = PreferencesBackupStatusFormatter.absoluteDate(
            latestBackupDate,
            locale: locale
        )
        let size = PreferencesBackupStatusFormatter.byteCount(
            summary.totalSize,
            locale: locale
        )
        let history = AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.automatic.history",
            defaultValue: "%d 个备份 · %@",
            count: summary.snapshotCount,
            size
        )
        return "\(date) · \(history)"
    }

    private func manualBackupFeedbackText(_ feedback: ManualBackupFeedback) -> String {
        switch feedback {
        case .created:
            AppL10n.preferencesBackup(
                "preferencesBackup.manual.created",
                defaultValue: "刚刚已备份"
            )
        case .unchanged:
            AppL10n.preferencesBackup(
                "preferencesBackup.manual.unchanged",
                defaultValue: "与上次备份相比没有变化"
            )
        }
    }

    private func backUpNow() {
        Task { @MainActor in
            isBackingUp = true
            defer { isBackingUp = false }
            do {
                let result = try await pluginHost.createAutomaticPreferencesBackupNow()
                switch result {
                case .created:
                    manualBackupFeedback = .created
                case .unchanged:
                    manualBackupFeedback = .unchanged
                }
            } catch {
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func openBackupFolder() {
        do {
            NSWorkspace.shared.open(
                try pluginHost.prepareAutomaticPreferencesBackupDirectory()
            )
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
        }
    }

    private func exportPreferences() {
        let backup = pluginHost.makePreferencesBackup()
        exportSelection = .all(pluginPreferenceIDs: Set(backup.pluginPreferences.keys))
        exportPluginOptions = pluginOptions(for: Set(backup.pluginPreferences.keys))
        deviceLocalAutomationRuleCount = pluginHost.deviceLocalAutomationRuleCount
        isChoosingExport = true
    }

    private func savePreferences(selection: PreferencesBackupSelection) {
        let data: Data
        do {
            data = try pluginHost.makePreferencesBackup(selection: selection).encodedJSON()
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PreferencesBackupExportFileName.make()
        panel.message = AppL10n.preferencesBackup("preferencesBackup.export.prompt", defaultValue: "将可移植的 MacTools 偏好设置保存为 JSON 文件。")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            alertMessage = AppL10n.preferencesBackup("preferencesBackup.exported", defaultValue: "偏好设置已导出。")
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
        }
    }

    private func choosePreferencesImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = AppL10n.preferencesBackup("preferencesBackup.import.prompt", defaultValue: "选择 MacTools 导出的偏好设置 JSON 文件。")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            isPreparingImport = true
            defer { isPreparingImport = false }

            do {
                let backup = try await PreferencesBackup.decodeJSON(contentsOf: url)
                await pluginHost.refreshPluginCatalog()
                pendingImport = PendingPreferencesImport(
                    backup: backup,
                    preview: try pluginHost.preferencesImportPreview(for: backup)
                )
            } catch {
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func importPreferences(
        _ backup: PreferencesBackup,
        installingMissingPluginIDs pluginIDs: Set<String>,
        selection: PreferencesBackupSelection
    ) {
        Task { @MainActor in
            isImporting = true
            defer { isImporting = false }

            do {
                let result = try await pluginHost.importPreferences(
                    backup,
                    installingMissingPluginIDs: pluginIDs,
                    selection: selection
                )
                pendingImport = nil
                let importedMessage = AppL10n.preferencesBackup(
                    "preferencesBackup.imported",
                    defaultValue: "偏好设置已导入。"
                )
                let warnings = result.pluginInstallationFailures
                    .sorted { $0.key < $1.key }
                    .map { pluginID, message in
                        let title = pluginHost.pluginManagementItems
                            .first(where: { $0.id == pluginID })?
                            .title
                            ?? pluginID
                        return "\(title): \(message)"
                    }
                    + result.shortcutErrors
                        .values
                        .sorted()
                alertMessage = warnings.isEmpty
                    ? importedMessage
                    : ([importedMessage] + warnings).joined(separator: "\n")
            } catch {
                pendingImport = nil
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func pluginOptions(for pluginIDs: Set<String>) -> [PreferencesPluginOption] {
        let titles = Dictionary(
            pluginHost.pluginManagementItems.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        return pluginIDs.map { id in
            PreferencesPluginOption(id: id, title: titles[id] ?? id)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private func preferencesBackupErrorMessage(_ error: Error) -> String {
        switch error as? PreferencesBackupError {
        case let .unsupportedFormatVersion(version):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.unsupportedFormat",
                defaultValue: "不支持的偏好设置备份版本（%d）。",
                version
            )
        case .invalidApplicationPreferences:
            return AppL10n.preferencesBackup(
                "preferencesBackup.error.invalidApplicationPreferences",
                defaultValue: "备份中的应用偏好设置无效。"
            )
        case let .fileTooLarge(maximumBytes):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.fileTooLarge",
                defaultValue: "偏好设置备份不能超过 %d MB。",
                maximumBytes / (1024 * 1024)
            )
        case nil:
            return error.localizedDescription
        }
    }
}

private struct PreferencesPluginOption: Identifiable, Equatable {
    let id: String
    let title: String
}

enum PreferencesBackupStatusFormatter {
    static func relativeDate(
        _ date: Date,
        relativeTo referenceDate: Date,
        locale: Locale,
        justNow: String
    ) -> String {
        guard referenceDate.timeIntervalSince(date) >= 60 else {
            return justNow
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    static func absoluteDate(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func byteCount(_ count: Int, locale: Locale) -> String {
        Int64(count).formatted(
            ByteCountFormatStyle(style: .file).locale(locale)
        )
    }
}

private struct PreferencesExportSelectionSheet: View {
    @Binding var selection: PreferencesBackupSelection
    let pluginOptions: [PreferencesPluginOption]
    let deviceLocalAutomationRuleCount: Int
    let onCancel: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppL10n.preferencesBackup(
                "preferencesBackup.exportSelection.title",
                defaultValue: "选择要导出的偏好设置"
            ))
            .font(PluginSettingsTheme.Typography.pageTitle)

            Text(AppL10n.preferencesBackup(
                "preferencesBackup.selection.description",
                defaultValue: "仅导出所选类别。导入时还可以再次选择要恢复的内容。"
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            PreferencesSelectionFields(
                selection: $selection,
                pluginOptions: pluginOptions
            )

            if selection.includesAutomation, deviceLocalAutomationRuleCount > 0 {
                Label {
                    Text(AppL10n.preferencesBackupFormat(
                        "preferencesBackup.exportSelection.deviceLocalRulesOmitted",
                        defaultValue: "%d 条绑定到此 Mac 显示器的自动化规则不会导出。",
                        deviceLocalAutomationRuleCount
                    ))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(AppL10n.settings("common.cancel", defaultValue: "取消"), action: onCancel)
                    .buttonStyle(.bordered)
                Button(AppL10n.preferencesBackup(
                    "preferencesBackup.exportSelection.confirm",
                    defaultValue: "继续导出…"
                ), action: onExport)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PreferencesSelectionFields: View {
    @Binding var selection: PreferencesBackupSelection
    let pluginOptions: [PreferencesPluginOption]
    var availableSelection: PreferencesBackupSelection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.preview.application",
                    defaultValue: "应用偏好"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.application.description",
                    defaultValue: "外观、语言和菜单栏点击方式；不包含权限、登录项或凭证。"
                ),
                isOn: $selection.includesApplicationPreferences,
                isAvailable: availableSelection?.includesApplicationPreferences ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.pluginLayout",
                    defaultValue: "插件布局与可见性"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.pluginLayout.description",
                    defaultValue: "恢复仪表盘和功能面板中的插件顺序与可见性；缺失插件需要另外安装。"
                ),
                isOn: $selection.includesPluginLayout,
                isAvailable: availableSelection?.includesPluginLayout ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.preview.shortcuts",
                    defaultValue: "快捷键"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.shortcuts.description",
                    defaultValue: "恢复应用和操作快捷键；插件操作还需要对应插件及其设置。"
                ),
                isOn: $selection.includesShortcuts,
                isAvailable: availableSelection?.includesShortcuts ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.automation",
                    defaultValue: "工作流与自动化规则"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.automation.description",
                    defaultValue: "保留工作流标识和直接 Run Link；工作流步骤仍需要对应插件及其设置。"
                ),
                isOn: $selection.includesAutomation,
                isAvailable: availableSelection?.includesAutomation ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.runLinks",
                    defaultValue: "已保存的 Run Link"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.runLinks.description",
                    defaultValue: "参数化操作的已保存链接；工作流链接随“工作流与自动化规则”一起恢复。"
                ),
                isOn: $selection.includesRunLinks,
                isAvailable: availableSelection?.includesRunLinks ?? true
            )

            if !pluginOptions.isEmpty {
                Divider()
                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.preview.plugins",
                    defaultValue: "插件设置"
                ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.selection.plugins.description",
                    defaultValue: "仅包含插件声明为可移植的设置。脚本文本等敏感内容仍需在对应插件中单独允许备份。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(pluginOptions) { plugin in
                    Toggle(plugin.title, isOn: pluginSelectionBinding(plugin.id))
                        .toggleStyle(.checkbox)
                        .padding(.leading, 18)
                        .disabled(
                            availableSelection.map {
                                !$0.pluginPreferenceIDs.contains(plugin.id)
                            } ?? false
                        )
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(PluginSettingsTheme.Typography.rowTitle)
        .padding(16)
        .pluginSettingsCardBackground(.standard)
    }

    private func selectionRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        isAvailable: Bool
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!isAvailable)
    }

    private func pluginSelectionBinding(_ pluginID: String) -> Binding<Bool> {
        Binding {
            selection.pluginPreferenceIDs.contains(pluginID)
        } set: { selected in
            if selected {
                selection.pluginPreferenceIDs.insert(pluginID)
            } else {
                selection.pluginPreferenceIDs.remove(pluginID)
            }
        }
    }
}

enum PreferencesBackupExportFileName {
    static func make(date: Date = .now, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "MacTools Preferences \(formatter.string(from: date)).json"
    }
}

private struct PreferencesImportPreviewSheet: View {
    let preview: PreferencesImportPreview
    let previewProvider: (PreferencesBackupSelection) throws -> PreferencesImportPreview
    let pluginOptions: [PreferencesPluginOption]
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: (Set<String>, PreferencesBackupSelection) -> Void
    @State private var selectedInstallablePluginIDs: Set<String> = []
    @State private var selection: PreferencesBackupSelection
    @State private var currentPreview: PreferencesImportPreview
    @State private var previewErrorMessage: String?

    init(
        preview: PreferencesImportPreview,
        previewProvider: @escaping (PreferencesBackupSelection) throws -> PreferencesImportPreview,
        pluginOptions: [PreferencesPluginOption],
        isImporting: Bool,
        onCancel: @escaping () -> Void,
        onImport: @escaping (Set<String>, PreferencesBackupSelection) -> Void
    ) {
        self.preview = preview
        self.previewProvider = previewProvider
        self.pluginOptions = pluginOptions
        self.isImporting = isImporting
        self.onCancel = onCancel
        self.onImport = onImport
        var availableSelection = preview.selection
        availableSelection.pluginPreferenceIDs.formIntersection(pluginOptions.map(\.id))
        _selection = State(initialValue: availableSelection)
        do {
            _currentPreview = State(initialValue: try previewProvider(availableSelection))
            _previewErrorMessage = State(initialValue: nil)
        } catch {
            _currentPreview = State(initialValue: preview)
            _previewErrorMessage = State(initialValue: error.localizedDescription)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                previewContent
                    .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
                Button(AppL10n.settings("common.cancel", defaultValue: "取消"), action: onCancel)
                    .buttonStyle(.bordered)
                    .disabled(isImporting)
                Button(confirmTitle) {
                    onImport(selectedInstallablePluginIDs, selection)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || selection.isEmpty || previewErrorMessage != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 640)
        .onChange(of: selection) { _, selection in
            refreshPreview(for: selection)
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppL10n.preferencesBackup("preferencesBackup.preview.title", defaultValue: "导入偏好设置"))
                .font(PluginSettingsTheme.Typography.pageTitle)

            Text(previewDescription)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PreferencesSelectionFields(
                selection: $selection,
                pluginOptions: pluginOptions,
                availableSelection: preview.selection
            )

            if let previewErrorMessage {
                Text(previewErrorMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }

            Text(AppL10n.preferencesBackup(
                "preferencesBackup.preview.replaceNotice",
                defaultValue: "将替换以上偏好类别；备份中未包含的设置会恢复为默认值。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !currentPreview.installablePlugins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.preview.installablePlugins",
                        defaultValue: "可安装的缺失插件"
                    ))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.preview.installablePluginsDescription",
                        defaultValue: "仅会从已验证的插件列表下载你选中的插件。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(currentPreview.installablePlugins) { plugin in
                        Toggle(isOn: installationSelectionBinding(for: plugin.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.title)
                                    .font(PluginSettingsTheme.Typography.rowTitle)

                                Text("\(plugin.version) · \(plugin.summary ?? plugin.id)")
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            if !currentPreview.unavailablePluginIDs.isEmpty
                || !currentPreview.unavailableShortcutIDs.isEmpty
                || !currentPreview.unavailableActionReferences.isEmpty {
                Text(AppL10n.preferencesBackupFormat(
                    "preferencesBackup.preview.skipped",
                    defaultValue: "将跳过 %d 个本机不可用的插件设置、%d 项快捷键和 %d 个不可用或不可移植的操作；不会安装缺失插件。",
                    currentPreview.unavailablePluginIDs.count,
                    currentPreview.unavailableShortcutIDs.count,
                    currentPreview.unavailableActionReferences.count
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            if !currentPreview.retainedUnavailableActionReferences.isEmpty {
                Text(AppL10n.preferencesBackupFormat(
                    "preferencesBackup.preview.retainedUnavailableActions",
                    defaultValue: "将保留 %d 个当前不可用的操作；对应插件恢复后可继续使用。",
                    currentPreview.retainedUnavailableActionReferences.count
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmTitle: String {
        if selectedInstallablePluginIDs.isEmpty {
            return AppL10n.preferencesBackup("preferencesBackup.preview.confirm", defaultValue: "导入")
        }

        return AppL10n.preferencesBackup(
            "preferencesBackup.preview.installAndImport",
            defaultValue: "安装所选插件并导入"
        )
    }

    private var previewDescription: String {
        if selectedInstallablePluginIDs.isEmpty {
            return AppL10n.preferencesBackup(
                "preferencesBackup.preview.description",
                defaultValue: "请确认以下更改。导入不会安装插件，也不会修改权限、缓存、Keychain 密钥或插件私有数据。"
            )
        }

        return AppL10n.preferencesBackup(
            "preferencesBackup.description",
            defaultValue: "包含应用偏好、插件布局、快捷键、工作流、自动化规则、已保存的运行链接和支持导出的插件设置；不包含权限、缓存、凭证或运行历史。"
        )
    }

    private func installationSelectionBinding(for pluginID: String) -> Binding<Bool> {
        Binding {
            selectedInstallablePluginIDs.contains(pluginID)
        } set: { isSelected in
            if isSelected {
                selectedInstallablePluginIDs.insert(pluginID)
            } else {
                selectedInstallablePluginIDs.remove(pluginID)
            }
        }
    }

    private func refreshPreview(for selection: PreferencesBackupSelection) {
        do {
            let refreshed = try previewProvider(selection)
            currentPreview = refreshed
            selectedInstallablePluginIDs.formIntersection(
                refreshed.installablePlugins.map(\.id)
            )
            previewErrorMessage = nil
        } catch {
            previewErrorMessage = error.localizedDescription
            selectedInstallablePluginIDs.removeAll()
        }
    }
}

private struct MenuBarClickBehaviorSettingsRow: View {
    @Binding var selectionRawValue: String
    @State private var isSwapped = false
    @State private var toggleID = UUID()

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "cursorarrow.click.2")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("menuBarClick.title", defaultValue: "交换左键与右键功能"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("menuBarClick.description", defaultValue: "关闭时左键打开仪表盘、右键功能打开功能面板；开启后互换。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppL10n.settings(
                    "menuBarClick.rightClickShortcutNotice",
                    defaultValue: "可以使用 Option + 左键触发右键功能。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(AppL10n.settings("menuBarClick.toggle", defaultValue: "交换左键与右键功能"), isOn: $isSwapped)
                .toggleStyle(.switch)
                .labelsHidden()
                .id(toggleID)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("menuBarClick.help", defaultValue: "开启后左键打开功能面板，右键功能打开仪表盘"))
        .onAppear {
            isSwapped = resolvedSelection.isSwapped
            DispatchQueue.main.async {
                toggleID = UUID()
            }
        }
        .onChange(of: isSwapped) { _, isSwapped in
            let rawValue = isSwapped
                ? MenuBarClickBehaviorPreference.swapped.rawValue
                : MenuBarClickBehaviorPreference.standard.rawValue
            if selectionRawValue != rawValue {
                selectionRawValue = rawValue
            }
        }
        .onChange(of: selectionRawValue) { _, _ in
            let storedValue = resolvedSelection.isSwapped
            if isSwapped != storedValue {
                isSwapped = storedValue
            }
        }
    }

    private var resolvedSelection: MenuBarClickBehaviorPreference {
        MenuBarClickBehaviorPreference(rawValue: selectionRawValue) ?? .standard
    }
}

private struct AppearanceSettingsRow: View {
    @Binding var selectionRawValue: String

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "circle.lefthalf.filled")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("appearance.title", defaultValue: "应用外观"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("appearance.description", defaultValue: "自动跟随系统，也可以固定为深色或浅色。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(AppL10n.settings("appearance.picker", defaultValue: "外观"), selection: $selectionRawValue) {
                ForEach(AppAppearancePreference.allCases) { preference in
                    Text(preference.title)
                        .tag(preference.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("appearance.help", defaultValue: "设置应用外观"))
    }
}

private struct LanguageSettingsRow: View {
    @Binding var selectionRawValue: String

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "globe")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("language.title", defaultValue: "语言"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("language.description", defaultValue: "默认跟随系统语言，也可以固定为指定语言。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(AppL10n.settings("language.picker", defaultValue: "语言"), selection: $selectionRawValue) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.pickerTitle)
                        .tag(preference.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("language.help", defaultValue: "设置应用语言"))
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var controller: LaunchAtLoginController
    @State private var toggleID = UUID()

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "power")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("launchAtLogin.title", defaultValue: "开机时启动"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(controller.lastErrorMessage == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(AppL10n.settings("launchAtLogin.toggle", defaultValue: "开机时启动 MacTools"), isOn: enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .id(toggleID)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("launchAtLogin.help", defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。"))
        .onAppear {
            DispatchQueue.main.async {
                toggleID = UUID()
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            controller.isEnabled
        } set: { newValue in
            controller.setEnabled(newValue)
        }
    }

    private var subtitle: String {
        controller.lastErrorMessage ?? AppL10n.settings("launchAtLogin.description", defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。")
    }
}

private struct SettingsSidebarSearchLauncher: NSViewRepresentable {
    let prompt: String
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchLauncherField()
        field.target = context.coordinator
        field.action = #selector(Coordinator.activate(_:))
        field.isEditable = false
        field.isSelectable = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        configure(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.onActivate = onActivate
        configure(field)
    }

    private func configure(_ field: NSSearchField) {
        field.placeholderString = prompt
        field.stringValue = ""
        field.toolTip = prompt
        field.setAccessibilityLabel(prompt)
    }

    final class Coordinator: NSObject {
        var onActivate: () -> Void

        init(onActivate: @escaping () -> Void) {
            self.onActivate = onActivate
        }

        @objc func activate(_ sender: Any?) {
            onActivate()
        }
    }

    private final class SearchLauncherField: NSSearchField {
        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            sendAction(action, to: target)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

private struct SettingsSidebar: View {
    private enum Layout {
        static let sectionHeaderTrailingInset: CGFloat = 8
        static let searchSectionSpacing = PluginSettingsTheme.Spacing.sectionHeaderContent
    }

    let configurationItems: [PluginSettingsPageItem]
    let orderedDestinations: [SettingsNavigationDestination]
    @ObservedObject var sidebarPreferences: SettingsSidebarPreferencesStore
    @Binding var selection: SettingsNavigationDestination
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsSidebarSearchLauncher(
                prompt: AppL10n.search("search.title", defaultValue: "搜索 MacTools"),
                onActivate: onSearch
            )
            .frame(height: 30)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, Layout.searchSectionSpacing)

            ScrollViewReader { proxy in
                List(selection: optionalSelectionBinding) {
                    Section {
                        ForEach(appDestinations, id: \.self) { destination in
                            sidebarRow(for: destination)
                        }
                    } header: {
                        Text("MacTools")
                    }

                    Section {
                        ForEach(primaryPluginDestinations, id: \.self) { destination in
                            sidebarRow(for: destination)
                        }
                    } header: {
                        Text(AppL10n.settings(
                            "plugins.sidebar.pluginsSection",
                            defaultValue: "插件"
                        ))
                    }

                    Section {
                        if configurationDestinations.isEmpty {
                            Text(emptyConfigurationsText)
                                .font(PluginSettingsTheme.Typography.secondaryLabel)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(configurationDestinations, id: \.self) { destination in
                                sidebarRow(for: destination)
                            }
                            .onMove(perform: moveConfigurations)
                        }
                    } header: {
                        configurationSectionHeader
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, destination in
                    withAnimation {
                        proxy.scrollTo(destination)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppL10n.settings(
                    "settings.sidebar.accessibilityLabel",
                    defaultValue: "设置导航"
                ))
                .accessibilityHint(configurationDestinations.isEmpty ? emptyConfigurationsText : "")
            }
        }
    }

    private var emptyConfigurationsText: String {
        AppL10n.settings(
            "plugins.sidebar.emptyConfigurations",
            defaultValue: "暂无可设置插件"
        )
    }

    private var configurationOrderItems: [SettingsSidebarPluginOrderItem] {
        configurationItems.map {
            SettingsSidebarPluginOrderItem(
                id: $0.id,
                title: $0.title,
                installedAt: $0.installedAt
            )
        }
    }

    private var appDestinations: [SettingsNavigationDestination] {
        orderedDestinations.filter {
            switch $0 {
            case .general, .plugins(.automation), .about:
                true
            case .plugins:
                false
            }
        }
    }

    private var primaryPluginDestinations: [SettingsNavigationDestination] {
        orderedDestinations.filter {
            guard case let .plugins(pane) = $0 else {
                return false
            }
            guard pane != .automation else {
                return false
            }
            if case .configuration = pane {
                return false
            }
            return true
        }
    }

    private var configurationDestinations: [SettingsNavigationDestination] {
        orderedDestinations.filter {
            guard case let .plugins(pane) = $0 else {
                return false
            }
            if case .configuration = pane {
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private func sidebarRow(for destination: SettingsNavigationDestination) -> some View {
        let title = settingsNavigationTitle(
            for: destination,
            configurationItems: configurationItems
        )
        let shortcutNumber = shortcutNumber(for: destination)

        switch destination {
        case .general:
            SettingsSidebarRow(
                title: title,
                systemImage: "gearshape",
                iconTint: .gray,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case .about:
            SettingsSidebarRow(
                title: title,
                systemImage: "info.circle",
                iconTint: .blue,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case .plugins(.actionsAndShortcuts):
            SettingsSidebarRow(
                title: title,
                systemImage: "command",
                iconTint: .orange,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case .plugins(.automation):
            SettingsSidebarRow(
                title: title,
                systemImage: "bolt.horizontal.circle",
                iconTint: .indigo,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case .plugins(.dashboardLayout):
            SettingsSidebarRow(
                title: title,
                systemImage: "square.grid.2x2",
                iconTint: .blue,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case .plugins(.featurePanelLayout):
            SettingsSidebarRow(
                title: title,
                systemImage: "switch.2",
                iconTint: .purple,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case .plugins(.marketplace):
            SettingsSidebarRow(
                title: title,
                systemImage: "shippingbox",
                iconTint: .blue,
                shortcutNumber: shortcutNumber
            )
            .tag(destination)
            .id(destination)
        case let .plugins(.configuration(pluginID)):
            if let item = configurationItems.first(where: { $0.id == pluginID }) {
                SettingsSidebarRow(
                    title: title,
                    systemImage: item.iconName,
                    iconTint: item.iconTint,
                    shortcutNumber: shortcutNumber
                )
                .tag(destination)
                .id(destination)
            }
        }
    }

    private var configurationSectionHeader: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Text(AppL10n.settings(
                "plugins.sidebar.configurationSection",
                defaultValue: "插件设置"
            ))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Menu {
                Picker(
                    AppL10n.settings(
                        "plugins.sidebar.configurationSection",
                        defaultValue: "插件设置"
                    ),
                    selection: configurationSortMode
                ) {
                    Section {
                        sortOption(.installedOldestFirst)
                        sortOption(.installedNewestFirst)
                    }

                    Section {
                        sortOption(.nameAscending)
                        sortOption(.nameDescending)
                    }

                    Section {
                        sortOption(.custom)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button(AppL10n.settings(
                    "settings.sidebar.pluginSort.resetCustom",
                    defaultValue: "重置自定义顺序"
                )) {
                    sidebarPreferences.resetCustomOrder()
                }
                .disabled(sidebarPreferences.customOrderedPluginIDs.isEmpty)

                Divider()

                Button {} label: {
                    Label(
                        AppL10n.settings(
                            "settings.sidebar.pluginSort.scopeNote",
                            defaultValue: "仅影响设置侧边栏"
                        ),
                        systemImage: "info.circle"
                    )
                }
                .disabled(true)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2.weight(.medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
                    .frame(width: 11, height: 11, alignment: .center)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .scaleEffect(0.80, anchor: .trailing)
            .padding(.trailing, Layout.sectionHeaderTrailingInset)
            .accessibilityLabel(sidebarPreferences.sortMode.localizedTitle)
            .help(AppL10n.settings(
                "settings.sidebar.pluginSortHelp",
                defaultValue: "调整设置侧边栏中的插件页面顺序，不影响仪表盘或功能面板"
            ))
        }
    }

    private var configurationSortMode: Binding<SettingsSidebarPluginSortMode> {
        Binding {
            sidebarPreferences.sortMode
        } set: { sortMode in
            sidebarPreferences.setSortMode(
                sortMode,
                availableItems: configurationOrderItems
            )
        }
    }

    private func sortOption(_ sortMode: SettingsSidebarPluginSortMode) -> some View {
        Text(sortMode.localizedTitle)
            .tag(sortMode)
    }

    private func shortcutNumber(for destination: SettingsNavigationDestination) -> Int? {
        guard
            let index = orderedDestinations.firstIndex(of: destination),
            index < 9
        else {
            return nil
        }
        return index + 1
    }

    private func moveConfigurations(fromOffsets: IndexSet, toOffset: Int) {
        _ = sidebarPreferences.movePlugins(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            availableItems: configurationOrderItems
        )
    }

    private var optionalSelectionBinding: Binding<SettingsNavigationDestination?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard let newSelection, newSelection != selection else {
                    return
                }

                // AppKit-backed sidebar lists write their selection while
                // SwiftUI is still updating the view hierarchy. Publish the
                // navigation change after the native list update completes.
                Task { @MainActor in
                    await Task.yield()
                    selection = newSelection
                }
            }
        )
    }
}

private struct SettingsSidebarColumn<Content: View>: View {
    private let content: Content
    @State private var headerHeight: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // Keep the sidebar viewport tied to the window chrome instead of the
        // transient safe-area proposal from an in-window overlay.
        content
            .padding(.top, headerHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                SettingsWindowTopSafeAreaReader(topInset: $headerHeight)
                    .frame(width: 0, height: 0)
            }
            .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SettingsDetailColumn<Content: View>: View {
    private let content: Content
    @State private var headerHeight: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.top, headerHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if headerHeight > 0 {
                    SettingsStyle.contentBackground
                        .frame(height: headerHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background {
                SettingsWindowTopSafeAreaReader(topInset: $headerHeight)
                    .frame(width: 0, height: 0)
            }
            .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SettingsWindowTopSafeAreaReader: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        configure(nsView)
        nsView.publishCurrentInset()
    }

    private func configure(_ view: ObserverView) {
        view.onTopInsetChange = { inset in
            guard topInset != inset else { return }
            topInset = inset
        }
    }

    final class ObserverView: NSView {
        var onTopInsetChange: ((CGFloat) -> Void)?
        private var lastPublishedInset: CGFloat = -1

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publishCurrentInset()
        }

        override func layout() {
            super.layout()
            publishCurrentInset()
        }

        func publishCurrentInset() {
            let inset = window?.contentView?.safeAreaInsets.top ?? 0
            guard inset != lastPublishedInset else { return }
            lastPublishedInset = inset

            DispatchQueue.main.async { [weak self] in
                self?.onTopInsetChange?(inset)
            }
        }
    }
}

private struct SettingsDetailToolbarTitle: View {
    let title: String
    let isHidden: Bool

    var body: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isHidden ? 0 : 1)
            .accessibilityHidden(isHidden)
            .accessibilityIdentifier("mactools.settings.detail-title")
    }
}

private struct SettingsSidebarRow: View {
    private enum Layout {
        static let iconWidth: CGFloat = 14
    }

    let title: String
    let systemImage: String
    let iconTint: Color
    let shortcutNumber: Int?

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .font(PluginSettingsTheme.Typography.rowIcon)
                    .foregroundStyle(iconTint)
                    .frame(width: Layout.iconWidth)
            }

            Spacer(minLength: 0)

            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .font(.body)
        .focusable(false)
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(shortcutAccessibilityHint)
    }

    private var shortcutAccessibilityHint: String {
        guard let shortcutNumber else {
            return ""
        }
        return AppL10n.settingsFormat(
            "settings.sidebar.shortcutAccessibilityHint",
            defaultValue: "Keyboard shortcut: Command-%d",
            shortcutNumber
        )
    }
}

private extension SettingsSidebarPluginSortMode {
    var localizedTitle: String {
        switch self {
        case .installedOldestFirst:
            AppL10n.settings(
                "settings.sidebar.pluginSort.installedOldestFirst",
                defaultValue: "安装时间：最早优先"
            )
        case .installedNewestFirst:
            AppL10n.settings(
                "settings.sidebar.pluginSort.installedNewestFirst",
                defaultValue: "安装时间：最新优先"
            )
        case .nameAscending:
            AppL10n.settings(
                "settings.sidebar.pluginSort.nameAscending",
                defaultValue: "名称：升序"
            )
        case .nameDescending:
            AppL10n.settings(
                "settings.sidebar.pluginSort.nameDescending",
                defaultValue: "名称：降序"
            )
        case .custom:
            AppL10n.settings(
                "settings.sidebar.pluginSort.custom",
                defaultValue: "自定义顺序"
            )
        }
    }

}

private struct SettingsDetailPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let destination: SettingsNavigationDestination
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    let appearanceUserDefaults: UserDefaults
    let showDashboard: () -> Void
    let showFeaturePanel: () -> Void

    @ViewBuilder
    var body: some View {
        switch destination {
        case .general:
            GeneralSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                menuBarIconSettings: menuBarIconSettings,
                menuBarIconGallery: menuBarIconGallery,
                launchAtLoginController: launchAtLoginController,
                menuBarPanelThemeStore: menuBarPanelThemeStore,
                appearanceUserDefaults: appearanceUserDefaults
            )
        case .about:
            AboutSettingsView(
                appUpdater: appUpdater,
                navigationCoordinator: navigationCoordinator
            )
        case let .plugins(pane):
            PluginSettingsDestinationPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                selectedPane: pane,
                uninstallConfirmationSession: uninstallConfirmationSession,
                showDashboard: showDashboard,
                showFeaturePanel: showFeaturePanel
            )
        }
    }
}

private struct PluginSettingsDestinationPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let selectedPane: FeatureSettingsPane
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    let showDashboard: () -> Void
    let showFeaturePanel: () -> Void

    var body: some View {
        detail
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane {
        case .actionsAndShortcuts:
            ActionShortcutSettingsView(pluginHost: pluginHost)
        case .automation:
            AutomationSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator
            )
        case .dashboardLayout:
            SurfaceLayoutSettingsView(
                navigationCoordinator: navigationCoordinator,
                surface: .dashboard,
                description: AppL10n.settings(
                    "plugins.dashboard.description",
                    defaultValue: "拖拽调整仪表盘组件的排列顺序。"
                ),
                systemImage: "square.grid.2x2",
                items: pluginHost.dashboardLayoutItems,
                hiddenItems: pluginHost.dashboardHiddenLayoutItems,
                openButtonTitle: AppL10n.settings("plugins.dashboard.open", defaultValue: "打开仪表盘"),
                emptyTitle: AppL10n.settings("plugins.dashboard.empty.title", defaultValue: "暂无仪表盘组件"),
                emptyDescription: AppL10n.settings(
                    "plugins.dashboard.empty.description",
                    defaultValue: "已安装且支持仪表盘的插件会显示在这里。"
                ),
                onMove: { pluginID, targetOffset in
                    pluginHost.movePlugin(id: pluginID, toOffset: targetOffset, on: .dashboard)
                },
                onSetVisible: { pluginID, isVisible in
                    pluginHost.setPluginVisible(isVisible, id: pluginID, on: .dashboard)
                },
                onResetOrder: { pluginHost.resetPluginOrder(on: .dashboard) },
                onOpenPanel: showDashboard,
                configurationPluginIDs: Set(pluginHost.pluginSettingsItems.map(\.pluginID)),
                uninstallConfirmationSession: uninstallConfirmationSession,
                onOpenSettings: pluginHost.presentPluginSettings(pluginID:),
                onOpenMarketplace: pluginHost.presentPluginMarketplace,
                onUninstall: { pluginID in
                    try pluginHost.uninstallDynamicPlugin(pluginID: pluginID)
                }
            )
        case .featurePanelLayout:
            SurfaceLayoutSettingsView(
                navigationCoordinator: navigationCoordinator,
                surface: .featurePanel,
                description: AppL10n.settings(
                    "plugins.featurePanel.description",
                    defaultValue: "拖拽调整功能面板操作的排列顺序。"
                ),
                systemImage: "switch.2",
                items: pluginHost.featurePanelLayoutItems,
                hiddenItems: pluginHost.featurePanelHiddenLayoutItems,
                openButtonTitle: AppL10n.settings("plugins.featurePanel.open", defaultValue: "打开功能面板"),
                emptyTitle: AppL10n.settings("plugins.featurePanel.empty.title", defaultValue: "暂无功能面板操作"),
                emptyDescription: AppL10n.settings(
                    "plugins.featurePanel.empty.description",
                    defaultValue: "已安装且支持功能面板的插件会显示在这里。"
                ),
                onMove: { pluginID, targetOffset in
                    pluginHost.movePlugin(id: pluginID, toOffset: targetOffset, on: .featurePanel)
                },
                onSetVisible: { pluginID, isVisible in
                    pluginHost.setPluginVisible(isVisible, id: pluginID, on: .featurePanel)
                },
                onResetOrder: { pluginHost.resetPluginOrder(on: .featurePanel) },
                onOpenPanel: showFeaturePanel,
                configurationPluginIDs: Set(pluginHost.pluginSettingsItems.map(\.pluginID)),
                uninstallConfirmationSession: uninstallConfirmationSession,
                onOpenSettings: pluginHost.presentPluginSettings(pluginID:),
                onOpenMarketplace: pluginHost.presentPluginMarketplace,
                onUninstall: { pluginID in
                    try pluginHost.uninstallDynamicPlugin(pluginID: pluginID)
                }
            )
        case .marketplace:
            PluginManagementSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                uninstallConfirmationSession: uninstallConfirmationSession
            )
        case let .configuration(pluginID):
            PluginSettingsDetailPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                item: configurationItem(for: pluginID)
            )
        }
    }

    private func configurationItem(for pluginID: String) -> PluginSettingsPageItem? {
        pluginHost.pluginSettingsItems.first { $0.id == pluginID }
    }
}

private struct SurfaceLayoutSettingsView: View {
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let surface: PluginDisplaySurface
    let description: String
    let systemImage: String
    let items: [PluginSurfaceLayoutItem]
    let hiddenItems: [PluginSurfaceLayoutItem]
    let openButtonTitle: String
    let emptyTitle: String
    let emptyDescription: String
    let onMove: (String, Int) -> Void
    let onSetVisible: (String, Bool) -> Void
    let onResetOrder: () -> Void
    let onOpenPanel: () -> Void
    let configurationPluginIDs: Set<String>
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    let onOpenSettings: (String) -> Void
    let onOpenMarketplace: () -> Void
    let onUninstall: (String) throws -> Void
    @State private var pendingUninstallItem: PluginUninstallConfirmation?
    @State private var uninstallErrorMessage: String?
    @State private var activeSearchTarget: SurfaceSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            SettingsGroupedFormPageScaffold(
                introduction: SettingsPageIntroductionConfiguration(
                    description: description
                ),
                introductionAccessory: {
                    Button(AppL10n.settings(
                        "plugins.layout.restoreDefaultOrder",
                        defaultValue: "恢复默认排列"
                    ), action: onResetOrder)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(items.count < 2)

                    Button(action: onOpenPanel) {
                        Label(openButtonTitle, systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            ) { widths in
                if uninstallConfirmationSession.isConfirmationPaused {
                    Section {
                        PluginUninstallConfirmationPausedBanner(session: uninstallConfirmationSession)
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                }

                Section {
                    if items.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: systemImage,
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    } else {
                        FeatureManagementTableView(
                            items: items.map {
                                FeatureManagementTableItem(
                                    surfaceItem: $0,
                                    hasSettings: configurationPluginIDs.contains($0.id)
                                )
                            },
                            mode: .surface(surface),
                            highlightedPluginID: highlightedPluginID(in: items),
                            onMove: onMove,
                            onSetVisible: onSetVisible,
                            onOpenSettings: onOpenSettings,
                            onOpenMarketplace: onOpenMarketplace,
                            onRequestUninstall: requestUninstall
                        )
                        .frame(height: FeatureManagementTableView.preferredHeight(for: items.count))
                        .overlay(alignment: .topLeading) {
                            SurfaceLayoutSearchAnchors(
                                surface: surface,
                                items: items,
                                isHidden: false
                            )
                        }
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                        .listRowInsets(EdgeInsets())
                    }
                }

                if !hiddenItems.isEmpty {
                    Section {
                        FeatureManagementTableView(
                            items: hiddenItems.map {
                                FeatureManagementTableItem(
                                    surfaceItem: $0,
                                    hasSettings: configurationPluginIDs.contains($0.id)
                                )
                            },
                            mode: .surface(surface),
                            isReorderEnabled: false,
                            highlightedPluginID: highlightedPluginID(in: hiddenItems),
                            onSetVisible: onSetVisible,
                            onOpenSettings: onOpenSettings,
                            onOpenMarketplace: onOpenMarketplace,
                            onRequestUninstall: requestUninstall
                        )
                        .frame(height: FeatureManagementTableView.preferredHeight(for: hiddenItems.count))
                        .overlay(alignment: .topLeading) {
                            SurfaceLayoutSearchAnchors(
                                surface: surface,
                                items: hiddenItems,
                                isHidden: true
                            )
                        }
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                        .listRowInsets(EdgeInsets())
                    } header: {
                        SettingsGroupedFormSectionHeader(
                            title: hiddenSectionTitle,
                            systemImage: "eye.slash",
                            layoutWidth: widths.readableContent
                        )
                    }
                }
            }
            .onAppear {
                applySearchRevealRequest(
                    navigationCoordinator.searchRevealRequest,
                    proxy: proxy
                )
            }
            .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                applySearchRevealRequest(request, proxy: proxy)
            }
        }
        .onDisappear {
            clearSearchTargetTask?.cancel()
            clearSearchTargetTask = nil
            if let activeSearchTarget {
                navigationCoordinator.clearSearchRevealRequest(
                    matching: .surface(activeSearchTarget)
                )
            }
            activeSearchTarget = nil
        }
        .sheet(item: $pendingUninstallItem) { item in
            PluginUninstallConfirmationSheet(
                confirmation: item,
                session: uninstallConfirmationSession,
                onConfirm: uninstall
            )
        }
        .alert(
            AppL10n.plugins("plugin.marketplace.operationFailed.title", defaultValue: "插件操作失败"),
            isPresented: Binding(
                get: { uninstallErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        uninstallErrorMessage = nil
                    }
                }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(uninstallErrorMessage ?? "")
        }
    }

    private func highlightedPluginID(
        in candidates: [PluginSurfaceLayoutItem]
    ) -> String? {
        guard
            let pluginID = activeSearchTarget?.pluginID,
            candidates.contains(where: { $0.id == pluginID })
        else {
            return nil
        }

        return pluginID
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        proxy: ScrollViewProxy
    ) {
        guard
            let request,
            case let .surface(target) = request.target,
            target.surface == surface
        else {
            return
        }

        let isHidden: Bool
        if items.contains(where: { $0.id == target.pluginID }) {
            isHidden = false
        } else if hiddenItems.contains(where: { $0.id == target.pluginID }) {
            isHidden = true
        } else {
            navigationCoordinator.clearSearchRevealRequest(request)
            return
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID(isHidden: isHidden), anchor: .center)
            }
        }

        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
    }

    private func requestUninstall(_ pluginID: String) {
        guard let item = (items + hiddenItems).first(where: { $0.id == pluginID && $0.canUninstall }) else {
            return
        }

        let confirmation = PluginUninstallConfirmation(
            pluginID: item.id,
            pluginTitle: item.title,
            surfaceCapabilitySummary: pluginCapabilitySummary(item.capabilities)
        )
        if uninstallConfirmationSession.shouldConfirmUninstall {
            pendingUninstallItem = confirmation
        } else {
            uninstall(confirmation)
        }
    }

    private var hiddenSectionTitle: String {
        switch surface {
        case .dashboard:
            return AppL10n.settingsFormat(
                "plugins.dashboard.hiddenSectionFormat",
                defaultValue: "已在仪表盘隐藏（%d）",
                hiddenItems.count
            )
        case .featurePanel:
            return AppL10n.settingsFormat(
                "plugins.featurePanel.hiddenSectionFormat",
                defaultValue: "已在功能面板隐藏（%d）",
                hiddenItems.count
            )
        }
    }

    private func uninstall(_ confirmation: PluginUninstallConfirmation) {
        do {
            try onUninstall(confirmation.pluginID)
        } catch {
            uninstallErrorMessage = error.localizedDescription
        }
    }
}

private struct SurfaceLayoutSearchAnchors: View {
    let surface: PluginDisplaySurface
    let items: [PluginSurfaceLayoutItem]
    let isHidden: Bool

    var body: some View {
        VStack(spacing: FeatureManagementTableView.rowSpacing) {
            ForEach(items) { item in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: FeatureManagementTableView.rowHeight)
                    .id(
                        SurfaceSettingsSearchTarget(
                            surface: surface,
                            pluginID: item.id
                        )
                        .scrollID(isHidden: isHidden)
                    )
            }
        }
        .padding(.top, FeatureManagementTableView.verticalContentInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PluginSettingsDetailPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let item: PluginSettingsPageItem?
    @State private var activeSearchTarget: PluginSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let item {
                ScrollViewReader { proxy in
                    pageContent(item)
                        .environment(\.pluginSettingsSearchTarget, activeSearchTarget)
                        .onAppear {
                            applySearchRevealRequest(
                                navigationCoordinator.searchRevealRequest,
                                pluginID: item.pluginID,
                                proxy: proxy
                            )
                        }
                        .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                            applySearchRevealRequest(
                                request,
                                pluginID: item.pluginID,
                                proxy: proxy
                            )
                        }
                }
            } else {
                ContentUnavailableView(
                    AppL10n.settings("plugins.configuration.empty.title", defaultValue: "暂无可配置插件"),
                    systemImage: "slider.horizontal.3",
                    description: Text(AppL10n.settings(
                        "plugins.configuration.empty.description",
                        defaultValue: "当插件提供权限、快捷键或自定义设置后，会显示在这里。"
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            clearSearchTargetTask?.cancel()
            clearSearchTargetTask = nil
            if let activeSearchTarget {
                navigationCoordinator.clearSearchRevealRequest(
                    matching: .plugin(activeSearchTarget)
                )
            }
            activeSearchTarget = nil
        }
    }

    @ViewBuilder
    private func pageContent(_ item: PluginSettingsPageItem) -> some View {
        Group {
            switch item.layout {
            case .form:
                PluginFormPage(pluginHost: pluginHost, item: item)
            case .workspace:
                PluginWorkspacePage(pluginHost: pluginHost, item: item)
            }
        }
        .onAppear {
            pluginHost.setPluginSettingsPage(item.pluginID, visible: true)
        }
        .onDisappear {
            pluginHost.setPluginSettingsPage(item.pluginID, visible: false)
        }
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        pluginID: String,
        proxy: ScrollViewProxy
    ) {
        guard
            let target = applySearchRevealRequest(request, pluginID: pluginID)
        else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID, anchor: .center)
            }
        }
    }

    @discardableResult
    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        pluginID: String
    ) -> PluginSettingsSearchTarget? {
        guard
            let request,
            case let .plugin(target) = request.target,
            target.pluginID == pluginID
        else {
            return nil
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target
        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
        return target
    }
}

private struct PluginFormPage: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginSettingsPageItem

    var body: some View {
        SettingsGroupedFormPageScaffold(introduction: item.introductionConfiguration) { widths in
            if !item.permissionCards.isEmpty {
                Section {
                    ForEach(item.permissionCards) { card in
                        PermissionSettingsRow(
                            card: card,
                            statusColor: statusColor(for: card.statusTone),
                            onAction: {
                                pluginHost.performPermissionAction(
                                    pluginID: card.pluginID,
                                    permissionID: card.permissionID
                                )
                            }
                        )
                        .pluginSettingsSearchAnchor(
                            pluginID: card.pluginID,
                            entryID: card.id
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings(
                            "plugins.configuration.section.permissions",
                            defaultValue: "权限"
                        ),
                        systemImage: "lock.shield",
                        layoutWidth: widths.readableContent
                    )
                }
            }

            ForEach(item.sections.filter(\.isVisible)) { section in
                PluginFormSection(
                    pluginHost: pluginHost,
                    pluginID: item.pluginID,
                    section: section,
                    shortcutItems: item.shortcutItems,
                    layoutWidths: widths
                )

                if let configuration = item.actionShortcutSettingsConfiguration,
                   configuration.placementAfterSectionID == section.id {
                    PluginActionShortcutFormSection(
                        pluginHost: pluginHost,
                        pluginID: item.pluginID,
                        configuration: configuration,
                        layoutWidths: widths
                    )
                }
            }

            if let configuration = item.actionShortcutSettingsConfiguration,
               configuration.placementAfterSectionID == nil
                   || !item.sections.contains(where: {
                       $0.isVisible && $0.id == configuration.placementAfterSectionID
                   }) {
                PluginActionShortcutFormSection(
                    pluginHost: pluginHost,
                    pluginID: item.pluginID,
                    configuration: configuration,
                    layoutWidths: widths
                )
            }

            if !item.remainingShortcutItems.isEmpty {
                Section {
                    PluginShortcutRowsContent(
                        pluginHost: pluginHost,
                        items: item.remainingShortcutItems
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings(
                            "plugins.configuration.section.shortcuts",
                            defaultValue: "快捷键"
                        ),
                        systemImage: "command",
                        layoutWidth: widths.readableContent
                    )
                }
            }
        }
    }
}

private struct PluginActionShortcutFormSection: View {
    @ObservedObject var pluginHost: PluginHost
    let pluginID: String
    let configuration: PluginActionShortcutSettingsConfiguration
    let layoutWidths: SettingsGroupedFormWidths

    var body: some View {
        Section {
            PluginActionShortcutRowsContent(
                pluginHost: pluginHost,
                providerID: pluginID,
                actionIDs: configuration.actionIDs
            )
            .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
        } header: {
            SettingsGroupedFormSectionHeader(
                title: configuration.title,
                systemImage: configuration.systemImage,
                layoutWidth: layoutWidths.readableContent
            ) {
                Button {
                    pluginHost.presentActionsAndShortcutsSettings()
                } label: {
                    Label(FeatureL10n.string("操作与快捷键"), systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } footer: {
            if let description = configuration.description {
                Text(description)
                    .frame(width: layoutWidths.sectionLayout, alignment: .leading)
            }
        }
        .pluginSettingsSearchAnchor(
            pluginID: pluginID,
            entryID: PluginActionShortcutSettingsConfiguration.settingsSearchEntryID
        )
    }
}

private extension PluginSettingsPageItem {
    var introductionConfiguration: SettingsPageIntroductionConfiguration {
        SettingsPageIntroductionConfiguration(
            description: description
        )
    }
}

private struct PluginFormSection: View {
    @ObservedObject var pluginHost: PluginHost
    let pluginID: String
    let section: PluginSettingsSection
    let shortcutItems: [ShortcutSettingsItem]
    let layoutWidths: SettingsGroupedFormWidths

    var body: some View {
        Section {
            switch section.content {
            case let .rows(rows):
                ForEach(rows.filter(\.isVisible)) { row in
                    PluginSettingsRowView(
                        pluginID: pluginID,
                        row: row,
                        onAction: { action in
                            pluginHost.performSettingsAction(
                                pluginID: pluginID,
                                action: action
                            )
                        }
                    )
                    .pluginSettingsSearchAnchor(
                        pluginID: pluginID,
                        entryID: row.id
                    )
                    .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
                }
            case let .shortcutGroup(groupID):
                PluginShortcutRowsContent(
                    pluginHost: pluginHost,
                    items: shortcutItems.filter { $0.settingsGroupID == groupID }
                )
                .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
            case .custom:
                customContent
            }
        } header: {
            sectionHeader
        } footer: {
            if let footer = section.footer {
                Text(footer)
                    .frame(
                        width: layoutWidths.sectionLayout,
                        alignment: .leading
                    )
            }
        }
    }

    @ViewBuilder
    private var customContent: some View {
        let content = pluginHost.pluginSettingsContentViewItem(
            for: pluginID,
            sectionID: section.id
        ).content
            .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
        switch section.presentation {
        case .standard:
            content
        case .edgeToEdge:
            content
                .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if section.title != nil || section.headerAccessory != nil {
            SettingsGroupedFormSectionHeader(
                title: section.title,
                systemImage: section.systemImage,
                layoutWidth: layoutWidths.readableContent
            ) {
                if section.headerAccessory != nil {
                    pluginHost.pluginSettingsHeaderAccessoryViewItem(
                        for: pluginID,
                        sectionID: section.id
                    ).content
                }
            }
        }
    }
}

private struct PluginWorkspacePage: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginSettingsPageItem

    var body: some View {
        SettingsPageScaffold {
            switch item.workspaceScrolling {
            case .host:
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: SettingsPageLayout.introductionContentSpacing
                    ) {
                        introduction
                        workspaceContent
                    }
                }
            case .selfManaged:
                VStack(
                    alignment: .leading,
                    spacing: SettingsPageLayout.introductionContentSpacing
                ) {
                    introduction
                    workspaceContent
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var introduction: some View {
        SettingsPageIntroduction(
            configuration: item.introductionConfiguration
        )
    }

    private var workspaceContent: some View {
        pluginHost.pluginSettingsContentViewItem(for: item.pluginID).content
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct PluginSettingsRowView: View {
    let pluginID: String
    let row: PluginSettingsRow
    let onAction: (PluginSettingsAction) -> Void
    @State private var showsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            rowContent

            if let error = row.error {
                Text(error)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !row.helpItems.isEmpty {
                PluginSettingsHelpList(
                    items: row.helpItems,
                    tone: row.helpTone
                )
            } else if let help = row.help {
                Text(help)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(statusColor(for: row.helpTone))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!row.isEnabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rowContent: some View {
        if case let .choiceGroup(selectionID, options) = row.control {
            PluginSettingsChoiceGroupControl(
                selectionID: selectionID,
                options: options,
                onSelect: {
                    onAction(.setSelection(controlID: row.id, optionID: $0))
                }
            )
        } else {
            HStack(alignment: .center, spacing: 0) {
                HStack(
                    alignment: .center,
                    spacing: PluginSettingsTheme.Spacing.rowContentControl
                ) {
                    if let systemImage = row.systemImage {
                        Image(systemName: systemImage)
                            .pluginSettingsRowIconStyle(.secondary)
                    }

                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(row.title)
                            .font(PluginSettingsTheme.Typography.rowTitle)

                        if let description = row.description {
                            Text(description)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch row.control {
        case let .toggle(isOn):
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { onAction(.setBoolean(controlID: row.id, value: $0)) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        case let .picker(selectionID, options, style):
            PluginSettingsPickerControl(
                selectionID: selectionID,
                options: options,
                style: style,
                onSelect: {
                    onAction(.setSelection(controlID: row.id, optionID: $0))
                }
            )
        case .choiceGroup:
            EmptyView()
        case let .slider(value, range, step, valueFormat):
            PluginSettingsSliderControl(
                controlID: row.id,
                value: value,
                range: range,
                step: step,
                valueFormat: valueFormat,
                onAction: onAction
            )
        case let .textField(value, prompt, isRequired):
            PluginSettingsTextControl(
                controlID: row.id,
                value: value,
                prompt: prompt,
                isRequired: isRequired,
                isSecure: false,
                onAction: onAction
            )
        case let .secureField(value, prompt, isRequired):
            PluginSettingsTextControl(
                controlID: row.id,
                value: value,
                prompt: prompt,
                isRequired: isRequired,
                isSecure: true,
                onAction: onAction
            )
        case let .action(title, role):
            PluginSettingsActionButton(title: title, role: role) {
                onAction(.invoke(controlID: row.id))
            }
        case let .confirmationAction(title, role, confirmation):
            PluginSettingsActionButton(title: title, role: role) {
                showsConfirmation = true
            }
            .alert(confirmation.title, isPresented: $showsConfirmation) {
                Button(confirmation.cancelButtonTitle, role: .cancel) {}
                Button(
                    confirmation.confirmButtonTitle,
                    role: role == .destructive ? .destructive : nil
                ) {
                    onAction(.invoke(controlID: row.id))
                }
            } message: {
                Text(confirmation.message)
            }
        case let .status(text, systemImage, tone, actionTitle):
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(text, systemImage: systemImage)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(statusColor(for: tone))
                    .lineLimit(1)

                if let actionTitle {
                    Button(actionTitle) {
                        onAction(.invoke(controlID: row.id))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct PluginSettingsHelpList: View {
    let items: [String]
    let tone: PluginStatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .accessibilityHidden(true)

                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(statusColor(for: tone))
        .accessibilityElement(children: .contain)
    }
}

private struct PluginSettingsPickerControl: View {
    let selectionID: String
    let options: [PluginSettingsOption]
    let style: PluginSettingsPickerStyle
    let onSelect: (String) -> Void

    var body: some View {
        switch style {
        case .automatic:
            picker
        case .menu:
            picker.pickerStyle(.menu)
        case .segmented:
            picker.pickerStyle(.segmented)
        }
    }

    private var picker: some View {
        Picker(
            "",
            selection: Binding(
                get: { selectionID },
                set: { selection in onSelect(selection) }
            )
        ) {
            ForEach(options) { option in
                Text(option.title).tag(option.id)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)
    }
}

private struct PluginSettingsChoiceGroupControl: View {
    let selectionID: String
    let options: [PluginSettingsOption]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            ViewThatFits(in: .horizontal) {
                horizontalChoices
                verticalChoices
            }

            if let description = selectedOption?.description {
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(statusColor(for: selectedOption?.descriptionTone ?? .neutral))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var horizontalChoices: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ForEach(options) { option in
                choiceButton(option: option)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalChoices: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ForEach(options) { option in
                choiceButton(option: option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedOption: PluginSettingsOption? {
        options.first { $0.id == selectionID }
    }

    @ViewBuilder
    private func choiceButton(option: PluginSettingsOption) -> some View {
        let isSelected = selectionID == option.id
        Button {
            onSelect(option.id)
        } label: {
            HStack(spacing: 6) {
                Text(option.title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(minWidth: 132, maxWidth: .infinity, minHeight: PluginSettingsTheme.Size.controlHeight + 8)
            .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
            .background {
                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                )
                .fill(
                    isSelected
                        ? Color.accentColor
                        : PluginSettingsTheme.Palette.recessedControlBackground
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                )
                .stroke(
                    isSelected ? Color.accentColor : PluginSettingsTheme.Palette.separator,
                    lineWidth: PluginSettingsTheme.Stroke.hairline
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}


private struct PluginSettingsSliderControl: View {
    let controlID: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let valueFormat: PluginSettingsSliderValueFormat?
    let onAction: (PluginSettingsAction) -> Void
    @State private var currentValue: Double

    init(
        controlID: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double?,
        valueFormat: PluginSettingsSliderValueFormat?,
        onAction: @escaping (PluginSettingsAction) -> Void
    ) {
        self.controlID = controlID
        self.value = value
        self.range = range
        self.step = step
        self.valueFormat = valueFormat
        self.onAction = onAction
        _currentValue = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            PluginSettingsSlider(
                value: $currentValue,
                in: range,
                step: step,
                onEditingChanged: editingChanged
            )

            if let valueFormat {
                Text(valueFormat.text(for: currentValue))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        .onChange(of: currentValue) { _, value in
            onAction(.setNumber(controlID: controlID, value: value, phase: .changed))
        }
        .onChange(of: value) { _, value in
            if currentValue != value {
                currentValue = value
            }
        }
    }

    private func editingChanged(_ isEditing: Bool) {
        if !isEditing {
            onAction(.setNumber(controlID: controlID, value: currentValue, phase: .committed))
        }
    }
}

private struct PluginSettingsTextControl: View {
    let controlID: String
    let value: String
    let prompt: String?
    let isRequired: Bool
    let isSecure: Bool
    let onAction: (PluginSettingsAction) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        controlID: String,
        value: String,
        prompt: String?,
        isRequired: Bool,
        isSecure: Bool,
        onAction: @escaping (PluginSettingsAction) -> Void
    ) {
        self.controlID = controlID
        self.value = value
        self.prompt = prompt
        self.isRequired = isRequired
        self.isSecure = isSecure
        self.onAction = onAction
        _text = State(initialValue: value)
    }

    var body: some View {
        Group {
            if isSecure {
                SecureField(prompt ?? "", text: $text)
            } else {
                TextField(prompt ?? "", text: $text)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        .focused($isFocused)
        .onChange(of: text) { _, value in
            onAction(.setText(controlID: controlID, value: value, phase: .changed))
        }
        .onChange(of: value) { _, value in
            if text != value {
                text = value
            }
        }
        .onChange(of: isFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commit()
            }
        }
        .onSubmit(commit)
    }

    private func commit() {
        guard !isRequired || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        onAction(.setText(controlID: controlID, value: text, phase: .committed))
    }
}

private struct PluginSettingsActionButton: View {
    let title: String
    let role: PluginSettingsActionRole
    let action: () -> Void

    var body: some View {
        switch role {
        case .normal:
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .prominent:
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .destructive:
            Button(title, role: .destructive, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct PluginShortcutRowsContent: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [ShortcutSettingsItem]

    var body: some View {
        if groupedItems.isEmpty {
            ShortcutSettingsRowsView(pluginHost: pluginHost, items: items)
        } else {
            GroupedShortcutSettingsRowsView(pluginHost: pluginHost, groups: groupedItems)
        }
    }

    private var groupedItems: [ShortcutSettingsGroup] {
        guard !items.isEmpty, items.allSatisfy({ $0.settingsGroupID != nil }) else {
            return []
        }

        var groupOrder: [String] = []
        var groups: [String: [ShortcutSettingsItem]] = [:]
        for item in items {
            guard let groupID = item.settingsGroupID else { continue }
            if groups[groupID] == nil {
                groupOrder.append(groupID)
            }
            groups[groupID, default: []].append(item)
        }

        return groupOrder.compactMap { groupID in
            guard let groupItems = groups[groupID], let first = groupItems.first else {
                return nil
            }
            return ShortcutSettingsGroup(
                id: groupID,
                title: first.settingsGroupTitle ?? first.title,
                description: first.settingsGroupDescription ?? first.description,
                items: groupItems
            )
        }
    }
}

private func statusColor(for tone: PluginStatusTone) -> Color {
    switch tone {
    case .neutral:
        return .secondary
    case .positive:
        return .green
    case .caution:
        return .orange
    }
}

struct AboutSettingsView: View {
    @StateObject private var updateViewModel: AboutUpdateViewModel
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    private let releaseHistory: ReleaseHistory

    init(
        appUpdater: AppUpdater,
        navigationCoordinator: SettingsNavigationCoordinator,
        releaseHistory: ReleaseHistory = .bundled
    ) {
        _updateViewModel = StateObject(
            wrappedValue: AboutUpdateViewModel(updater: appUpdater)
        )
        self.navigationCoordinator = navigationCoordinator
        self.releaseHistory = releaseHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            AboutProductSummary(viewModel: updateViewModel)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)

            Divider()

            AboutReleaseHistoryView(releaseHistory: releaseHistory)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(
            of: navigationCoordinator.aboutUpdateActionRequest,
            initial: true
        ) { _, request in
            handleUpdateActionRequest(request)
        }
    }

    private func handleUpdateActionRequest(_ request: AboutUpdateActionRequest?) {
        guard
            let request,
            navigationCoordinator.consumeAboutUpdateActionRequest(request)
        else {
            return
        }

        Task { @MainActor in
            await Task.yield()
            updateViewModel.performAvailableUpdateAction(version: request.version)
        }
    }
}

private struct AboutProductSummary: View {
    @ObservedObject var viewModel: AboutUpdateViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            AppIconPreview()

            VStack(alignment: .leading, spacing: 6) {
                Text(AppMetadata.appName)
                    .font(PluginSettingsTheme.Typography.pageTitle)

                Text(AppL10n.settingsFormat("about.versionFormat", defaultValue: "版本 %@", AppMetadata.versionDescription))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)

                Text(AppMetadata.aboutDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Link(destination: AppMetadata.repositoryURL) {
                    HStack(spacing: 5) {
                        Text(AppMetadata.repositoryDisplayName)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            AboutUpdateCard(viewModel: viewModel)
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 220)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}

private struct AboutReleaseHistoryView: View {
    private static let maximumReleaseCount = 10

    let releaseHistory: ReleaseHistory

    private var displayedReleases: [ReleaseHistoryItem] {
        releaseHistory.mostRecentReleases(limit: Self.maximumReleaseCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    AppL10n.settings("about.changelog.title", defaultValue: "版本记录"),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)

                Text(
                    AppL10n.settings(
                        "about.changelog.description",
                        defaultValue: "MacTools 与插件最近 10 个版本的发布记录"
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if displayedReleases.isEmpty {
                ContentUnavailableView(
                    AppL10n.settings(
                        "about.changelog.empty.title",
                        defaultValue: "暂无版本记录"
                    ),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        AppL10n.settings(
                            "about.changelog.empty.description",
                            defaultValue: "发布新版本后，更新内容会显示在这里。"
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(displayedReleases) { release in
                            AboutReleaseCard(release: release)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AboutReleaseCard: View {
    let release: ReleaseHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(releaseKindTitle, systemImage: releaseKindSystemImage)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)

                Text(release.version)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                if isCurrentVersion {
                    Text(
                        AppL10n.settings(
                            "about.changelog.currentVersion",
                            defaultValue: "当前版本"
                        )
                    )
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 12)

                Text(release.date)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.tertiary)
            }

            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.kind.displayName)
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(.secondary)

                    ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(Color.secondary.opacity(0.7))
                                .frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { dimensions in
                                    dimensions[VerticalAlignment.center]
                                }
                                .accessibilityHidden(true)

                            Text(entry)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    private var releaseKindTitle: String {
        switch release.kind {
        case .app:
            return AppMetadata.appName
        case .plugin:
            return AppL10n.settings("tab.plugins", defaultValue: "插件")
        }
    }

    private var releaseKindSystemImage: String {
        switch release.kind {
        case .app:
            return "app.fill"
        case .plugin:
            return "shippingbox.fill"
        }
    }

    private var isCurrentVersion: Bool {
        release.kind == .app && release.version == AppMetadata.shortVersion
    }
}

private struct AboutUpdateCard: View {
    private enum Layout {
        static let verticalSpacing: CGFloat = 12
        static let statusMinHeight: CGFloat = 16
    }

    @ObservedObject var viewModel: AboutUpdateViewModel

    var body: some View {
        VStack(spacing: Layout.verticalSpacing) {
            Button(viewModel.primaryButtonTitle) {
                Task {
                    await viewModel.performPrimaryAction()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(viewModel.isPrimaryButtonDisabled)

            Text(statusText ?? " ")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(viewModel.statusColor)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: Layout.statusMinHeight, alignment: .top)
                .opacity(statusText == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String? {
        switch viewModel.state {
        case .idle:
            return nil
        default:
            return viewModel.statusDetail ?? viewModel.statusHeadline
        }
    }
}

private struct AppIconPreview: View {
    private static let iconSize: CGFloat = 76

    var body: some View {
        if let appIcon = AppMetadata.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "wrench.and.screwdriver.fill")
                .resizable()
                .scaledToFit()
                .padding(12)
                .foregroundStyle(.secondary)
                .background(PluginSettingsTheme.Palette.recessedControlBackground)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
