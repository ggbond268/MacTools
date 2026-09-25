import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class ControlledWindowAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var windows: [AXUIElement]? = []
        var focused: AXUIElement?
        var windowListReadFailures = 0
        var windowListReadFailuresAfterRaise = 0
        var closesAfterRaise = false
        var windowNumber: CGWindowID? = nil
        var windowNumbersByPID: [pid_t: CGWindowID] = [:]
        var onScreenReads = 0
        var metadataAvailable = true
        var windowSubrole = kAXStandardWindowSubrole as String
        var windowTitle = "Same title"
        var childCount: Int? = nil
        var isMain: Bool? = nil
        var isFocused: Bool? = nil
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
        lock.lock(); defer { lock.unlock() }
        if state.windowListReadFailures > 0 { state.windowListReadFailures -= 1; return nil }
        return state.windows
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
        return [kAXWindowRole, read { $0.windowSubrole }, read { $0.windowTitle }, read { $0.minimized },
                AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }
    func childCount(_ window: AXUIElement) -> Int? { read { $0.childCount } }
    func boolValue(_ element: AXUIElement, attribute: String) -> Bool? {
        read { state in
            switch attribute {
            case kAXMainAttribute: state.isMain
            case kAXFocusedAttribute: state.isFocused
            default: nil
            }
        }
    }
    func windowNumber(_ window: AXUIElement) -> CGWindowID? {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(window, &pid)
        return read { $0.windowNumbersByPID[pid] ?? $0.windowNumber }
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
            if action == kAXRaiseAction {
                $0.windowListReadFailures = $0.windowListReadFailuresAfterRaise
                if $0.closesAfterRaise { $0.windows = [] }
            }
            if action == kAXRaiseAction && $0.focusAfterRaise {
                $0.focused = element; $0.focusReadFailures = $0.focusReadFailuresAfterRaise
            }
        }
        return action == kAXRaiseAction && !read({ $0.raiseSucceeds }) ? .cannotComplete : .success
    }
}

final class WindowSwitcherProcessWorkerTests: XCTestCase, @unchecked Sendable {
    func testEmptyUnfocusedDialogIsNotListedAsAWindow() async {
        let access = ControlledWindowAXAccess()
        access.update {
            $0.windows = [AXUIElementCreateApplication(201)]
            $0.windowSubrole = kAXDialogSubrole as String
            $0.windowTitle = ""
            $0.childCount = 0
            $0.isMain = false
            $0.isFocused = false
        }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: { _ in })
        defer { worker.stop() }
        let empty = await worker.scan()
        XCTAssertTrue(empty.windows.isEmpty)

