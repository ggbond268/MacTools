import ApplicationServices
import Foundation
import Darwin

/// Used only on the owning process worker queue. AXWindows may omit windows on
/// other Spaces, so a selected exact window can require a bounded remote lookup.
struct WindowSwitcherOffSpaceResolver {
    private typealias CreateElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let createElement: CreateElement? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let pointer = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(pointer, to: CreateElement.self)
    }()

    // Continue a sparse lookup on the next explicit selection instead of
    // repeatedly scanning the same prefix. This is not a background polling loop.
    private(set) var nextElementID: UInt64 = 0
    private var searchTarget: CGWindowID?
    private var cached: [CGWindowID: AXUIElement] = [:]

    mutating func resolve(pid: pid_t, number: CGWindowID, access: any WindowSwitcherAXAccess,
                          candidates: [AXUIElement], shouldContinue: () -> Bool,
                          now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                          candidate: ((pid_t, UInt64) -> AXUIElement?)? = nil) -> AXUIElement? {
        guard pid > 0, number > 0, shouldContinue() else { return nil }
        let deadline = now() + 0.25
        func matches(_ element: AXUIElement) -> Bool {
            guard shouldContinue(), now() < deadline,
                  access.windowNumber(element) == number,
                  let attributes = access.windowAttributes(element),
                  attributes.first as? String == kAXWindowRole else { return false }
            return true
        }
        if let existing = cached[number], matches(existing) { return existing }
        cached[number] = nil
        for element in candidates {
            guard shouldContinue(), now() < deadline else { return nil }
            if matches(element) { remember(element, number: number); return element }
        }
        guard candidate != nil || (access.observesSystemNotifications && Self.createElement != nil) else { return nil }
        if searchTarget != number {
            searchTarget = number
            nextElementID = 0
        }
        let make = candidate ?? Self.element
        // Both time and count are bounded even if an injected/system clock stalls.
        for _ in 0..<20_000 {
            guard shouldContinue(), now() < deadline else { return nil }
            let id = nextElementID
            nextElementID = id == UInt64.max ? 0 : id + 1
            guard let element = make(pid, id) else { continue }
            AXUIElementSetMessagingTimeout(element, 0.025)
            if matches(element) { remember(element, number: number); return element }
        }
        return nil
    }

    private mutating func remember(_ element: AXUIElement, number: CGWindowID) {
        if cached.count >= 8 { cached.removeAll() }
        cached[number] = element
    }

    private static func element(pid: pid_t, id: UInt64) -> AXUIElement? {
        // Runtime token layout: process ID, reserved word, Cocoa marker, element ID.
        // The unaligned ID field is written as bytes, never loaded through a pointer.
        var token = Data(count: 20)
        token.withUnsafeMutableBytes {
            $0.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            $0.storeBytes(of: UInt32(0x636f636f), toByteOffset: 8, as: UInt32.self)
            $0.storeBytes(of: id, toByteOffset: 12, as: UInt64.self)
        }
        return createElement?(token as CFData)?.takeRetainedValue()
    }
}

/// The handle remains confined to its process worker for reads and mutations.
struct WindowSwitcherResolvedWindow: @unchecked Sendable {
    let number: CGWindowID
    let element: AXUIElement
}
