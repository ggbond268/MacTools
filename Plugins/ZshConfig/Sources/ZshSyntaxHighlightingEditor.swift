import AppKit
import SwiftUI

// MARK: - ZshSyntaxHighlightingEditor

/// NSTextView-based code editor with zsh/shell syntax highlighting.
/// Supports comments, keywords, quoted strings, and variable references.
@MainActor
struct ZshSyntaxHighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// Called whenever the user edits the content (not on programmatic updates).
    var onChange: (() -> Void)? = nil
    /// Increment to trigger a one-shot scroll to the bottom of the document.
    var scrollToBottomID: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingHighlighting()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.typingAttributes = Self.baseAttributes

        if !text.isEmpty {
            textView.string = text
            Self.applyHighlighting(to: textView)
        }
        // Store the initial content so `updateNSView` can detect external resets.
        context.coordinator.lastTextFedToBinding = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        guard !context.coordinator.isHighlighting else { return }

        // Reset `textView.string` only when external input, such as loading a file or appending a
        // snippet, actually changed `text`. Do not compare `textView.string != text`: `@Published`
        // emits `objectWillChange` in `willSet`, so `updateNSView` can observe the old value and
        // incorrectly reset the editor, clearing the undo stack.
        if text != context.coordinator.lastTextFedToBinding {
            context.coordinator.cancelPendingHighlighting()
            context.coordinator.lastTextFedToBinding = text
            let sel = textView.selectedRange()
            textView.string = text
            Self.applyHighlighting(to: textView)
            let safeLocation = min(sel.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
        }
        textView.isEditable = isEditable
        if scrollToBottomID != context.coordinator.lastScrollToBottomID {
            context.coordinator.lastScrollToBottomID = scrollToBottomID
            textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Syntax Definitions

    private static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    private static let syntaxRules: [(NSRegularExpression, NSColor)] = {
        let defs: [(String, NSColor)] = [
            // Double-quoted strings
            (#""[^"\\]*(?:\\.[^"\\]*)*""#,           .systemOrange),
            // Single-quoted strings
            (#"'[^']*'"#,                             .systemOrange),
            // Variable references: $VAR or ${VAR}
            (#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#,    .systemTeal),
            // zsh/shell keywords and builtins
            (
                #"\b(alias|export|source|function|eval|if|then|else|elif|fi|for|in|do|done|while|until|case|esac|return|local|readonly|unset|typeset|setopt|unsetopt|autoload|bindkey|compinit|zle)\b"#,
                .systemBlue
            ),
        ]
        return defs.compactMap { pattern, color in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, color) }
        }
    }()

    private static let commentRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)

    static func applyHighlighting(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let string = textView.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let selectedRange = textView.selectedRange()
        let scrollView = textView.enclosingScrollView
        let scrollOrigin = scrollView?.contentView.bounds.origin

        // Syntax highlighting attributes must not enter the undo stack, or Cmd-Z would undo
        // highlighting instead of text edits.
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        storage.beginEditing()

        // Reset to base style
        storage.setAttributes(baseAttributes, range: fullRange)

        // Apply keyword / string / variable coloring
        for (regex, color) in syntaxRules {
            regex.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
                guard let r = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }

        // Comments override all other rules (applied last)
        commentRegex?.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
            guard let r = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
        }

        storage.endEditing()

        // Keep typing attributes consistent so new characters start with base style
        textView.typingAttributes = baseAttributes
        textView.setSelectedRange(selectedRange)
        if let scrollView, let scrollOrigin {
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        typealias Highlighter = @MainActor (NSTextView) -> Void

        static let highlightingDelay: TimeInterval = 0.1

        var parent: ZshSyntaxHighlightingEditor
        var isHighlighting = false
        var lastScrollToBottomID: Int = 0
        /// Last text pushed to the binding by `textDidChange`, used to distinguish user input from external assignment.
        var lastTextFedToBinding: String = ""
        private let highlightingDelay: TimeInterval
        private let highlighter: Highlighter
        private var pendingHighlightingWork: DispatchWorkItem?

        init(
            _ parent: ZshSyntaxHighlightingEditor,
            highlightingDelay: TimeInterval = Coordinator.highlightingDelay,
            highlighter: @escaping Highlighter = ZshSyntaxHighlightingEditor.applyHighlighting
        ) {
            self.parent = parent
            self.highlightingDelay = highlightingDelay
            self.highlighter = highlighter
        }

        func textDidChange(_ notification: Notification) {
            guard !isHighlighting, let textView = notification.object as? NSTextView else { return }
            lastTextFedToBinding = textView.string
            parent.text = textView.string
            parent.onChange?()

            scheduleHighlighting(for: textView)
        }

        func cancelPendingHighlighting() {
            pendingHighlightingWork?.cancel()
            pendingHighlightingWork = nil
        }

        private func scheduleHighlighting(for textView: NSTextView) {
            cancelPendingHighlighting()

            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingHighlightingWork = nil
                guard !textView.hasMarkedText() else { return }
                self.isHighlighting = true
                defer { self.isHighlighting = false }
                self.highlighter(textView)
            }
            pendingHighlightingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + highlightingDelay, execute: work)
        }
    }
}
