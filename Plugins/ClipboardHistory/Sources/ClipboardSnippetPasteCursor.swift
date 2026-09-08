import AppKit
import ApplicationServices

/// Best-effort caret positioning after panel paste. It never blocks or rewrites user input.
@MainActor
protocol ClipboardSnippetPasteCursorAccess: AnyObject {
    var ownsUnchangedFocus: Bool { get }
    var selection: CFRange? { get }
    func text(in range: CFRange) -> String?
    func move(to location: Int)
}

struct ClipboardSnippetPasteCursorContext {
    enum State { case pending, ready(Int), invalid }
    let initialSelection: CFRange
    let replacementLength: Int
    let offset: Int
    let prefix: String
    let suffix: String

    init?(selection: CFRange, expansion: ClipboardSnippetExpansion) {
        guard selection.location >= 0, selection.length >= 0,
              let offset = expansion.cursorUTF16OffsetFromEnd, offset > 0 else { return nil }
        self.initialSelection = selection
        replacementLength = expansion.text.utf16.count
        guard offset <= replacementLength, selection.location <= Int.max - replacementLength else { return nil }
        self.offset = offset
        prefix = String(expansion.text.prefix(32))
        suffix = String(expansion.text.suffix(32))
    }

    @MainActor func state(access: any ClipboardSnippetPasteCursorAccess) -> State {
        guard access.ownsUnchangedFocus, let selection = access.selection else { return .invalid }
        let end = initialSelection.location + replacementLength
        if selection.length == 0, selection.location == end,
           access.text(in: CFRange(location: initialSelection.location, length: prefix.utf16.count)) == prefix,
           access.text(in: CFRange(location: end - suffix.utf16.count, length: suffix.utf16.count)) == suffix {
            return .ready(end - offset)
        }
        // A lagging editor may still expose the original range. Any other range is
        // intervening input, not a reason to keep chasing the user's caret.
        return selection.location == initialSelection.location && selection.length == initialSelection.length
            ? .pending : .invalid
    }

    @MainActor func apply(
        access: any ClipboardSnippetPasteCursorAccess,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async {
        for _ in 0..<10 {
            guard !Task.isCancelled else { return }
            switch state(access: access) {
            case .ready(let location):
                guard !Task.isCancelled, access.ownsUnchangedFocus else { return }
                access.move(to: location)
                return
            case .invalid: return
            case .pending:
                do { try await pause() } catch { return }
            }
        }
    }
}

@MainActor
final class SystemClipboardSnippetPasteCursorAccess: ClipboardSnippetPasteCursorAccess {
    private let element: AXUIElement
    private let processIdentifier: pid_t
    private var interrupted = false
    private var monitors: [Any] = []

    init?(processIdentifier: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let element = ClipboardSnippetKeywordExpander.focusedElement(processIdentifier: processIdentifier),
              ClipboardSnippetKeywordExpander.secureTextClassification(element) == .nonSecure else { return nil }
        self.element = element
        self.processIdentifier = processIdentifier
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.observe(event)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.observe(event)
            return event
        }) { monitors.append(local) }
        // Without observation, fail closed instead of moving the caret after unknown input.
        interrupted = monitors.count != 2
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func observe(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                != SystemClipboardSnippetReplacementAccess.syntheticEventMarker else { return }
        interrupted = true
    }

    var ownsUnchangedFocus: Bool {
        guard !interrupted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let focused = ClipboardSnippetKeywordExpander.focusedElement(processIdentifier: processIdentifier),
              CFEqual(focused, element),
              ClipboardSnippetKeywordExpander.secureTextClassification(element) == .nonSecure else { return false }
        return true
    }

    var selection: CFRange? { ClipboardSnippetKeywordExpander.selectedTextRange(element) }

    func text(in range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                        parameter, &value) == .success else { return nil }
        // Do not fetch the entire editor value just to validate a short boundary.
        return value as? String
    }

    func move(to location: Int) {
        guard ownsUnchangedFocus else { return }
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }
}
