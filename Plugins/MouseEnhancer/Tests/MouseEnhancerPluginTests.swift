import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import MouseEnhancerPlugin

@MainActor
private final class MouseEnhancerMemoryStorage: PluginStorage {
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

@MainActor
private final class MockMouseEnhancerSession: MouseEnhancerSessionManaging {
    private(set) var state: MouseEnhancerSessionState = .inactive
    private(set) var activatedConfigurations: [MouseEnhancerConfiguration] = []
    private(set) var updatedConfigurations: [MouseEnhancerConfiguration] = []
    private(set) var deactivateCallCount = 0
    var activationSucceeds = true

    @discardableResult
    func activate(configuration: MouseEnhancerConfiguration) -> Bool {
        activatedConfigurations.append(configuration)
        state.scrollTapInstalled = activationSucceeds
        state.gestureTapInstalled = activationSucceeds
        return activationSucceeds
    }

    func update(configuration: MouseEnhancerConfiguration) {
        updatedConfigurations.append(configuration)
    }

    func deactivate() {
        deactivateCallCount += 1
        state = .inactive
    }
}

@MainActor
private final class MockMouseEnhancerMiddleClickSession: MouseEnhancerMiddleClickSessionManaging {
    private(set) var assignedFingerCounts: [Int] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    var requiredFingerCount: Int = 3 {
        didSet {
            assignedFingerCounts.append(requiredFingerCount)
        }
    }

    func activate() {
        activateCallCount += 1
    }

