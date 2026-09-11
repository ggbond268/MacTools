import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

enum MacSettingsWorkspaceSection: String, CaseIterable, Identifiable {
    case settings
    case profiles
    case history

    var id: String { rawValue }

    init(destination: MacSettingsDestination) {
        switch destination {
        case .profiles, .importExport: self = .profiles
        case .history: self = .history
        case .all, .favorites, .recent, .attention, .category: self = .settings
        }
    }

    var title: String {
        switch self {
        case .settings: MacSettingsStrings.text("Settings")
        case .profiles: MacSettingsStrings.text("Profiles")
        case .history: MacSettingsStrings.text("History")
        }
    }

    var systemImage: String {
        switch self {
        case .settings: "slider.horizontal.3"
        case .profiles: "square.stack.3d.up"
        case .history: "clock.arrow.circlepath"
        }
    }

    func destination(returningTo settingsDestination: MacSettingsDestination) -> MacSettingsDestination {
        switch self {
        case .settings: settingsDestination
        case .profiles: .profiles
        case .history: .history
        }
    }
}

struct MacSettingsSearchScopeState: Equatable {
    private(set) var destinationBeforeSearch: MacSettingsDestination?

    mutating func destination(
        afterChanging query: String,
        from currentDestination: MacSettingsDestination
    ) -> MacSettingsDestination {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery {
            if destinationBeforeSearch == nil,
               MacSettingsWorkspaceSection(destination: currentDestination) == .settings {
                destinationBeforeSearch = currentDestination
            }
            return .all
        }
        guard let destinationBeforeSearch else { return currentDestination }
        self.destinationBeforeSearch = nil
        return destinationBeforeSearch
    }
}

struct MacSettingsPaletteRowIdentity: Hashable {
    let sectionID: String
    let settingID: SystemSettingID
    let isFavorite: Bool
}

private struct MacSettingsPaletteDisplayRow: Identifiable {
    let record: SystemSettingRecord
    let isFavorite: Bool
    let id: MacSettingsPaletteRowIdentity
}

