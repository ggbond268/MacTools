import AppKit
import SwiftUI

/// A multiline editor whose Return handling respects marked text and Shift-Return.
struct CommandPaletteMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onBack: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.delegate = context.coordinator
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandPaletteMessageEditor
        init(_ parent: CommandPaletteMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
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
