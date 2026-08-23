import AppKit
import ApplicationServices
import Foundation

protocol DockApplicationHiding: AnyObject {
    func hasVisibleWindow(for processIdentifier: pid_t) -> Bool
    @discardableResult
    func hideApplication(bundleIdentifier: String, processIdentifier: pid_t) -> Bool
}

final class DockApplicationHider: DockApplicationHiding {
    private let logger = DockClickLog.applicationHider

    func hasVisibleWindow(for processIdentifier: pid_t) -> Bool {
        guard let window = focusedWindow(for: processIdentifier),
              let isMinimized = attributeValue(kAXMinimizedAttribute, of: window) as? Bool
        else {
            return false
        }
        return !isMinimized
    }

    func hideApplication(bundleIdentifier: String, processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier == processIdentifier })
        else {
            logger.error("Dock target application exited before it could be hidden")
            return false
        }
        guard application.hide() else {
            logger.error("Failed to hide Dock target application")
            return false
        }
        return true
    }

    private func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        // Some apps do not expose focusedWindow. Their main window is the narrowest safe fallback.
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = elementAttributeValue(attribute, of: application) {
                return window
            }
        }
        return nil
    }

    private func attributeValue(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func elementAttributeValue(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(attribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
