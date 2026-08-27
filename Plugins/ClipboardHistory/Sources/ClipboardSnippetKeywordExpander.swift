@preconcurrency import ApplicationServices
import AppKit
import Foundation

struct ClipboardSnippetKeywordMatch: Equatable, Sendable {
    let itemID: UUID
    let keyword: String
    let delimiter: String

    var requiresPostDeliveryExpansion: Bool { delimiter.isEmpty }
}

struct ClipboardSnippetReplacementContext: Equatable, Sendable {
    let selectionLocation: Int
    let selectionLength: Int
    let keywordLocation: Int
    let keywordLength: Int
    let keyword: String

    func isValid(selection: CFRange, keywordText: String?) -> Bool {
        selection.location == selectionLocation
            && selection.length == selectionLength
            && keywordText == keyword
    }
}

enum ClipboardSnippetExpansionOutcome: Equatable, Sendable {
    case succeeded
    case safelyRejectedBeforeMutation
    case consumedAfterMutation
}

/// Ephemeral, content-free diagnostics. Never persist typed characters or editor contents.
enum ClipboardSnippetExpansionDiagnostic: Equatable, Sendable {
    case listening
    case receivingTyping
    case expanded
    case unsupportedEditor
    case focusUnavailable
    case focusOwnershipUnverified
    case selectionUnavailable
    case contextChanged
    case templateUnavailable
    case replacementUnavailable
}

/// The event tap must return before querying an editor through Accessibility. A
/// generation prevents delayed work from modifying text after another input event.
@MainActor
final class ClipboardSnippetExpansionScheduler {
    private var task: Task<Void, Never>?
    private var generation = 0

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func schedule(attempt: @escaping @MainActor () -> ClipboardSnippetExpansionOutcome) {
        cancel()
        let expectedGeneration = generation
        task = Task { @MainActor [weak self] in
            for delay in [10_000_000, 20_000_000, 40_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                      self.generation == expectedGeneration else { return }
                if attempt() != .safelyRejectedBeforeMutation {
                    if self.generation == expectedGeneration { self.task = nil }
                    return
                }
            }
            guard let self, self.generation == expectedGeneration else { return }
            self.task = nil
        }
    }
}

enum ClipboardSnippetMatchedEventPolicy {
    static func suppressesOriginalDelimiter(outcome: ClipboardSnippetExpansionOutcome) -> Bool {
        // Replaying is safe only when the original focus, selection, and keyword were
        // revalidated and no Accessibility mutation succeeded.
        outcome != .safelyRejectedBeforeMutation
    }
}

enum ClipboardSnippetSecureTextClassification: Equatable, Sendable {
    case secure
    case nonSecure
    case unknown
}

enum ClipboardSnippetTextElementClassification {
    static func classify(role: String?, subrole: String?) -> ClipboardSnippetSecureTextClassification {
        if subrole == "AXSecureTextField" {
            return .secure
        }
        guard let role else { return .unknown }
        let supportedRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        return supportedRoles.contains(role) ? .nonSecure : .unknown
    }
}

struct ClipboardSnippetKeywordMatcher: Sendable {
    private(set) var buffer = ""
    var snippetsByKeyword: [String: UUID] = [:]

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func consume(
        text: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> ClipboardSnippetKeywordMatch? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            reset()
            return nil
        }
        if keyCode == 51 {
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        }
        guard !text.isEmpty else {
            reset()
            return nil
        }
        guard text.allSatisfy(Self.isDelimiter) else {
            buffer.append(contentsOf: text)
            if buffer.count > ClipboardSavedItem.maximumKeywordCharacterCount {
                buffer = String(buffer.suffix(ClipboardSavedItem.maximumKeywordCharacterCount))
            }
            if let keyword = exactUnambiguousKeywordMatch(in: buffer),
               let itemID = snippetsByKeyword[keyword] {
                reset()
                return ClipboardSnippetKeywordMatch(
                    itemID: itemID,
                    keyword: keyword,
                    delimiter: ""
                )
            }
            return nil
        }

        if let keyword = snippetsByKeyword.keys
            .filter({ buffer.hasSuffix($0) })
            .sorted(by: { $0.count > $1.count })
            .first,
            Self.isBoundaryMatch(keyword: keyword, in: buffer),
           let itemID = snippetsByKeyword[keyword] {
            reset()
            return ClipboardSnippetKeywordMatch(itemID: itemID, keyword: keyword, delimiter: text)
        }

