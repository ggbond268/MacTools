import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class CatalogAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var number: CGWindowID?
        var beforeRead: (() -> Void)?
        var reads = 0
        var actions: [String] = []
    }
    private let lock = NSLock()
    private var state: State
    private let window: AXUIElement
    let observesSystemNotifications = false

    init(number: CGWindowID?, elementPID: pid_t) {
        state = State(number: number)
        window = AXUIElementCreateApplication(elementPID)
    }
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    func windows(of application: AXUIElement) -> [AXUIElement]? {
        update { $0.reads += 1 }
        read { $0.beforeRead }?()
        return read { $0.number == nil ? [] : [window] }
    }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        attribute == kAXCloseButtonAttribute ? owner : nil
    }
    func windowAttributes(_ window: AXUIElement) -> [Any]? {
        var point = CGPoint(x: 20, y: 20)
        var size = CGSize(width: 800, height: 600)
        return [kAXWindowRole, kAXStandardWindowSubrole, "Fixture", false,
                AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }
    func windowNumber(_ window: AXUIElement) -> CGWindowID? { read { $0.number } }
    func minimized(_ window: AXUIElement) -> Bool? { false }
    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError { .success }
    func perform(_ element: AXUIElement, action: String) -> AXError {
        update { $0.actions.append(action) }
        return .success
    }
}

