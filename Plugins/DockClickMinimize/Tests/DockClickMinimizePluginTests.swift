import CoreGraphics
import Foundation
import MacToolsPluginKit
import XCTest
@testable import DockClickMinimizePlugin

@MainActor
final class DockClickMinimizePluginTests: XCTestCase {
    func testFirstLaunchIsEnabledAndStartsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext()
        let plugin = makePlugin(context: context, monitor: monitor)

        plugin.activate(context: context)

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(monitor.startCallCount, 1)
    }

    func testEnablingWithPermissionsStartsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext()
        let plugin = makePlugin(context: context, monitor: monitor)

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testDisablingStopsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)
        plugin.activate(context: context)

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testSettingsPageExposesPersistedEnableSwitch() {
        let plugin = makePlugin(context: makeContext(isEnabled: true))

        guard case let .form(sections) = plugin.settingsPage?.body,
              case let .rows(rows) = sections.first?.content,
              let row = rows.first,
              case let .toggle(isOn) = row.control
        else {
            return XCTFail("Expected a Hide Active App on Dock Click settings toggle")
        }

        XCTAssertEqual(row.title, plugin.metadata.title)
        XCTAssertTrue(isOn)
    }

    func testSettingsSwitchUsesPrimaryPanelLifecycleAndPersistsState() {
        let monitor = MockDockClickMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)
        plugin.activate(context: context)

        plugin.handleSettingsAction(
            .setBoolean(controlID: "dock-click-minimize.settings.enabled", value: false)
        )

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertFalse(plugin.primaryPanelState.isOn)

        let reloadedPlugin = makePlugin(context: context)
        XCTAssertFalse(reloadedPlugin.primaryPanelState.isOn)
    }

    func testDeactivationAlwaysStopsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)
        plugin.activate(context: context)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(monitor.stopCallCount, 1)
    }

    func testMissingPermissionPreventsMonitoring() {
        let monitor = MockDockClickMonitor()
        let permissions = PermissionState(accessibilityGranted: false, inputMonitoringStatus: .denied)
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor, permissions: permissions)

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
        XCTAssertFalse(plugin.permissionState(for: "input-monitoring").isGranted)
    }

    func testMonitorStartupFailureIsExposed() {
        let monitor = MockDockClickMonitor(startResult: false)
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testResolverAcceptsOnlyApplicationDockItemWithBundleURL() {
        let target = DockClickResolver.applicationTarget(
            from: DockItemSnapshot(
                processIdentifier: 42,
                role: DockClickResolver.dockItemRole,
                subrole: DockClickResolver.applicationDockItemSubrole,
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
            dockProcessIdentifier: 42,
            bundleIdentifierForURL: { _ in "com.apple.Safari" }
        )

        XCTAssertEqual(target, DockApplicationTarget(bundleIdentifier: "com.apple.Safari"))
    }

    func testResolverRejectsTrashFoldersFilesAndUnknownDockItems() {
        let snapshots = [
            DockItemSnapshot(processIdentifier: 42, role: DockClickResolver.dockItemRole, subrole: "AXTrashDockItem", url: nil),
            DockItemSnapshot(processIdentifier: 42, role: DockClickResolver.dockItemRole, subrole: "AXFolderDockItem", url: URL(fileURLWithPath: "/Users/me/Downloads")),
            DockItemSnapshot(processIdentifier: 42, role: DockClickResolver.dockItemRole, subrole: "AXApplicationDockItem", url: URL(fileURLWithPath: "/tmp/file.pdf")),
            DockItemSnapshot(processIdentifier: 7, role: DockClickResolver.dockItemRole, subrole: DockClickResolver.applicationDockItemSubrole, url: URL(fileURLWithPath: "/Applications/Safari.app")),
        ]

        for snapshot in snapshots {
            XCTAssertNil(
                DockClickResolver.applicationTarget(
                    from: snapshot,
                    dockProcessIdentifier: 42,
                    bundleIdentifierForURL: { _ in nil }
                )
            )
        }
    }

    func testResolverScopesHitTestingToDockProcess() {
        let expectedDockProcessIdentifier: pid_t = 42
        var queriedProcessIdentifier: pid_t?
        let resolver = DockAccessibilityResolver(
            workspaceNotificationCenter: NotificationCenter(),
            dockProcessIdentifierProvider: { expectedDockProcessIdentifier },
            accessibilityElementAtPosition: { processIdentifier, _ in
                queriedProcessIdentifier = processIdentifier
                return nil
            }
        )

        XCTAssertNil(resolver.resolveApplication(at: .zero))
        XCTAssertEqual(queriedProcessIdentifier, expectedDockProcessIdentifier)
    }

    func testModifiedClicksAreIgnoredByPolicy() {
        XCTAssertTrue(DockClickModifierPolicy.isPlainClick(flags: []))
        XCTAssertFalse(DockClickModifierPolicy.isPlainClick(flags: .maskCommand))
        XCTAssertFalse(DockClickModifierPolicy.isPlainClick(flags: .maskAlternate))
        XCTAssertFalse(DockClickModifierPolicy.isPlainClick(flags: .maskControl))
        XCTAssertFalse(DockClickModifierPolicy.isPlainClick(flags: .maskShift))
    }

    func testGesturePolicyRejectsDraggingAndLongPresses() {
        XCTAssertTrue(
            DockClickGesturePolicy.isCompletedClick(
                downLocation: .zero,
                upLocation: CGPoint(x: DockClickGesturePolicy.maximumDistance, y: 0),
                duration: DockClickGesturePolicy.maximumDuration
            )
        )
        XCTAssertFalse(
            DockClickGesturePolicy.isCompletedClick(
                downLocation: .zero,
                upLocation: CGPoint(x: DockClickGesturePolicy.maximumDistance + 1, y: 0),
                duration: 0
            )
        )
        XCTAssertFalse(
            DockClickGesturePolicy.isCompletedClick(
                downLocation: .zero,
                upLocation: .zero,
                duration: DockClickGesturePolicy.maximumDuration + 0.01
            )
        )
    }

    func testGesturePolicyAllowsMinorMovementUntilToleranceIsExceeded() {
        XCTAssertTrue(
            DockClickGesturePolicy.isWithinMaximumDistance(
                downLocation: .zero,
                currentLocation: CGPoint(x: 1, y: 0)
            )
        )
        XCTAssertTrue(
            DockClickGesturePolicy.isWithinMaximumDistance(
                downLocation: .zero,
                currentLocation: CGPoint(x: DockClickGesturePolicy.maximumDistance, y: 0)
            )
        )
        XCTAssertFalse(
            DockClickGesturePolicy.isWithinMaximumDistance(
                downLocation: .zero,
                currentLocation: CGPoint(x: DockClickGesturePolicy.maximumDistance + 1, y: 0)
            )
        )
    }

    func testVisibleWindowQueryRunsOffMainThread() async {
        let hider = DockApplicationHider { _ in
            !Thread.isMainThread
        }

        let hasVisibleWindow = await hider.hasVisibleWindow(for: 42)

        XCTAssertTrue(hasVisibleWindow)
    }

    func testCurrentProcessVisibilityQueryRunsOnMainActor() async {
        let currentProcessIdentifier: pid_t = 42
        let hider = DockApplicationHider(
            currentProcessIdentifier: currentProcessIdentifier,
            currentProcessVisibleWindowQuery: { Thread.isMainThread },
            visibleWindowQuery: { _ in false }
        )

        let hasVisibleWindow = await hider.hasVisibleWindow(for: currentProcessIdentifier)

        XCTAssertTrue(hasVisibleWindow)
    }

    func testClickDecisionOnlySchedulesActiveApplicationWithVisibleWindow() {
        let safari = DockApplicationTarget(bundleIdentifier: "com.apple.Safari")
        let activeSafari = DockFrontmostApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 123)

        XCTAssertFalse(
            DockClickDecision.shouldScheduleHide(
                target: nil,
                frontmostApplication: activeSafari,
                hasVisibleWindow: true
            )
        )
        XCTAssertFalse(
            DockClickDecision.shouldScheduleHide(
                target: safari,
                frontmostApplication: DockFrontmostApplication(bundleIdentifier: "com.apple.Terminal", processIdentifier: 99),
                hasVisibleWindow: true
            )
        )
        XCTAssertFalse(
            DockClickDecision.shouldScheduleHide(
                target: safari,
                frontmostApplication: activeSafari,
                hasVisibleWindow: false
            )
        )
        XCTAssertTrue(
            DockClickDecision.shouldScheduleHide(
                target: safari,
                frontmostApplication: activeSafari,
                hasVisibleWindow: true
            )
        )
    }

    func testActiveApplicationClickHidesExactlyOnceAfterDelay() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let frontmost = MutableFrontmostApplicationProvider(application: safariApplication)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmost,
            scheduler: scheduler
        )
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        scheduler.runNext()

        XCTAssertEqual(applicationHider.hiddenProcessIdentifiers, [safariApplication.processIdentifier])
    }

    func testAllMinimizedOrNoFocusedWindowDoesNotScheduleHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: false)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor, applicationHider: applicationHider, scheduler: scheduler)
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { applicationHider.hasVisibleWindowCallCount == 1 }

        XCTAssertTrue(scheduler.actions.isEmpty)
        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    func testDifferentDockTargetDoesNotQueryVisibleWindow() {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor, applicationHider: applicationHider)
        plugin.activate(context: context)

        monitor.emit(
            target: DockApplicationTarget(bundleIdentifier: "com.apple.Terminal"),
            frontmostApplication: safariApplication
        )

        XCTAssertEqual(applicationHider.hasVisibleWindowCallCount, 0)
    }

    func testFrontmostApplicationChangeBeforeDelayDoesNotHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let frontmost = MutableFrontmostApplicationProvider(application: safariApplication)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmost,
            scheduler: scheduler
        )
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        frontmost.application = DockFrontmostApplication(bundleIdentifier: "com.apple.Terminal", processIdentifier: 99)
        scheduler.runNext()

        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    func testApplicationExitBeforeDelayDoesNotHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let frontmost = MutableFrontmostApplicationProvider(application: safariApplication)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmost,
            scheduler: scheduler
        )
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        frontmost.application = nil
        scheduler.runNext()

        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    func testDisablingBeforeDelayDoesNotHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor, applicationHider: applicationHider, scheduler: scheduler)
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        plugin.handleAction(.setSwitch(false))
        scheduler.runNext()

        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    func testFrontmostApplicationChangeDuringVisibilityQueryDoesNotScheduleHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(
            hasVisibleWindow: true,
            suspendsVisibilityCheck: true
        )
        let frontmost = MutableFrontmostApplicationProvider(application: safariApplication)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmost,
            scheduler: scheduler
        )
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { applicationHider.hasVisibleWindowCallCount == 1 }
        frontmost.application = DockFrontmostApplication(
            bundleIdentifier: "com.apple.Terminal",
            processIdentifier: 99
        )
        applicationHider.resumeVisibilityCheck()
        await waitUntil { frontmost.frontmostApplicationCallCount == 1 }

        XCTAssertTrue(scheduler.actions.isEmpty)
        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    private var safariTarget: DockApplicationTarget {
        DockApplicationTarget(bundleIdentifier: "com.apple.Safari")
    }

    private var safariApplication: DockFrontmostApplication {
        DockFrontmostApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 123)
    }

    private func makePlugin(
        context: PluginRuntimeContext? = nil,
        monitor: MockDockClickMonitor? = nil,
        applicationHider: MockDockApplicationHider? = nil,
        frontmostApplicationProvider: MutableFrontmostApplicationProvider? = nil,
        permissions: PermissionState? = nil,
        scheduler: ManualScheduler? = nil
    ) -> DockClickMinimizePlugin {
        let monitor = monitor ?? MockDockClickMonitor()
        let applicationHider = applicationHider ?? MockDockApplicationHider(hasVisibleWindow: true)
        let frontmostApplicationProvider = frontmostApplicationProvider ?? MutableFrontmostApplicationProvider(
            application: DockFrontmostApplication(
                bundleIdentifier: "com.apple.Safari",
                processIdentifier: 123
            )
        )
        let permissions = permissions ?? PermissionState()
        let scheduler = scheduler ?? ManualScheduler()

        return DockClickMinimizePlugin(
            context: context ?? makeContext(),
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmostApplicationProvider,
            accessibilityTrusted: { permissions.accessibilityGranted },
            requestAccessibilityTrust: { _ in permissions.accessibilityGranted },
            inputMonitoringStatus: { permissions.inputMonitoringStatus },
            scheduleDelayedAction: { scheduler.schedule($0) }
        )
    }

    private func makeContext(isEnabled: Bool? = nil) -> PluginRuntimeContext {
        let storage = DockClickMinimizeMemoryStorage()
        if let isEnabled {
            storage.set(isEnabled, forKey: "dock-click-minimize.enabled")
        }
        return PluginRuntimeContext(pluginID: "dock-click-minimize", storage: storage)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0 ..< attempts {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous Dock Click state")
    }
}

