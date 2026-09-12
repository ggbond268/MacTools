import ApplicationServices
import Foundation
import MacToolsPluginKit

struct AccessibilitySelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .accessibility
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

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success,
              let focusedElementValue = focusedValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        let focusedElement = focusedElementValue as! AXUIElement
        let isEditable = isEditableTextElement(focusedElement)
        if let selectedText = stringAttribute(kAXSelectedTextAttribute, from: focusedElement),
           !selectedText.isEmpty {
            return SelectedTextCaptureResult(
                text: selectedText,
                strategyID: strategyID,
                isEditable: isEditable,
                sourceApplicationBundleID: context.frontmostApplicationBundleID,
                failureReason: nil
            )
        }

        if let selectedText = selectedTextFromValueAndRange(focusedElement),
           !selectedText.isEmpty {
            return SelectedTextCaptureResult(
                text: selectedText,
                strategyID: strategyID,
                isEditable: isEditable,
                sourceApplicationBundleID: context.frontmostApplicationBundleID,
                failureReason: nil
            )
        }

        return failure(
            context: context,
            reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
        )
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

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else {
            return false
        }

        return role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
    }

    private func selectedTextFromValueAndRange(_ element: AXUIElement) -> String? {
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

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
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
}
