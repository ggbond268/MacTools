import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum UnifiedSearchPaletteLayout {
    static let maximumWidth: CGFloat = 672
    static let minimumWidth: CGFloat = 560
    static let outerHorizontalPadding: CGFloat = 48
    static let maximumResultListHeight: CGFloat = 468
    static let minimumResultListHeight: CGFloat = 260
    static let verticalChromeHeight: CGFloat = 202

    static func width(for availableWidth: CGFloat) -> CGFloat {
        let screenSafeWidth = max(0, availableWidth - outerHorizontalPadding)
        return min(maximumWidth, screenSafeWidth)
    }

    static func resultListHeight(for availableHeight: CGFloat) -> CGFloat {
        min(
            max(0, availableHeight - verticalChromeHeight),
            min(
                maximumResultListHeight,
                max(minimumResultListHeight, availableHeight - verticalChromeHeight)
            )
        )
    }
}

enum UnifiedSearchResultRowLayout {
    static let quickSelectionColumnWidth: CGFloat = 32
    static let primaryActionColumnWidth: CGFloat = 56
    static let rowVerticalPadding: CGFloat = 8
    static let selectedAccessorySpacing: CGFloat = 5
    static let minimumShortcutRecorderWidth: CGFloat = 60
    static let titleSubtitleSpacing: CGFloat = 2
    static let selectedSubtitleOpacity = 0.64

    static var subtitleFont: Font {
        .caption
    }

    static func shortcutRecorderDisplayText(for binding: ShortcutBinding?) -> String {
        ShortcutFormatter.compactDisplayString(for: binding)
    }

    static func showsInlineActions(
        for action: MacToolsSearchAction,
        isSelected: Bool
    ) -> Bool {
        guard isSelected else { return false }
        if case .executeAction = action { return true }
        return false
    }
}

enum UnifiedSearchSelectionPolicy {
    static func shouldResetForQueryChange(from oldQuery: String, to newQuery: String) -> Bool {
        MacToolsSearchResult.normalize(oldQuery) != MacToolsSearchResult.normalize(newQuery)
    }

    static func selection(
        currentID: String?,
        availableIDs: [String],
        resetToFirst: Bool
    ) -> String? {
        guard !resetToFirst,
              let currentID,
              availableIDs.contains(currentID) else {
            return availableIDs.first
        }
        return currentID
    }
}

@MainActor
final class UnifiedSearchPaletteModel: ObservableObject {
    @Published private(set) var results: [MacToolsSearchResult]
    @Published private(set) var sections: [MacToolsSearchSection]

    private let commandContext: AppHostCommandContext
    private let recentStore: CommandPaletteRecentStore
    private var index: MacToolsSearchIndex
    private var query = ""
    private var stateCancellables: Set<AnyCancellable> = []
    private var rebuildTask: Task<Void, Never>?

    init(
        commandContext: AppHostCommandContext,
        recentStore: CommandPaletteRecentStore
    ) {
        self.commandContext = commandContext
        self.recentStore = recentStore
        commandContext.launchAtLoginController.refreshStatus()
        let index = Self.buildIndex(commandContext: commandContext)
        self.index = index
        let suggestedResults = index.results(matching: "")
        let recentReferences = Self.resolvedRecentReferences(
            from: recentStore,
            registry: commandContext.pluginHost.actionRegistry
        )
        let recentResults = recentReferences.compactMap { index.result(for: $0) }
        let sections = MacToolsSearchPresentation.sections(
            query: "",
            results: suggestedResults,
            recentResults: recentResults
        )
        self.sections = sections
        self.results = sections.flatMap(\.results)
        observeStateChanges()
    }

    func updateQuery(_ query: String) {
        guard self.query != query else {
            return
        }

        self.query = query
        updateResults()
    }

    func refresh() {
        rebuildTask?.cancel()
        commandContext.launchAtLoginController.refreshStatus()
        index = Self.buildIndex(commandContext: commandContext)
        updateResults()
    }

    var recentActionsEnabled: Bool {
        recentStore.isEnabled
    }

    var hasRecentActions: Bool {
        !recentStore.references.isEmpty
    }

    var recentActionsNeedRepair: Bool {
        recentStore.loadError != nil
    }

    @discardableResult
    func clearRecentActions() -> Bool {
        guard recentStore.clear() else { return false }
        updateResults()
        return true
    }

    @discardableResult
    func setRecentActionsEnabled(_ enabled: Bool) -> Bool {
        guard recentStore.setEnabled(enabled) else { return false }
        updateResults()
        return true
    }

