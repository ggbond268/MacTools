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

final class DockClickMonitor: DockClickMonitoring {
    private let logger = DockClickLog.monitor
    private let resolver: any DockApplicationResolving
    private let frontmostApplicationProvider: any DockFrontmostApplicationProviding
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: events,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create Dock Click Hide event tap")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create Dock Click Hide run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
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

        guard type == .leftMouseDown,
              DockClickModifierPolicy.isPlainClick(flags: event.flags),
              let frontmostApplication = frontmostApplicationProvider.frontmostApplication(),
              let target = resolver.resolveApplication(at: event.location)
        else {
            return Unmanaged.passUnretained(event)
        }

        onApplicationClick?(target, frontmostApplication)
        return Unmanaged.passUnretained(event)
    }
}
