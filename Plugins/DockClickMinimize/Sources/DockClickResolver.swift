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

final class DockAccessibilityResolver: DockApplicationResolving {
    private static let dockBundleIdentifier = "com.apple.dock"
    private static let maximumParentDepth = 4

    private let bundleIdentifierForURL: (URL) -> String?
    private var cachedDockProcessIdentifier: pid_t?

    init(bundleIdentifierForURL: @escaping (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) {
        self.bundleIdentifierForURL = bundleIdentifierForURL
    }

    func resolveApplication(at location: CGPoint) -> DockApplicationTarget? {
        guard let element = accessibilityElement(at: location) else {
            return nil
        }

        guard let cachedOrResolvedDockProcessIdentifier = cachedDockProcessIdentifier ?? resolveDockProcessIdentifier() else {
            return nil
        }
        let hitProcessIdentifier = processIdentifier(of: element)
        let dockProcessIdentifier: pid_t
        if hitProcessIdentifier == cachedOrResolvedDockProcessIdentifier {
            dockProcessIdentifier = cachedOrResolvedDockProcessIdentifier
        } else {
            // A Dock restart changes its PID. Re-resolve only after the cached PID no longer matches.
            cachedDockProcessIdentifier = nil
            guard let refreshedDockProcessIdentifier = resolveDockProcessIdentifier(),
                  hitProcessIdentifier == refreshedDockProcessIdentifier
            else {
                return nil
            }
            dockProcessIdentifier = refreshedDockProcessIdentifier
        }
        return applicationTarget(from: element, dockProcessIdentifier: dockProcessIdentifier)
    }

    private func resolveDockProcessIdentifier() -> pid_t? {
        let processIdentifier = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first?
            .processIdentifier
        cachedDockProcessIdentifier = processIdentifier
        return processIdentifier
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

    private func accessibilityElement(at location: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(location.x),
            Float(location.y),
            &element
        )
        return result == .success ? element : nil
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