    func actionCompletionObserver(
        for reference: ActionReference
    ) -> (@MainActor (ActionExecutionOutcome) -> Void) {
        let recentStore = recentStore
        return { outcome in
            recentStore.recordCompletion(of: reference, outcome: outcome)
        }
    }

    private func observeStateChanges() {
        commandContext.pluginHost.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleIndexRebuild()
                }
            }
            .store(in: &stateCancellables)

        commandContext.launchAtLoginController.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleIndexRebuild()
                }
            }
            .store(in: &stateCancellables)

        NotificationCenter.default.publisher(for: AppAppearancePreference.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleIndexRebuild()
                }
            }
            .store(in: &stateCancellables)

        recentStore.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.updateResults()
                }
            }
            .store(in: &stateCancellables)
    }

    private func scheduleIndexRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else {
                return
            }

            index = Self.buildIndex(commandContext: commandContext)
            updateResults()
        }
    }

    private static func buildIndex(
        commandContext: AppHostCommandContext
    ) -> MacToolsSearchIndex {
        MacToolsSearchIndexBuilder.build(
            pluginHost: commandContext.pluginHost,
            appHostCommandDefinitions: AppHostCommandCatalog.applicableDefinitions(
                in: commandContext
            )
        )
    }

    private func updateResults() {
        let recentReferences = Self.resolvedRecentReferences(
            from: recentStore,
            registry: commandContext.pluginHost.actionRegistry
        )
        let matchingResults = index.results(
            matching: query,
            recentReferences: recentReferences
        )
        let recentResults = recentReferences.compactMap { index.result(for: $0) }
        sections = MacToolsSearchPresentation.sections(
            query: query,
            results: matchingResults,
            recentResults: recentResults
        )
        results = sections.flatMap(\.results)
    }

    private static func resolvedRecentReferences(
        from store: CommandPaletteRecentStore,
        registry: ActionRegistry
    ) -> [ActionReference] {
        store.resolvedReferences { reference in
            guard case let .success(migrated) = registry.migrate(reference) else {
                return nil
            }
            return migrated
        }
    }
}

struct UnifiedSearchTextField: NSViewRepresentable {
    enum Command: Equatable {
        case moveSelection(Int)
        case submit
        case openOwner
        case cancel
    }

    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let focusRequestID: UInt
    let onCommand: (Command) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.onOpenOwner = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCommand(.openOwner)
        }
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier("mactools.unified-search.field")
        context.coordinator.focus(field, for: focusRequestID)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.focus(field, for: focusRequestID)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
    }

    static func command(
        for selector: Selector,
        hasMarkedText: Bool,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Command? {
        guard !hasMarkedText else {
            return nil
        }

        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            return .moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            return .moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            return modifierFlags.contains(.command) ? .openOwner : .submit
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return .openOwner
        case #selector(NSResponder.cancelOperation(_:)):
            return .cancel
        default:
            return nil
        }
    }

    static func isOpenOwnerKeyEquivalent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && (keyCode == 36 || keyCode == 76)
    }

    @MainActor
    final class SearchTextField: NSTextField {
        var onOpenOwner: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) {
                onOpenOwner?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private static let maximumFocusAttemptCount = 25
        private static let focusRetryDelay = Duration.milliseconds(20)

        var parent: UnifiedSearchTextField
        private var completedFocusRequestID: UInt?
        private var pendingFocusRequestID: UInt?
        private var focusTask: Task<Void, Never>?
        private let focusClaim: @MainActor (NSTextField) -> Bool

        init(
            parent: UnifiedSearchTextField,
            focusClaim: (@MainActor (NSTextField) -> Bool)? = nil
        ) {
            self.parent = parent
            self.focusClaim = focusClaim ?? Self.claimFocus
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }

            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard let command = UnifiedSearchTextField.command(
                for: selector,
                hasMarkedText: textView.hasMarkedText(),
                modifierFlags: NSApp.currentEvent?.modifierFlags ?? []
            ) else {
                return false
            }

            parent.onCommand(command)
            return true
        }

        func focus(_ field: NSTextField, for requestID: UInt) {
            guard completedFocusRequestID != requestID,
                  pendingFocusRequestID != requestID else {
                return
            }

            focusTask?.cancel()
            pendingFocusRequestID = requestID
            focusTask = Task { @MainActor [weak self, weak field] in
                guard let self, let field else { return }

                for attempt in 0 ..< Self.maximumFocusAttemptCount {
                    guard !Task.isCancelled,
                          pendingFocusRequestID == requestID else {
                        return
                    }

                    if focusClaim(field) {
                        completedFocusRequestID = requestID
                        pendingFocusRequestID = nil
                        focusTask = nil
                        return
                    }

                    guard attempt + 1 < Self.maximumFocusAttemptCount else {
                        break
                    }
                    if attempt == 0 {
                        await Task.yield()
                    } else {
                        try? await Task.sleep(for: Self.focusRetryDelay)
                    }
                }

                if pendingFocusRequestID == requestID {
                    pendingFocusRequestID = nil
                    focusTask = nil
                }
            }
        }

        func cancelPendingFocus() {
            focusTask?.cancel()
            focusTask = nil
            pendingFocusRequestID = nil
        }

        private static func claimFocus(for field: NSTextField) -> Bool {
            guard let window = field.window,
                  window.isVisible,
                  window.isKeyWindow,
                  window.makeFirstResponder(field) else {
                return false
            }
            return field.currentEditor() != nil
        }
    }
}