        let candidate = buffer + text
        if snippetsByKeyword.keys.contains(where: { keyword in
            keyword.hasPrefix(candidate) || candidate.hasSuffix(String(keyword.prefix(candidate.count)))
        }) {
            buffer = String(candidate.suffix(ClipboardSavedItem.maximumKeywordCharacterCount))
        } else {
            reset()
        }
        return nil
    }

    private static func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation
    }

    private static func isBoundaryMatch(keyword: String, in buffer: String) -> Bool {
        guard buffer.count > keyword.count else { return buffer == keyword }
        let boundary = buffer.index(buffer.endIndex, offsetBy: -keyword.count)
        let previous = buffer.index(before: boundary)
        return isDelimiter(buffer[previous])
    }

    private func exactUnambiguousKeywordMatch(in buffer: String) -> String? {
        let matches = snippetsByKeyword.keys.filter { keyword in
            buffer.hasSuffix(keyword) && Self.isBoundaryMatch(keyword: keyword, in: buffer)
        }
        guard let exact = matches.max(by: { $0.count < $1.count }) else { return nil }
        let identity = exact.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let hasLongerCandidate = snippetsByKeyword.keys.contains { keyword in
            guard keyword.count > exact.count else { return false }
            return keyword.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ).hasPrefix(identity)
        }
        return hasLongerCandidate ? nil : exact
    }
}

@MainActor
final class ClipboardSnippetKeywordExpander {
    var onDiagnostic: ((ClipboardSnippetExpansionDiagnostic) -> Void)?
    private let savedLibraryController: ClipboardSavedLibraryController
    private let pasteboard: any ClipboardPasteboardAccess
    private let onPasteboardWrite: () -> Void
    private var replacementTask: Task<Void, Never>?
    private var matcher = ClipboardSnippetKeywordMatcher()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trackedElement: AXUIElement?
    private let expansionScheduler = ClipboardSnippetExpansionScheduler()
    private var hasReceivedTyping = false

    init(
        savedLibraryController: ClipboardSavedLibraryController,
        pasteboard: any ClipboardPasteboardAccess,
        onPasteboardWrite: @escaping () -> Void = {}
    ) {
        self.savedLibraryController = savedLibraryController
        self.pasteboard = pasteboard
        self.onPasteboardWrite = onPasteboardWrite
    }

    var isRunning: Bool { eventTap != nil }
    var hasConfiguredKeywords: Bool { !matcher.snippetsByKeyword.isEmpty }

