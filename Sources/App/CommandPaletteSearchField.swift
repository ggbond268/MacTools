import AppKit
import MacToolsPluginKit
import SwiftUI

/// Keeps ordinary palette editing behavior while preserving an explicit action message verbatim.
struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding private var text: String
    private let placeholder: String
    private let accessibilityLabel: String
    private let accessibilityIdentifier: String
    private let focusRequestID: UInt
    private let alternateSubmitModifier: NSEvent.ModifierFlags?
    private let onCommand: (PluginPaletteSearchCommand) -> Void
    private let preservesText: (String) -> Bool
    private let onMarkedTextChange: (Bool) -> Void
    private let completion: () -> String?

    init(
        text: Binding<String>,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        focusRequestID: UInt,
        alternateSubmitModifier: NSEvent.ModifierFlags? = nil,
        onCommand: @escaping (PluginPaletteSearchCommand) -> Void,
        preservesText: @escaping (String) -> Bool,
        onMarkedTextChange: @escaping (Bool) -> Void,
        completion: @escaping () -> String? = { nil }
    ) {
        _text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.focusRequestID = focusRequestID
        self.alternateSubmitModifier = alternateSubmitModifier
        self.onCommand = onCommand
        self.preservesText = preservesText
        self.onMarkedTextChange = onMarkedTextChange
        self.completion = completion
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField(frame: .zero)
        field.onAlternateSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCommand(.alternateSubmit)
        }
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        configure(field)
        context.coordinator.focus(field, for: focusRequestID)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.focus(field, for: focusRequestID)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
    }

    private func configure(_ field: NSTextField) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        guard let field = field as? SearchTextField else { return }
        field.alternateSubmitModifier = alternateSubmitModifier
    }

    static func normalizedSingleLineText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || $0 == "\t"
        }) else {
            return text
        }
        return text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    static func normalizedSelection(
        _ selection: NSRange,
        in originalText: String
    ) -> NSRange {
        let string = originalText as NSString
        let location = min(max(0, selection.location), string.length)
        let length = min(max(0, selection.length), string.length - location)
        let upperBound = location + length
        let normalizedLocation = normalizedOffset(location, in: string)
        let normalizedUpperBound = normalizedOffset(upperBound, in: string)
        return NSRange(
            location: normalizedLocation,
            length: max(0, normalizedUpperBound - normalizedLocation)
        )
    }

    private static func normalizedOffset(_ offset: Int, in text: NSString) -> Int {
        let prefix = text.substring(to: offset)
        let normalizedPrefix = normalizedSingleLineText(prefix)
        guard prefix.last?.isWhitespace == true,
              text.substring(from: offset).contains(where: { !$0.isWhitespace }),
              !normalizedPrefix.isEmpty else {
            return normalizedPrefix.utf16.count
        }
        return normalizedPrefix.utf16.count + 1
    }

    @MainActor
    final class SearchTextField: NSTextField {
        fileprivate var alternateSubmitModifier: NSEvent.ModifierFlags?
        fileprivate var onAlternateSubmit: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureSingleLineEditing()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureSingleLineEditing()
        }

        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            if let font {
                size.height = ceil(font.ascender - font.descender + font.leading)
            }
            return size
        }

        private func configureSingleLineEditing() {
            usesSingleLineMode = true
            maximumNumberOfLines = 1
            cell?.usesSingleLineMode = true
            cell?.wraps = false
            cell?.isScrollable = true
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if (currentEditor() as? NSTextView)?.hasMarkedText() != true,
               PluginPaletteSearchField.isAlternateSubmitKeyEquivalent(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                alternateSubmitModifier: alternateSubmitModifier
            ) {
                onAlternateSubmit?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private static let maximumFocusAttemptCount = 25
        private static let focusRetryDelay = Duration.milliseconds(20)

        var parent: CommandPaletteSearchField
        private var completedFocusRequestID: UInt?
        private var pendingFocusRequestID: UInt?
        private var focusTask: Task<Void, Never>?
        private var isNormalizingText = false
        private let focusClaim: @MainActor (NSTextField) -> Bool

        init(
            parent: CommandPaletteSearchField,
            focusClaim: (@MainActor (NSTextField) -> Bool)? = nil
        ) {
            self.parent = parent
            self.focusClaim = focusClaim ?? Self.claimFocus
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            guard !isNormalizingText else { return }
            let originalText = field.stringValue
            parent.onMarkedTextChange((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false)
            if parent.preservesText(originalText) {
                parent.text = originalText
                return
            }
            guard let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else {
                parent.text = originalText
                return
            }
            let normalizedText = CommandPaletteSearchField.normalizedSingleLineText(originalText)
            guard normalizedText != originalText else {
                parent.text = originalText
                return
            }

            let normalizedSelection = CommandPaletteSearchField.normalizedSelection(
                editor.selectedRange(),
                in: originalText
            )
            isNormalizingText = true
            field.stringValue = normalizedText
            editor.string = normalizedText
            editor.setSelectedRange(normalizedSelection)
            parent.text = normalizedText
            isNormalizingText = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if selector == #selector(NSResponder.insertTab(_:)), !textView.hasMarkedText(),
               modifiers.intersection([.shift, .command, .control, .option]).isEmpty,
               let completed = parent.completion(), let field = control as? NSTextField {
                field.stringValue = completed
                textView.string = completed
                textView.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
                parent.text = completed
                return true
            }
            guard let command = PluginPaletteSearchField.command(
                for: selector,
                hasMarkedText: textView.hasMarkedText(),
                modifierFlags: NSApp.currentEvent?.modifierFlags ?? [],
                alternateSubmitModifier: parent.alternateSubmitModifier
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

        private static func claimFocus(_ field: NSTextField) -> Bool {
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

