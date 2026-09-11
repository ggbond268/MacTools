import AppKit
import CoreGraphics
import Foundation

struct DockFrontmostApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
}

protocol DockFrontmostApplicationProviding: AnyObject {
    func frontmostApplication() -> DockFrontmostApplication?
}

final class WorkspaceDockFrontmostApplicationProvider: DockFrontmostApplicationProviding {
    func frontmostApplication() -> DockFrontmostApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier
        else {
            return nil
        }
        return DockFrontmostApplication(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }
}

protocol DockClickMonitoring: AnyObject {
    var onApplicationClick: ((DockApplicationTarget, DockFrontmostApplication) -> Void)? { get set }
    @discardableResult
    func start() -> Bool
    func stop()
}

enum DockClickModifierPolicy {
    private static let modifiedClickFlags: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift,
    ]

    static func isPlainClick(flags: CGEventFlags) -> Bool {
        flags.intersection(modifiedClickFlags).isEmpty
    }
}

enum DockClickGesturePolicy {
    static let maximumDuration: TimeInterval = 0.35
    static let maximumDistance: CGFloat = 4

    static func isWithinMaximumDistance(
        downLocation: CGPoint,
        currentLocation: CGPoint
    ) -> Bool {
        hypot(
            currentLocation.x - downLocation.x,
            currentLocation.y - downLocation.y
        ) <= maximumDistance
    }

    static func isCompletedClick(
        downLocation: CGPoint,
        upLocation: CGPoint,
        duration: TimeInterval
    ) -> Bool {
        guard duration <= maximumDuration else {
            return false
        }
        return isWithinMaximumDistance(
            downLocation: downLocation,
            currentLocation: upLocation
        )
    }
}

// Event-tap state stays on the main run loop; Accessibility resolution is confined to accessibilityQueue.
final class DockClickMonitor: DockClickMonitoring, @unchecked Sendable {
    private struct PendingClick {
        let location: CGPoint
        let startedAt: TimeInterval
        let frontmostApplication: DockFrontmostApplication
        let generation: Int
    }

    private let logger = DockClickLog.monitor
    private let resolver: any DockApplicationResolving
    private let frontmostApplicationProvider: any DockFrontmostApplicationProviding
    private let accessibilityQueue = DispatchQueue(
        label: "cc.ggbond.mactools.dock-click-minimize.accessibility"
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingClick: PendingClick?
    private var monitoringGeneration = 0

    var onApplicationClick: ((DockApplicationTarget, DockFrontmostApplication) -> Void)?

    init(
        resolver: any DockApplicationResolving = DockAccessibilityResolver(),
        frontmostApplicationProvider: any DockFrontmostApplicationProviding = WorkspaceDockFrontmostApplicationProvider()
    ) {
        self.resolver = resolver
        self.frontmostApplicationProvider = frontmostApplicationProvider
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let events = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
            | CGEventMask(1) << CGEventType.leftMouseUp.rawValue
            | CGEventMask(1) << CGEventType.leftMouseDragged.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: events,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create Hide Active App on Dock Click event tap")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create Hide Active App on Dock Click run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        monitoringGeneration &+= 1
        pendingClick = nil
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<DockClickMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            beginClick(event)
        case .leftMouseDragged:
            if let pendingClick,
               !DockClickGesturePolicy.isWithinMaximumDistance(
                   downLocation: pendingClick.location,
                   currentLocation: event.location
               ) {
                self.pendingClick = nil
            }
        case .leftMouseUp:
            completeClick(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func beginClick(_ event: CGEvent) {
        guard DockClickModifierPolicy.isPlainClick(flags: event.flags),
              let frontmostApplication = frontmostApplicationProvider.frontmostApplication()
        else {
            pendingClick = nil
            return
        }

        pendingClick = PendingClick(
            location: event.location,
            startedAt: ProcessInfo.processInfo.systemUptime,
            frontmostApplication: frontmostApplication,
            generation: monitoringGeneration
        )
    }

    private func completeClick(_ event: CGEvent) {
        guard let pendingClick else {
            return
        }
        self.pendingClick = nil

        guard pendingClick.generation == monitoringGeneration,
              DockClickModifierPolicy.isPlainClick(flags: event.flags),
              DockClickGesturePolicy.isCompletedClick(
                  downLocation: pendingClick.location,
                  upLocation: event.location,
                  duration: ProcessInfo.processInfo.systemUptime - pendingClick.startedAt
              )
        else {
            return
        }

        let location = event.location
        accessibilityQueue.async { [weak self] in
            guard let self,
                  let target = self.resolver.resolveApplication(at: location)
            else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      pendingClick.generation == self.monitoringGeneration,
                      self.eventTap != nil
                else {
                    return
                }
                self.onApplicationClick?(target, pendingClick.frontmostApplication)
            }
        }
    }
}
