import ApplicationServices
import Foundation
import MacToolsPluginKit

/// Outcome of one synchronous Accessibility probe. Sendable so it can cross
/// from a detached probe task back to the main actor.
struct AXProbeOutcome: Sendable {
    let text: String?
    let isEditable: Bool
}

struct AccessibilitySelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .accessibility

    /// Upper bound for one AX probe. AXUIElementCopyAttributeValue can block
    /// for a long time on a misbehaving target app, so the capture path fails
    /// fast with a timeout instead of hanging the caller.
    private static let probeTimeout: TimeInterval = 1.0

    /// Per-element AX messaging timeout applied to every element this probe
    /// creates, so a blocked AX call self-terminates natively instead of being
    /// abandoned behind the watchdog. Kept below `probeTimeout` so the
    /// watchdog stays the outer bound. Only per-element timeouts are used:
    /// setting the timeout on the system-wide element would make it the
    /// process-wide default and also bound other plugins' AX calls.
    private nonisolated static let axMessagingTimeout: Float = 0.8

    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        guard AccessibilityCheck.isTrusted() else {
            return failure(
                context: context,
                reason: localization.string("capture.error.permissionRequired", defaultValue: "需要辅助功能授权")
            )
        }

        let outcome: AXProbeOutcome
        do {
            outcome = try await probeSelectionWithTimeout(context)
        } catch {
            return failure(
                context: context,
                reason: localization.string("capture.error.axTimeout", defaultValue: "辅助功能取词超时")
            )
        }

        guard let selectedText = outcome.text, !selectedText.isEmpty else {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        return SelectedTextCaptureResult(
            text: selectedText,
            strategyID: strategyID,
            isEditable: outcome.isEditable,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: nil
        )
    }

    /// Runs the synchronous AX probe off the main actor and bounds it with a
    /// timeout watchdog. The continuation box guarantees exactly one resume,
    /// whether the probe finishes first or the watchdog fires first.
    private func probeSelectionWithTimeout(_ context: SelectedTextCaptureContext) async throws -> AXProbeOutcome {
        let timeoutNanoseconds = Self.timeoutNanoseconds(for: Self.probeTimeout)

        return try await withCheckedThrowingContinuation { continuation in
            let box = AXProbeContinuationBox()
            let probe = Task.detached(priority: .userInitiated) {
                let outcome = Self.probeSelection(context: context)
                box.resume(continuation, returning: outcome)
            }

            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                // Abandon the probe; its late result is dropped by the box.
                probe.cancel()
                box.resume(continuation, throwing: AXProbeError.timeout)
            }
        }
    }

    /// Synchronous Accessibility probe. Must stay off the main actor because
    /// every AXUIElementCopyAttributeValue call below can block.
    nonisolated static func probeSelection(context: SelectedTextCaptureContext) -> AXProbeOutcome {
        if Task.isCancelled {
            return AXProbeOutcome(text: nil, isEditable: false)
        }

        guard let focusedElement = findFocusedElement(context: context) else {
            return AXProbeOutcome(text: nil, isEditable: false)
        }

        if Task.isCancelled {
            return AXProbeOutcome(text: nil, isEditable: false)
        }

        let isEditable = isEditableTextElement(focusedElement)

        if let selectedText = stringAttribute(kAXSelectedTextAttribute, from: focusedElement),
           !selectedText.isEmpty {
            return AXProbeOutcome(text: selectedText, isEditable: isEditable)
        }

        if Task.isCancelled {
            return AXProbeOutcome(text: nil, isEditable: false)
        }

        if let selectedText = selectedTextFromValueAndRange(focusedElement),
           !selectedText.isEmpty {
            return AXProbeOutcome(text: selectedText, isEditable: isEditable)
        }

        // If the focused element does not expose selected text, query the
        // frontmost app's top-level element directly.
        if let pid = context.frontmostApplicationProcessIdentifier {
            if Task.isCancelled {
                return AXProbeOutcome(text: nil, isEditable: false)
            }
            let appElement = AXUIElementCreateApplication(pid)
            setMessagingTimeout(appElement)
            if let selectedText = stringAttribute(kAXSelectedTextAttribute, from: appElement),
               !selectedText.isEmpty {
                return AXProbeOutcome(text: selectedText, isEditable: isEditable)
            }
        }

        return AXProbeOutcome(text: nil, isEditable: false)
    }

    // Pure AX C-API helpers below are `nonisolated`: the struct inherits main
    // actor isolation from the @MainActor SelectedTextCapturing protocol, but
    // these probes must run on the detached probe task instead.

    nonisolated private static func timeoutNanoseconds(for timeout: TimeInterval) -> UInt64 {
        UInt64(max(timeout, 0) * 1_000_000_000)
    }

    nonisolated private static func findFocusedElement(context: SelectedTextCaptureContext) -> AXUIElement? {
        if let pid = context.frontmostApplicationProcessIdentifier {
            let appElement = AXUIElementCreateApplication(pid)
            setMessagingTimeout(appElement)
            var appFocusedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocusedValue) == .success,
               let element = appFocusedValue,
               CFGetTypeID(element) == AXUIElementGetTypeID() {
                let focusedElement = (element as! AXUIElement)
                setMessagingTimeout(focusedElement)
                return focusedElement
            }
        }
        // A system-wide query cannot be bounded without changing the AX
        // timeout for this entire process. Let the next capture strategy try.
        return nil
    }

    /// Applies the native per-element messaging timeout so a blocked AX call
    /// returns an error instead of hanging the probe.
    nonisolated private static func setMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    nonisolated private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    nonisolated private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else {
            return false
        }

        return role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
    }

    nonisolated private static func selectedTextFromValueAndRange(_ element: AXUIElement) -> String? {
        guard let value = stringAttribute(kAXValueAttribute, from: element),
              let selectedRange = selectedTextRange(from: element),
              selectedRange.length > 0 else {
            return nil
        }

        return Self.substring(in: value, utf16Range: selectedRange)
    }

    nonisolated static func substring(in value: String, utf16Range selectedRange: CFRange) -> String? {
        let utf16View = value.utf16
        let location = selectedRange.location
        let length = selectedRange.length

        guard location >= 0,
              length > 0,
              location <= utf16View.count,
              length <= utf16View.count - location else {
            return nil
        }

        let upperOffset = location + length
        let utf16Lower = utf16View.index(utf16View.startIndex, offsetBy: location)
        let utf16Upper = utf16View.index(utf16View.startIndex, offsetBy: upperOffset)

        guard let lower = String.Index(utf16Lower, within: value),
              let upper = String.Index(utf16Upper, within: value) else {
            return nil
        }

        return String(value[lower..<upper])
    }

    nonisolated private static func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let typedValue = axValue as! AXValue
        guard AXValueGetType(typedValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(typedValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    private func failure(context: SelectedTextCaptureContext, reason: String) -> SelectedTextCaptureResult {
        SelectedTextCaptureResult(
            text: nil,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: reason
        )
    }
}

private enum AXProbeError: Error {
    case timeout
}

/// NSLock + didResume guard so only the first resume (probe result or
/// timeout) wins; the loser is silently dropped.
private final class AXProbeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume<T>(_ continuation: CheckedContinuation<T, any Error>, returning value: sending T) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }

    func resume<T>(_ continuation: CheckedContinuation<T, any Error>, throwing error: any Error) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
}