    func deactivate() {
        deactivateCallCount += 1
    }
}

@MainActor
final class MouseEnhancerPluginTests: XCTestCase {
    func testMetadataIdentifiesPlugin() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "mouse-enhancer")
        XCTAssertEqual(plugin.metadata.title, "鼠标增强")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "设置")
    }

    func testDefaultConfigurationStartsWithAllDirectionsOff() {
        let store = MouseEnhancerStore(storage: MouseEnhancerMemoryStorage())

        XCTAssertFalse(store.configuration.reverseMouseHorizontal)
        XCTAssertFalse(store.configuration.reverseMouseVertical)
        XCTAssertFalse(store.configuration.reverseTrackpadHorizontal)
        XCTAssertFalse(store.configuration.reverseTrackpadVertical)
        XCTAssertFalse(store.configuration.middleClickEnabled)
        XCTAssertEqual(store.configuration.middleClickFingerCount, 3)
        XCTAssertFalse(store.configuration.shouldInstallEventTap)
    }

    func testStoreIgnoresLegacyMiddleClickStorageKeys() {
        let storage = MouseEnhancerMemoryStorage()
        storage.values["middle-click.enabled"] = true
        storage.values["middle-click.required-finger-count"] = 5

        let store = MouseEnhancerStore(storage: storage)

        XCTAssertFalse(store.configuration.middleClickEnabled)
        XCTAssertEqual(store.configuration.middleClickFingerCount, 3)
    }

    func testMiddleClickConfigurationPersistsUnderMouseEnhancerKeys() {
        let storage = MouseEnhancerMemoryStorage()
        let store = MouseEnhancerStore(storage: storage)

        store.setMiddleClickEnabled(true)
        store.setMiddleClickFingerCount(5)

        XCTAssertEqual(storage.values["mouse-enhancer.middle-click.enabled"] as? Bool, true)
        XCTAssertEqual(storage.values["mouse-enhancer.middle-click.finger-count"] as? Int, 5)
    }

    func testPanelButtonRequestsConfigurationPresentation() {
        let plugin = makePlugin()
        var didRequestConfigurationPresentation = false
        plugin.requestConfigurationPresentation = {
            didRequestConfigurationPresentation = true
        }

        plugin.handleAction(.invokeAction(controlID: "execute"))

        XCTAssertTrue(didRequestConfigurationPresentation)
    }

    func testConfigurationChangeEnablesSessionWhenAccessibilityGranted() {
        let session = MockMouseEnhancerSession()
        let plugin = makePlugin(session: session, accessibilityTrusted: true)

        plugin.store.setReverseMouseVertical(true)
        plugin.configurationDidChange()

        XCTAssertEqual(session.activatedConfigurations.count, 1)
        XCTAssertTrue(session.activatedConfigurations[0].reverseMouseVertical)
        XCTAssertFalse(session.activatedConfigurations[0].reverseMouseHorizontal)
    }

    func testConfigurationChangeRequestsPermissionWhenAccessibilityDenied() {
        let session = MockMouseEnhancerSession()
        var didRequestPermission = false
        let plugin = makePlugin(
            session: session,
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        plugin.requestPermissionGuidance = { id in
            didRequestPermission = id == "accessibility"
        }

        plugin.store.setReverseMouseVertical(true)
        plugin.configurationDidChange()

        XCTAssertTrue(didRequestPermission)
        XCTAssertTrue(session.activatedConfigurations.isEmpty)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testTurningOffAllDirectionsStopsSession() {
        let session = MockMouseEnhancerSession()
        let plugin = makePlugin(session: session, accessibilityTrusted: true)

        plugin.store.setReverseMouseVertical(true)
        plugin.configurationDidChange()
        plugin.store.setReverseMouseVertical(false)
        plugin.configurationDidChange()

        XCTAssertFalse(plugin.store.configuration.shouldInstallEventTap)
        XCTAssertGreaterThanOrEqual(session.deactivateCallCount, 1)
    }

    func testConfigurationChangeUpdatesRunningSession() {
        let session = MockMouseEnhancerSession()
        let plugin = makePlugin(session: session, accessibilityTrusted: true)

        plugin.store.setReverseMouseVertical(true)
        plugin.configurationDidChange()
        plugin.store.setReverseMouseHorizontal(true)
        plugin.configurationDidChange()

        XCTAssertFalse(session.updatedConfigurations.isEmpty)
        XCTAssertTrue(session.updatedConfigurations.last?.reverseMouseHorizontal == true)
    }

    func testMiddleClickStartsWhenEnabledAndAccessibilityGranted() {
        let scrollSession = MockMouseEnhancerSession()
        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let plugin = makePlugin(
            session: scrollSession,
            middleClickSession: middleClickSession,
            accessibilityTrusted: true
        )

        plugin.store.setMiddleClickFingerCount(4)
        plugin.store.setMiddleClickEnabled(true)
        plugin.configurationDidChange()

        XCTAssertTrue(scrollSession.activatedConfigurations.isEmpty)
        XCTAssertEqual(middleClickSession.activateCallCount, 1)
        XCTAssertEqual(middleClickSession.requiredFingerCount, 4)
    }

    func testMiddleClickFingerCountChangeUpdatesRunningSession() {
        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let plugin = makePlugin(
            middleClickSession: middleClickSession,
            accessibilityTrusted: true
        )

        plugin.store.setMiddleClickEnabled(true)
        plugin.configurationDidChange()
        plugin.store.setMiddleClickFingerCount(5)
        plugin.configurationDidChange()

        XCTAssertEqual(middleClickSession.activateCallCount, 1)
        XCTAssertEqual(middleClickSession.requiredFingerCount, 5)
        XCTAssertTrue(middleClickSession.assignedFingerCounts.contains(5))
    }

    func testTurningMiddleClickOffStopsSession() {
        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let plugin = makePlugin(
            middleClickSession: middleClickSession,
            accessibilityTrusted: true
        )

        plugin.store.setMiddleClickEnabled(true)
        plugin.configurationDidChange()
        plugin.store.setMiddleClickEnabled(false)
        plugin.configurationDidChange()

        XCTAssertEqual(middleClickSession.activateCallCount, 1)
        XCTAssertEqual(middleClickSession.deactivateCallCount, 1)
    }

    func testMiddleClickRequestsPermissionWhenAccessibilityDenied() {
        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        var didRequestPermission = false
        let plugin = makePlugin(
            middleClickSession: middleClickSession,
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        plugin.requestPermissionGuidance = { id in
            didRequestPermission = id == "accessibility"
        }

        plugin.store.setMiddleClickEnabled(true)
        plugin.configurationDidChange()

        XCTAssertTrue(didRequestPermission)
        XCTAssertEqual(middleClickSession.activateCallCount, 0)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "启用前需要辅助功能授权")
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testPermissionRequirementsIncludeAccessibilityAndInputMonitoring() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility", "input-monitoring"])
    }

    func testPluginHostIncludesMouseEnhancerPlugin() {
        let host = makePluginHostForTests(plugins: [makePlugin(accessibilityTrusted: true)])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "mouse-enhancer" })
    }

    func testProcessorReversesDiscreteMouseVerticalDeltas() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 3,
                deltaAxis2: 4,
                pointDeltaAxis1: 24,
                pointDeltaAxis2: 32,
                fixedPointDeltaAxis1: 3,
                fixedPointDeltaAxis2: 4
            )
        )

        XCTAssertEqual(result.source, .mouse)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, -3)
        XCTAssertEqual(result.deltas.pointDeltaAxis1, -24)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis1, -3)
        XCTAssertEqual(result.deltas.deltaAxis2, 4)
    }

    func testProcessorReversesHorizontalOnlyWhenConfigured() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: true,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 3,
                deltaAxis2: 4,
                pointDeltaAxis1: 24,
                pointDeltaAxis2: 32,
                fixedPointDeltaAxis1: 3,
                fixedPointDeltaAxis2: 4
            )
        )

        XCTAssertEqual(result.deltas.deltaAxis1, 3)
        XCTAssertEqual(result.deltas.deltaAxis2, -4)
        XCTAssertEqual(result.deltas.pointDeltaAxis2, -32)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis2, -4)
    }

    func testProcessorClassifiesRecentGestureScrollAsTrackpad() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: true
            )
        )

        processor.setGestureMonitoringAvailable(true)
        processor.recordGestureTouchingCount(2, timestamp: 1_000)
        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 0
            ),
            timestamp: 1_000 + 10_000_000
        )

        XCTAssertEqual(result.source, .trackpad)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, -2)
    }

    func testProcessorReversesTrackpadHorizontalIndependently() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: true,
                reverseTrackpadVertical: false
            )
        )

        processor.setGestureMonitoringAvailable(true)
        processor.recordGestureTouchingCount(2, timestamp: 1_000)
        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 4,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 20,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 4
            ),
            timestamp: 1_000 + 10_000_000
        )

        XCTAssertEqual(result.source, .trackpad)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, 2)
        XCTAssertEqual(result.deltas.deltaAxis2, -4)
    }

    func testProcessorTreatsPhaseLessContinuousScrollAsMouse() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        processor.setGestureMonitoringAvailable(false)
        let result = processor.process(
            snapshot: .phaseLessContinuousWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertEqual(result.source, .mouse)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, -2)
    }

    func testProcessorConservativelyTreatsContinuousPhaseWithoutGestureAsTrackpad() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertEqual(result.source, .trackpad)
        XCTAssertFalse(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, 2)
    }

    func testProcessorClassifiesStaleNormalContinuousScrollAsMouseAfterGestureMonitoringStarts() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        processor.setGestureMonitoringAvailable(true)
        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 0
            ),
            timestamp: 500_000_000
        )

        XCTAssertEqual(result.source, .mouse)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, -2)
    }

    func testProcessorDoesNotReverseWhenNoDirectionIsEnabled() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 3,
                pointDeltaAxis1: 16,
                pointDeltaAxis2: 24,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 3
            )
        )

        XCTAssertEqual(result.source, .mouse)
        XCTAssertFalse(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, 2)
        XCTAssertEqual(result.deltas.deltaAxis2, 3)
    }

    func testProcessorKeepsTrackpadSourceForMomentumAfterTrackpadGesture() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: true
            )
        )

        processor.setGestureMonitoringAvailable(true)
        processor.recordGestureTouchingCount(2, timestamp: 1_000)
        _ = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 0
            ),
            timestamp: 10_000_000
        )

        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 0,
                momentumPhase: 1
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 1,
                deltaAxis2: 0,
                pointDeltaAxis1: 8,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 1,
                fixedPointDeltaAxis2: 0
            ),
            timestamp: 400_000_000
        )

        XCTAssertEqual(result.source, .trackpad)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, -1)
    }

    func testProcessorResetsClassificationStateWhenGestureMonitoringStops() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        processor.setGestureMonitoringAvailable(true)
        processor.recordGestureTouchingCount(2, timestamp: 1_000)
        _ = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 2,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 2,
                fixedPointDeltaAxis2: 0
            ),
            timestamp: 10_000_000
        )

        processor.setGestureMonitoringAvailable(false)
        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 0,
                momentumPhase: 1
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 1,
                deltaAxis2: 0,
                pointDeltaAxis1: 8,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 1,
                fixedPointDeltaAxis2: 0
            ),
            timestamp: 400_000_000
        )

        XCTAssertEqual(result.source, .trackpad)
        XCTAssertFalse(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, 1)
    }

    func testMiddleClickStartsOnActivateWhenSavedAsEnabledAndAccessibilityGranted() {
        let storage = MouseEnhancerMemoryStorage()
        storage.values["mouse-enhancer.middle-click.enabled"] = true
        storage.values["mouse-enhancer.middle-click.finger-count"] = 4

        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let context = PluginRuntimeContext(pluginID: "mouse-enhancer", storage: storage)
        let plugin = MouseEnhancerPlugin(
            context: context,
            makeMiddleClickSession: { middleClickSession },
            accessibilityTrusted: { true },
            requestAccessibilityTrust: { _ in true },
            inputMonitoringAuthorizationStatus: { .granted },
            openURL: { _ in }
        )

        plugin.activate(context: context)

        XCTAssertEqual(middleClickSession.activateCallCount, 1)
        XCTAssertEqual(middleClickSession.requiredFingerCount, 4)
    }

    func testMiddleClickDoesNotStartOnActivateWhenAccessibilityDenied() {
        let storage = MouseEnhancerMemoryStorage()
        storage.values["mouse-enhancer.middle-click.enabled"] = true

        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let context = PluginRuntimeContext(pluginID: "mouse-enhancer", storage: storage)
        let plugin = MouseEnhancerPlugin(
            context: context,
            makeMiddleClickSession: { middleClickSession },
            accessibilityTrusted: { false },
            requestAccessibilityTrust: { _ in false },
            inputMonitoringAuthorizationStatus: { .granted },
            openURL: { _ in }
        )

        plugin.activate(context: context)

        XCTAssertEqual(middleClickSession.activateCallCount, 0)
    }

    private func makePlugin(
        session: MockMouseEnhancerSession? = nil,
        middleClickSession: MockMouseEnhancerMiddleClickSession? = nil,
        accessibilityTrusted: Bool = true,
        requestAccessibilityTrust: Bool = true,
        inputMonitoringStatus: MouseEnhancerInputMonitoringAuthorizationStatus = .granted
    ) -> MouseEnhancerPlugin {
        let storage = MouseEnhancerMemoryStorage()
        return MouseEnhancerPlugin(
            context: PluginRuntimeContext(pluginID: "mouse-enhancer", storage: storage),
            session: session ?? MockMouseEnhancerSession(),
            makeMiddleClickSession: {
                middleClickSession ?? MockMouseEnhancerMiddleClickSession()
            },
            accessibilityTrusted: { accessibilityTrusted },
            requestAccessibilityTrust: { _ in requestAccessibilityTrust },
            inputMonitoringAuthorizationStatus: { inputMonitoringStatus },
            openURL: { _ in }
        )
    }
}