@MainActor
final class WindowSwitcherAppCatalogTests: XCTestCase {
    func testBurstInvalidationReadsOnlyAffectedHostWithoutWindowServerQuery() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let cgReads = CatalogAXAccess(number: nil, elementPID: 203)
        let catalog = twoHostCatalog(first, second, cgReads: cgReads)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let firstReads = first.read { $0.reads }, secondReads = second.read { $0.reads }
        let recordReads = cgReads.read { $0.reads }
        for _ in 0..<100 { catalog.invalidate(processIdentifiers: [42], windowRecords: false) }
        try await waitUntil { first.read { $0.reads } > firstReads }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(first.read { $0.reads }, firstReads + 1)
        XCTAssertEqual(second.read { $0.reads }, secondReads)
        XCTAssertEqual(cgReads.read { $0.reads }, recordReads)
    }

    func testInvalidationDuringScanRetainsOneFollowUp() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = twoHostCatalog(first, second)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let initialReads = first.read { $0.reads }
        first.update { $0.beforeRead = { _ = release.wait(timeout: .now() + 3) } }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { first.read { $0.reads } > initialReads }
        for _ in 0..<20 { catalog.invalidate(processIdentifiers: [42], windowRecords: false) }
        try await Task.sleep(for: .milliseconds(250))
        first.update { $0.beforeRead = nil }
        release.signal()
        try await waitUntil { first.read { $0.reads } == initialReads + 2 }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(first.read { $0.reads }, initialReads + 2)
    }

    func testInvocationReconcilesANonemptyCacheBeforeBecomingReady() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = twoHostCatalog(first, second)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        first.update { $0.number = 9 }
        catalog.prepareForInvocation()
        XCTAssertFalse(catalog.isInvocationReady)
        XCTAssertEqual(numbers(catalog), [7])
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(numbers(catalog), [9])
    }

    func testGeometryEventsWaitUntilDragEndsAndKeepUnrelatedHostsIdle() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        var dragging = false
        let catalog = twoHostCatalog(first, second, isDragging: { dragging })
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let firstReads = first.read { $0.reads }, secondReads = second.read { $0.reads }
        dragging = true
        for _ in 0..<100 { catalog.invalidate(processIdentifiers: [42], windowRecords: true) }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(first.read { $0.reads }, firstReads)
        XCTAssertEqual(second.read { $0.reads }, secondReads)
        dragging = false
        try await waitUntil { first.read { $0.reads } == firstReads + 1 }
        XCTAssertEqual(second.read { $0.reads }, secondReads)
        XCTAssertTrue(WindowSwitcherProcessWorker.windowNotifications.contains(kAXMovedNotification))
        XCTAssertTrue(WindowSwitcherProcessWorker.windowNotifications.contains(kAXResizedNotification))
    }

    func testStopAndRestartDoNotReleasePhysicalScanSlotsEarly() async throws {
        let access = CatalogAXAccess(number: nil, elementPID: 201)
        let release = DispatchSemaphore(value: 0)
        access.update { $0.beforeRead = { _ = release.wait(timeout: .now() + 3) } }
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(), accessFactory: { _ in access },
            allSpacesCatalog: .init(windowRecordProvider: { [] }), discovery: .init(applications: {
                (40..<48).map { .init(processIdentifier: pid_t($0), bundleIdentifier: "fixture.\($0)",
                                     bundlePath: "/Fixture\($0).app", localizedName: "Fixture") }
            }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer {
            for _ in 0..<4 { release.signal() }
            catalog.stop()
        }
        catalog.start()
        try await waitUntil { access.read { $0.reads } == 4 }
        catalog.stop()
        catalog.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(access.read { $0.reads }, 4)
        access.update { $0.beforeRead = nil }
        for _ in 0..<4 { release.signal() }
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(access.read { $0.reads }, 12)
    }

    func testUnchangedReconciliationDoesNotNotifyTheUI() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = twoHostCatalog(first, second)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        var notifications = 0
        catalog.onChange = { notifications += 1 }
        let reads = first.read { $0.reads }
        catalog.refresh()
        try await waitUntil { first.read { $0.reads } > reads }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(notifications, 0)
    }

    func testWakeAndSpaceChangesDoNotResumeAnInactiveSession() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let center = NotificationCenter()
        let catalog = twoHostCatalog(first, second, notificationCenter: center)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        let reads = first.read { $0.reads }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        catalog.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first.read { $0.reads }, reads)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await waitUntil { first.read { $0.reads } > reads }
    }

    private func twoHostCatalog(_ first: CatalogAXAccess, _ second: CatalogAXAccess,
                                cgReads: CatalogAXAccess? = nil,
                                notificationCenter: NotificationCenter = NotificationCenter(),
                                isDragging: @escaping () -> Bool = { false }) -> WindowSwitcherAppCatalog {
        WindowSwitcherAppCatalog(notificationCenter: notificationCenter, accessFactory: { $0 == 42 ? first : second },
            allSpacesCatalog: .init(windowRecordProvider: { cgReads?.update { $0.reads += 1 }; return [] }),
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "first", bundlePath: "/First.app", localizedName: "First"),
                 .init(processIdentifier: 43, bundleIdentifier: "second", bundlePath: "/Second.app", localizedName: "Second")]
            }, isAccessibilityTrusted: { true }, isDragging: isDragging))
    }

    func testOnlyScannedHostLoadsFreshPresentationMetadata() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        var hostReads = 0
        var helperReads = 0
        var name = "Original"
        let records = WindowSwitcherWindowRecords(windowRecordProvider: {
            [.init(windowNumber: 8, processIdentifier: 43, title: "Fixture", isOnScreen: true,
                   bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
        })
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? host : helper }, allSpacesCatalog: records,
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture.host", bundlePath: "/Fixture.app",
                       localizedName: nil, loadPresentation: {
                           hostReads += 1
                           return .init(localizedName: name, icon: nil, isHidden: false, isActive: false)
                       }),
                 .init(processIdentifier: 43, bundleIdentifier: "fixture.host.helper", bundlePath: "/Fixture.app/Helper.app",
                       localizedName: nil, isRegular: false, loadPresentation: {
                           helperReads += 1
                           return .init(localizedName: "Helper", icon: nil, isHidden: false, isActive: false)
                       })]
            }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        catalog.refresh()
        XCTAssertEqual(hostReads, 1, "An in-flight host scan must not reread presentation metadata")
        try await waitUntil { catalog.refresh(); return numbers(catalog) == [7, 8] }
        XCTAssertEqual(helperReads, 0)
        name = "Renamed"
        try await waitUntil {
            catalog.refresh()
            return catalog.entries(sortMode: .fixed).filter { $0.processIdentifier == 42 }.allSatisfy { $0.appName == name }
        }
        XCTAssertEqual(helperReads, 0)
    }

    private func makeCatalog(host: CatalogAXAccess, helper: CatalogAXAccess,
                             accessFactory: (@Sendable (pid_t) -> any WindowSwitcherAXAccess)? = nil) -> WindowSwitcherAppCatalog {
        let records = WindowSwitcherWindowRecords(windowRecordProvider: {
            guard let number = helper.read({ $0.number }) else { return [] }
            return [.init(windowNumber: number, processIdentifier: 43, title: "Fixture", isOnScreen: true,
                          bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
        })
        return WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: accessFactory ?? { $0 == 42 ? host : helper }, allSpacesCatalog: records,
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture.host", bundlePath: "/Fixture.app", localizedName: "Fixture"),
                 .init(processIdentifier: 43, bundleIdentifier: "fixture.host.helper", bundlePath: "/Fixture.app/Helper.app",
                       localizedName: "Helper", isRegular: false)]
            }, isAccessibilityTrusted: { true }, isDragging: { false }))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func numbers(_ catalog: WindowSwitcherAppCatalog) -> Set<CGWindowID> {
        Set(catalog.entries(sortMode: .fixed).filter { $0.processIdentifier == 42 }.compactMap(\.windowNumber))
    }

    func testStopDuringHelperScanDoesNotRepublishWindows() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        let release = DispatchSemaphore(value: 0)
        helper.update { $0.beforeRead = { _ = release.wait(timeout: .now() + 5) } }
        let catalog = makeCatalog(host: host, helper: helper)
        defer { release.signal(); catalog.stop() }
        var callbacks = 0
        catalog.onChange = { callbacks += 1 }
        catalog.start()
        try await waitUntil { catalog.refresh(); return helper.read { $0.reads > 0 } }
        catalog.stop()
        let callbacksAtStop = callbacks
        XCTAssertTrue(catalog.entries(sortMode: .fixed).isEmpty)
        release.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(catalog.entries(sortMode: .fixed).isEmpty)
        XCTAssertEqual(callbacks, callbacksAtStop)
    }

    func testOldHelperScanCannotOverwriteRestartedCatalog() async throws {
        let oldHost = CatalogAXAccess(number: 7, elementPID: 201)
        let oldHelper = CatalogAXAccess(number: 8, elementPID: 202)
        let newHost = CatalogAXAccess(number: 9, elementPID: 301)
        let newHelper = CatalogAXAccess(number: 10, elementPID: 302)
        let phase = CatalogAXAccess(number: nil, elementPID: 303)
        let release = DispatchSemaphore(value: 0)
        oldHelper.update { $0.beforeRead = { _ = release.wait(timeout: .now() + 5) } }
        let catalog = makeCatalog(host: oldHost, helper: newHelper, accessFactory: { pid in
            if phase.read({ $0.number != nil }) { return pid == 42 ? newHost : newHelper }
            return pid == 42 ? oldHost : oldHelper
        })
        defer { release.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.refresh(); return oldHelper.read { $0.reads > 0 } }
        catalog.stop()
        phase.update { $0.number = 1 }
        catalog.start()
        try await waitUntil { catalog.refresh(); return numbers(catalog) == [9, 10] }
        release.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(numbers(catalog), [9, 10])
    }

    func testHostAXRecordKeepsItsWorkerWhenCompositorOwnerIsHelper() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let helper = CatalogAXAccess(number: 7, elementPID: 202)
        let catalog = makeCatalog(host: host, helper: helper)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil {
            catalog.entries(sortMode: .fixed).contains { $0.processIdentifier == 42 && $0.owningProcessIdentifier == 43 }
        }
        let entry = try XCTUnwrap(catalog.entries(sortMode: .fixed).first { $0.processIdentifier == 42 })
        XCTAssertEqual(entry.owningProcessIdentifier, 43)
        XCTAssertEqual(entry.axWorkerPID, 42)
        let result = await catalog.closeWindow(entry)
        XCTAssertEqual(result, .requested)
        XCTAssertEqual(host.read { $0.actions }, [kAXPressAction])
        XCTAssertTrue(helper.read { $0.actions.isEmpty })
    }

    func testHelperAXRecordUsesHelperWorkerForClose() async throws {
        let host = CatalogAXAccess(number: nil, elementPID: 201)
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = makeCatalog(host: host, helper: helper)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil {
            catalog.refresh()
            return catalog.entries(sortMode: .fixed).contains { $0.axWorkerPID == 43 }
        }
        let entry = try XCTUnwrap(catalog.entries(sortMode: .fixed).first { $0.axWorkerPID == 43 })
        let result = await catalog.closeWindow(entry)
        XCTAssertEqual(result, .requested)
        XCTAssertEqual(helper.read { $0.actions }, [kAXPressAction])
        XCTAssertTrue(host.read { $0.actions.isEmpty })
    }
}