@MainActor
private final class MockDockClickMonitor: @preconcurrency DockClickMonitoring {
    var onApplicationClick: ((DockApplicationTarget, DockFrontmostApplication) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let startResult: Bool

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {
        stopCallCount += 1
    }

    func emit(target: DockApplicationTarget, frontmostApplication: DockFrontmostApplication) {
        onApplicationClick?(target, frontmostApplication)
    }
}

@MainActor
private final class MockDockApplicationHider: @preconcurrency DockApplicationHiding {
    var hasVisibleWindowResult: Bool
    private(set) var hasVisibleWindowCallCount = 0
    private(set) var hiddenProcessIdentifiers: [pid_t] = []
    private let suspendsVisibilityCheck: Bool
    private var visibilityContinuation: CheckedContinuation<Bool, Never>?

    init(hasVisibleWindow: Bool, suspendsVisibilityCheck: Bool = false) {
        self.hasVisibleWindowResult = hasVisibleWindow
        self.suspendsVisibilityCheck = suspendsVisibilityCheck
    }

    func hasVisibleWindow(for processIdentifier: pid_t) async -> Bool {
        hasVisibleWindowCallCount += 1
        guard suspendsVisibilityCheck else {
            return hasVisibleWindowResult
        }
        return await withCheckedContinuation { continuation in
            visibilityContinuation = continuation
        }
    }