struct UnifiedSearchPresentationView: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    let pluginHost: PluginHost
    let launchAtLoginController: LaunchAtLoginController
    let appearanceUserDefaults: UserDefaults
    let recentStore: CommandPaletteRecentStore
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(accessibilityReduceTransparency ? 0.30 : 0.24)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navigationCoordinator.dismissUnifiedSearch()
                    }
                    .accessibilityHidden(true)

                UnifiedSearchPaletteView(
                    pluginHost: pluginHost,
                    launchAtLoginController: launchAtLoginController,
                    appearanceUserDefaults: appearanceUserDefaults,
                    recentStore: recentStore,
                    availableSize: geometry.size,
                    presentationOrigin: navigationCoordinator.unifiedSearchPresentationOrigin,
                    shortcutHint: "⌘K",
                    focusRequestID: navigationCoordinator.unifiedSearchFocusRequestID,
                    resetRequestID: nil,
                    quickSelectionRequest: navigationCoordinator.unifiedSearchQuickSelectionRequest,
                    showsCustomShadow: true,
                    actions: UnifiedSearchPaletteActions(
                        dismiss: navigationCoordinator.dismissUnifiedSearch,
                        dismissAfterSuccessfulExecution: navigationCoordinator.dismissUnifiedSearch,
                        navigate: navigationCoordinator.navigateFromSearch,
                        consumeQuickSelection: navigationCoordinator.consumeUnifiedSearchQuickSelectionRequest,
                        setPendingExecutionCancellation: { _ in }
                    )
                )
                .padding(24)
            }
        }
    }
}

struct UnifiedSearchPaletteActions {
    let dismiss: () -> Void
    let dismissAfterSuccessfulExecution: () -> Void
    let navigate: (SettingsNavigationDestination, SettingsSearchRevealTarget?) -> Bool
    let consumeQuickSelection: (UnifiedSearchQuickSelectionRequest) -> Bool
    let setPendingExecutionCancellation: ((() -> Void)?) -> Void
}

private struct UnifiedSearchPaletteShadowModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        } else {
            content
        }
    }
}

struct UnifiedSearchPaletteView: View {
    private enum Layout {
        static let rowCornerRadius: CGFloat = 8
    }

    private enum PendingAlert: Identifiable {
        case execute(MacToolsSearchResult)
        case replaceShortcut(
            reference: ActionReference,
            assignmentID: UUID?,
            binding: ShortcutBinding,
            ownerDescription: String
        )

        var id: String {
            switch self {
            case let .execute(result):
                "execute.\(result.id)"
            case let .replaceShortcut(reference, assignmentID, _, _):
                "shortcut.\(assignmentID?.uuidString ?? reference.key.id)"
            }
        }
    }

    let pluginHost: PluginHost
    let commandContext: AppHostCommandContext
    let availableSize: CGSize
    let presentationOrigin: UnifiedSearchPresentationOrigin?
    let shortcutHint: String?
    let focusRequestID: UInt
    let resetRequestID: UInt?
    let quickSelectionRequest: UnifiedSearchQuickSelectionRequest?
    let showsCustomShadow: Bool
    let actions: UnifiedSearchPaletteActions
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @StateObject private var model: UnifiedSearchPaletteModel
    @State private var query = ""
    @State private var selectedResultID: String?
    @State private var pendingAlert: PendingAlert?
    @State private var executionFeedback: String?
    @State private var executionTask: Task<Void, Never>?
    @State private var executionGeneration: UInt = 0

