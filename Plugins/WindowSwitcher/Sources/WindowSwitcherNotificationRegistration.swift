import ApplicationServices
import Foundation

/// Unsupported notifications use inventory reconciliation. Transient failures
/// retry on later scans with bounded backoff instead of being marked observed.
struct WindowSwitcherNotificationRegistration {
    private(set) var isRegistered = false
    private(set) var isUnsupported = false
    private(set) var requiresObserverReset = false
    private var failures = 0
    private var retryAfter: TimeInterval = 0

    mutating func attempt(at now: TimeInterval, register: () -> AXError) {
        guard !isRegistered, !isUnsupported, now >= retryAfter else { return }
        switch register() {
        case .success, .notificationAlreadyRegistered:
            isRegistered = true
        case .notificationUnsupported, .notImplemented:
            isUnsupported = true
        case .invalidUIElementObserver:
            requiresObserverReset = true
        default:
            failures = min(failures + 1, 6)
            retryAfter = now + min(30, pow(2, Double(failures - 1)))
        }
    }
}

struct WindowSwitcherProcessEvent: Sendable {
    enum Kind: Sendable {
        case focus, metadata, windows, geometry

        init(notification: String) {
            switch notification {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification: self = .focus
            case kAXTitleChangedNotification: self = .metadata
            case kAXMovedNotification, kAXResizedNotification: self = .geometry
            default: self = .windows
            }
        }

        var requiresWindowRecords: Bool { self == .windows || self == .geometry }
    }

    let processIdentifier: pid_t
    let lifetime: UUID
    let kind: Kind
}
