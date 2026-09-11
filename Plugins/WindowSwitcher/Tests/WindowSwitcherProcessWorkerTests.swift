import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class ControlledWindowAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var windows: [AXUIElement]? = []
        var focused: AXUIElement?
        var metadataAvailable = true
        var minimized = false
        var minimizedReadFailures = 0
        var restoreSucceeds = true
        var restoreReadFailures = 0
        var restoreRequested: (() -> Void)?
        var raiseSucceeds = true
        var focusAfterRaise = true
        var focusReadFailuresAfterRaise = 0
        var focusReadFailures = 0
        var actions: [String] = []
        var delayRead: (() -> Void)?
    }
    private let lock = NSLock()
    private var state = State()
    let observesSystemNotifications = false
    func update(_ change: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; change(&state) }
    func read<T>(_ value: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return value(state) }
    func windows(of application: AXUIElement) -> [AXUIElement]? {
        let delay = read { $0.delayRead }
        delay?()
        return read { $0.windows }
    }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        if attribute == kAXCloseButtonAttribute { return owner }
        lock.lock(); defer { lock.unlock() }
        if attribute == kAXFocusedWindowAttribute, state.focusReadFailures > 0 {
            state.focusReadFailures -= 1
            return nil
        }
        return state.focused
    }
    func windowAttributes(_ window: AXUIElement) -> [Any]? {
        guard read({ $0.metadataAvailable }) else { return nil }
        var point = CGPoint(x: 20, y: 20)
        var size = CGSize(width: 800, height: 600)
        return [kAXWindowRole, kAXStandardWindowSubrole, "Same title", read { $0.minimized },
                AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }
    func minimized(_ window: AXUIElement) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        if state.minimizedReadFailures > 0 { state.minimizedReadFailures -= 1; return nil }
        return state.minimized
    }
    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError {
        update { $0.actions.append(attribute) }
        if attribute == kAXMinimizedAttribute {
            guard read({ $0.restoreSucceeds }) else { return .cannotComplete }
            update { $0.minimized = false; $0.minimizedReadFailures = $0.restoreReadFailures }
            read { $0.restoreRequested }?()
        }
        return .success
    }
    func perform(_ element: AXUIElement, action: String) -> AXError {
        update {
            $0.actions.append(action)
            if action == kAXRaiseAction && $0.focusAfterRaise {
                $0.focused = element; $0.focusReadFailures = $0.focusReadFailuresAfterRaise
            }
        }
        return action == kAXRaiseAction && !read({ $0.raiseSucceeds }) ? .cannotComplete : .success
    }
}

final class WindowSwitcherProcessWorkerTests: XCTestCase, @unchecked Sendable {
    func testRestoreWaitsForAnimationWithoutResubmitting() async throws {
        let access = ControlledWindowAXAccess()
        access.update {
            $0.windows = [AXUIElementCreateApplication(201)]
            $0.minimized = true
            $0.restoreReadFailures = 3
        }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let result = await worker.perform(try XCTUnwrap(initial.windows.first?.id), close: false)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(access.read { $0.minimizedReadFailures }, 0)
        XCTAssertEqual(access.read { $0.actions }, [kAXMinimizedAttribute, kAXMainAttribute, kAXFocusedAttribute, kAXRaiseAction])
    }

    func testCancelDuringRestoreNeverSubmitsFocusCommands() async throws {
        let access = ControlledWindowAXAccess()
        let restored = expectation(description: "restore request submitted")
        access.update {
            $0.windows = [AXUIElementCreateApplication(201)]
            $0.minimized = true
            $0.restoreReadFailures = 20
            $0.restoreRequested = { restored.fulfill() }
        }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let id = try XCTUnwrap(initial.windows.first?.id)
        let action = Task { await worker.perform(id, close: false) }
        await fulfillment(of: [restored], timeout: 2)
        action.cancel()
        let result = await action.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(access.read { $0.actions }, [kAXMinimizedAttribute])
    }

