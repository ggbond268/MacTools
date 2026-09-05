import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import WindowSwitcherPlugin

@MainActor
private final class WindowSwitcherMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

private final class WindowSwitcherWindowRecordProviderHarness: @unchecked Sendable {
    let releaseFirstInvocation = DispatchSemaphore(value: 0)
    let firstInvocationFinished = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let firstRecords: [WindowSwitcherWindowRecord]
    private let laterRecords: [WindowSwitcherWindowRecord]
    private var invocationCount = 0

    init(
        firstRecords: [WindowSwitcherWindowRecord],
        laterRecords: [WindowSwitcherWindowRecord]
    ) {
        self.firstRecords = firstRecords
        self.laterRecords = laterRecords
    }

    func records() -> [WindowSwitcherWindowRecord] {
        lock.lock()
        invocationCount += 1
        let invocation = invocationCount
        lock.unlock()

        guard invocation == 1 else {
            return laterRecords
        }

        _ = releaseFirstInvocation.wait(timeout: .now() + .seconds(5))
        firstInvocationFinished.signal()
        return firstRecords
    }

    func hasAtLeastInvocations(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount >= count
    }
}

private final class WindowSwitcherActivationRecordProviderHarness: @unchecked Sendable {
    let releaseSecondInvocation = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let initialRecords: [WindowSwitcherWindowRecord]
    private var invocationCount = 0

    init(initialRecords: [WindowSwitcherWindowRecord]) {
        self.initialRecords = initialRecords
    }

    func records() -> [WindowSwitcherWindowRecord] {
        lock.lock()
        invocationCount += 1
        let invocation = invocationCount
        lock.unlock()

        guard invocation > 1 else {
            return initialRecords
        }

        _ = releaseSecondInvocation.wait(timeout: .now() + .seconds(5))
        return initialRecords
    }
}

private final class WindowSwitcherAccessibilityHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = true
    private var checks = 0

    var isTrusted: Bool {
        get {
            lock.withLock { trusted }
        }
        set {
            lock.withLock {
                trusted = newValue
            }
        }
    }

    var checkCount: Int {
        lock.withLock { checks }
    }

    func check() -> Bool {
        lock.withLock {
            checks += 1
            return trusted
        }
    }
}

@MainActor
private final class WindowSwitcherApplicationHarness: WindowSwitcherApplicationControlling {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let launchDate: Date?
    var isTerminated = false
    private(set) var unhideCount = 0
    private(set) var activationOptions: NSApplication.ActivationOptions?
    private(set) var terminateCount = 0

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = "com.example.window-switcher",
        launchDate: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    @discardableResult
    func unhide() -> Bool {
        unhideCount += 1
        return true
    }

    @discardableResult
    func activate(options: NSApplication.ActivationOptions) -> Bool {
        activationOptions = options
        return true
    }

    @discardableResult
    func terminate() -> Bool {
        terminateCount += 1
        isTerminated = true
        return true
    }
}

@MainActor
private final class WindowSwitcherDirectEntriesProviderHarness {
    let entries: [WindowSwitcherAppEntry]
    private(set) var didStart = false
    private var continuation: CheckedContinuation<[WindowSwitcherAppEntry], Never>?

    init(entries: [WindowSwitcherAppEntry]) {
        self.entries = entries
    }

    func load() async -> [WindowSwitcherAppEntry] {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        guard let continuation else {
            return
        }

        self.continuation = nil
        continuation.resume(returning: entries)
    }
}

