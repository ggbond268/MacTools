import AppKit
import MacToolsPluginKit
import SwiftUI

struct ClipboardSavedPreviewState {
    let itemID: UUID
    let image: NSImage?
    let text: String?

    func image(for id: UUID) -> NSImage? {
        itemID == id ? image : nil
    }

    func text(for id: UUID) -> String? {
        itemID == id ? text : nil
    }
}

@MainActor
struct ClipboardSavedLibraryView: View {
    @ObservedObject var controller: ClipboardSavedLibraryController
    @ObservedObject var settings: ClipboardHistorySettingsStore
    @Binding var query: String
    @Binding var selectedItemID: UUID?
    let contentFilter: ClipboardHistoryContentFilter
    let semanticFilter: ClipboardHistorySemanticFilter
    let editRequestID: UInt
    let localization: PluginLocalization
    let onPaste: (UUID, Bool) -> Void
    let onCopy: (UUID) -> Void
    let onVisibleItemIDsChange: ([UUID]) -> Void

    @State private var editorDraft: ClipboardSnippetDraft?
    @State private var metadataDraft: ClipboardSavedMetadataDraft?
    @State private var previewState: ClipboardSavedPreviewState?
    @State private var visibleItems: [ClipboardSavedItem] = []
    @State private var hasMoreItems = false
    @State private var visibleItemLimit = 50
    @State private var searchTask: Task<Void, Never>?
    @State private var previewRetryRevision = 0

