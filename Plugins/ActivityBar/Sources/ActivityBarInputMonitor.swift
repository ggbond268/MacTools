import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol ActivityBarInputMonitoring: AnyObject {
    var status: ActivityBarInputMonitorStatus { get }
    var onEvent: ((ActivityBarInputEvent) -> Void)? { get set }

    func start()
    func stop()
    /// Re-attempt only the event tap if a prior `start()` was denied Input
    /// Monitoring permission. Safe to call repeatedly; no-op unless denied.
    func retryEventTapIfDenied()
}

@MainActor
final class ActivityBarInputMonitor: ActivityBarInputMonitoring {
    private enum Timing {
        static let screenTimeFlushInterval: TimeInterval = 30
        static let minimumScreenTimeFlush: TimeInterval = 0.5
        static let scrollGestureGap: TimeInterval = 0.3
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeApp: String?
    private var activeAppSince: Date?
    private var screenTimeTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?

    private nonisolated(unsafe) static var lastScrollTime: Date = .distantPast

    var status: ActivityBarInputMonitorStatus = .idle
    var onEvent: ((ActivityBarInputEvent) -> Void)?

    func start() {
        guard status != .running else {
            return
        }

        startScreenTimeTracking()
        startEventTap()
    }

    /// Re-attempt only the event tap after an earlier denial. Screen-time
    /// tracking already started during `start()`, so we must NOT re-run
    /// `startScreenTimeTracking()` here — doing so would leak the existing
    /// timer/workspace observer. Granting the permission then re-opening the
    /// panel (which calls `refresh()`) now recovers without a restart.
    func retryEventTapIfDenied() {
        guard status == .inputMonitoringDenied else { return }
        startEventTap()
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil

        flushScreenTime()
        screenTimeTimer?.invalidate()
        screenTimeTimer = nil

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil

        activeApp = nil
        activeAppSince = nil
        status = .idle
    }

    private var frontmostAppName: String {
        let application = NSWorkspace.shared.frontmostApplication

        if let localizedName = application?.localizedName, !localizedName.isEmpty {
            return localizedName
        }

        if let bundleIdentifier = application?.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return "Unknown"
    }

    private func startEventTap() {
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        )

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, eventType, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<ActivityBarInputMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                Task { @MainActor in
                    monitor.handleCGEvent(type: eventType)
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            status = .inputMonitoringDenied
            ActivityBarLog.input.warning("Input event tap could not be created; Input Monitoring may be missing")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status = .running
    }

    private func handleCGEvent(type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let app = frontmostAppName

        switch type {
        case .keyDown:
            onEvent?(.keystroke(app: app))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onEvent?(.pointerClick(app: app))
        case .scrollWheel:
            let now = Date()
            if now.timeIntervalSince(Self.lastScrollTime) > Timing.scrollGestureGap {
                onEvent?(.scroll(app: app))
            }
            Self.lastScrollTime = now
        default:
            break
        }
    }

    private func startScreenTimeTracking() {
        activeApp = frontmostAppName
        activeAppSince = Date()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedAppName = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .localizedName

            Task { @MainActor [weak self, activatedAppName] in
                guard let self else {
                    return
                }

                self.flushScreenTime()
                self.activeApp = activatedAppName ?? self.frontmostAppName
                self.activeAppSince = Date()
            }
        }

        screenTimeTimer = Timer.scheduledTimer(withTimeInterval: Timing.screenTimeFlushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.flushScreenTime()
                self.activeAppSince = Date()
            }
        }
    }

    private func flushScreenTime() {
        guard let app = activeApp, let since = activeAppSince else {
            return
        }

        let elapsed = Date().timeIntervalSince(since)
        if elapsed > Timing.minimumScreenTimeFlush {
            onEvent?(.screenTime(app: app, seconds: elapsed))
        }
    }
}