@MainActor
final class WindowSwitcherPluginTests: XCTestCase {
    func testManifestActionMatchesRuntimePolicy() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )

        try PluginManifestActionAssertions.assertConsistency(
            pluginDirectoryName: "WindowSwitcher",
            definitions: plugin.actionDefinitions,
            permissionIDs: plugin.permissionRequirementIDs(for:)
        )
    }

    func testShortcutRecorderUsesGroupSummaryWithoutDuplicateControlLabel() {
        let plugin = WindowSwitcherPlugin(accessibilityTrusted: { true })
        let definition = plugin.shortcutDefinitions.first

        XCTAssertNil(definition?.settingsControlTitle)
        XCTAssertNil(definition?.settingsControlSystemImage)
    }

    func testPublishesForegroundCanonicalActionWithAccessibilityRequirement() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.actionID, WindowSwitcherConstants.shortcutActionID)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: definition.key),
            [WindowSwitcherConstants.accessibilityPermissionID]
        )
        XCTAssertEqual(
            plugin.actionAvailability(for: ActionReference(key: definition.key)),
            .available
        )
    }

    func testCanonicalActionIsUnavailableWhenWindowSwitcherIsDisabled() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )
        plugin.store.setEnabled(false)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertFalse(
            plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable
        )
    }

    func testWorkspaceNotificationHopsSafelyToMainActor() async {
        let center = NotificationCenter()
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: center,
            windowRecordProvider: { [] }
        )
        let changed = expectation(description: "catalog reports a workspace change")
        catalog.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            changed.fulfill()
        }
        catalog.start()

        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        await fulfillment(of: [changed], timeout: 1)
        catalog.stop()
    }

    func testStaleWindowRecordRefreshCannotReplaceNewerSnapshot() async {
        let firstRecord = WindowSwitcherWindowRecord(
            windowNumber: 901,
            processIdentifier: 321,
            title: "stale snapshot",
            isOnScreen: false,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        let laterRecord = WindowSwitcherWindowRecord(
            windowNumber: 902,
            processIdentifier: 321,
            title: "current snapshot",
            isOnScreen: false,
            bounds: CGRect(x: 40, y: 60, width: 900, height: 700)
        )
        let harness = WindowSwitcherWindowRecordProviderHarness(
            firstRecords: [firstRecord],
            laterRecords: [laterRecord]
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { harness.records() }
        )
        defer {
            harness.releaseFirstInvocation.signal()
            catalog.stop()
        }

        catalog.start()
        let pendingWindowNumbers = Task { @MainActor in
            await catalog.windowRecordsSnapshot().map(\.windowNumber)
        }
        for _ in 0..<100 where !harness.hasAtLeastInvocations(1) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(harness.hasAtLeastInvocations(1))

        catalog.stop()
        harness.releaseFirstInvocation.signal()
        XCTAssertEqual(
            harness.firstInvocationFinished.wait(timeout: .now() + .seconds(1)),
            .success
        )
        for _ in 0..<100 {
            await Task.yield()
        }
        catalog.start()
        let currentWindowNumbersTask = Task { @MainActor in
            await catalog.windowRecordsSnapshot().map(\.windowNumber)
        }
        for _ in 0..<100 where !harness.hasAtLeastInvocations(2) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(harness.hasAtLeastInvocations(2))
        let currentWindowNumbers = await currentWindowNumbersTask.value
        let windowNumbers = await pendingWindowNumbers.value
        XCTAssertTrue(currentWindowNumbers.contains(laterRecord.windowNumber))
        XCTAssertFalse(windowNumbers.contains(firstRecord.windowNumber))
    }

    func testCancelledWindowRecordRefreshDoesNotBlockTheNextSnapshot() async {
        let firstRecord = WindowSwitcherWindowRecord(
            windowNumber: 903,
            processIdentifier: 321,
            title: "blocked snapshot",
            isOnScreen: false,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        let harness = WindowSwitcherWindowRecordProviderHarness(
            firstRecords: [firstRecord],
            laterRecords: []
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { harness.records() }
        )
        defer {
            harness.releaseFirstInvocation.signal()
            catalog.stop()
        }

        catalog.start()
        let pendingSnapshot = Task { @MainActor in
            await catalog.windowRecordsSnapshot()
        }
        for _ in 0..<100 where !harness.hasAtLeastInvocations(1) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(harness.hasAtLeastInvocations(1))

        pendingSnapshot.cancel()
        let cancelledSnapshot = await pendingSnapshot.value
        XCTAssertTrue(cancelledSnapshot.isEmpty)

        let nextSnapshot = Task { @MainActor in
            await catalog.windowRecordsSnapshot()
        }
        let currentSnapshot = await nextSnapshot.value
        XCTAssertTrue(currentSnapshot.isEmpty)
    }

    func testTimedOutWindowRecordRefreshReturnsWithoutWaitingForProvider() async {
        let harness = WindowSwitcherWindowRecordProviderHarness(
            firstRecords: [
                WindowSwitcherWindowRecord(
                    windowNumber: 904,
                    processIdentifier: 321,
                    title: "timed out snapshot",
                    isOnScreen: false,
                    bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
                ),
            ],
            laterRecords: []
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { harness.records() },
            windowRecordRefreshTimeout: 0.01
        )
        defer {
            harness.releaseFirstInvocation.signal()
            catalog.stop()
        }

        catalog.start()
        let completed = expectation(description: "timed-out refresh returns a fallback snapshot")
        var snapshot: [WindowSwitcherWindowRecord]?
        Task { @MainActor in
            snapshot = await catalog.windowRecordsSnapshot()
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertTrue(snapshot?.isEmpty == true)
    }

    func testTimedOutWindowRecordRefreshAllowsOneBoundedReplacement() async {
        let laterRecord = WindowSwitcherWindowRecord(
            windowNumber: 905,
            processIdentifier: 321,
            title: "replacement snapshot",
            isOnScreen: false,
            bounds: CGRect(x: 40, y: 60, width: 900, height: 700)
        )
        let harness = WindowSwitcherWindowRecordProviderHarness(
            firstRecords: [],
            laterRecords: [laterRecord]
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { harness.records() },
            windowRecordRefreshTimeout: 0.01
        )
        defer {
            harness.releaseFirstInvocation.signal()
            catalog.stop()
        }

        catalog.start()
        let firstSnapshot = await catalog.windowRecordsSnapshot()
        XCTAssertTrue(firstSnapshot.isEmpty)

        let replacementSnapshot = await catalog.windowRecordsSnapshot()
        XCTAssertEqual(replacementSnapshot.map(\.windowNumber), [laterRecord.windowNumber])
        XCTAssertTrue(harness.hasAtLeastInvocations(2))
    }

    func testDirectCycleQueuesPressesWhileAllSpaceSnapshotIsPreparing() async {
        let expectedEntries = (0..<4).map { index in
            makeEntry(
                index: index,
                appName: "Test window " + String(index),
                bundleIdentifier: "com.example.window-switcher-test-" + String(index)
            )
        }
        let harness = WindowSwitcherDirectEntriesProviderHarness(entries: expectedEntries)
        let overlay = WindowSwitcherOverlayController()
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            overlayController: overlay,
            sessionEntriesProvider: { await harness.load() },
            accessibilityTrusted: { true }
        )
        plugin.store.setMode(.directCycle)
        defer {
            harness.release()
            plugin.deactivate(reason: .hostShutdown)
        }

        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .pressed
        )
        for _ in 0..<100 where !harness.didStart {
            await Task.yield()
        }
        XCTAssertTrue(harness.didStart)

        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .pressed
        )
        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .pressed
        )
        harness.release()

        for _ in 0..<100 where !overlay.isVisible {
            await Task.yield()
        }
        XCTAssertTrue(overlay.isVisible)

        let entries = overlay.displayedEntries
        guard !entries.isEmpty,
              let selectedID = overlay.selectedEntryID else {
            return XCTFail("Expected the direct-cycle overlay to expose a selected entry.")
        }

        let initialIndex = WindowSwitcherPlugin.directSelectionIndex(
            startingAt: 0,
            advancingBy: 1,
            count: entries.count
        )
        let expectedIndex = WindowSwitcherPlugin.directSelectionIndex(
            startingAt: initialIndex,
            advancingBy: 2,
            count: entries.count
        )
        XCTAssertEqual(selectedID, entries[expectedIndex].id)
    }

    func testDirectCycleReleaseRechecksAccessibilityPermission() async {
        let entries = (0..<2).map { index in
            makeEntry(
                index: index,
                appName: "Permission test window " + String(index),
                bundleIdentifier: "com.example.window-switcher-permission-test-" + String(index)
            )
        }
        let harness = WindowSwitcherDirectEntriesProviderHarness(entries: entries)
        let overlay = WindowSwitcherOverlayController()
        let accessibility = WindowSwitcherAccessibilityHarness()
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            overlayController: overlay,
            sessionEntriesProvider: { await harness.load() },
            accessibilityTrusted: { accessibility.check() }
        )
        plugin.store.setMode(.directCycle)
        defer {
            harness.release()
            plugin.deactivate(reason: .hostShutdown)
        }

        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .pressed
        )
        for _ in 0..<100 where !harness.didStart {
            await Task.yield()
        }
        XCTAssertTrue(harness.didStart)
        harness.release()

        for _ in 0..<100 where !overlay.isVisible {
            await Task.yield()
        }
        XCTAssertTrue(overlay.isVisible)

        let checksBeforeRelease = accessibility.checkCount
        accessibility.isTrusted = false
        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .released
        )

        XCTAssertGreaterThan(accessibility.checkCount, checksBeforeRelease)
        XCTAssertFalse(overlay.isVisible)
        XCTAssertFalse(
            plugin.permissionState(for: WindowSwitcherConstants.accessibilityPermissionID).isGranted
        )
    }

    func testDirectCycleNewPressAfterPendingReleaseStartsANewGesture() async {
        let entries = (0..<3).map { index in
            makeEntry(
                index: index,
                appName: "Repress test window " + String(index),
                bundleIdentifier: "com.example.window-switcher-repress-test-" + String(index)
            )
        }
        let harness = WindowSwitcherDirectEntriesProviderHarness(entries: entries)
        let overlay = WindowSwitcherOverlayController()
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            overlayController: overlay,
            sessionEntriesProvider: { await harness.load() },
            accessibilityTrusted: { true }
        )
        plugin.store.setMode(.directCycle)
        defer {
            harness.release()
            plugin.deactivate(reason: .hostShutdown)
        }

        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .pressed
        )
        for _ in 0..<100 where !harness.didStart {
            await Task.yield()
        }
        XCTAssertTrue(harness.didStart)

        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .released
        )
        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .pressed
        )
        harness.release()

        for _ in 0..<100 where !overlay.isVisible {
            await Task.yield()
        }
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.selectedEntryID, entries[1].id)
    }

    func testDirectCycleReversedRepressUsesOneInitialStep() async {
        let entries = (0..<3).map { index in
            makeEntry(
                index: index,
                appName: "Reverse repress test window " + String(index),
                bundleIdentifier: "com.example.window-switcher-reverse-repress-test-" + String(index)
            )
        }
        let harness = WindowSwitcherDirectEntriesProviderHarness(entries: entries)
        let overlay = WindowSwitcherOverlayController()
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            overlayController: overlay,
            sessionEntriesProvider: { await harness.load() },
            accessibilityTrusted: { true }
        )
        plugin.store.setMode(.directCycle)
        defer {
            harness.release()
            plugin.deactivate(reason: .hostShutdown)
        }

        plugin.handleShortcutPressed(reversed: false, isRepeat: false)
        for _ in 0..<100 where !harness.didStart {
            await Task.yield()
        }
        XCTAssertTrue(harness.didStart)

        plugin.handleShortcutEvent(
            id: WindowSwitcherConstants.shortcutActionID,
            phase: .released
        )
        plugin.handleShortcutPressed(reversed: true, isRepeat: false)
        harness.release()

        for _ in 0..<100 where !overlay.isVisible {
            await Task.yield()
        }
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.selectedEntryID, entries[2].id)
    }

    func testShortcutTapReportsAccessibilityRevocationToPlugin() async throws {
        let accessibility = WindowSwitcherAccessibilityHarness()
        let tapDefaults = try XCTUnwrap(
            UserDefaults(suiteName: "WindowSwitcherPluginTests-tap-" + UUID().uuidString)
        )
        let tap = WindowSwitcherShortcutTap(
            userDefaults: tapDefaults,
            accessibilityTrusted: { accessibility.check() }
        )
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            shortcutTap: tap,
            accessibilityTrusted: { accessibility.check() }
        )

        accessibility.isTrusted = false
        let event = try XCTUnwrap(CGEvent(source: nil))
        _ = tap.handle(type: .keyDown, event: event)

        for _ in 0..<100 where plugin.permissionState(
            for: WindowSwitcherConstants.accessibilityPermissionID
        ).isGranted {
            await Task.yield()
        }

        XCTAssertGreaterThan(accessibility.checkCount, 0)
        XCTAssertFalse(
            plugin.permissionState(for: WindowSwitcherConstants.accessibilityPermissionID).isGranted
        )
    }

    func testShortcutTapReportsAccessibilityRevocationWhenTapIsDisabled() async throws {
        let accessibility = WindowSwitcherAccessibilityHarness()
        let tapDefaults = try XCTUnwrap(
            UserDefaults(suiteName: "WindowSwitcherPluginTests-disabled-tap-" + UUID().uuidString)
        )
        let tap = WindowSwitcherShortcutTap(
            userDefaults: tapDefaults,
            accessibilityTrusted: { accessibility.check() }
        )
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            shortcutTap: tap,
            accessibilityTrusted: { accessibility.check() }
        )

        accessibility.isTrusted = false
        let event = try XCTUnwrap(CGEvent(source: nil))
        _ = tap.handle(type: .tapDisabledByTimeout, event: event)

        for _ in 0..<100 where plugin.permissionState(
            for: WindowSwitcherConstants.accessibilityPermissionID
        ).isGranted {
            await Task.yield()
        }

        XCTAssertGreaterThan(accessibility.checkCount, 0)
        XCTAssertFalse(
            plugin.permissionState(for: WindowSwitcherConstants.accessibilityPermissionID).isGranted
        )
    }

    func testWindowRecordsKeepInactiveSpaceAndSameApplicationWindowsDistinct() {
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 101,
                ownerPID: 321,
                title: "Finder — Space 1",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
            ),
            windowInfo(
                number: 102,
                ownerPID: 321,
                title: "Finder — Space 2",
                isOnscreen: false,
                bounds: CGRect(x: 40, y: 60, width: 900, height: 700)
            ),
        ])

        XCTAssertEqual(records.map(\.windowNumber), [101, 102])
        XCTAssertEqual(records.map(\.processIdentifier), [321, 321])
        XCTAssertEqual(records.map(\.title), ["Finder — Space 1", "Finder — Space 2"])
        XCTAssertEqual(records.map(\.isOnScreen), [true, false])
    }

    func testAllSpaceRecordsPreferAXMetadataAndKeepCoreGraphicsWindows() {
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 301,
                ownerPID: 321,
                title: "Shared title",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
            ),
            windowInfo(
                number: 302,
                ownerPID: 321,
                title: "Inactive Space window",
                isOnscreen: false,
                bounds: CGRect(x: 40, y: 60, width: 900, height: 700)
            ),
        ])
        let axSnapshot = WindowSwitcherWindowSnapshot(
            element: nil,
            windowNumber: nil,
            title: "Shared title",
            isMinimized: true,
            position: CGPoint(x: 20, y: 40),
            size: CGSize(width: 900, height: 700)
        )

        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axSnapshot],
            records: records
        )

        XCTAssertEqual(merged.map(\.windowNumber), [301, 302])
        XCTAssertEqual(merged.map(\.title), ["Shared title", "Inactive Space window"])
        XCTAssertTrue(merged[0].isMinimized)
        XCTAssertNil(merged[1].element)

        let entries = WindowSwitcherAppCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.example.Finder",
            appName: "Finder",
            icon: nil,
            windows: merged
        )
        XCTAssertEqual(entries.map(\.id), ["window:321:cg:301", "window:321:cg:302"])
        XCTAssertTrue(entries.allSatisfy(\.isWindowEntry))

        let mixedEntries = WindowSwitcherAppCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.example.Finder",
            appName: "Finder",
            icon: nil,
            windows: [
                merged[0],
                WindowSwitcherWindowSnapshot(
                    element: nil,
                    windowNumber: nil,
                    title: "AX-only window",
                    isMinimized: false,
                    position: CGPoint(x: 60, y: 80),
                    size: CGSize(width: 900, height: 700)
                ),
            ]
        )
        XCTAssertEqual(mixedEntries.map(\.id), ["window:321:cg:301", "window:321:ax:1"])
        XCTAssertEqual(Set(mixedEntries.map(\.id)).count, mixedEntries.count)

        let applicationEntry = WindowSwitcherAppCatalog.applicationEntry(
            id: "bundle:com.example.Finder",
            processIdentifier: 321,
            bundleIdentifier: "com.example.Finder",
            appName: "Finder",
            icon: nil
        )
        XCTAssertFalse(applicationEntry.isWindowEntry)
        XCTAssertEqual(applicationEntry.displayName, "Finder")
    }

    func testAllSpaceMergeUsesUniqueGeometryWhenCoreGraphicsTitleIsMissing() {
        var titlelessRecord = windowInfo(
            number: 303,
            ownerPID: 321,
            title: "",
            isOnscreen: true,
            bounds: CGRect(x: 80, y: 100, width: 900, height: 700)
        )
        titlelessRecord.removeValue(forKey: kCGWindowName as String)

        let axWindow = WindowSwitcherWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            windowNumber: nil,
            title: "Window title from AX",
            isMinimized: false,
            position: CGPoint(x: 80, y: 100),
            size: CGSize(width: 900, height: 700)
        )
        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axWindow],
            records: WindowSwitcherWindowRecord.parse([titlelessRecord])
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.windowNumber, 303)
        XCTAssertEqual(merged.first?.title, "Window title from AX")
        XCTAssertNotNil(merged.first?.element)
    }

    func testAllSpaceMergePrioritizesExactTitleBeforeGeometryFallback() {
        let bounds = CGRect(x: 100, y: 120, width: 900, height: 700)
        var titlelessRecord = windowInfo(
            number: 309,
            ownerPID: 321,
            title: "",
            isOnscreen: true,
            bounds: bounds
        )
        titlelessRecord.removeValue(forKey: kCGWindowName as String)
        let exactRecord = windowInfo(
            number: 310,
            ownerPID: 321,
            title: "Exact title",
            isOnscreen: true,
            bounds: bounds
        )
        let records = WindowSwitcherWindowRecord.parse([titlelessRecord, exactRecord])
        let axWindow = WindowSwitcherWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            windowNumber: nil,
            title: "Exact title",
            isMinimized: false,
            position: bounds.origin,
            size: bounds.size
        )

        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axWindow],
            records: records
        )
        let reversed = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axWindow],
            records: Array(records.reversed())
        )

        XCTAssertNil(merged[0].element)
        XCTAssertNotNil(merged[1].element)
        XCTAssertNotNil(reversed[0].element)
        XCTAssertNil(reversed[1].element)
    }

    func testAllSpaceMergeUsesOnScreenRecordWhenMetadataIsOtherwiseAmbiguous() {
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 304,
                ownerPID: 321,
                title: "Duplicate title",
                isOnscreen: false,
                bounds: bounds
            ),
            windowInfo(
                number: 305,
                ownerPID: 321,
                title: "Duplicate title",
                isOnscreen: true,
                bounds: bounds
            ),
        ])
        let axWindow = WindowSwitcherWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            windowNumber: nil,
            title: "Duplicate title",
            isMinimized: false,
            position: bounds.origin,
            size: bounds.size
        )

        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axWindow],
            records: records
        )

        XCTAssertEqual(merged.map(\.windowNumber), [304, 305])
        XCTAssertNil(merged[0].element)
        XCTAssertNotNil(merged[1].element)

        let reversed = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axWindow],
            records: Array(records.reversed())
        )

        XCTAssertEqual(reversed.map(\.windowNumber), [305, 304])
        XCTAssertNotNil(reversed[0].element)
        XCTAssertNil(reversed[1].element)
    }

    func testAllSpaceMergeDoesNotGuessWhenOnScreenMetadataIsUnknown() {
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        var unknownRecord = windowInfo(
            number: 306,
            ownerPID: 321,
            title: "Duplicate title",
            isOnscreen: false,
            bounds: bounds
        )
        unknownRecord.removeValue(forKey: kCGWindowIsOnscreen as String)
        let records = WindowSwitcherWindowRecord.parse([
            unknownRecord,
            windowInfo(
                number: 307,
                ownerPID: 321,
                title: "Duplicate title",
                isOnscreen: true,
                bounds: bounds
            ),
        ])
        let axWindow = WindowSwitcherWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            windowNumber: nil,
            title: "Duplicate title",
            isMinimized: false,
            position: bounds.origin,
            size: bounds.size
        )

        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: [axWindow],
            records: records
        )

        XCTAssertNil(records[0].isOnScreen)
        XCTAssertEqual(merged.map(\.windowNumber), [306, 307])
        XCTAssertNil(merged[0].element)
        XCTAssertNotNil(merged[1].element)

        var malformedRecord = windowInfo(
            number: 308,
            ownerPID: 321,
            title: "Malformed on-screen value",
            isOnscreen: false,
            bounds: bounds
        )
        malformedRecord[kCGWindowIsOnscreen as String] = NSNumber(value: 1)
        let malformed = WindowSwitcherWindowRecord.parse([malformedRecord])
        XCTAssertNil(malformed.first?.isOnScreen)
    }

    func testAllSpaceMergePreservesAXOnlyWindowsWhenAXHasMoreCandidates() {
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 311,
                ownerPID: 321,
                title: "Duplicate title",
                isOnscreen: false,
                bounds: bounds
            ),
        ])
        let axWindows = [
            WindowSwitcherWindowSnapshot(
                element: AXUIElementCreateSystemWide(),
                windowNumber: nil,
                title: "Duplicate title",
                isMinimized: false,
                position: bounds.origin,
                size: bounds.size
            ),
            WindowSwitcherWindowSnapshot(
                element: AXUIElementCreateApplication(1),
                windowNumber: nil,
                title: "Duplicate title",
                isMinimized: true,
                position: bounds.origin,
                size: bounds.size
            ),
        ]

        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: axWindows,
            records: records
        )
        let reversed = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: Array(axWindows.reversed()),
            records: records
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.filter { $0.windowNumber != nil }.count, 1)
        XCTAssertEqual(merged.filter { $0.element != nil }.count, 1)
        XCTAssertEqual(reversed.count, 2)
        XCTAssertEqual(reversed.filter { $0.windowNumber != nil }.count, 1)
        XCTAssertEqual(reversed.filter { $0.element != nil }.count, 1)
    }

    func testAllSpaceMergePreservesDistinctAXOnlyTitleWithSharedBounds() {
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 314,
                ownerPID: 321,
                title: "First title",
                isOnscreen: false,
                bounds: bounds
            ),
            windowInfo(
                number: 315,
                ownerPID: 321,
                title: "Second title",
                isOnscreen: false,
                bounds: bounds
            ),
        ])
        let axSnapshots = [
            WindowSwitcherWindowSnapshot(
                element: AXUIElementCreateSystemWide(),
                windowNumber: nil,
                title: "First title",
                isMinimized: false,
                position: bounds.origin,
                size: bounds.size
            ),
            WindowSwitcherWindowSnapshot(
                element: AXUIElementCreateApplication(1),
                windowNumber: nil,
                title: "AX-only title",
                isMinimized: false,
                position: bounds.origin,
                size: bounds.size
            ),
        ]

        let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
            axSnapshots: axSnapshots,
            records: records
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map(\.title), ["First title", "Second title", "AX-only title"])
        XCTAssertEqual(merged.filter { $0.element != nil }.count, 2)
        XCTAssertNil(merged[1].element)
    }

    func testAllSpaceMergeMatchesResidualGeometryAfterExactTitleMatch() {
        let bounds = CGRect(x: 120, y: 140, width: 900, height: 700)
        var titlelessRecord = windowInfo(
            number: 312,
            ownerPID: 321,
            title: "",
            isOnscreen: true,
            bounds: bounds
        )
        titlelessRecord.removeValue(forKey: kCGWindowName as String)
        let exactRecord = windowInfo(
            number: 313,
            ownerPID: 321,
            title: "Exact title",
            isOnscreen: true,
            bounds: bounds
        )
        let records = WindowSwitcherWindowRecord.parse([titlelessRecord, exactRecord])
        let axSnapshots = [
            WindowSwitcherWindowSnapshot(
                element: AXUIElementCreateSystemWide(),
                windowNumber: nil,
                title: "Exact title",
                isMinimized: false,
                position: bounds.origin,
                size: bounds.size
            ),
            WindowSwitcherWindowSnapshot(
                element: AXUIElementCreateApplication(1),
                windowNumber: nil,
                title: "Residual title",
                isMinimized: true,
                position: bounds.origin,
                size: bounds.size
            ),
        ]

        for (candidateRecords, candidates) in [
            (records, axSnapshots),
            (Array(records.reversed()), Array(axSnapshots.reversed())),
        ] {
            let merged = WindowSwitcherAppCatalog.mergeWindowSnapshots(
                axSnapshots: candidates,
                records: candidateRecords
            )

            XCTAssertEqual(merged.count, 2)
            let exact = merged.first { $0.windowNumber == 313 }
            let residual = merged.first { $0.windowNumber == 312 }
            XCTAssertEqual(exact?.title, "Exact title")
            XCTAssertNotNil(exact?.element)
            XCTAssertEqual(residual?.title, "Residual title")
            XCTAssertTrue(residual?.isMinimized == true)
            XCTAssertNotNil(residual?.element)
        }
    }

    func testAXTimeoutIsCappedByRemainingGlobalBudget() throws {
        XCTAssertEqual(
            try XCTUnwrap(WindowSwitcherAppCatalog.axTimeout(forRemaining: 0.5)),
            0.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(WindowSwitcherAppCatalog.axTimeout(forRemaining: 0.05)),
            0.05,
            accuracy: 0.0001
        )
        XCTAssertNil(WindowSwitcherAppCatalog.axTimeout(forRemaining: 0))
        XCTAssertNil(WindowSwitcherAppCatalog.axTimeout(forRemaining: -0.1))
    }

    func testAXSessionBudgetAllocatesADeadlineToEveryApplication() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sessionDeadline = now.addingTimeInterval(1)

        let firstDeadline = WindowSwitcherAppCatalog.axDeadline(
            sessionDeadline: sessionDeadline,
            appIndex: 0,
            appCount: 2,
            now: now
        )
        let secondDeadline = WindowSwitcherAppCatalog.axDeadline(
            sessionDeadline: sessionDeadline,
            appIndex: 1,
            appCount: 2,
            now: now.addingTimeInterval(0.5)
        )

        XCTAssertEqual(firstDeadline.timeIntervalSince(now), 0.5, accuracy: 0.0001)
        XCTAssertEqual(secondDeadline, sessionDeadline)
    }

    func testAXFallbackLookupStopsWhenItsDeadlineIsReached() {
        let candidate = AXUIElementCreateSystemWide()
        let snapshot = WindowSwitcherWindowSnapshot(
            element: candidate,
            windowNumber: nil,
            title: "different title",
            isMinimized: false,
            position: CGPoint(x: 80, y: 100),
            size: CGSize(width: 900, height: 700)
        )
        let deadline = Date(timeIntervalSince1970: 10)
        var nowCallCount = 0
        var snapshotCallCount = 0

        let result = WindowSwitcherAppCatalog.firstMatchingWindow(
            in: [candidate, candidate],
            title: "requested title",
            bounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            deadline: deadline,
            now: {
                nowCallCount += 1
                return nowCallCount == 1
                    ? Date(timeIntervalSince1970: 9)
                    : Date(timeIntervalSince1970: 11)
            },
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return snapshot
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(snapshotCallCount, 1)
    }

    func testAXFallbackLookupPreservesMinimizedState() {
        let candidate = AXUIElementCreateSystemWide()
        let snapshot = WindowSwitcherWindowSnapshot(
            element: candidate,
            windowNumber: nil,
            title: "requested title",
            isMinimized: true,
            position: CGPoint(x: 80, y: 100),
            size: CGSize(width: 900, height: 700)
        )

        let result = WindowSwitcherAppCatalog.firstMatchingWindow(
            in: [candidate],
            title: "requested title",
            bounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            deadline: Date().addingTimeInterval(1),
            now: { Date() },
            snapshotProvider: { _ in snapshot }
        )

        XCTAssertTrue(result?.isMinimized == true)
        XCTAssertNotNil(result?.element)
    }

    func testAXFallbackLookupRejectsAmbiguousMatches() {
        let candidate = AXUIElementCreateSystemWide()
        let snapshot = WindowSwitcherWindowSnapshot(
            element: candidate,
            windowNumber: nil,
            title: "requested title",
            isMinimized: false,
            position: CGPoint(x: 80, y: 100),
            size: CGSize(width: 900, height: 700)
        )
        var snapshotCallCount = 0

        let result = WindowSwitcherAppCatalog.firstMatchingWindow(
            in: [candidate, candidate],
            title: "requested title",
            bounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            deadline: Date().addingTimeInterval(1),
            now: { Date() },
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return snapshot
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(snapshotCallCount, 2)
    }

    func testActivationFallbackUsesCurrentAXMinimizedState() async {
        let processIdentifier: pid_t = 321
        let launchDate = Date(timeIntervalSince1970: 3_000)
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        let windowElement = AXUIElementCreateSystemWide()
        let snapshot = WindowSwitcherWindowSnapshot(
            element: windowElement,
            windowNumber: nil,
            title: "Restored title",
            isMinimized: true,
            position: bounds.origin,
            size: bounds.size
        )
        var focusedMinimizedStates: [Bool] = []
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: {
                [
                    WindowSwitcherWindowRecord(
                        windowNumber: 701,
                        processIdentifier: processIdentifier,
                        title: "Restored title",
                        isOnScreen: true,
                        bounds: bounds
                    ),
                ]
            },
            applicationProvider: { _ in application },
            activationWindowSnapshotProvider: { _, _ in snapshot },
            focusWindowHandler: { focusedWindow, isMinimized in
                XCTAssertTrue(CFEqual(focusedWindow, windowElement))
                focusedMinimizedStates.append(isMinimized)
            }
        )
        let entry = WindowSwitcherAppEntry(
            id: "window:321:cg:701",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "Restored title",
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: 701,
            windowBounds: bounds,
            applicationLaunchDate: launchDate,
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 1)
        XCTAssertEqual(application.activationOptions, [.activateAllWindows])
        XCTAssertEqual(focusedMinimizedStates, [true])
    }

    func testActivationFallbackLeavesCGOnlyEntryUnfocusedWhenAXLookupFindsNoMatch() async {
        let processIdentifier: pid_t = 322
        let launchDate = Date(timeIntervalSince1970: 3_001)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        var focusCount = 0
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: {
                [
                    WindowSwitcherWindowRecord(
                        windowNumber: 702,
                        processIdentifier: processIdentifier,
                        title: "Unavailable title",
                        isOnScreen: true,
                        bounds: CGRect(x: 80, y: 100, width: 900, height: 700)
                    ),
                ]
            },
            applicationProvider: { _ in application },
            activationWindowSnapshotProvider: { _, _ in nil },
            focusWindowHandler: { _, _ in
                focusCount += 1
            }
        )
        let entry = WindowSwitcherAppEntry(
            id: "window:322:cg:702",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "Unavailable title",
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: 702,
            windowBounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            applicationLaunchDate: launchDate,
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.activationOptions, [.activateAllWindows])
        XCTAssertEqual(focusCount, 0)
    }

    func testActivationAXBackedEntryDoesNotRequireUnchangedCoreGraphicsBounds() async {
        let processIdentifier: pid_t = 325
        let launchDate = Date(timeIntervalSince1970: 3_003)
        let expectedBounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        let windowElement = AXUIElementCreateSystemWide()
        var focusedMinimizedStates: [Bool] = []
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: {
                [
                    WindowSwitcherWindowRecord(
                        windowNumber: 704,
                        processIdentifier: processIdentifier,
                        title: "Moved title",
                        isOnScreen: true,
                        bounds: CGRect(x: 90, y: 110, width: 900, height: 700)
                    ),
                ]
            },
            applicationProvider: { _ in application },
            focusWindowHandler: { focusedWindow, isMinimized in
                XCTAssertTrue(CFEqual(focusedWindow, windowElement))
                focusedMinimizedStates.append(isMinimized)
            }
        )
        let entry = WindowSwitcherAppEntry(
            id: "window:325:cg:704",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "Moved title",
            icon: nil,
            windowElement: windowElement,
            isMinimized: true,
            windowNumber: 704,
            windowBounds: expectedBounds,
            applicationLaunchDate: launchDate,
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 1)
        XCTAssertEqual(application.activationOptions, [])
        XCTAssertEqual(focusedMinimizedStates, [true])
    }

    func testActivationRejectsAReusedProcessBeforeAnyApplicationSideEffect() async {
        let processIdentifier: pid_t = 323
        let currentLaunchDate = Date(timeIntervalSince1970: 2_000)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: currentLaunchDate
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { [] },
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppEntry(
            id: "app:323",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: nil,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: nil,
            windowBounds: nil,
            applicationLaunchDate: currentLaunchDate.addingTimeInterval(-1),
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testActivationAllowsApplicationWhenLaunchDateIsUnavailable() async {
        let processIdentifier: pid_t = 327
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: nil
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppCatalog.applicationEntry(
            id: "app:327",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            icon: nil,
            applicationLaunchDate: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 1)
        XCTAssertEqual(application.activationOptions, [])
    }

    func testActivationAllowsApplicationWhenCurrentLaunchDateIsUnavailable() async {
        let processIdentifier: pid_t = 328
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: nil
        )
        let entry = WindowSwitcherAppCatalog.applicationEntry(
            id: "app:328",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            icon: nil,
            applicationLaunchDate: Date(timeIntervalSince1970: 3_004)
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            applicationProvider: { _ in application }
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 1)
        XCTAssertEqual(application.activationOptions, [])
    }

    func testActivationAllowsApplicationWhenEntryLaunchDateIsUnavailable() async {
        let processIdentifier: pid_t = 329
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: Date(timeIntervalSince1970: 3_005)
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppCatalog.applicationEntry(
            id: "app:329",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            icon: nil,
            applicationLaunchDate: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 1)
        XCTAssertEqual(application.activationOptions, [])
    }

    func testCancelledApplicationActivationDoesNotPerformSideEffects() async {
        let processIdentifier: pid_t = 330
        let application = WindowSwitcherApplicationHarness(processIdentifier: processIdentifier)
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppCatalog.applicationEntry(
            id: "app:330",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            icon: nil
        )
        let task = Task { @MainActor in
            await Task.yield()
            await catalog.activate(entry)
        }

        task.cancel()
        await task.value

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testCancelledAXActivationDoesNotPerformSideEffects() async {
        let processIdentifier: pid_t = 331
        let application = WindowSwitcherApplicationHarness(processIdentifier: processIdentifier)
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppEntry(
            id: "window:331:ax:0",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "AX window",
            icon: nil,
            windowElement: AXUIElementCreateSystemWide(),
            isMinimized: false,
            windowNumber: nil,
            windowBounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            shortcutToken: nil
        )
        let task = Task { @MainActor in
            await Task.yield()
            await catalog.activate(entry)
        }

        task.cancel()
        await task.value

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testActivationRejectsStaleCoreGraphicsWindowBeforeUnhiding() async {
        let processIdentifier: pid_t = 324
        let launchDate = Date(timeIntervalSince1970: 3_002)
        let expectedBounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: {
                [
                    WindowSwitcherWindowRecord(
                        windowNumber: 703,
                        processIdentifier: processIdentifier,
                        title: "Current title",
                        isOnScreen: true,
                        bounds: CGRect(x: 90, y: 110, width: 900, height: 700)
                    ),
                ]
            },
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppEntry(
            id: "window:324:cg:703",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "Current title",
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: 703,
            windowBounds: expectedBounds,
            applicationLaunchDate: launchDate,
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testActivationRejectsCachedCoreGraphicsWindowAfterRefreshTimeout() async {
        let processIdentifier: pid_t = 326
        let launchDate = Date(timeIntervalSince1970: 3_004)
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let record = WindowSwitcherWindowRecord(
            windowNumber: 705,
            processIdentifier: processIdentifier,
            title: "Cached title",
            isOnScreen: true,
            bounds: bounds
        )
        let harness = WindowSwitcherActivationRecordProviderHarness(initialRecords: [record])
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        let catalog = WindowSwitcherAppCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { harness.records() },
            windowRecordRefreshTimeout: 0.01,
            applicationProvider: { _ in application }
        )
        defer {
            harness.releaseSecondInvocation.signal()
            catalog.stop()
        }

        let initialSnapshot = await catalog.windowRecordsSnapshot()
        XCTAssertEqual(initialSnapshot.map(\.windowNumber), [705])
        let entry = WindowSwitcherAppEntry(
            id: "window:326:cg:705",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "Cached title",
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: 705,
            windowBounds: bounds,
            applicationLaunchDate: launchDate,
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testWindowRecordsIgnoreNonSwitchableOrTransparentWindows() {
        var missingAlpha = windowInfo(
            number: 204,
            ownerPID: 321,
            title: "Missing alpha",
            isOnscreen: true,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        missingAlpha.removeValue(forKey: kCGWindowAlpha as String)
        var booleanNumber = windowInfo(
            number: 205,
            ownerPID: 321,
            title: "Boolean number",
            isOnscreen: true,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        booleanNumber[kCGWindowNumber as String] = true
        let nonFiniteBounds = windowInfo(
            number: 206,
            ownerPID: 321,
            title: "Non-finite bounds",
            isOnscreen: true,
            bounds: CGRect(x: CGFloat.infinity, y: 40, width: 900, height: 700)
        )

        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 201,
                ownerPID: 321,
                title: "Too small",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 79, height: 60)
            ),
            windowInfo(
                number: 202,
                ownerPID: 321,
                title: "Transparent",
                isOnscreen: false,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700),
                alpha: 0
            ),
            windowInfo(
                number: 203,
                ownerPID: 321,
                title: "Menu",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700),
                layer: 1
            ),
            missingAlpha,
            booleanNumber,
            nonFiniteBounds,
        ])

        XCTAssertTrue(records.isEmpty)
    }

    func testWindowRecordParserRejectsMalformedRequiredMetadataIndividually() {
        let valid = windowInfo(
            number: 250,
            ownerPID: 321,
            title: "Valid",
            isOnscreen: true,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        XCTAssertEqual(WindowSwitcherWindowRecord.parse([valid]).count, 1)

        var missingNumber = valid
        missingNumber.removeValue(forKey: kCGWindowNumber as String)
        var fractionalNumber = valid
        fractionalNumber[kCGWindowNumber as String] = 250.5
        var missingOwner = valid
        missingOwner.removeValue(forKey: kCGWindowOwnerPID as String)
        var booleanOwner = valid
        booleanOwner[kCGWindowOwnerPID as String] = true
        var fractionalOwner = valid
        fractionalOwner[kCGWindowOwnerPID as String] = 321.5
        var missingLayer = valid
        missingLayer.removeValue(forKey: kCGWindowLayer as String)
        var booleanLayer = valid
        booleanLayer[kCGWindowLayer as String] = false
        var fractionalLayer = valid
        fractionalLayer[kCGWindowLayer as String] = 0.5
        var missingAlpha = valid
        missingAlpha.removeValue(forKey: kCGWindowAlpha as String)
        var booleanAlpha = valid
        booleanAlpha[kCGWindowAlpha as String] = true
        var nonFiniteAlpha = valid
        nonFiniteAlpha[kCGWindowAlpha as String] = NSNumber(value: Double.nan)
        var outOfRangeAlpha = valid
        outOfRangeAlpha[kCGWindowAlpha as String] = 1.1
        var missingBounds = valid
        missingBounds.removeValue(forKey: kCGWindowBounds as String)
        var malformedBounds = valid
        malformedBounds[kCGWindowBounds as String] = NSNull()

        let malformedCases = [
            ("missing window number", missingNumber),
            ("fractional window number", fractionalNumber),
            ("missing owner PID", missingOwner),
            ("boolean owner PID", booleanOwner),
            ("fractional owner PID", fractionalOwner),
            ("missing layer", missingLayer),
            ("boolean layer", booleanLayer),
            ("fractional layer", fractionalLayer),
            ("missing alpha", missingAlpha),
            ("boolean alpha", booleanAlpha),
            ("non-finite alpha", nonFiniteAlpha),
            ("out-of-range alpha", outOfRangeAlpha),
            ("missing bounds", missingBounds),
            ("malformed bounds", malformedBounds),
        ]

        for (label, item) in malformedCases {
            XCTAssertTrue(
                WindowSwitcherWindowRecord.parse([item]).isEmpty,
                "Expected \(label) to be rejected."
            )
        }
    }

    func testWindowRecordParserKeepsAllEligibleWindowsForOneApplication() {
        let records = (0..<65).map { index in
            windowInfo(
                number: 1_000 + index,
                ownerPID: 321,
                title: "Window (index)",
                isOnscreen: index == 0,
                bounds: CGRect(x: CGFloat(index), y: 40, width: 900, height: 700)
            )
        }

        XCTAssertEqual(WindowSwitcherWindowRecord.parse(records).count, 65)
    }

    func testWindowEntryIsWindowWhenOnlySystemWindowNumberIsAvailable() {
        let entry = WindowSwitcherAppEntry(
            id: "window:321:102",
            processIdentifier: 321,
            bundleIdentifier: "com.apple.finder",
            appName: "Finder",
            windowTitle: "Finder — Space 2",
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: 102,
            windowBounds: CGRect(x: 40, y: 60, width: 900, height: 700),
            shortcutToken: nil
        )

        XCTAssertTrue(entry.isWindowEntry)
        XCTAssertEqual(entry.displayName, "Finder — Space 2")
    }

    func testModePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setMode(.directCycle)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(loaded.configuration.mode, .directCycle)
    }

    func testSortModePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setSortMode(.fixed)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(loaded.configuration.sortMode, .fixed)
    }

    func testLegacyConfigurationDefaultsToEnabled() throws {
        let storage = WindowSwitcherMemoryStorage()
        let data = try XCTUnwrap(#"{"mode":"directCycle"}"#.data(using: .utf8))
        storage.set(data, forKey: "configuration")

        let store = WindowSwitcherStore(storage: storage)

        XCTAssertTrue(store.configuration.isEnabled)
        XCTAssertEqual(store.configuration.mode, .directCycle)
        XCTAssertEqual(store.configuration.sortMode, .recentUse)
    }

    func testEnabledStatePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setEnabled(false)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertFalse(loaded.configuration.isEnabled)
    }

    func testObsoleteShortcutAssignmentsAreDiscarded() throws {
        let storage = WindowSwitcherMemoryStorage()
        storage.set(
            try JSONEncoder().encode(["bundle:com.apple.Safari": "s"]),
            forKey: "shortcut-assignments"
        )

        let store = WindowSwitcherStore(storage: storage)

        XCTAssertEqual(store.shortcutBindings.manual, [:])
        XCTAssertEqual(store.shortcutBindings.automatic, [:])
        XCTAssertNil(storage.data(forKey: "shortcut-assignments"))
        XCTAssertNil(storage.data(forKey: "shortcut-bindings"))
    }

    func testShortcutAssignmentUsesLettersThenDigitsThenCommandKeys() {
        let entries = (0..<73).map { index in
            makeEntry(index: index, appName: "\(index)")
        }

        let assigned = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries)

        XCTAssertEqual(assigned[0].shortcutToken, "f")
        XCTAssertEqual(assigned[1].shortcutToken, "j")
        XCTAssertEqual(assigned[25].shortcutToken, "y")
        XCTAssertEqual(assigned[26].shortcutToken, "1")
        XCTAssertEqual(assigned[35].shortcutToken, "0")
        XCTAssertEqual(assigned[36].shortcutToken, "cmd+f")
        XCTAssertEqual(assigned[71].shortcutToken, "cmd+0")
        XCTAssertNil(assigned[72].shortcutToken)
    }

    func testShortcutAssignmentPrefersApplicationInitials() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ]

        let assigned = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries)

        XCTAssertEqual(assigned[0].shortcutToken, "s")
        XCTAssertEqual(assigned[1].shortcutToken, "f")
    }

    func testShortcutAssignmentKeepsStoredTokensAcrossOrderChanges() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
        ]
        let first = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: WindowSwitcherShortcutBindingState()
        )
        let reordered = [
            makeEntry(index: 1, appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ]

        let second = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: reordered,
            bindingState: first.bindingState
        )

        XCTAssertEqual(first.entries[0].shortcutToken, "s")
        XCTAssertEqual(first.entries[1].shortcutToken, "f")
        XCTAssertEqual(second.entries[0].shortcutToken, "f")
        XCTAssertEqual(second.entries[1].shortcutToken, "s")
    }

    func testManualShortcutTakesPriorityOverConflictingAutomaticShortcut() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ]
        let state = WindowSwitcherShortcutBindingState(
            manual: ["bundle:com.apple.Safari": "f"],
            automatic: ["bundle:com.apple.finder": "f"]
        )

        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: state
        )

        XCTAssertEqual(result.entries[0].shortcutToken, "f")
        XCTAssertEqual(result.entries[1].shortcutToken, "j")
        XCTAssertEqual(result.bindingState.manual["bundle:com.apple.Safari"], "f")
        XCTAssertEqual(result.bindingState.automatic["bundle:com.apple.finder"], "j")
    }

    func testManualShortcutRejectsConflictWithRunningEntry() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ])
        let finderToken = entries[1].shortcutToken
        let bindingsBeforeConflict = store.shortcutBindings

        let result = store.setManualShortcut(finderToken, for: entries[0].id, in: entries)

        guard case .conflict = result else {
            return XCTFail("Expected an active shortcut conflict.")
        }
        XCTAssertEqual(store.shortcutBindings, bindingsBeforeConflict)
        XCTAssertEqual(store.assignShortcuts(to: entries), entries)
    }

    func testManualShortcutPersistsAndSurvivesSortingChanges() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ])

        let result = store.setManualShortcut("q", for: entries[0].id, in: entries)
        guard case let .updated(updatedEntries) = result else {
            return XCTFail("Expected a saved manual shortcut.")
        }

        XCTAssertEqual(updatedEntries[0].shortcutToken, "q")
        let loaded = WindowSwitcherStore(storage: storage)
        let reordered = loaded.assignShortcuts(to: [entries[1], entries[0]])
        XCTAssertEqual(reordered[0].shortcutToken, entries[1].shortcutToken)
        XCTAssertEqual(reordered[1].shortcutToken, "q")
        XCTAssertEqual(loaded.shortcutBindings.manual["bundle:com.apple.Safari"], "q")
    }

    func testManualShortcutRejectsMultiKeyAndUnsupportedInput() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])

        for invalidToken in ["ff", "f1", "s1", "cmd+ff", "cmd+-", "⌘a", "窗口"] {
            guard case .unavailable = store.setManualShortcut(
                invalidToken,
                for: entries[0].id,
                in: entries
            ) else {
                return XCTFail("Expected \(invalidToken) to be rejected.")
            }
        }
        XCTAssertTrue(store.shortcutBindings.manual.isEmpty)
    }

    func testClearingManualShortcutRestoresAutomaticShortcut() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])
        XCTAssertEqual(entries[0].shortcutToken, "s")
        guard case let .updated(customized) = store.setManualShortcut(
            "q",
            for: entries[0].id,
            in: entries
        ) else {
            return XCTFail("Expected a saved manual shortcut.")
        }

        let result = store.setManualShortcut(nil, for: customized[0].id, in: customized)

        guard case let .updated(restored) = result else {
            return XCTFail("Expected the manual shortcut to be cleared.")
        }
        XCTAssertEqual(restored[0].shortcutToken, "s")
        XCTAssertTrue(store.shortcutBindings.manual.isEmpty)
        XCTAssertEqual(store.shortcutBindings.automatic["bundle:com.apple.Safari"], "s")
    }

    func testMultiWindowEntriesUseDistinctPersistentBindingIdentities() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])

        let result = store.setManualShortcut("q", for: entries[1].id, in: entries)

        guard case let .updated(updated) = result else {
            return XCTFail("Expected a saved shortcut for the second window.")
        }
        XCTAssertEqual(updated[0].shortcutToken, "s")
        XCTAssertEqual(updated[1].shortcutToken, "q")
        XCTAssertEqual(
            store.shortcutBindings.manual["bundle:com.apple.Safari#window:2"],
            "q"
        )
    }

    func testLegacySingleWindowShortcutMigratesToStableAXIdentity() throws {
        let entry = try XCTUnwrap(
            WindowSwitcherAppCatalog.windowEntries(
                processIdentifier: 321,
                bundleIdentifier: "com.apple.Safari",
                appName: "Safari",
                icon: nil,
                windows: [
                    WindowSwitcherWindowSnapshot(
                        element: AXUIElementCreateSystemWide(),
                        windowNumber: nil,
                        title: "Only window",
                        isMinimized: false,
                        position: CGPoint(x: 80, y: 100),
                        size: CGSize(width: 900, height: 700)
                    ),
                ]
            ).first
        )
        let storage = WindowSwitcherMemoryStorage()
        let legacyState = WindowSwitcherShortcutBindingState(
            manual: ["bundle:com.apple.Safari": "q"]
        )
        storage.set(
            try JSONEncoder().encode(legacyState),
            forKey: "shortcut-bindings"
        )

        let store = WindowSwitcherStore(storage: storage)
        let assigned = store.assignShortcuts(to: [entry])

        XCTAssertEqual(assigned[0].shortcutToken, "q")
        XCTAssertEqual(
            store.shortcutBindings.manual["window:321:ax:\(entry.id)"],
            "q"
        )
        XCTAssertNil(store.shortcutBindings.manual["bundle:com.apple.Safari"])
    }

    func testAmbiguousLegacyFirstWindowShortcutCanBeExplicitlyReassigned() throws {
        let entries = WindowSwitcherAppCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            icon: nil,
            windows: [
                WindowSwitcherWindowSnapshot(
                    element: nil,
                    windowNumber: 401,
                    title: "First window",
                    isMinimized: false,
                    position: CGPoint(x: 80, y: 100),
                    size: CGSize(width: 900, height: 700)
                ),
                WindowSwitcherWindowSnapshot(
                    element: nil,
                    windowNumber: 402,
                    title: "Second window",
                    isMinimized: false,
                    position: CGPoint(x: 100, y: 120),
                    size: CGSize(width: 900, height: 700)
                ),
            ]
        )
        let storage = WindowSwitcherMemoryStorage()
        let legacyState = WindowSwitcherShortcutBindingState(
            manual: ["bundle:com.apple.Safari": "q"]
        )
        storage.set(
            try JSONEncoder().encode(legacyState),
            forKey: "shortcut-bindings"
        )

        let store = WindowSwitcherStore(storage: storage)
        let assigned = store.assignShortcuts(to: entries)
        XCTAssertFalse(assigned.contains { $0.shortcutToken == "q" })

        guard case let .updated(reassigned) = store.setManualShortcut(
            "q",
            for: entries[1].id,
            in: assigned
        ) else {
            return XCTFail("Expected explicit reassignment of the legacy shortcut.")
        }

        XCTAssertEqual(reassigned[1].shortcutToken, "q")
        XCTAssertEqual(store.shortcutBindings.manual["window:321:cg:402"], "q")
        XCTAssertEqual(store.shortcutBindings.manual["bundle:com.apple.Safari"], "q")
    }

    func testWindowShortcutIdentityUsesCoreGraphicsNumberAcrossSpaceInsertion() throws {
        let bounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let first = WindowSwitcherAppCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            icon: nil,
            windows: [
                WindowSwitcherWindowSnapshot(
                    element: AXUIElementCreateSystemWide(),
                    windowNumber: 401,
                    title: "First window",
                    isMinimized: false,
                    position: bounds.origin,
                    size: bounds.size
                ),
            ]
        )[0]
        let second = WindowSwitcherAppCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            icon: nil,
            windows: [
                WindowSwitcherWindowSnapshot(
                    element: AXUIElementCreateSystemWide(),
                    windowNumber: 402,
                    title: "Second window",
                    isMinimized: false,
                    position: CGPoint(x: 100, y: 120),
                    size: bounds.size
                ),
            ]
        )[0]
        let inactiveSpaceWindow = WindowSwitcherAppCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            icon: nil,
            windows: [
                WindowSwitcherWindowSnapshot(
                    element: nil,
                    windowNumber: 403,
                    title: "Inactive Space window",
                    isMinimized: false,
                    position: CGPoint(x: 120, y: 140),
                    size: bounds.size
                ),
            ]
        )[0]

        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        let initialEntries = store.assignShortcuts(to: [first, second])
        guard case .updated = store.setManualShortcut("q", for: second.id, in: initialEntries) else {
            return XCTFail("Expected a saved shortcut for the second window.")
        }

        let reorderedEntries = store.assignShortcuts(to: [inactiveSpaceWindow, first, second])
        XCTAssertEqual(reorderedEntries[2].shortcutToken, "q")
        XCTAssertEqual(store.shortcutBindings.manual["window:321:cg:402"], "q")

        let legacyStorage = WindowSwitcherMemoryStorage()
        let legacyState = WindowSwitcherShortcutBindingState(
            manual: ["bundle:com.apple.Safari#window:2": "q"]
        )
        legacyStorage.set(
            try JSONEncoder().encode(legacyState),
            forKey: "shortcut-bindings"
        )
        let migratedStore = WindowSwitcherStore(storage: legacyStorage)
        let migratedEntries = migratedStore.assignShortcuts(
            to: [inactiveSpaceWindow, first, second]
        )

        XCTAssertNotEqual(migratedEntries[2].shortcutToken, "q")
        XCTAssertNil(migratedStore.shortcutBindings.manual["window:321:cg:402"])
        XCTAssertEqual(
            migratedStore.shortcutBindings.manual["bundle:com.apple.Safari#window:2"],
            "q"
        )

        guard case let .updated(reassignedEntries) = migratedStore.setManualShortcut(
            "q",
            for: migratedEntries[2].id,
            in: migratedEntries
        ) else {
            return XCTFail("Expected explicit reassignment of the legacy shortcut.")
        }

        XCTAssertEqual(reassignedEntries[2].shortcutToken, "q")
        XCTAssertEqual(migratedStore.shortcutBindings.manual["window:321:cg:402"], "q")
        XCTAssertEqual(
            migratedStore.shortcutBindings.manual["bundle:com.apple.Safari#window:2"],
            "q"
        )
    }

    func testFocusStillRaisesWindowWhenFocusedAttributeIsReadOnly() {
        let window = AXUIElementCreateSystemWide()
        var writtenAttributes: [String] = []
        var didRaise = false

        WindowSwitcherAppCatalog.focusWindow(
            window,
            isMinimized: false,
            deadline: Date().addingTimeInterval(1),
            writeAttribute: { _, attribute, _, _ in
                writtenAttributes.append(attribute as String)
                return attribute as String != kAXFocusedAttribute as String
            },
            performRaise: { _, _ in
                didRaise = true
                return true
            }
        )

        XCTAssertEqual(
            writtenAttributes,
            [kAXMainAttribute as String, kAXFocusedAttribute as String]
        )
        XCTAssertTrue(didRaise)
    }

    func testRestartedApplicationReleasesExpiredWindowShortcutForReassignment() {
        let storage = WindowSwitcherMemoryStorage()
        let oldState = WindowSwitcherShortcutBindingState(
            manual: ["window:321:cg:401": "q"]
        )
        storage.set(try? JSONEncoder().encode(oldState), forKey: "shortcut-bindings")
        let store = WindowSwitcherStore(storage: storage, processIsRunning: { _ in false })
        let restartedEntry = makeWindowEntry(
            processIdentifier: 654,
            windowNumber: 501,
            title: "Restarted window"
        )
        let entries = store.assignShortcuts(to: [restartedEntry])

        guard case let .updated(reassigned) = store.setManualShortcut(
            "q",
            for: restartedEntry.id,
            in: entries
        ) else {
            return XCTFail("Expected the expired shortcut to be reassigned after restart.")
        }

        XCTAssertEqual(reassigned[0].shortcutToken, "q")
        XCTAssertNil(store.shortcutBindings.manual["window:321:cg:401"])
        XCTAssertEqual(store.shortcutBindings.manual["window:654:cg:501"], "q")
    }

    func testTemporarilyMissingWindowKeepsShortcutWhileProcessIsRunning() {
        let storage = WindowSwitcherMemoryStorage()
        let oldState = WindowSwitcherShortcutBindingState(
            manual: ["window:321:cg:401": "q"]
        )
        storage.set(try? JSONEncoder().encode(oldState), forKey: "shortcut-bindings")
        let store = WindowSwitcherStore(storage: storage, processIsRunning: { $0 == 321 })
        let visibleEntry = makeWindowEntry(
            processIdentifier: 654,
            windowNumber: 501,
            title: "Visible window"
        )
        let entries = store.assignShortcuts(to: [visibleEntry])

        XCTAssertTrue(store.hasShortcutConflict("q", for: visibleEntry.id, in: entries))
        XCTAssertEqual(store.shortcutBindings.manual["window:321:cg:401"], "q")
    }

    private func makeEntry(
        index: Int,
        appName: String,
        bundleIdentifier: String? = nil
    ) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: "app-\(index)",
            processIdentifier: pid_t(index + 100),
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: nil,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: nil,
            windowBounds: nil,
            shortcutToken: nil
        )
    }

    private func makeWindowEntry(
        processIdentifier: pid_t,
        windowNumber: CGWindowID,
        title: String
    ) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: "window-\(processIdentifier)-\(windowNumber)",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.WindowApp",
            appName: "Window App",
            windowTitle: title,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: windowNumber,
            windowBounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            shortcutToken: nil
        )
    }

    private func windowInfo(
        number: Int,
        ownerPID: Int,
        title: String,
        isOnscreen: Bool,
        bounds: CGRect,
        layer: Int = 0,
        alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: number,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowName as String: title,
            kCGWindowIsOnscreen as String: isOnscreen,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }
}