    private var selectedItem: ClipboardSavedItem? {
        guard let selectedItemID else { return nil }
        return controller.items.first { $0.id == selectedItemID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(hasMoreItems
                    ? localization.format(
                        "saved.results.count.more",
                        defaultValue: "Showing %d+ saved items",
                        visibleItems.count
                    )
                    : localization.format(
                        "saved.results.count",
                        defaultValue: "%d saved items",
                        visibleItems.count
                    ))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editorDraft = .empty
                } label: {
                    Label(
                        localization.string("saved.create", defaultValue: "New Snippet"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.fatalErrorMessage != nil)
            }
            .padding(.horizontal, 8)

            if let errorMessage = controller.errorMessage,
               controller.fatalErrorMessage == nil {
                HStack(spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                    Spacer()
                    Button {
                        controller.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help(localization.string("common.close", defaultValue: "Close"))
                }
                .padding(.horizontal, 8)
            }

            if !controller.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = controller.fatalErrorMessage {
                ContentUnavailableView {
                    Label(
                        localization.string(
                            "saved.error.title",
                            defaultValue: "Saved Library Unavailable"
                        ),
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(localization.string("settings.storage.retry", defaultValue: "Retry")) {
                        controller.retryLoading()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleItems.isEmpty {
                ContentUnavailableView(
                    query.isEmpty
                        ? localization.string("saved.empty.title", defaultValue: "No Saved Items")
                        : localization.string("saved.search.empty", defaultValue: "No Matching Saved Items"),
                    systemImage: query.isEmpty ? "bookmark" : "magnifyingglass",
                    description: Text(localization.string(
                        "saved.empty.description",
                        defaultValue: "Save something from History or create a reusable snippet."
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 12) {
                        savedList
                            .frame(width: min(310, max(240, geometry.size.width * 0.34)))
                        Divider()
                        savedDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onAppear { scheduleSearch(debounce: false) }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: controller.items) { _, _ in scheduleSearch(debounce: false) }
        .onChange(of: query) { _, _ in
            visibleItemLimit = 50
            scheduleSearch(debounce: true)
        }
        .onChange(of: contentFilter) { _, _ in
            visibleItemLimit = 50
            scheduleSearch(debounce: false)
        }
        .onChange(of: semanticFilter) { _, _ in
            visibleItemLimit = 50
            scheduleSearch(debounce: false)
        }
        .onChange(of: editRequestID) { _, _ in
            guard let selectedItemID else { return }
            beginEditing(selectedItemID)
        }
        .sheet(item: $editorDraft) { draft in
            ClipboardSnippetEditorSheet(
                initialDraft: draft,
                settings: settings,
                errorMessage: controller.errorMessage,
                localization: localization,
                onSave: { updatedDraft in
                    if let saved = await controller.saveSnippet(updatedDraft) {
                        selectedItemID = saved.id
                        editorDraft = nil
                        return true
                    }
                    return false
                },
                onCancel: { editorDraft = nil }
            )
        }
        .sheet(item: $metadataDraft) { draft in
            ClipboardSavedMetadataEditorSheet(
                initialDraft: draft,
                localization: localization,
                onSave: { updatedDraft in
                    Task { @MainActor in
                        if let saved = await controller.updateMetadata(updatedDraft) {
                            selectedItemID = saved.id
                            metadataDraft = nil
                        }
                    }
                },
                onCancel: { metadataDraft = nil }
            )
        }
    }

    private var savedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleItems) { item in
                        savedRow(item)
                            .id(item.id)
                    }
                    if hasMoreItems {
                        Button(localization.string("saved.loadMore", defaultValue: "Load More")) {
                            visibleItemLimit += 50
                            scheduleSearch(debounce: false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.trailing, 6)
                .padding(.bottom, 8)
            }
            .onChange(of: selectedItemID) { _, itemID in
                guard let itemID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
    }

    private func savedRow(_ item: ClipboardSavedItem) -> some View {
        let isSelected = selectedItemID == item.id
        return HStack(alignment: .top, spacing: PluginPaletteMetrics.rowContentSpacing) {
            Image(systemName: savedItemSystemImage(item))
                .frame(width: PluginPaletteMetrics.rowIconWidth, height: 20)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            VStack(alignment: .leading, spacing: PluginPaletteMetrics.rowTitleDescriptionSpacing) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .lineLimit(2)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    Spacer(minLength: 4)
                    if item.hasDynamicTemplateContent {
                        Image(systemName: "curlybraces")
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                            .help(localization.string("saved.dynamic", defaultValue: "Dynamic Snippet"))
                    }
                }
                HStack(spacing: 5) {
                    Text(savedKindTitle(item))
                    if let keyword = item.keyword {
                        Text(keyword)
                            .font(.system(.caption, design: .monospaced))
                    }
                    Spacer(minLength: 0)
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginPaletteSelectableRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { selectedItemID = item.id }
        .contextMenu {
            Button(localization.string("panel.footer.paste", defaultValue: "Paste")) {
                onPaste(item.id, false)
            }
            Button(localization.string("common.copy", defaultValue: "Copy")) {
                onCopy(item.id)
            }
            Button(editTitle(for: item)) {
                beginEditing(item.id)
            }
            Divider()
            Button(localization.string("common.delete", defaultValue: "Delete"), role: .destructive) {
                Task { await controller.delete(id: item.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedItemID = item.id }
    }

    @ViewBuilder
    private var savedDetail: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(PluginSettingsTheme.Typography.pageTitle)
                            .textSelection(.enabled)
                        Text(savedKindTitle(item))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(editTitle(for: item)) {
                        beginEditing(item.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(localization.string("common.copy", defaultValue: "Copy")) {
                        onCopy(item.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(localization.string("panel.footer.paste", defaultValue: "Paste")) {
                        onPaste(item.id, false)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if item.isSnippet {
                    ClipboardSnippetKeywordNotice(settings: settings, localization: localization)
                }

                savedPreview(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 8) {
                    if !item.tags.isEmpty {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag)
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    PluginSettingsTheme.Palette.activeControlBackground,
                                    in: Capsule()
                                )
                        }
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(item.payloadByteCount),
                        countStyle: .file
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: "\(item.id.uuidString)-\(previewRetryRevision)") {
                previewState = nil
                guard let payload = await controller.previewPayload(id: item.id),
                      !Task.isCancelled else { return }
                let imageData = payload.representations.first(where: {
                    ClipboardRepresentationType.isImage($0.typeIdentifier)
                })?.data
                let image: NSImage? = if let imageData {
                    await ClipboardBoundedImagePreviewWork.image(from: imageData)
                } else {
                    nil
                }
                guard !Task.isCancelled else { return }
                previewState = ClipboardSavedPreviewState(
                    itemID: item.id,
                    image: image,
                    text: previewText(for: payload)
                )
            }
        } else {
            ContentUnavailableView(
                localization.string("saved.select", defaultValue: "Select a Saved Item"),
                systemImage: "bookmark"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func savedPreview(_ item: ClipboardSavedItem) -> some View {
        if let errorMessage = controller.itemLoadErrorMessages[item.id] {
            ContentUnavailableView {
                Label(
                    localization.string("saved.preview.unavailable", defaultValue: "Preview Unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button(localization.string("settings.storage.retry", defaultValue: "Retry")) {
                    controller.clearItemLoadError(id: item.id)
                    previewRetryRevision &+= 1
                }
                Button(localization.string("common.delete", defaultValue: "Delete"), role: .destructive) {
                    Task { await controller.delete(id: item.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let previewText = previewState?.text(for: item.id), !previewText.isEmpty {
            ScrollView {
                Text(previewText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
            }
        } else if let previewImage = previewState?.image(for: item.id) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
            }
        } else {
            ContentUnavailableView(
                item.title,
                systemImage: savedItemSystemImage(item),
                description: Text(localization.string(
                    "saved.clip.description",
                    defaultValue: "The original clipboard representation is preserved."
                ))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewText(for payload: ClipboardHistoryPayload) -> String? {
        if let plainText = payload.plainText, !plainText.isEmpty { return plainText }
        if !payload.fileURLs.isEmpty {
            return payload.fileURLs.map(\.path).joined(separator: "\n")
        }
        if !payload.linkURLs.isEmpty {
            return payload.linkURLs.map(\.absoluteString).joined(separator: "\n")
        }
        return nil
    }

    private func repairSelection() {
        let visibleIDs = Set(visibleItems.map(\.id))
        if let selectedItemID, visibleIDs.contains(selectedItemID) { return }
        selectedItemID = visibleItems.first?.id
    }

    private func scheduleSearch(debounce: Bool) {
        searchTask?.cancel()
        let items = controller.items
        let searchQuery = query
        let limit = visibleItemLimit
        let contentFilter = contentFilter
        let semanticFilter = semanticFilter
        searchTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let filteredItems = items.filter {
                    let presentation = $0.historyPresentationItem()
                    return contentFilter.matches(presentation)
                        && semanticFilter.matches(presentation)
                }
                return ClipboardSavedLibrarySearch.result(
                    items: filteredItems,
                    query: searchQuery,
                    limit: limit,
                    itemsAreSorted: false
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            visibleItems = result.items
            hasMoreItems = result.hasMore
            onVisibleItemIDsChange(result.items.map(\.id))
            repairSelection()
        }
    }

    private func beginEditing(_ id: UUID) {
        controller.clearError()
        selectedItemID = id
        Task { @MainActor in
            if let snippetDraft = await controller.draft(for: id) {
                guard selectedItemID == id else { return }
                editorDraft = snippetDraft
                metadataDraft = nil
            } else {
                guard selectedItemID == id else { return }
                metadataDraft = controller.metadataDraft(for: id)
                editorDraft = nil
            }
        }
    }

    private func editTitle(for item: ClipboardSavedItem) -> String {
        item.isSnippet
            ? localization.string("saved.edit", defaultValue: "Edit Snippet")
            : localization.string("saved.editDetails", defaultValue: "Edit Details")
    }

    private func savedKindTitle(_ item: ClipboardSavedItem) -> String {
        item.isSnippet
            ? localization.string("saved.kind.snippet", defaultValue: "Snippet")
            : localization.string("saved.kind.clip", defaultValue: "Saved Item")
    }

    private func savedItemSystemImage(_ item: ClipboardSavedItem) -> String {
        if item.isSnippet { return "text.quote" }
        return switch item.contentKind {
        case .plainText: "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .files: "doc.on.doc"
        case .link: "link"
        case .color: "paintpalette"
        case .media: "play.rectangle"
        }
    }
}

@MainActor
struct ClipboardSnippetKeywordNotice: View {
    @ObservedObject var settings: ClipboardHistorySettingsStore
    let localization: PluginLocalization

    var isExpansionDisabled: Bool { !settings.isKeywordExpansionEnabled }

    var body: some View {
        if isExpansionDisabled {
            HStack(spacing: 10) {
                Label(
                    localization.string(
                        "saved.keyword.disabled",
                        defaultValue: "Keyword expansion is off. You can still paste this snippet manually."
                    ),
                    systemImage: "keyboard"
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(localization.string("saved.keyword.enable", defaultValue: "Enable")) {
                    settings.isKeywordExpansionEnabled = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(localization.string(
                    "settings.saved.expansion.title", defaultValue: "Expand Snippet Keywords"
                ))
            }
            .padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("mactools.clipboard.snippet.keyword-disabled")
        }
    }
}

struct ClipboardSnippetEditorSheet: View {
    let initialDraft: ClipboardSnippetDraft
    @ObservedObject var settings: ClipboardHistorySettingsStore
    let errorMessage: String?
    let localization: PluginLocalization
    let onSave: (ClipboardSnippetDraft) async -> Bool
    let onCancel: () -> Void

    @State private var draft: ClipboardSnippetDraft
    @State private var tagsText: String
    @State private var preview: Result<ClipboardSnippetExpansion, Error>?
    @State private var isSaving = false
    @State private var contentSelection = NSRange(location: 0, length: 0)
    @State private var variablePickerRequest: VariablePickerRequest?

    private struct VariablePickerRequest: Identifiable {
        let id = UUID()
        let text: String
        let selection: NSRange
    }

    init(
        initialDraft: ClipboardSnippetDraft,
        settings: ClipboardHistorySettingsStore,
        errorMessage: String?,
        localization: PluginLocalization,
        onSave: @escaping (ClipboardSnippetDraft) async -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.initialDraft = initialDraft
        self.settings = settings
        self.errorMessage = errorMessage
        self.localization = localization
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _tagsText = State(initialValue: initialDraft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.isNew
                    ? localization.string("saved.editor.new", defaultValue: "New Snippet")
                    : localization.string("saved.editor.edit", defaultValue: "Edit Snippet"))
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Spacer()
                Button {
                    variablePickerRequest = VariablePickerRequest(text: draft.content, selection: contentSelection)
                } label: {
                    Label(
                        localization.string("saved.editor.variable", defaultValue: "Insert Variable"),
                        systemImage: "curlybraces"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .sheet(item: $variablePickerRequest) { request in
                    ClipboardSnippetVariablePicker(
                        text: request.text,
                        selection: request.selection,
                        localization: localization,
                        onInsert: insertVariable
                    )
                }
            }

            TextField(localization.string("saved.editor.title", defaultValue: "Name"), text: $draft.title)
            ClipboardSnippetTextEditor(
                text: $draft.content,
                selectedRange: $contentSelection
            )
                .font(.body)
                .frame(minHeight: 220)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
                }
            HStack(spacing: 12) {
                TextField(localization.string("saved.editor.tags", defaultValue: "Tags, separated by commas"), text: $tagsText)
                TextField(
                    localization.string("saved.editor.keyword", defaultValue: "Expansion keyword (optional)"),
                    text: Binding(
                        get: { draft.keyword ?? "" },
                        set: { draft.keyword = $0.isEmpty ? nil : $0 }
                    )
                )
                .frame(maxWidth: 240)
            }
            Text(localization.string(
                "saved.editor.keywordHint",
                defaultValue: "Unique keywords expand as you type in supported editors. Keywords that prefix another keyword wait for Space. Requires Accessibility permission."
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            ClipboardSnippetKeywordNotice(settings: settings, localization: localization)
            if let preview {
                switch preview {
                case let .success(expansion):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.string("saved.editor.preview", defaultValue: "Preview"))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Text(expansion.text)
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                case let .failure(error):
                    Label(
                        (error as? ClipboardSnippetTemplateError)?.localizedMessage(localization)
                            ?? error.localizedDescription,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(localization.string("saved.editor.preview", defaultValue: "Preview")) {
                    preview = Result {
                        try ClipboardSnippetTemplateEngine.expand(
                            draft.content,
                            context: .current(clipboardText: NSPasteboard.general.string(forType: .string))
                        )
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(localization.string("common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(localization.string("common.save", defaultValue: "Save")) {
                    guard !isSaving else { return }
                    draft.tags = tagsText.split(separator: ",").map(String.init)
                    isSaving = true
                    let submittedDraft = draft
                    Task { @MainActor in
                        let didSave = await onSave(submittedDraft)
                        if !didSave { isSaving = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSaving
                        || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.content.isEmpty
                )
            }
        }
        .padding(22)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 480)
    }

    private func insertVariable(_ insertion: String) {
        let result = ClipboardSnippetEditorInsertion.insert(
            insertion,
            into: draft.content,
            selectedRange: contentSelection
        )
        draft.content = result.text
        contentSelection = result.selectedRange
    }
}

enum ClipboardSnippetEditorInsertion {
    static func insert(
        _ insertion: String,
        into text: String,
        selectedRange: NSRange
    ) -> (text: String, selectedRange: NSRange) {
        let content = text as NSString
        let location = min(selectedRange.location, content.length)
        let length = min(selectedRange.length, content.length - location)
        let updatedText = content.replacingCharacters(
            in: NSRange(location: location, length: length),
            with: insertion
        )
        return (
            updatedText,
            NSRange(location: location + (insertion as NSString).length, length: 0)
        )
    }
}

@MainActor
private struct ClipboardSnippetTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClipboardSnippetTextEditor

        init(parent: ClipboardSnippetTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selectedRange = textView.selectedRange()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.string = text
        textView.setSelectedRange(selectedRange)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        let length = (text as NSString).length
        let location = min(selectedRange.location, length)
        let selectionLength = min(selectedRange.length, length - location)
        let clampedRange = NSRange(location: location, length: selectionLength)
        if textView.selectedRange() != clampedRange {
            textView.setSelectedRange(clampedRange)
        }
    }
}

extension ClipboardSnippetDraft: Identifiable {}

@MainActor
struct ClipboardSavedMetadataEditorSheet: View {
    let localization: PluginLocalization
    let onSave: (ClipboardSavedMetadataDraft) -> Void
    let onCancel: () -> Void

    @State private var draft: ClipboardSavedMetadataDraft
    @State private var tagsText: String

    init(
        initialDraft: ClipboardSavedMetadataDraft,
        localization: PluginLocalization,
        onSave: @escaping (ClipboardSavedMetadataDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.localization = localization
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _tagsText = State(initialValue: initialDraft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.string("saved.editDetails", defaultValue: "Edit Details"))
                .font(PluginSettingsTheme.Typography.pageTitle)
            TextField(
                localization.string("saved.editor.title", defaultValue: "Name"),
                text: $draft.title
            )
            TextField(
                localization.string("saved.editor.tags", defaultValue: "Tags, separated by commas"),
                text: $tagsText
            )
            HStack {
                Spacer()
                Button(localization.string("common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(localization.string("common.save", defaultValue: "Save")) {
                    draft.tags = tagsText.split(separator: ",").map(String.init)
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 560)
    }
}
