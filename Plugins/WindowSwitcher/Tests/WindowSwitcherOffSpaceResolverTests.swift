import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private struct ResolverAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    let observesSystemNotifications = false
    let root = AXUIElementCreateApplication(42)
    let descendant = AXUIElementCreateApplication(43)
    func windows(of app: AXUIElement) -> [AXUIElement]? { [] }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? { nil }
    func windowNumber(_ element: AXUIElement) -> CGWindowID? { 7 }
    func windowAttributes(_ element: AXUIElement) -> [Any]? {
        [CFEqual(element, root) ? kAXWindowRole : kAXButtonRole]
    }
    func minimized(_ element: AXUIElement) -> Bool? { false }
    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError { .failure }
    func perform(_ element: AXUIElement, action: String) -> AXError { .failure }
}

final class WindowSwitcherOffSpaceResolverTests: XCTestCase {
    func testLookupSkipsDescendantsEvenWhenTheyReportTheRequestedWindowID() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        var visited: [UInt64] = []
        let result = resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { true }, now: { 0 }, candidate: { _, id in
            visited.append(id)
            return id == 0 ? access.descendant : access.root
        })
        XCTAssertEqual(visited, [0, 1])
        XCTAssertTrue(result.map { CFEqual($0, access.root) } ?? false)
    }

    func testWrongWindowIDCannotBeAcceptedFromKnownHandles() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        XCTAssertNil(resolver.resolve(pid: 42, number: 8, access: access, candidates: [access.root], shouldContinue: { true }))
    }

    func testCancellationStopsLookupAndNextAttemptResumes() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        var current = true
        let first = resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { current }, now: { 0 }, candidate: { _, _ in
            current = false
            return nil
        })
        XCTAssertNil(first)
        XCTAssertEqual(resolver.nextElementID, 1)
        current = true
        var visited: [UInt64] = []
        let second = resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { current }, now: { 0 }, candidate: { _, id in
            visited.append(id)
            return access.root
        })
        XCTAssertNotNil(second)
        XCTAssertEqual(visited, [1])
    }

    func testElapsedBudgetStopsBeforeRequestingAnotherRemoteHandle() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        var clock: TimeInterval = 0
        var reads = 0
        XCTAssertNil(resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { true }, now: { clock }, candidate: { _, _ in
            reads += 1
            clock = 0.3
            return access.root
        }))
        XCTAssertEqual(reads, 1)
    }

    func testChangingTargetRestartsTheScanSoEarlierWindowIDsRemainReachable() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        var clock: TimeInterval = 0
        _ = resolver.resolve(pid: 42, number: 8, access: access, candidates: [], shouldContinue: { true }, now: { clock }, candidate: { _, _ in
            clock = 1
            return nil
        })
        XCTAssertEqual(resolver.nextElementID, 1)
        clock = 0
        var visited: [UInt64] = []
        XCTAssertNotNil(resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { true }, now: { clock }, candidate: { _, id in
            visited.append(id)
            return access.root
        }))
        XCTAssertEqual(visited, [0])
    }

    func testStalledClockStillHasAFiniteCandidateLimit() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        var reads = 0
        XCTAssertNil(resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { true }, now: { 0 }, candidate: { _, _ in
            reads += 1
            return nil
        }))
        XCTAssertEqual(reads, 20_000)
    }

    func testCancelledRequestNeverUsesACachedHandle() {
        let access = ResolverAccess()
        var resolver = WindowSwitcherOffSpaceResolver()
        XCTAssertNotNil(resolver.resolve(pid: 42, number: 7, access: access, candidates: [access.root], shouldContinue: { true }))
        XCTAssertNil(resolver.resolve(pid: 42, number: 7, access: access, candidates: [], shouldContinue: { false }))
    }
}