    func resumeVisibilityCheck() {
        visibilityContinuation?.resume(returning: hasVisibleWindowResult)
        visibilityContinuation = nil
    }

    func hideApplication(bundleIdentifier: String, processIdentifier: pid_t) -> Bool {
        guard hasVisibleWindowResult else { return false }
        hiddenProcessIdentifiers.append(processIdentifier)
        return true
    }
}

@MainActor
private final class MutableFrontmostApplicationProvider: @preconcurrency DockFrontmostApplicationProviding {
    var application: DockFrontmostApplication?
    private(set) var frontmostApplicationCallCount = 0

    init(application: DockFrontmostApplication?) {
        self.application = application
    }

    func frontmostApplication() -> DockFrontmostApplication? {
        frontmostApplicationCallCount += 1
        return application
    }
}

@MainActor
private final class ManualScheduler {
    var actions: [@MainActor () -> Void] = []

    func schedule(_ action: @escaping @MainActor () -> Void) {
        actions.append(action)
    }

    func runNext() {
        actions.removeFirst()()
    }
}

@MainActor
private final class PermissionState {
    var accessibilityGranted: Bool
    var inputMonitoringStatus: DockClickMinimizeInputMonitoringStatus

    init(
        accessibilityGranted: Bool = true,
        inputMonitoringStatus: DockClickMinimizeInputMonitoringStatus = .granted
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringStatus = inputMonitoringStatus
    }
}

@MainActor
private final class DockClickMinimizeMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
