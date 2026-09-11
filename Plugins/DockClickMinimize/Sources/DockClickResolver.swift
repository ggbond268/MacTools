import AppKit
import ApplicationServices
import Foundation

struct DockApplicationTarget: Equatable, Sendable {
    let bundleIdentifier: String
}

struct DockItemSnapshot: Equatable {
    let processIdentifier: pid_t
    let role: String?
    let subrole: String?
    let url: URL?
}

protocol DockApplicationResolving: AnyObject {
    func resolveApplication(at location: CGPoint) -> DockApplicationTarget?
}

enum DockClickResolver {
    static let dockItemRole = "AXDockItem"
    static let applicationDockItemSubrole = "AXApplicationDockItem"

    static func applicationTarget(
        from snapshot: DockItemSnapshot,
        dockProcessIdentifier: pid_t,
        bundleIdentifierForURL: (URL) -> String?
    ) -> DockApplicationTarget? {
        guard snapshot.processIdentifier == dockProcessIdentifier,
              snapshot.role == dockItemRole,
              snapshot.subrole == applicationDockItemSubrole,
              let url = snapshot.url,
              let bundleIdentifier = bundleIdentifierForURL(url)
        else {
            return nil
        }
        return DockApplicationTarget(bundleIdentifier: bundleIdentifier)
    }
}

// Accessibility resolution is confined to DockClickMonitor's serial queue; the process cache is locked for lifecycle notifications.
final class DockAccessibilityResolver: DockApplicationResolving, @unchecked Sendable {
    private final class DockProcessCache {
        private let lock = NSLock()
        private var processIdentifier: pid_t?

        func cachedOrResolve(_ resolve: () -> pid_t?) -> pid_t? {
            lock.lock()
            defer { lock.unlock() }
            if let processIdentifier {
                return processIdentifier
            }
            let resolvedProcessIdentifier = resolve()
            processIdentifier = resolvedProcessIdentifier
            return resolvedProcessIdentifier
        }

        func invalidate() {
            lock.lock()
            processIdentifier = nil
            lock.unlock()
        }
    }

    private static let dockBundleIdentifier = "com.apple.dock"
    private static let maximumParentDepth = 4
    private static let messagingTimeout: Float = 0.2

    private let bundleIdentifierForURL: (URL) -> String?
    private let dockProcessIdentifierProvider: () -> pid_t?
    private let accessibilityElementAtPosition: (pid_t, CGPoint) -> AXUIElement?
    private let dockProcessCache = DockProcessCache()
    private let workspaceNotificationCenter: NotificationCenter
    private var dockLifecycleObservers: [NSObjectProtocol] = []

    init(
        bundleIdentifierForURL: @escaping (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        dockProcessIdentifierProvider: @escaping () -> pid_t? = DockAccessibilityResolver.resolveDockProcessIdentifier,
        accessibilityElementAtPosition: @escaping (pid_t, CGPoint) -> AXUIElement? = DockAccessibilityResolver.accessibilityElement
    ) {
        self.bundleIdentifierForURL = bundleIdentifierForURL
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.dockProcessIdentifierProvider = dockProcessIdentifierProvider
        self.accessibilityElementAtPosition = accessibilityElementAtPosition
        observeDockLifecycle()
    }

    deinit {
        dockLifecycleObservers.forEach(workspaceNotificationCenter.removeObserver)
    }

    func resolveApplication(at location: CGPoint) -> DockApplicationTarget? {
        guard let dockProcessIdentifier = dockProcessCache.cachedOrResolve(dockProcessIdentifierProvider),
              let element = accessibilityElementAtPosition(dockProcessIdentifier, location)
        else {
            return nil
        }
        guard processIdentifier(of: element) == dockProcessIdentifier else {
            return nil
        }
        return applicationTarget(from: element, dockProcessIdentifier: dockProcessIdentifier)
    }

    private static func resolveDockProcessIdentifier() -> pid_t? {
        let processIdentifier = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first?
            .processIdentifier
        return processIdentifier
    }

    private func observeDockLifecycle() {
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == Self.dockBundleIdentifier
                else {
                    return
                }
                self?.dockProcessCache.invalidate()
            }
            dockLifecycleObservers.append(observer)
        }
    }

    private func applicationTarget(
        from element: AXUIElement,
        dockProcessIdentifier: pid_t
    ) -> DockApplicationTarget? {
        var currentElement: AXUIElement? = element
        for _ in 0..<Self.maximumParentDepth {
            guard let resolvedElement = currentElement else {
                return nil
            }
            AXUIElementSetMessagingTimeout(resolvedElement, Self.messagingTimeout)
            if let target = DockClickResolver.applicationTarget(
                from: snapshot(of: resolvedElement),
                dockProcessIdentifier: dockProcessIdentifier,
                bundleIdentifierForURL: bundleIdentifierForURL
            ) {
                return target
            }
            currentElement = elementAttributeValue(kAXParentAttribute, of: resolvedElement)
        }
        return nil
    }

    private static func accessibilityElement(
        dockProcessIdentifier: pid_t,
        location: CGPoint
    ) -> AXUIElement? {
        let dockApplication = AXUIElementCreateApplication(dockProcessIdentifier)
        AXUIElementSetMessagingTimeout(dockApplication, messagingTimeout)

        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            dockApplication,
            Float(location.x),
            Float(location.y),
            &element
        )
        guard result == .success, let element else {
            return nil
        }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private func snapshot(of element: AXUIElement) -> DockItemSnapshot {
        return DockItemSnapshot(
            processIdentifier: processIdentifier(of: element),
            role: attributeValue(kAXRoleAttribute, of: element) as? String,
            subrole: attributeValue(kAXSubroleAttribute, of: element) as? String,
            url: attributeValue(kAXURLAttribute, of: element) as? URL
        )
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return processIdentifier
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
