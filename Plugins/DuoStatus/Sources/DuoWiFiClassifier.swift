import Foundation
import SystemConfiguration

// Adapted from Status Trio (https://github.com/lingyired/status-trio, Apache-2.0).

/// The precise Wi-Fi situation the classifier can recognise, before the renderer
/// decides whether the user asked to distinguish it.
enum DuoWiFiClassification: Equatable, Sendable {
    case off
    case notAssociated
    case shared
    case temporary
    case hotspot
    case noInternet
    case connected
}

/// Maps CoreWLAN interface flags plus the current network path to a Wi-Fi state.
/// Precedence matches the upstream classifier: off, notAssociated, shared,
/// temporary, hotspot, noInternet, connected.
///
/// The classifier always produces the precise state. Collapsing a precise state
/// back to the plain Wi-Fi glyph when its option is off is the renderer's job,
/// so the tooltip stays accurate even when the glyph is generic.
enum DuoWiFiClassifier {
    /// - Parameters:
    ///   - serviceActive: whether the interface is associated with a network.
    ///   - pathSatisfied: `nil` when no path update has arrived yet. An unknown
    ///     path never downgrades an associated interface to `noInternet`.
    static func classify(
        powerOn: Bool,
        serviceActive: Bool,
        isIBSS: Bool,
        sharingActive: Bool,
        pathSatisfied: Bool?,
        usesWiFi: Bool,
        isExpensive: Bool
    ) -> DuoWiFiClassification {
        if !powerOn { return .off }
        if !serviceActive { return .notAssociated }
        if sharingActive { return .shared }
        if isIBSS { return .temporary }

        if let pathSatisfied {
            if pathSatisfied && usesWiFi && isExpensive {
                return .hotspot
            }
            if !pathSatisfied {
                return .noInternet
            }
        }

        return .connected
    }

    /// `com.apple.nat` is an undocumented dynamic-store key used only as a
    /// best-effort signal. Missing or unreadable data returns `nil`, which means
    /// "not definitively sharing" and never assumes sharing is active.
    static func isInternetSharingActive() -> Bool? {
        guard let store = SCDynamicStoreCreate(nil, "MacTools.DuoStatus" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "com.apple.nat" as CFString) as? [String: Any],
              let nat = value["NAT"] as? [String: Any] else {
            return nil
        }
        return booleanValue(nat["Enabled"])
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
