import AppKit
import MacToolsPluginKit
import SwiftUI

@MainActor
enum ClipboardSnippetPreviewClipboard {
    static func readText(
        from pasteboard: any ClipboardPasteboardAccess,
        maximumByteCount: Int = ClipboardSnippetExpansionContext.defaultMaximumUTF8ByteCount
    ) async -> String? {
        let changeCount = pasteboard.changeCount
        guard pasteboard.typeNames.isDisjoint(with: ClipboardCapturePolicy.ignoredProducerTypes) else { return nil }
        let result = await pasteboard.readPlainTextAsynchronously(
            maximumByteCount: maximumByteCount,
            expectedChangeCount: changeCount
        )
        guard !Task.isCancelled, pasteboard.changeCount == changeCount,
              case let .payload(payload) = result else {
            return nil
        }
        return payload.plainText
    }
}

enum ClipboardSnippetVariable: String, CaseIterable, Identifiable, Sendable {
    case date, time, datetime, clipboard, cursor
    var id: String { rawValue }
    var isDate: Bool { self == .date || self == .time || self == .datetime }

    var formats: [String] {
        switch self {
        case .date: ["yyyy-MM-dd", "MMM d, yyyy", "EEEE, MMMM d, yyyy", "dd/MM/yyyy", "MM/dd/yyyy"]
        case .time: ["HH:mm", "HH:mm:ss", "h:mm a"]
        case .datetime: ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ssXXX", "MMM d, yyyy h:mm a"]
        default: []
        }
    }
}

struct ClipboardSnippetVariableOptions: Equatable, Sendable {
    var variable: ClipboardSnippetVariable = .date
    var format = ""
    var offset = ""
    var timeZone = ""
    var trimsClipboard = false
    var clipboardCase = ""
    var fallback = ""

    var template: String {
        var options: [(String, String)] = []
        if variable.isDate {
            if !format.isEmpty { options.append(("format", format)) }
            if !offset.isEmpty { options.append(("offset", offset)) }
            if !timeZone.isEmpty { options.append(("timezone", timeZone)) }
        } else if variable == .clipboard {
            if trimsClipboard { options.append(("trim", "true")) }
            if !clipboardCase.isEmpty { options.append(("case", clipboardCase)) }
            if !fallback.isEmpty { options.append(("fallback", fallback)) }
        }
        return "{{" + variable.rawValue + options.map { key, value in
            // JSON escaping also makes quotes, backslashes, and line breaks safe in options.
            let quoted = String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
            return " \(key)=\(quoted)"
        }.joined() + "}}"
    }

    func preview(
        context: ClipboardSnippetExpansionContext,
        text: String,
        selection: NSRange
    ) throws -> ClipboardSnippetExpansion {
        try ClipboardSnippetTemplateEngine.expand(previewTemplate(text: text, selection: selection), context: context)
    }

    func previewTemplate(text: String, selection: NSRange) -> String {
        if variable == .cursor {
            let candidate = ClipboardSnippetEditorInsertion.insert(template, into: text, selectedRange: selection)
            return candidate.text
        }
        return template
    }
}