    func updateItems() {
        matcher.snippetsByKeyword = Dictionary(
            savedLibraryController.items.compactMap { item in
                guard item.isSnippet, let keyword = item.keyword else { return nil }
                return (keyword, item.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        if matcher.snippetsByKeyword.isEmpty {
            stop()
        }
    }

    @discardableResult
    func start() -> Bool {
        updateItems()
        guard hasConfiguredKeywords else { return false }
        guard eventTap == nil else { return true }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        hasReceivedTyping = false
        onDiagnostic?(.listening)
        return true
    }

    func stop() {
        replacementTask?.cancel()
        expansionScheduler.cancel()
        matcher.reset()
        trackedElement = nil
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
    }

    private nonisolated static let eventCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let expander = Unmanaged<ClipboardSnippetKeywordExpander>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return MainActor.assumeIsolated {
            expander.handle(type: type, event: event)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == SystemClipboardSnippetReplacementAccess.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        replacementTask?.cancel()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            expansionScheduler.cancel()
            resetTracking()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Subsequent typing, navigation, or a click invalidates any pending match.
        expansionScheduler.cancel()
        guard type == .keyDown else {
            resetTracking()
            return Unmanaged.passUnretained(event)
        }
        if !hasReceivedTyping {
            hasReceivedTyping = true
            onDiagnostic?(.receivingTyping)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let text = Self.unicodeString(from: event)
        guard let match = matcher.consume(
            text: text,
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        ) else {
            return Unmanaged.passUnretained(event)
        }

        if match.requiresPostDeliveryExpansion {
            guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                onDiagnostic?(.focusUnavailable)
                resetTracking()
                return Unmanaged.passUnretained(event)
            }
            schedulePostDeliveryExpansion(match, processIdentifier: processIdentifier)
            // The final keyword character has not reached the target editor yet. Let this
            // key event through, then validate and replace the complete keyword once the
            // editor's Accessibility value and selection catch up.
            return Unmanaged.passUnretained(event)
        }

        let outcome = attemptExpansion(match)
        return ClipboardSnippetMatchedEventPolicy.suppressesOriginalDelimiter(
            outcome: outcome
        ) ? nil : Unmanaged.passUnretained(event)
    }

    private func schedulePostDeliveryExpansion(
        _ match: ClipboardSnippetKeywordMatch,
        processIdentifier: pid_t
    ) {
        var expectedElement: AXUIElement?
        var didRequestManualAccessibility = false
        var focusFailure = ClipboardSnippetFocusFailure.unavailable
        expansionScheduler.schedule { [weak self] in
            guard let self else { return .consumedAfterMutation }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                onDiagnostic?(.contextChanged)
                return .consumedAfterMutation
            }
            if expectedElement == nil {
                expectedElement = Self.focusedElement(
                    processIdentifier: processIdentifier,
                    requestManualAccessibilityIfNeeded: !didRequestManualAccessibility,
                    onFailure: { focusFailure = $0 }
                )
                didRequestManualAccessibility = true
            }
            guard let expectedElement else {
                onDiagnostic?(focusFailure == .ownershipUnverified ? .focusOwnershipUnverified : .focusUnavailable)
                return .safelyRejectedBeforeMutation
            }
            return attemptExpansion(match, expectedElement: expectedElement)
        }
    }

    private func attemptExpansion(
        _ match: ClipboardSnippetKeywordMatch,
        expectedElement: AXUIElement? = nil
    ) -> ClipboardSnippetExpansionOutcome {

        // Accessibility calls are comparatively expensive and can make normal typing
        // feel sluggish. Defer them until the in-memory matcher finds a keyword. The
        // focused element and exact text range are still revalidated before mutation,
        // so switching fields cannot expand stale buffered text.
        guard let focusedElement = Self.focusedElement() else {
            onDiagnostic?(.focusUnavailable)
            resetTracking()
            return .safelyRejectedBeforeMutation
        }
        guard expectedElement.map({ Self.isSameElement(focusedElement, $0) }) ?? true,
              Self.secureTextClassification(focusedElement) == .nonSecure else {
            onDiagnostic?(.unsupportedEditor)
            resetTracking()
            return .safelyRejectedBeforeMutation
        }
        guard let selectedRange = Self.selectedTextRange(focusedElement) else {
            onDiagnostic?(.selectionUnavailable)
            resetTracking()
            return .safelyRejectedBeforeMutation
        }
        trackedElement = focusedElement

        let keywordUTF16Count = match.keyword.utf16.count
        guard selectedRange.length == 0,
              selectedRange.location >= keywordUTF16Count else {
            onDiagnostic?(.contextChanged)
            resetTracking()
            return .safelyRejectedBeforeMutation
        }
        let keywordRange = CFRange(
            location: selectedRange.location - keywordUTF16Count,
            length: keywordUTF16Count
        )
        let replacementContext = ClipboardSnippetReplacementContext(
            selectionLocation: selectedRange.location,
            selectionLength: selectedRange.length,
            keywordLocation: keywordRange.location,
            keywordLength: keywordRange.length,
            keyword: match.keyword
        )
        guard replacementContext.isValid(
            selection: selectedRange,
            keywordText: Self.string(in: keywordRange, of: focusedElement)
        ) else {
            onDiagnostic?(.contextChanged)
            resetTracking()
            return .safelyRejectedBeforeMutation
        }

        return expand(
            match,
            expectedElement: focusedElement,
            replacementContext: replacementContext
        )
    }

    private func expand(
        _ match: ClipboardSnippetKeywordMatch,
        expectedElement: AXUIElement,
        replacementContext: ClipboardSnippetReplacementContext
    ) -> ClipboardSnippetExpansionOutcome {
        let keywordRange = CFRange(
            location: replacementContext.keywordLocation,
            length: replacementContext.keywordLength
        )
        guard savedLibraryController.items.contains(where: { $0.id == match.itemID }),
              let template = savedLibraryController.templateForKeywordExpansion(id: match.itemID) else {
            onDiagnostic?(.templateUnavailable)
            return .safelyRejectedBeforeMutation
        }
        guard let focusedElement = Self.focusedElement(),
              Self.isSameElement(focusedElement, expectedElement),
              Self.secureTextClassification(focusedElement) == .nonSecure,
              let selectedRange = Self.selectedTextRange(focusedElement),
              replacementContext.isValid(
                  selection: selectedRange,
                  keywordText: Self.string(in: keywordRange, of: focusedElement)
              ),
              let expansion = try? ClipboardSnippetTemplateEngine.expand(
                  template,
                  context: .current(clipboardText: pasteboard.readPlainText())
              ) else {
            onDiagnostic?(.contextChanged)
            resetTracking()
            return .safelyRejectedBeforeMutation
        }

        var mutableKeywordRange = keywordRange
        guard let keywordRangeValue = AXValueCreate(.cfRange, &mutableKeywordRange),
              AXUIElementSetAttributeValue(
                  focusedElement,
                  kAXSelectedTextRangeAttribute as CFString,
                  keywordRangeValue
              ) == .success else {
            onDiagnostic?(.replacementUnavailable)
            let canReplay = Self.revalidatesOriginalContext(
                expectedElement: expectedElement,
                replacementContext: replacementContext
            )
            resetTracking()
            return canReplay ? .safelyRejectedBeforeMutation : .consumedAfterMutation
        }

        var cursorLocation: Int?
        if let offset = expansion.cursorOffsetFromEnd,
           let characterIndex = expansion.text.index(
               expansion.text.endIndex,
               offsetBy: -offset,
               limitedBy: expansion.text.startIndex
           ) {
            let prefixUTF16Count = expansion.text[..<characterIndex].utf16.count
            cursorLocation = keywordRange.location + prefixUTF16Count
        }
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return .consumedAfterMutation
        }
        let access = SystemClipboardSnippetReplacementAccess(
            element: focusedElement, processIdentifier: processIdentifier, context: replacementContext,
            replacement: expansion.text + match.delimiter, cursorLocation: cursorLocation,
            onPasteboardWrite: onPasteboardWrite
        )
        replacementTask?.cancel()
        let previousTask = replacementTask
        replacementTask = Task { @MainActor [weak self] in
            // Finish restoration of any earlier temporary pasteboard before starting another.
            await previousTask?.value
            guard !Task.isCancelled else { return }
            let succeeded = await ClipboardSnippetTextReplacement.perform(using: access)
            guard !Task.isCancelled else { return }
            self?.onDiagnostic?(succeeded ? .expanded : .replacementUnavailable)
        }
        resetTracking()
        return .consumedAfterMutation
    }

    private func resetTracking() {
        matcher.reset()
        trackedElement = nil
    }

    static func focusedElement(
        processIdentifier: pid_t? = nil,
        requestManualAccessibilityIfNeeded: Bool = false,
        onFailure: (ClipboardSnippetFocusFailure) -> Void = { _ in }
    ) -> AXUIElement? {
        guard let processIdentifier = processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return ClipboardSnippetFocusResolver(access: SystemClipboardSnippetFocusAccess()).resolve(
            processIdentifier: processIdentifier,
            requestManualAccessibilityIfNeeded: requestManualAccessibilityIfNeeded,
            onFailure: onFailure
        )
    }

    static func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func string(in range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success,
           let string = value as? String {
            return string
        }
        value = nil
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success,
        let fullText = value as? String,
        range.location >= 0,
        range.length >= 0,
        range.location + range.length <= (fullText as NSString).length else {
            return nil
        }
        return (fullText as NSString).substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }

    private static func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    static func secureTextClassification(
        _ element: AXUIElement
    ) -> ClipboardSnippetSecureTextClassification {
        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success ? roleValue as? String : nil
        var value: CFTypeRef?
        let subrole = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success ? value as? String : nil
        return ClipboardSnippetTextElementClassification.classify(
            role: role,
            subrole: subrole
        )
    }

    private static func revalidatesOriginalContext(
        expectedElement: AXUIElement,
        replacementContext: ClipboardSnippetReplacementContext
    ) -> Bool {
        let keywordRange = CFRange(
            location: replacementContext.keywordLocation,
            length: replacementContext.keywordLength
        )
        guard let focusedElement = focusedElement(),
              isSameElement(focusedElement, expectedElement),
              secureTextClassification(focusedElement) == .nonSecure,
              let selectedRange = selectedTextRange(focusedElement) else {
            return false
        }
        return replacementContext.isValid(
            selection: selectedRange,
            keywordText: string(in: keywordRange, of: focusedElement)
        )
    }

    private static func unicodeString(from event: CGEvent) -> String {
        var count = 0
        event.keyboardGetUnicodeString(
            maxStringLength: 0,
            actualStringLength: &count,
            unicodeString: nil
        )
        guard count > 0 else { return "" }
        var characters = [UniChar](repeating: 0, count: count)
        event.keyboardGetUnicodeString(
            maxStringLength: count,
            actualStringLength: &count,
            unicodeString: &characters
        )
        return String(utf16CodeUnits: characters, count: count)
    }

}