    init(
        pluginHost: PluginHost,
        launchAtLoginController: LaunchAtLoginController,
        appearanceUserDefaults: UserDefaults,
        recentStore: CommandPaletteRecentStore,
        availableSize: CGSize,
        presentationOrigin: UnifiedSearchPresentationOrigin?,
        shortcutHint: String?,
        focusRequestID: UInt,
        resetRequestID: UInt?,
        quickSelectionRequest: UnifiedSearchQuickSelectionRequest?,
        showsCustomShadow: Bool,
        actions: UnifiedSearchPaletteActions
    ) {
        self.pluginHost = pluginHost
        let commandContext = AppHostCommandContext(
            pluginHost: pluginHost,
            launchAtLoginController: launchAtLoginController,
            appearanceUserDefaults: appearanceUserDefaults
        )
        self.commandContext = commandContext
        self.availableSize = availableSize
        self.presentationOrigin = presentationOrigin
        self.shortcutHint = shortcutHint
        self.focusRequestID = focusRequestID
        self.resetRequestID = resetRequestID
        self.quickSelectionRequest = quickSelectionRequest
        self.showsCustomShadow = showsCustomShadow
        self.actions = actions
        _model = StateObject(wrappedValue: UnifiedSearchPaletteModel(
            commandContext: commandContext,
            recentStore: recentStore
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            metadataRow

            if let executionFeedback {
                Label(executionFeedback, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mactools.unified-search.execution-feedback")
            }

            resultList

            footer
        }
        .padding(16)
        .frame(width: UnifiedSearchPaletteLayout.width(for: availableSize.width))
        .background {
            UnifiedSearchPaletteSurface(
                reducesTransparency: accessibilityReduceTransparency
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .modifier(UnifiedSearchPaletteShadowModifier(isEnabled: showsCustomShadow))
        .onAppear {
            syncSelection()
            handleQuickSelectionRequest(quickSelectionRequest)
        }
        .onChange(of: query) { oldQuery, newQuery in
            executionFeedback = nil
            model.updateQuery(newQuery)
            syncSelection(
                resetToFirst: UnifiedSearchSelectionPolicy.shouldResetForQueryChange(
                    from: oldQuery,
                    to: newQuery
                )
            )
        }
        .onChange(of: resultIDs) {
            syncSelection()
        }
        .onChange(of: quickSelectionRequest) { _, request in
            handleQuickSelectionRequest(request)
        }
        .onChange(of: resetRequestID) {
            resetTransientState()
        }
        .onDisappear {
            invalidateExecution()
        }
        .onExitCommand {
            actions.dismiss()
        }
        .alert(item: $pendingAlert) { pendingAlert in
            switch pendingAlert {
            case let .execute(result):
                let confirmation = result.confirmation
                return Alert(
                    title: Text(confirmation?.title ?? result.title),
                    message: Text(confirmation?.message ?? result.detail),
                    primaryButton: .destructive(
                        Text(
                            confirmation?.confirmButtonTitle
                                ?? AppL10n.search("search.action.run", defaultValue: "执行")
                        )
                    ) {
                        execute(result)
                    },
                    secondaryButton: .cancel()
                )
            case let .replaceShortcut(reference, assignmentID, binding, ownerDescription):
                return Alert(
                    title: Text(FeatureL10n.string("替换快捷键？")),
                    message: Text(
                        FeatureL10n.format(
                            "此快捷键已分配给“%@”。替换后，原操作将不再使用它。",
                            ownerDescription
                        )
                    ),
                    primaryButton: .destructive(Text(FeatureL10n.string("替换"))) {
                        _ = pluginHost.setActionShortcutBinding(
                            binding,
                            to: reference,
                            assignmentID: assignmentID,
                            replacingConflictingActionAssignments: true
                        )
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppL10n.search("search.title", defaultValue: "搜索 MacTools")
        )
        .accessibilityIdentifier("mactools.unified-search.palette")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            UnifiedSearchTextField(
                text: $query,
                placeholder: AppL10n.search(
                    "search.prompt",
                    defaultValue: "搜索插件、设置和命令"
                ),
                accessibilityLabel: AppL10n.search(
                    "search.title",
                    defaultValue: "搜索 MacTools"
                ),
                focusRequestID: focusRequestID,
                onCommand: handleSearchFieldCommand
            )
            .frame(maxWidth: .infinity, minHeight: 22)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(AppL10n.search("search.clear", defaultValue: "清除搜索"))
                .accessibilityLabel(
                    AppL10n.search("search.clear", defaultValue: "清除搜索")
                )
            }

            if let shortcutHint, !shortcutHint.isEmpty {
                Text(shortcutHint)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                    )
                    .accessibilityHidden(true)
            }

            Button {
                actions.dismiss()
            } label: {
                Text("Esc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(AppL10n.search("search.close", defaultValue: "关闭搜索"))
            .accessibilityLabel(
                AppL10n.search("search.close", defaultValue: "关闭搜索")
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(PluginSettingsTheme.Palette.fieldBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
        }
    }

    private var metadataRow: some View {
        HStack {
            HStack {
                Text(originText)
                Spacer()
                Text(resultCountText)
            }
            .accessibilityElement(children: .combine)

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recentActionsMenu
            }
        }
        .font(PluginSettingsTheme.Typography.secondaryLabel)
        .foregroundStyle(.secondary)
    }

    private var recentActionsMenu: some View {
        Menu {
            if model.recentActionsEnabled {
                if model.recentActionsNeedRepair {
                    Label(
                        AppL10n.search(
                            "search.recent.loadFailed",
                            defaultValue: "无法加载最近操作"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .disabled(true)

                    Button {
                        performRecentActionsUpdate {
                            model.clearRecentActions()
                        }
                    } label: {
                        Label(
                            AppL10n.search(
                                "search.recent.reset",
                                defaultValue: "重置最近操作"
                            ),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                } else {
                    Button {
                        performRecentActionsUpdate {
                            model.clearRecentActions()
                        }
                    } label: {
                        Label(
                            AppL10n.search(
                                "search.recent.clear",
                                defaultValue: "清除最近操作"
                            ),
                            systemImage: "trash"
                        )
                    }
                    .disabled(!model.hasRecentActions)
                }

                Divider()

                Button(role: .destructive) {
                    performRecentActionsUpdate {
                        model.setRecentActionsEnabled(false)
                    }
                } label: {
                    Label(
                        AppL10n.search(
                            "search.recent.disable",
                            defaultValue: "停止记录并清除最近操作"
                        ),
                        systemImage: "clock.badge.xmark"
                    )
                }
            } else {
                Button {
                    performRecentActionsUpdate {
                        model.setRecentActionsEnabled(true)
                    }
                } label: {
                    Label(
                        AppL10n.search(
                            "search.recent.enable",
                            defaultValue: "启用最近操作"
                        ),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            AppL10n.search(
                "search.recent.manage",
                defaultValue: "管理最近操作"
            )
        )
        .accessibilityLabel(
            AppL10n.search(
                "search.recent.manage",
                defaultValue: "管理最近操作"
            )
        )
    }

    private func performRecentActionsUpdate(_ update: () -> Bool) {
        guard !update() else {
            executionFeedback = nil
            return
        }
        executionFeedback = AppL10n.search(
            "search.recent.updateFailed",
            defaultValue: "无法更新最近操作。"
        )
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if results.isEmpty {
                    ContentUnavailableView(
                        AppL10n.search("search.empty.title", defaultValue: "未找到结果"),
                        systemImage: "magnifyingglass",
                        description: Text(
                            AppL10n.search(
                                "search.empty.description",
                                defaultValue: "尝试插件名称、设置、功能或命令。"
                            )
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(searchSections) { section in
                            if let title = section.kind.title {
                                Text(title)
                                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 6)
                                    .accessibilityAddTraits(.isHeader)
                            }

                            ForEach(section.results) { result in
                                resultRow(
                                    result,
                                    quickSelectionNumber: quickSelectionNumber(for: result)
                                )
                                    .id(result.id)
                            }
                        }
                    }
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
                }
            }
            .frame(
                height: UnifiedSearchPaletteLayout.resultListHeight(
                    for: availableSize.height
                )
            )
            .onChange(of: selectedResultID) { _, resultID in
                guard let resultID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(resultID, anchor: .center)
                }
            }
        }
    }

    private func resultRow(
        _ result: MacToolsSearchResult,
        quickSelectionNumber: Int?
    ) -> some View {
        let isSelected = result.id == selectedResultID
        let showsInlineActions = UnifiedSearchResultRowLayout.showsInlineActions(
            for: result.action,
            isSelected: isSelected
        )

        return VStack(
            alignment: .leading,
            spacing: showsInlineActions
                ? UnifiedSearchResultRowLayout.selectedAccessorySpacing
                : 0
        ) {
            Button {
                selectedResultID = result.id
                activate(result)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: PluginSystemImage.resolvedName(result.systemImage))
                        .frame(width: 18)
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                    VStack(
                        alignment: .leading,
                        spacing: UnifiedSearchResultRowLayout.titleSubtitleSpacing
                    ) {
                        Text(result.title)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)

                        Text(result.subtitle)
                            .font(UnifiedSearchResultRowLayout.subtitleFont)
                            .foregroundStyle(
                                isSelected
                                    ? Color.white.opacity(
                                        UnifiedSearchResultRowLayout.selectedSubtitleOpacity
                                    )
                                    : Color.secondary
                            )
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(quickSelectionNumber.map { "⌘\($0)" } ?? "")
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                        .frame(
                            width: UnifiedSearchResultRowLayout.quickSelectionColumnWidth,
                            alignment: .trailing
                        )
                        .accessibilityHidden(true)

                    Text(result.kind.actionTitle)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        .frame(width: UnifiedSearchResultRowLayout.primaryActionColumnWidth)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isSelected
                                        ? Color.white.opacity(0.16)
                                        : Color.accentColor.opacity(0.1)
                                )
                        )
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            // Selection is owned by `selectedResultID`. Keeping the primary row button out of
            // the focus ring prevents AppKit from rendering a second, conflicting highlight;
            // keyboard activation continues through the search field's Return handling.
            .focusable(false)

            if showsInlineActions {
                HStack(spacing: 8) {
                    Spacer(minLength: 42)
                    shortcutControls(for: result, isSelected: isSelected)
                }
                .tint(Color.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, UnifiedSearchResultRowLayout.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Layout.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .accessibilityLabel(result.accessibilityLabel)
        .accessibilityHint(accessibilityHint(for: result, number: quickSelectionNumber))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("mactools.unified-search.result.\(result.id)")
    }

    @ViewBuilder
    private func shortcutControls(
        for result: MacToolsSearchResult,
        isSelected: Bool
    ) -> some View {
        if case let .executeAction(reference) = result.action {
            let shortcut = pluginHost.actionShortcutSettingsItem(for: reference)
            PluginShortcutRecorder(
                title: FeatureL10n.format("%@ 快捷键", result.title),
                displayText: UnifiedSearchResultRowLayout.shortcutRecorderDisplayText(
                    for: shortcut?.assignment.binding
                ),
                minWidth: UnifiedSearchResultRowLayout.minimumShortcutRecorderWidth,
                onRecord: { binding in
                    switch pluginHost.setActionShortcutBinding(
                        binding,
                        to: reference,
                        assignmentID: shortcut?.assignment.id
                    ) {
                    case .success:
                        return .accepted
                    case let .failure(.conflict(ownerDescription)):
                        pendingAlert = .replaceShortcut(
                            reference: reference,
                            assignmentID: shortcut?.assignment.id,
                            binding: binding,
                            ownerDescription: ownerDescription
                        )
                        return .accepted
                    case let .failure(error):
                        return .rejected(error.localizedDescription)
                    }
                }
            )
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: false)
            .help(shortcut?.bindingText ?? FeatureL10n.string("设置快捷键"))
            .accessibilityValue(Text(shortcut?.bindingText ?? ""))

            if shortcut != nil {
                Button {
                    pluginHost.clearActionShortcut(
                        for: reference,
                        assignmentID: shortcut?.assignment.id
                    )
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .help(FeatureL10n.string("清除快捷键"))
            }

            ActionRunLinkCopyButton(
                pluginHost: pluginHost,
                reference: reference
            )

            if pluginHost.canPresentActionOwner(for: reference) {
                Button {
                    pluginHost.presentActionOwner(for: reference)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .help(FeatureL10n.string("打开所属功能的设置"))
                .accessibilityLabel(FeatureL10n.string("打开所属功能的设置"))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let selectedResult {
                Text(
                    AppL10n.searchFormat(
                        "search.footer.actionFormat",
                        defaultValue: "%@“%@”",
                        selectedResult.kind.actionTitle,
                        selectedResult.title
                    )
                )
                    .lineLimit(1)
            } else {
                Text(
                    AppL10n.search(
                        "search.footer.tryAnotherQuery",
                        defaultValue: "尝试其他关键词"
                    )
                )
            }

            Spacer()

            Text(
                AppL10n.search(
                    "search.footer.keyboard",
                    defaultValue: "↑↓ 选择　↩ 打开　⌘↩ 设置　Tab 操作　⌘1–9 快速打开"
                )
            )
        }
        .font(PluginSettingsTheme.Typography.secondaryLabel)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var results: [MacToolsSearchResult] {
        model.results
    }

    private var searchSections: [MacToolsSearchSection] {
        model.sections
    }

    private var resultIDs: [String] {
        results.map(\.id)
    }

    private var selectedResult: MacToolsSearchResult? {
        guard let selectedResultID else {
            return nil
        }

        return results.first { $0.id == selectedResultID }
    }

    private var resultCountText: String {
        AppL10n.searchPluralFormat(
            "search.resultCountFormat",
            defaultValue: "%d 个结果",
            count: results.count
        )
    }

    private var originText: String {
        switch presentationOrigin {
        case .settingsSidebar:
            return AppL10n.search(
                "search.origin.settingsSidebar",
                defaultValue: "来自设置导航"
            )
        case .keyboard:
            return AppL10n.search(
                "search.origin.keyboard",
                defaultValue: "MacTools 快捷键 ⌘K"
            )
        case let .globalShortcut(label):
            return AppL10n.searchFormat(
                "search.origin.globalShortcutFormat",
                defaultValue: "全局快捷键 %@",
                label
            )
        case nil:
            return AppL10n.search(
                "search.title",
                defaultValue: "搜索 MacTools"
            )
        }
    }

    private func quickSelectionNumber(
        for result: MacToolsSearchResult
    ) -> Int? {
        MacToolsSearchPresentation.quickSelectionNumber(
            for: result.id,
            in: results
        )
    }

    private func accessibilityHint(
        for result: MacToolsSearchResult,
        number: Int?
    ) -> String {
        guard let number else {
            return result.detail
        }

        return "⌘\(number). \(result.detail)"
    }

    private func syncSelection(resetToFirst: Bool = false) {
        selectedResultID = UnifiedSearchSelectionPolicy.selection(
            currentID: selectedResultID,
            availableIDs: resultIDs,
            resetToFirst: resetToFirst
        )
    }

    private func moveSelection(by offset: Int) {
        let availableResults = results
        guard !availableResults.isEmpty else {
            return
        }

        let currentIndex = selectedResultID.flatMap { selectedID in
            availableResults.firstIndex { $0.id == selectedID }
        } ?? 0
        let nextIndex = (currentIndex + offset + availableResults.count) % availableResults.count
        let result = availableResults[nextIndex]
        selectedResultID = result.id
        announceSelection(result)
    }

    private func announceSelection(_ result: MacToolsSearchResult) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: result.accessibilityLabel,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func activateSelectedResult() {
        guard let selectedResult else {
            return
        }

        activate(selectedResult)
    }

    private func handleSearchFieldCommand(
        _ command: UnifiedSearchTextField.Command
    ) {
        switch command {
        case let .moveSelection(offset):
            moveSelection(by: offset)
        case .submit:
            activateSelectedResult()
        case .openOwner:
            openSelectedResultOwner()
        case .cancel:
            actions.dismiss()
        }
    }

    private func openSelectedResultOwner() {
        guard
            let selectedResult,
            case let .executeAction(reference) = selectedResult.action,
            pluginHost.canPresentActionOwner(for: reference)
        else {
            return
        }

        _ = pluginHost.presentActionOwner(for: reference)
    }

    private func handleQuickSelectionRequest(
        _ request: UnifiedSearchQuickSelectionRequest?
    ) {
        guard
            let request,
            actions.consumeQuickSelection(request)
        else {
            return
        }

        guard results.indices.contains(request.number - 1) else {
            return
        }

        let result = results[request.number - 1]
        selectedResultID = result.id
        activate(result)
    }

    private func activate(_ result: MacToolsSearchResult) {
        guard executionTask == nil else { return }
        switch MacToolsSearchActivationDecision.resolve(for: result) {
        case .confirm:
            pendingAlert = .execute(result)
        case .execute:
            execute(result)
        }
    }

    private func execute(_ result: MacToolsSearchResult) {
        switch result.action {
        case let .navigate(destination, target):
            if !actions.navigate(destination, target) {
                model.refresh()
            }
        case let .executeAction(reference):
            let generation = executionGeneration
            executionTask = Task { @MainActor in
                guard case let .success(action) = pluginHost.actionRegistry.registeredAction(
                    for: reference
                ), let mode = ActionSurfaceExecutionSupport.preferredMode(
                    for: action.definition
                ) else {
                    guard generation == executionGeneration else { return }
                    actions.setPendingExecutionCancellation(nil)
                    executionTask = nil
                    executionFeedback = FeatureL10n.string("找不到对应操作。")
                    model.refresh()
                    return
                }
                let confirmationService: (any ActionConfirmationRequesting)? =
                    result.confirmation.map { confirmation in
                        MatchingApprovedActionConfirmationService(
                            expectedRequest: ActionConfirmationRequest(
                                reference: reference,
                                confirmation: ActionConfirmation(
                                    title: confirmation.title,
                                    message: confirmation.message,
                                    confirmButtonTitle: confirmation.confirmButtonTitle
                                ),
                                source: .unifiedSearch
                            )
                        )
                    }
                let invocation = ActionInvocation(
                    reference: reference,
                    source: .unifiedSearch,
                    mode: mode
                )
                if ActionSurfaceExecutionSupport.continuesAfterSurfaceDismissal(
                    for: action.definition
                ) {
                    let start = await pluginHost.actionExecutor
                        .startSurfaceIndependentTrackingCompletion(
                            invocation,
                            expectedDefinition: action.definition,
                            confirmationService: confirmationService,
                            completionObserver: model.actionCompletionObserver(for: reference)
                        )
                    guard generation == executionGeneration else { return }
                    actions.setPendingExecutionCancellation(nil)
                    executionTask = nil
                    switch start.outcome {
                    case .started:
                        actions.dismissAfterSuccessfulExecution()
                    case .cancelled:
                        executionFeedback = FeatureL10n.string("操作已取消。")
                        model.refresh()
                    case let .rejected(rejection):
                        executionFeedback = ActionSurfaceExecutionSupport.message(for: rejection)
                        model.refresh()
                    }
                    return
                }
                let start = await pluginHost.actionExecutor
                    .startSurfaceIndependentTrackingCompletion(
                        invocation,
                        expectedDefinition: action.definition,
                        confirmationService: confirmationService,
                        completionObserver: model.actionCompletionObserver(for: reference)
                    )
                guard generation == executionGeneration else { return }
                actions.setPendingExecutionCancellation(nil)
                switch start.outcome {
                case .started:
                    guard let completion = start.completion else {
                        executionTask = nil
                        executionFeedback = FeatureL10n.string("操作未能开始。")
                        model.refresh()
                        return
                    }
                    executionTask = Task { @MainActor in
                        var iterator = completion.makeAsyncIterator()
                        guard let outcome = await iterator.next(),
                              !Task.isCancelled,
                              generation == executionGeneration else {
                            return
                        }
                        executionTask = nil
                        if case .completed(.succeeded) = outcome {
                            actions.dismissAfterSuccessfulExecution()
                        } else {
                            executionFeedback = ActionSurfaceExecutionSupport.feedback(for: outcome)
                            model.refresh()
                        }
                    }
                case .cancelled:
                    executionTask = nil
                    executionFeedback = FeatureL10n.string("操作已取消。")
                    model.refresh()
                case let .rejected(rejection):
                    executionTask = nil
                    executionFeedback = ActionSurfaceExecutionSupport.message(for: rejection)
                    model.refresh()
                }
            }
            actions.setPendingExecutionCancellation {
                invalidateExecution()
            }
        case let .pluginCommand(pluginID, expectedDefinition):
            if pluginHost.performCommand(
                pluginID: pluginID,
                expectedDefinition: expectedDefinition
            ) {
                actions.dismissAfterSuccessfulExecution()
            } else {
                model.refresh()
            }
        case let .appHostCommand(expectedDefinition):
            switch AppHostCommandExecutor.perform(
                expectedDefinition: expectedDefinition,
                context: commandContext
            ) {
            case .performed(.dismissPalette):
                actions.dismissAfterSuccessfulExecution()
            case .performed(.refreshIndex), .unavailable, .failed:
                model.refresh()
            }
        }
    }

    private func resetTransientState() {
        invalidateExecution()
        query = ""
        pendingAlert = nil
        executionFeedback = nil
        model.updateQuery("")
        model.refresh()
        selectedResultID = nil
        syncSelection()
    }

    private func invalidateExecution() {
        executionGeneration &+= 1
        actions.setPendingExecutionCancellation(nil)
        executionTask?.cancel()
        executionTask = nil
    }

}

private struct UnifiedSearchPaletteSurface: View {
    let reducesTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(
                reducesTransparency
                    ? AnyShapeStyle(SettingsStyle.contentBackground)
                    : AnyShapeStyle(.regularMaterial)
            )
            .overlay {
                if !reducesTransparency {
                    shape.fill(SettingsStyle.contentBackground.opacity(0.88))
                }
            }
    }
}