/// Preview is ephemeral and shares the exact parser used by paste and keyword expansion.
struct ClipboardSnippetVariablePicker: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let selection: NSRange
    let localization: PluginLocalization
    let previewPasteboard: any ClipboardPasteboardAccess
    let onInsert: (String) -> Void
    var maximumExpandedTextByteCount: Int = ClipboardSnippetExpansionContext.defaultMaximumUTF8ByteCount

    @State private var options = ClipboardSnippetVariableOptions()
    @State private var usesCustomFormat = false
    @State private var preview: Result<ClipboardSnippetExpansion, Error>?
    @State private var previewedTemplate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(localization.string("saved.editor.variable", defaultValue: "Insert Variable"))
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                Picker(localization.string("saved.editor.variable", defaultValue: "Insert Variable"), selection: $options.variable) {
                    ForEach(ClipboardSnippetVariable.allCases) { variable in
                        Text("{{\(variable.rawValue)}}").tag(variable)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("mactools.clipboard.variable.kind")
            }

            if options.variable.isDate { dateControls }
            if options.variable == .clipboard { clipboardControls }
            if options.variable == .cursor {
                Text(localization.string("saved.variable.cursorHelp", defaultValue: "Places the typing cursor here after automatic paste. Only one marker is allowed. Works in supported editors; copying text does not preserve cursor position. The line below shows its position in your snippet."))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            previewBlock(localization.string("saved.variable.template", defaultValue: "Variable Template")) {
                Text(options.template).font(.body.monospaced()).textSelection(.enabled)
                    .accessibilityLabel(options.template)
                    .id(options.template)
            }
            previewBlock(localization.string("saved.variable.value", defaultValue: "Value Right Now")) {
                switch preview {
                case let .success(expansion):
                    ScrollView {
                        Text(displayText(expansion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityLabel(displayText(expansion))
                    }
                    .frame(height: 88)
                    .accessibilityIdentifier("mactools.clipboard.variable.value")
                case let .failure(error):
                    Label((error as? ClipboardSnippetTemplateError)?.localizedMessage(localization)
                        ?? error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(minHeight: 88)
                case nil:
                    ProgressView().frame(height: 88)
                }
            }
            HStack {
                Button(localization.string("common.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localization.string("saved.variable.insert", defaultValue: "Insert")) {
                    guard canInsert else { return }
                    onInsert(options.template)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInsert)
                .accessibilityIdentifier("mactools.clipboard.variable.insert")
            }
            .controlSize(.small)
        }
        .textFieldStyle(.roundedBorder)
        .padding(18)
        .frame(width: 470)
        .onChange(of: options.variable) { _, variable in
            options = ClipboardSnippetVariableOptions(variable: variable)
            usesCustomFormat = false
        }
        .task(id: options) {
            while !Task.isCancelled {
                await refreshPreview()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var dateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(localization.string("saved.variable.format", defaultValue: "Format"), selection: Binding(
                get: { usesCustomFormat ? "custom" : options.format },
                set: { value in
                    usesCustomFormat = value == "custom"
                    if !usesCustomFormat { options.format = value }
                }
            )) {
                Text(localization.string("saved.variable.default", defaultValue: "System Default")).tag("")
                ForEach(options.variable.formats, id: \.self) { Text($0).tag($0) }
                Text(localization.string("saved.variable.custom", defaultValue: "Custom Format…")).tag("custom")
            }
            if usesCustomFormat {
                TextField("yyyy-MM-dd", text: $options.format)
                    .accessibilityLabel(localization.string("saved.variable.format", defaultValue: "Format"))
                Text(localization.string("saved.variable.formatHelp", defaultValue: "yyyy = year, MM = month, dd = day; HH = hour, mm = minute. Quote literal text with single quotes."))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(localization.string("saved.variable.offset", defaultValue: "Offset"))
                Spacer()
                TextField("+1d", text: $options.offset).frame(width: 250)
                    .accessibilityLabel(localization.string("saved.variable.offset", defaultValue: "Offset"))
            }
            Text(localization.string("saved.variable.offsetHelp", defaultValue: "Optional: +1d tomorrow, -1w last week. Units: s, m, h, d, w, M (month), y. Calendar offsets respect daylight saving time."))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            HStack {
                Text(localization.string("saved.variable.timeZone", defaultValue: "Time Zone"))
                Spacer()
                TextField(localization.string("saved.variable.localZone", defaultValue: "Local, or UTC / America/New_York"), text: $options.timeZone)
                    .frame(width: 250)
                    .accessibilityLabel(localization.string("saved.variable.timeZone", defaultValue: "Time Zone"))
            }
        }
    }

    private var clipboardControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(localization.string("saved.variable.trim", defaultValue: "Trim Surrounding Whitespace"), isOn: $options.trimsClipboard)
                .toggleStyle(.checkbox)
            Picker(localization.string("saved.variable.case", defaultValue: "Letter Case"), selection: $options.clipboardCase) {
                Text(localization.string("saved.variable.unchanged", defaultValue: "Unchanged")).tag("")
                Text(localization.string("saved.variable.upper", defaultValue: "UPPERCASE")).tag("upper")
                Text(localization.string("saved.variable.lower", defaultValue: "lowercase")).tag("lower")
            }
            TextField(localization.string("saved.variable.fallback", defaultValue: "Fallback when empty (optional)"), text: $options.fallback)
            Text(localization.string("saved.variable.clipboardHelp", defaultValue: "Uses current clipboard text. Trimming happens before the empty check, then letter case is applied. Clipboard text is never evaluated as a template."))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
    }

    private func previewBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canInsert: Bool {
        if case .success = preview, previewedTemplate == options.template { return true }
        return false
    }

    private func displayText(_ expansion: ClipboardSnippetExpansion) -> String {
        var value = expansion.text
        if let offset = expansion.cursorOffsetFromEnd {
            let index = value.index(value.endIndex, offsetBy: -offset)
            // Show the cursor neighborhood even in very long snippets.
            value = String(value[..<index].suffix(120)) + "▏" + String(value[index...].prefix(380))
        }
        if value.isEmpty { return localization.string("saved.variable.empty", defaultValue: "(Empty text)") }
        return value.count > 2000 ? String(value.prefix(2000)) + "…" : value
    }

    private func refreshPreview() async {
        let currentOptions = options
        let template = currentOptions.previewTemplate(text: text, selection: selection)
        let needsClipboard = await Task.detached { ClipboardSnippetTemplateEngine.requiresClipboardText(template) }.value
        guard !Task.isCancelled else { return }
        let clipboardText = needsClipboard
            ? await ClipboardSnippetPreviewClipboard.readText(
                from: previewPasteboard,
                maximumByteCount: maximumExpandedTextByteCount
            )
            : nil
        guard !Task.isCancelled else { return }
        var context = ClipboardSnippetExpansionContext.current(clipboardText: clipboardText)
        context.maximumUTF8ByteCount = maximumExpandedTextByteCount
        do {
            let expansion = try await ClipboardSnippetTemplateEngine.expandAsync(template, context: context)
            guard !Task.isCancelled else { return }
            preview = .success(expansion)
        } catch is CancellationError { return }
        catch { preview = .failure(error) }
        previewedTemplate = currentOptions.template
    }
}
