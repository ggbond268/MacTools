import AppKit
import ApplicationServices
import Foundation

protocol DockApplicationHiding: AnyObject, Sendable {
    func hasVisibleWindow(for processIdentifier: pid_t) async -> Bool
    @MainActor
    @discardableResult
    func hideApplication(bundleIdentifier: String, processIdentifier: pid_t) -> Bool
}

final class DockApplicationHider: DockApplicationHiding {
    private static let messagingTimeout: Float = 0.2

    private let logger = DockClickLog.applicationHider
    private let accessibilityQueue = DispatchQueue(
        label: "cc.ggbond.mactools.dock-click-minimize.window-visibility"
    )
    private let currentProcessIdentifier: pid_t
    private let currentProcessVisibleWindowQuery: @MainActor @Sendable () -> Bool
    private let visibleWindowQuery: @Sendable (pid_t) -> Bool

    convenience init() {
        self.init(visibleWindowQuery: Self.hasVisibleWindowSynchronously)
    }

    init(
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        currentProcessVisibleWindowQuery: @escaping @MainActor @Sendable () -> Bool = DockApplicationHider.hasVisibleCurrentProcessWindow,
        visibleWindowQuery: @escaping @Sendable (pid_t) -> Bool
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.currentProcessVisibleWindowQuery = currentProcessVisibleWindowQuery
        self.visibleWindowQuery = visibleWindowQuery
    }

    func hasVisibleWindow(for processIdentifier: pid_t) async -> Bool {
        if processIdentifier == currentProcessIdentifier {
            return await currentProcessVisibleWindowQuery()
        }

        return await withCheckedContinuation { continuation in
            accessibilityQueue.async { [visibleWindowQuery] in
                continuation.resume(returning: visibleWindowQuery(processIdentifier))
            }
        }
    }

    @MainActor
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

    @MainActor
    private static func hasVisibleCurrentProcessWindow() -> Bool {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else {
            return false
        }
        return window.isVisible && !window.isMiniaturized
    }

    private static func hasVisibleWindowSynchronously(for processIdentifier: pid_t) -> Bool {
        guard let window = focusedWindow(for: processIdentifier),
              let isMinimized = attributeValue(kAXMinimizedAttribute, of: window) as? Bool
        else {
            return false
        }
        return !isMinimized
    }

    private static func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        // Some apps do not expose focusedWindow. Their main window is the narrowest safe fallback.
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = elementAttributeValue(attribute, of: application) {
                AXUIElementSetMessagingTimeout(window, messagingTimeout)
                return window
            }
        }
        return nil
    }

    private static func attributeValue(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elementAttributeValue(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(attribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