    func testTransientReadFailureDuringActivationSettlesWithoutRepeatingActions() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)]; $0.minimizedReadFailures = 1 }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let result = await worker.perform(try XCTUnwrap(initial.windows.first?.id), close: false)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testFailedReadRetainsIdentityWhileSuccessfulEmptyReadRemovesIt() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201), AXUIElementCreateApplication(202)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        XCTAssertEqual(initial.windows.count, 2)
        XCTAssertFalse(initial.unavailable)
        access.update { $0.windows = nil }
        let unavailable = await worker.scan()
        XCTAssertTrue(unavailable.unavailable)
        XCTAssertTrue(unavailable.windows.allSatisfy(\.unavailable))
        XCTAssertEqual(initial.windows.map(\.id), unavailable.windows.map(\.id))
        access.update { $0.windows = [] }
        let empty = await worker.scan()
        XCTAssertFalse(empty.unavailable)
        XCTAssertTrue(empty.windows.isEmpty)
    }

    func testApplicationRootInWindowListIsUnavailableRatherThanEmpty() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        access.update { $0.windows = [AXUIElementCreateApplication(200)] }
        let invalid = await worker.scan()
        XCTAssertTrue(invalid.unavailable)
        XCTAssertFalse(invalid.windowListReadSucceeded)
        XCTAssertEqual(invalid.windows.map(\.id), initial.windows.map(\.id))
        XCTAssertTrue(invalid.windows.allSatisfy(\.unavailable))
    }

    func testMetadataFailureDoesNotRemoveKnownWindowOrInventWindowlessApp() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        access.update { $0.metadataAvailable = false }
        let result = await worker.scan()
        XCTAssertTrue(result.unavailable)
        XCTAssertEqual(result.windows.first?.id, initial.windows.first?.id)
        XCTAssertTrue(result.windows.first?.unavailable == true)
    }

    func testCancelledActionWaitingBehindSlowReadNeverSubmits() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let id = try XCTUnwrap(initial.windows.first?.id)
        let entered = expectation(description: "slow AX read began")
        let release = DispatchSemaphore(value: 0)
        access.update { state in state.delayRead = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) } }
        let scan = Task { await worker.scan() }
        await fulfillment(of: [entered], timeout: 2)
        let action = Task { await worker.perform(id, close: true) }
        action.cancel()
        access.update { $0.delayRead = nil }
        release.signal()
        _ = await scan.value
        let result = await action.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(access.read { $0.actions.isEmpty })
    }

    func testSlowProcessDoesNotBlockAnotherProcessScan() async throws {
        let slow = ControlledWindowAXAccess(), fast = ControlledWindowAXAccess()
        slow.update { $0.windows = [AXUIElementCreateApplication(201)] }
        fast.update { $0.windows = [AXUIElementCreateApplication(301)] }
        let slowWorker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: slow, invalidated: {})
        let fastWorker = WindowSwitcherProcessWorker(pid: 300, launchDate: nil, access: fast, invalidated: {})
        defer { slowWorker.stop(); fastWorker.stop() }
        let entered = expectation(description: "slow process is blocked")
        let completed = expectation(description: "other process completes before slow process resumes")
        let release = DispatchSemaphore(value: 0)
        slow.update { $0.delayRead = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) } }
        let scan = Task { await slowWorker.scan() }
        await fulfillment(of: [entered], timeout: 2)
        let other = Task { let result = await fastWorker.scan(); XCTAssertEqual(result.windows.count, 1); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 1)
        release.signal()
        _ = await scan.value; _ = await other.value
    }

    func testRaiseOnlyAppDoesNotRequireWritingMinimizedStateAndIsVerified() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)]; $0.restoreSucceeds = false }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let result = await worker.perform(try XCTUnwrap(initial.windows.first?.id), close: false)
        XCTAssertEqual(result, .succeeded)
        XCTAssertFalse(access.read { $0.actions.contains(kAXMinimizedAttribute) })
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testDelayedFocusAcknowledgementAfterRaiseDoesNotFailEarly() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)]; $0.focusReadFailuresAfterRaise = 5 }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let result = await worker.perform(try XCTUnwrap(initial.windows.first?.id), close: false)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testUnconfirmedFocusRetriesObservationWithoutResubmittingRaise() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)]; $0.focusAfterRaise = false }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let result = await worker.perform(try XCTUnwrap(initial.windows.first?.id), close: false)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testClosedTargetAndFailedRestoreNeverRaiseAnotherWindow() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)]; $0.minimized = true; $0.restoreSucceeds = false }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let id = try XCTUnwrap(initial.windows.first?.id)
        let restore = await worker.perform(id, close: false)
        XCTAssertEqual(restore, .failed)
        XCTAssertEqual(access.read { $0.actions }, [kAXMinimizedAttribute])
        access.update { $0.windows = []; $0.actions = [] }
        let closed = await worker.perform(id, close: false)
        XCTAssertEqual(closed, .unavailable)
        XCTAssertTrue(access.read { $0.actions.isEmpty })
    }

    func testCloseRequestDoesNotOptimisticallyDeleteWindow() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: {})
        defer { worker.stop() }
        let initial = await worker.scan()
        let id = try XCTUnwrap(initial.windows.first?.id)
        let close = await worker.perform(id, close: true)
        XCTAssertEqual(close, .requested)
        let afterCancelledSaveDialog = await worker.scan()
        XCTAssertEqual(afterCancelledSaveDialog.windows.first?.id, id)
    }
}