struct MacSettingsWorkspaceView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var lastSettingsDestination: MacSettingsDestination = .all
    @State private var searchScopeState = MacSettingsSearchScopeState()
    @FocusState private var focusedElement: MacSettingsWorkspaceFocus?

    var body: some View {
        VStack(spacing: 0) {
            if controller.operationState != .idle {
                MacSettingsOperationBanner(controller: controller)
            }
            if !controller.pendingRecoveries.isEmpty || controller.recoveryPersistenceError != nil {
                MacSettingsRecoveryView(controller: controller)
            }
            workspaceNavigation
            Divider()
            content
        }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.searchFocusRequest) {
            focusedElement = .search
        }
        .onChange(of: controller.destination) {
            rememberSettingsDestination()
            if controller.destination != .all,
               let request = controller.settingFocusRequest {
                controller.consumeSettingFocusRequest(request)
            }
        }
        .task {
            rememberSettingsDestination()
            focusedElement = .search
            if controller.rowStates.values.contains(where: \.isLoading) {
                controller.refresh()
            }
        }
    }

    private var workspaceNavigation: some View {
        Picker(
            MacSettingsStrings.text("Mac Settings Workspace"),
            selection: Binding(
                get: { MacSettingsWorkspaceSection(destination: controller.destination) },
                set: { section in
                    controller.destination = section.destination(
                        returningTo: lastSettingsDestination
                    )
                }
            )
        ) {
            ForEach(MacSettingsWorkspaceSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .focusable()
        .frame(maxWidth: 620)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityIdentifier("mac-settings.workspace-navigation")
    }

    @ViewBuilder
    private var content: some View {
        switch controller.destination {
        case .profiles, .importExport:
            MacSettingsProfilesView(controller: controller)
        case .history:
            MacSettingsHistoryView(controller: controller)
        case .all, .favorites, .recent, .attention, .category:
            liveSettings
        }
    }

    private var liveSettings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(MacSettingsStrings.text("Search All Mac Settings"), text: $controller.searchText)
                        .textFieldStyle(.plain)
                        .focused($focusedElement, equals: .search)
                        .accessibilityLabel(MacSettingsStrings.text("Search All Mac Settings"))
                        .onMoveCommand { direction in
                            guard direction == .down else { return }
                            moveKeyboardFocus(from: nil, movingForward: true)
                        }
                        .onKeyPress(.downArrow) {
                            moveKeyboardFocus(from: nil, movingForward: true)
                            return .handled
                        }

                    if !controller.searchText.isEmpty {
                        Button {
                            controller.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(MacSettingsStrings.text("Clear Search"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

                Group {
                    if controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       controller.destination == .all || controller.destination == .favorites {
                        Picker(
                            MacSettingsStrings.text("Settings Filter"),
                            selection: Binding(
                                get: { controller.destination == .favorites },
                                set: { $0 ? controller.showFavorites() : controller.showPaletteHome() }
                            )
                        ) {
                            Text(MacSettingsStrings.text("All")).tag(false)
                            Text(MacSettingsStrings.format("Pinned %@", "\(controller.favoriteIDs.count)")).tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .focusable()
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 170, height: 28)
                paletteMenu
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            if controller.paletteSections.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(controller.paletteSections, id: \.id) { section in
                                HStack {
                                    Text(section.title)
                                        .font(PluginSettingsTheme.Typography.sectionTitle)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(section.records.count)")
                                        .font(PluginSettingsTheme.Typography.statusBadge)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.top, PluginSettingsTheme.Spacing.section)
                                .padding(.bottom, PluginSettingsTheme.Spacing.sectionHeaderContent)
                                .accessibilityAddTraits(.isHeader)

                                let displayRows = paletteDisplayRows(for: section)
                                ForEach(displayRows) { displayRow in
                                    let record = displayRow.record
                                    MacSettingRow(
                                        record: record,
                                        state: controller.rowStates[record.id],
                                        canEditSettings: controller.canEditSettings,
                                        isFavorite: displayRow.isFavorite,
                                        showsCategory: section.kind != .category,
                                        isKeyboardFocused: focusedElement == .setting(record.id)
                                            || controller.settingFocusRequest?.settingID == record.id,
                                        focusedElement: $focusedElement,
                                        onApply: { controller.apply($0, to: record.id) },
                                        onFavorite: { controller.toggleFavorite(record.id) },
                                        favoriteIndex: section.kind == .favorites
                                            ? controller.favoriteIDs.firstIndex(of: record.id)
                                            : nil,
                                        favoriteCount: controller.favoriteIDs.count,
                                        onMoveFavorite: { controller.moveFavorite(record.id, by: $0) },
                                        onOpenSystemSettings: { controller.openSystemSettings(for: record.id) },
                                        onOpenProviderSettings: { controller.openProviderSettings(for: record.id) },
                                        canRetry: controller.failedDesiredValues[record.id] != nil && controller.pendingRecoveries[record.id] == nil,
                                        onRetry: { controller.retryFailedChange(record.id) },
                                        onMoveFocus: { movingForward in
                                            moveKeyboardFocus(from: record.id, movingForward: movingForward)
                                        }
                                    )
                                    .id(displayRow.id)
                                    if displayRow.id != displayRows.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                    .onChange(of: focusedElement) {
                        guard case let .setting(focusedSettingID) = focusedElement else { return }
                        if let request = controller.settingFocusRequest,
                           focusedSettingID != request.settingID {
                            controller.consumeSettingFocusRequest(request)
                        }
                        guard let displayID = paletteDisplayRowIdentity(for: focusedSettingID) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(displayID, anchor: .center)
                        }
                    }
                    .task(id: controller.settingFocusRequest) {
                        guard let request = controller.settingFocusRequest else { return }
                        await Task.yield()
                        guard let displayID = paletteDisplayRowIdentity(for: request.settingID) else {
                            controller.consumeSettingFocusRequest(request)
                            return
                        }
                        focusedElement = .setting(request.settingID)
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(displayID, anchor: .center)
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                        guard controller.settingFocusRequest == request else { return }
                        focusedElement = .setting(request.settingID)
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                focusedElement = .search
            }
        }
        .onChange(of: controller.searchText) {
            updateSearchScope()
        }
    }

    private var keyboardSettingIDs: [SystemSettingID] {
        controller.paletteSections.flatMap { $0.records.map(\.id) }
    }

    private func paletteDisplayRows(
        for section: MacSettingsPaletteSection
    ) -> [MacSettingsPaletteDisplayRow] {
        section.records.map { record in
            let isFavorite = section.kind == .favorites
                || controller.favoriteIDs.contains(record.id)
            return MacSettingsPaletteDisplayRow(
                record: record,
                isFavorite: isFavorite,
                id: .init(
                    sectionID: section.id,
                    settingID: record.id,
                    isFavorite: isFavorite
                )
            )
        }
    }

    private func paletteDisplayRowIdentity(
        for settingID: SystemSettingID
    ) -> MacSettingsPaletteRowIdentity? {
        for section in controller.paletteSections {
            if let row = paletteDisplayRows(for: section).first(where: {
                $0.record.id == settingID
            }) {
                return row.id
            }
        }
        return nil
    }

    private func moveKeyboardFocus(
        from currentID: SystemSettingID?,
        movingForward: Bool
    ) {
        switch MacSettingsKeyboardNavigation.target(
            from: currentID,
            movingForward: movingForward,
            settingIDs: keyboardSettingIDs
        ) {
        case .search:
            focusedElement = .search
        case let .setting(id):
            focusedElement = .setting(id)
        }
    }

    private func rememberSettingsDestination() {
        guard MacSettingsWorkspaceSection(destination: controller.destination) == .settings else {
            return
        }
        lastSettingsDestination = controller.destination
    }

    private func updateSearchScope() {
        if let request = controller.settingFocusRequest {
            controller.consumeSettingFocusRequest(request)
            searchScopeState = MacSettingsSearchScopeState()
        }
        let destination = searchScopeState.destination(
            afterChanging: controller.searchText,
            from: controller.destination
        )
        if destination != controller.destination {
            controller.destination = destination
        }
    }

    private var paletteMenu: some View {
        Menu {
            Button(MacSettingsStrings.text("Pinned")) { controller.showFavorites() }
                .disabled(controller.favoriteIDs.isEmpty)
            Button(MacSettingsStrings.text("Recently Changed")) { controller.destination = .recent }
                .disabled(controller.history.isEmpty)
            Button(MacSettingsStrings.format("Needs Attention (%@)", "\(controller.attentionCount)")) { controller.destination = .attention }
                .disabled(controller.attentionCount == 0)

            Divider()

            Button(MacSettingsStrings.text("Refresh Current Values")) { controller.refresh() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .accessibilityLabel(MacSettingsStrings.text("More Mac Settings Actions"))
    }

    private var emptyTitle: String {
        if !controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MacSettingsStrings.text("No Settings Found")
        }
        switch controller.destination {
        case .favorites: return MacSettingsStrings.text("No Pinned Settings")
        case .attention: return MacSettingsStrings.text("Nothing Needs Attention")
        case .recent: return MacSettingsStrings.text("No Recent Changes")
        default: return MacSettingsStrings.text("Search Mac Settings")
        }
    }

    private var emptyImage: String {
        controller.destination == .attention ? "checkmark.circle" : "magnifyingglass"
    }

    private var emptyDescription: String {
        if !controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MacSettingsStrings.text("Try another name, category, or keyword.")
        }
        switch controller.destination {
        case .favorites: return MacSettingsStrings.text("Use the pin button on any setting. The first four pinned settings also appear in the Feature Panel.")
        case .attention: return MacSettingsStrings.text("No settings have errors, missing requirements, or pending steps.")
        case .recent: return MacSettingsStrings.text("Settings changed through MacTools appear here.")
        default: return MacSettingsStrings.text("Enter a name or keyword to view and change settings directly.")
        }
    }
}
