import AppKit
import SwiftUI

/// A multiline editor whose Return handling respects marked text and Shift-Return.
struct CommandPaletteMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onBack: () -> Void
    let onCompositionChange: (Bool) -> Void

    init(
        text: Binding<String>, onSubmit: @escaping () -> Void, onBack: @escaping () -> Void,
        onCompositionChange: @escaping (Bool) -> Void = { _ in }
    ) {
        _text = text
        self.onSubmit = onSubmit
        self.onBack = onBack
        self.onCompositionChange = onCompositionChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CompositionTextView.scrollableTextView()
        let editor = scroll.documentView as! CompositionTextView
        editor.isRichText = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.delegate = context.coordinator
        editor.onInputStateChange = { [weak coordinator = context.coordinator] editor in
            coordinator?.inputStateDidChange(editor)
        }
        editor.setAccessibilityIdentifier("mactools.action-input.message")
        editor.setAccessibilityLabel(FeatureL10n.string("消息"))
        editor.string = text
        DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }
            editor.window?.makeFirstResponder(editor)
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? NSTextView, !editor.hasMarkedText() else { return }
        if editor.string != text { editor.string = text }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        guard let editor = view.documentView as? CompositionTextView else { return }
        editor.onInputStateChange = nil
        editor.delegate = nil
    }

    /// IME operations can change marked text without posting textDidChange.
    @MainActor
    final class CompositionTextView: NSTextView {
        var onInputStateChange: ((CompositionTextView) -> Void)?
        private var inputOperationDepth = 0

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            inputOperationDepth += 1
            defer { finishInputOperation() }
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }

        override func unmarkText() {
            inputOperationDepth += 1
            defer { finishInputOperation() }
            super.unmarkText()
        }

        override func insertText(_ insertString: Any, replacementRange: NSRange) {
            inputOperationDepth += 1
            defer { finishInputOperation() }
            super.insertText(insertString, replacementRange: replacementRange)
        }

        var isPerformingInputOperation: Bool { inputOperationDepth > 0 }

        private func finishInputOperation() {
            inputOperationDepth -= 1
            if inputOperationDepth == 0 { onInputStateChange?(self) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandPaletteMessageEditor
        private var hasMarkedText = false
        init(_ parent: CommandPaletteMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            guard (view as? CompositionTextView)?.isPerformingInputOperation != true else { return }
            inputStateDidChange(view)
        }
        func inputStateDidChange(_ view: NSTextView) {
            let marked = view.hasMarkedText()
            // Disable submission before publishing preedit text; enable it only after the committed text is current.
            if marked { updateComposition(true) }
            if parent.text != view.string { parent.text = view.string }
            if !marked { updateComposition(false) }
        }
        private func updateComposition(_ marked: Bool) {
            guard hasMarkedText != marked else { return }
            hasMarkedText = marked
            parent.onCompositionChange(marked)
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onBack(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)),
               !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