        access.update { $0.childCount = 1 }
        let withContent = await worker.scan()
        XCTAssertEqual(withContent.windows.count, 1)
        access.update { $0.childCount = 0; $0.isMain = true }
        let main = await worker.scan()
        XCTAssertEqual(main.windows.count, 1)
    }

    func testOffSpaceFocusWaitsUntilTheExactWindowIsOnScreen() async {
        let access = ControlledWindowAXAccess()
        let element = AXUIElementCreateApplication(42)
        access.update { $0.windowNumber = 7 }
        let worker = WindowSwitcherProcessWorker(pid: 42, launchDate: nil, access: access,
            requestWindowActivation: { _, _, _ in true }, windowIsRevealable: { _, _ in true }, windowIsOnScreen: { _, _ in
                access.update { $0.onScreenReads += 1 }
                return access.read { $0.onScreenReads >= 3 }
            }, windowIsOnActiveSpace: { _ in nil }, invalidated: { _ in })
        defer { worker.stop() }
        let result = await worker.focusOffSpaceWindow(.init(number: 7, element: element), cancellation: .init())
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(access.read { $0.onScreenReads }, 3)
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testOffSpaceFocusCannotSucceedForAnotherWindowInTheSameApp() async {
        let access = ControlledWindowAXAccess()
        access.update {
            $0.windowNumber = 7
            $0.windowNumbersByPID[43] = 8
            $0.focusAfterRaise = false
            $0.focused = AXUIElementCreateApplication(43)
        }
        let worker = WindowSwitcherProcessWorker(pid: 42, launchDate: nil, access: access,
            requestWindowActivation: { _, _, _ in true }, windowIsRevealable: { _, _ in true },
            windowIsOnScreen: { _, _ in true }, windowIsOnActiveSpace: { _ in true }, invalidated: { _ in })
        defer { worker.stop() }
        let result = await worker.focusOffSpaceWindow(.init(number: 7, element: AXUIElementCreateApplication(42)), cancellation: .init())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testOffSpaceFocusRejectsClosedWindowBeforeAnyMutation() async {
        let access = ControlledWindowAXAccess()
        access.update { $0.windowNumber = 7 }
        let worker = WindowSwitcherProcessWorker(pid: 42, launchDate: nil, access: access,
            requestWindowActivation: { _, _, _ in true }, windowIsRevealable: { _, _ in false }, windowIsOnScreen: { _, _ in true }, windowIsOnActiveSpace: { _ in nil }, invalidated: { _ in })
        defer { worker.stop() }
        let result = await worker.focusOffSpaceWindow(.init(number: 7, element: AXUIElementCreateApplication(42)), cancellation: .init())
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(access.read { $0.actions.isEmpty })
    }

    func testOffSpaceFocusCancelsDuringDestinationWaitWithoutAnotherRaise() async {
        let access = ControlledWindowAXAccess()
        access.update { $0.windowNumber = 7 }
        let cancellation = WindowSwitcherActionCancellation()
        let worker = WindowSwitcherProcessWorker(pid: 42, launchDate: nil, access: access,
            requestWindowActivation: { _, _, _ in true }, windowIsRevealable: { _, _ in true }, windowIsOnScreen: { _, _ in
                cancellation.cancel()
                return false
            }, windowIsOnActiveSpace: { _ in nil }, invalidated: { _ in })
        defer { worker.stop() }
        let result = await worker.focusOffSpaceWindow(.init(number: 7, element: AXUIElementCreateApplication(42)), cancellation: cancellation)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(access.read { $0.actions.filter { $0 == kAXRaiseAction }.count }, 1)
    }

    func testFailedReadRetainsIdentityWhileSuccessfulEmptyReadRemovesIt() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201), AXUIElementCreateApplication(202)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: { _ in })
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

    func testMetadataFailureDoesNotRemoveKnownWindowOrInventWindowlessApp() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)] }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: { _ in })
        defer { worker.stop() }
        let initial = await worker.scan()
        access.update { $0.metadataAvailable = false }
        let result = await worker.scan()
        XCTAssertTrue(result.unavailable)
        XCTAssertEqual(result.windows.first?.id, initial.windows.first?.id)
        XCTAssertTrue(result.windows.first?.unavailable == true)
    }

    func testSlowProcessDoesNotBlockAnotherProcessScan() async throws {
        let slow = ControlledWindowAXAccess(), fast = ControlledWindowAXAccess()
        slow.update { $0.windows = [AXUIElementCreateApplication(201)] }
        fast.update { $0.windows = [AXUIElementCreateApplication(301)] }
        let slowWorker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: slow, invalidated: { _ in })
        let fastWorker = WindowSwitcherProcessWorker(pid: 300, launchDate: nil, access: fast, invalidated: { _ in })
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

    func testClosedTargetAndFailedRestoreNeverRaiseAnotherWindow() async throws {
        let access = ControlledWindowAXAccess()
        access.update { $0.windows = [AXUIElementCreateApplication(201)]; $0.minimized = true; $0.restoreSucceeds = false }
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: { _ in })
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
        let worker = WindowSwitcherProcessWorker(pid: 200, launchDate: nil, access: access, invalidated: { _ in })
        defer { worker.stop() }
        let initial = await worker.scan()
        let id = try XCTUnwrap(initial.windows.first?.id)
        let close = await worker.perform(id, close: true)
        XCTAssertEqual(close, .requested)
        let afterCancelledSaveDialog = await worker.scan()
        XCTAssertEqual(afterCancelledSaveDialog.windows.first?.id, id)
    }

}
