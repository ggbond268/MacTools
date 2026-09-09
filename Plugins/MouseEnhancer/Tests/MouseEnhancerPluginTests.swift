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
    private(set) var inputUnavailableCallCount = 0
    private(set) var inputAvailableCallCount = 0
    private(set) var displayTopologyChangeCallCount = 0
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

    func inputActivityDidBecomeUnavailable() {
        inputUnavailableCallCount += 1
    }

    func inputActivityDidBecomeAvailable() {
        inputAvailableCallCount += 1
    }

    func displayTopologyDidChange() {
        displayTopologyChangeCallCount += 1
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
    func testStoreLeavesExtractedMiddleClickStorageKeysUntouched() {
        let storage = MouseEnhancerMemoryStorage()
        storage.values["mouse-enhancer.middle-click.enabled"] = true
        storage.values["mouse-enhancer.middle-click.finger-count"] = 5

        let store = MouseEnhancerStore(storage: storage)

        XCTAssertFalse(store.configuration.shouldInstallEventTap)
        XCTAssertTrue(store.configuration.middleClickEnabled)
        XCTAssertEqual(store.configuration.middleClickFingerCount, 5)
        XCTAssertEqual(storage.values["mouse-enhancer.middle-click.enabled"] as? Bool, true)
        XCTAssertEqual(storage.values["mouse-enhancer.middle-click.finger-count"] as? Int, 5)
    }

    func testFeatureExtractionHostNeverStartsLegacyMiddleClickListener() {
        let storage = MouseEnhancerMemoryStorage()
        storage.values["mouse-enhancer.middle-click.enabled"] = true
        storage.values["mouse-enhancer.middle-click.finger-count"] = 5
        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let plugin = makePlugin(
            storage: storage,
            middleClickSession: middleClickSession,
            hostVersion: "1.2.0"
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "mouse-enhancer"))

        XCTAssertEqual(middleClickSession.activateCallCount, 0)
        XCTAssertEqual(middleClickSession.deactivateCallCount, 0)
    }

    func testDowngradedHostRestoresLegacyMiddleClickFromPreservedPreferences() {
        let storage = MouseEnhancerMemoryStorage()
        storage.values["mouse-enhancer.middle-click.enabled"] = true
        storage.values["mouse-enhancer.middle-click.finger-count"] = 5
        let middleClickSession = MockMouseEnhancerMiddleClickSession()
        let plugin = makePlugin(
            storage: storage,
            middleClickSession: middleClickSession,
            hostVersion: "1.1.5"
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "mouse-enhancer"))

        XCTAssertEqual(middleClickSession.activateCallCount, 1)
        XCTAssertEqual(middleClickSession.requiredFingerCount, 5)
    }

    func testLegacyMiddleClickOwnershipUsesHostVersionBoundary() {
        XCTAssertTrue(MouseEnhancerHostCompatibility.ownsLegacyMiddleClick(hostVersion: "1.1.5"))
        XCTAssertTrue(MouseEnhancerHostCompatibility.ownsLegacyMiddleClick(hostVersion: "1.1.6"))
        XCTAssertTrue(MouseEnhancerHostCompatibility.ownsLegacyMiddleClick(hostVersion: "1.1.6-beta.1"))
        XCTAssertFalse(MouseEnhancerHostCompatibility.ownsLegacyMiddleClick(hostVersion: "1.2.0"))
        XCTAssertFalse(MouseEnhancerHostCompatibility.ownsLegacyMiddleClick(hostVersion: nil))
    }

    func testLegacyMultitouchRuntimeResolvesRequiredSymbolsDynamically() {
        XCTAssertNotNil(MouseEnhancerMultitouchRuntime.load())
    }

    func testPanelButtonRequestsConfigurationPresentation() {
        let plugin = makePlugin()
        var didRequestConfigurationPresentation = false
        plugin.requestSettingsPresentation = {
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

    func testPermissionRequirementsIncludeAccessibilityAndInputMonitoring() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility", "input-monitoring"])
    }

    func testApplicationActivityTransitionsRecoverSessionOnlyAtInteractiveBoundary() {
        let session = MockMouseEnhancerSession()
        let plugin = makePlugin(session: session)

        plugin.applicationActivityStateDidChange(.sessionInactive)
        plugin.applicationActivityStateDidChange(.displayAsleep)
        plugin.applicationActivityStateDidChange(.waking)

        XCTAssertEqual(session.inputUnavailableCallCount, 1)
        XCTAssertEqual(session.inputAvailableCallCount, 0)

        plugin.applicationActivityStateDidChange(.interactive)

        XCTAssertEqual(session.inputUnavailableCallCount, 1)
        XCTAssertEqual(session.inputAvailableCallCount, 1)
    }

    func testDisplayTopologyRefreshIsForwardedWhileInputIsUnavailable() {
        let session = MockMouseEnhancerSession()
        let plugin = makePlugin(session: session)

        plugin.refreshDisplayTopology()
        XCTAssertEqual(session.displayTopologyChangeCallCount, 1)

        plugin.applicationActivityStateDidChange(.sessionInactive)
        plugin.refreshDisplayTopology()
        XCTAssertEqual(session.displayTopologyChangeCallCount, 2)

        plugin.applicationActivityStateDidChange(.interactive)
        plugin.refreshDisplayTopology()
        XCTAssertEqual(session.displayTopologyChangeCallCount, 3)
    }

    func testRecoveryStatePreservesLongerDisplaySettleAcrossInputInterruption() {
        var state = MouseEnhancerRecoveryState()

        state.request(.displayTopology)
        state.setInputAvailable(false)
        state.request(.applicationActivity)

        XCTAssertFalse(state.isInputAvailable)
        XCTAssertEqual(state.pendingCause, .displayTopology)
        XCTAssertEqual(state.pendingCause?.delay, 2)

        state.setInputAvailable(true)
        state.request(.applicationActivity)

        XCTAssertTrue(state.isInputAvailable)
        XCTAssertEqual(state.pendingCause, .displayTopology)
    }

    func testRecoveryStateUsesShortActivitySettleWithoutDisplayChange() {
        var state = MouseEnhancerRecoveryState()

        state.setInputAvailable(false)
        state.request(.applicationActivity)
        state.setInputAvailable(true)

        XCTAssertEqual(state.pendingCause, .applicationActivity)
        XCTAssertEqual(state.pendingCause?.delay, 0.25)

        state.clearPending()
        XCTAssertNil(state.pendingCause)
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

    func testProcessorTreatsPhasedContinuousScrollAsTrackpadUntilTouchEvidenceRecovers() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            )
        )

        // An installed gesture tap can stay enabled but stop delivering useful touch callbacks
        // across screen locking or display reconfiguration.
        processor.setGestureMonitoringAvailable(true)
        processor.recordGestureTouchingCount(1, timestamp: 1_000)
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
            timestamp: 1_000_000_000
        )

        XCTAssertEqual(result.source, .trackpad)
        XCTAssertFalse(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, 2)
    }

    func testProcessorStillTreatsPhaseLessContinuousWheelAsMouseDuringRecovery() {
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

    func testProcessorAppliesMouseScrollGainToAllRepresentations() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false,
                mouseScrollGain: 2
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 3,
                deltaAxis2: 1,
                pointDeltaAxis1: 24,
                pointDeltaAxis2: 10,
                fixedPointDeltaAxis1: 3,
                fixedPointDeltaAxis2: 1
            )
        )

        XCTAssertEqual(result.source, .mouse)
        XCTAssertFalse(result.shouldReverse)
        XCTAssertTrue(result.isTuned)
        XCTAssertEqual(result.deltas.deltaAxis1, 6)
        XCTAssertEqual(result.deltas.pointDeltaAxis1, 48)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis1, 6, accuracy: 0.001)
        XCTAssertEqual(result.deltas.deltaAxis2, 2)
        XCTAssertEqual(result.deltas.pointDeltaAxis2, 20)
    }

    func testProcessorGainBelowOneKeepsCoarseDeltasNonZero() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false,
                mouseScrollGain: 0.5
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 1,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 1,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertEqual(result.deltas.deltaAxis1, 1)
        XCTAssertEqual(result.deltas.pointDeltaAxis1, 5)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis1, 0.5, accuracy: 0.001)
    }

    func testProcessorFloorsSmallTicksToMouseScrollStep() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false,
                mouseScrollStep: 40
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: 1,
                deltaAxis2: 0,
                pointDeltaAxis1: 10,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 1,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertTrue(result.isTuned)
        XCTAssertEqual(result.deltas.pointDeltaAxis1, 40)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis1, 4, accuracy: 0.001)
        XCTAssertEqual(result.deltas.deltaAxis1, 4)
    }

    func testProcessorStepFloorPreservesSignAndLargeTicks() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false,
                mouseScrollStep: 40
            )
        )

        let result = processor.process(
            snapshot: .discreteWheel,
            deltas: MouseScrollDeltas(
                deltaAxis1: -2,
                deltaAxis2: 0,
                pointDeltaAxis1: -50,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: -2,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertEqual(result.deltas.pointDeltaAxis1, -50)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis1, -2, accuracy: 0.001)
        XCTAssertEqual(result.deltas.deltaAxis1, -2)
    }

    func testProcessorPassesThroughRemoteSmoothedEvents() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false,
                mouseScrollStep: 40,
                mouseScrollGain: 2
            ),
            remoteSourceEvaluator: { $0 == 4242 }
        )

        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: true,
                scrollPhase: 1,
                momentumPhase: 0,
                sourceProcessID: 4242
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 3,
                deltaAxis2: 0,
                pointDeltaAxis1: 30,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 3,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertFalse(result.shouldReverse)
        XCTAssertFalse(result.isTuned)
        XCTAssertEqual(result.deltas.deltaAxis1, 3)
        XCTAssertEqual(result.deltas.pointDeltaAxis1, 30)
    }

    func testProcessorStillProcessesRemoteDiscreteEvents() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: true,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false
            ),
            remoteSourceEvaluator: { $0 == 4242 }
        )

        let result = processor.process(
            snapshot: MouseScrollEventSnapshot(
                isContinuous: false,
                scrollPhase: 0,
                momentumPhase: 0,
                sourceProcessID: 4242
            ),
            deltas: MouseScrollDeltas(
                deltaAxis1: 3,
                deltaAxis2: 0,
                pointDeltaAxis1: 24,
                pointDeltaAxis2: 0,
                fixedPointDeltaAxis1: 3,
                fixedPointDeltaAxis2: 0
            )
        )

        XCTAssertEqual(result.source, .mouse)
        XCTAssertTrue(result.shouldReverse)
        XCTAssertEqual(result.deltas.deltaAxis1, -3)
    }

    func testProcessorScrollTuningIsPerDevice() {
        let processor = MouseScrollEventProcessor(
            configuration: MouseEnhancerConfiguration(
                reverseMouseHorizontal: false,
                reverseMouseVertical: false,
                reverseTrackpadHorizontal: false,
                reverseTrackpadVertical: false,
                mouseScrollStep: 40,
                mouseScrollGain: 2
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
        XCTAssertFalse(result.isTuned)
        XCTAssertEqual(result.deltas.pointDeltaAxis1, 10)
        XCTAssertEqual(result.deltas.fixedPointDeltaAxis1, 2, accuracy: 0.001)
    }

    func testConfigurationInstallsEventTapForScrollTuningOnly() {
        let off = MouseEnhancerConfiguration(
            reverseMouseHorizontal: false,
            reverseMouseVertical: false,
            reverseTrackpadHorizontal: false,
            reverseTrackpadVertical: false
        )
        let tuningOnly = MouseEnhancerConfiguration(
            reverseMouseHorizontal: false,
            reverseMouseVertical: false,
            reverseTrackpadHorizontal: false,
            reverseTrackpadVertical: false,
            mouseScrollStep: 40
        )

        XCTAssertFalse(off.shouldInstallEventTap)
        XCTAssertFalse(off.hasAnyScrollTuning)
        XCTAssertTrue(tuningOnly.shouldInstallEventTap)
        XCTAssertTrue(tuningOnly.hasMouseEnhancement)
        XCTAssertFalse(tuningOnly.hasTrackpadEnhancement)
    }

    func testStorePersistsAndNormalizesScrollTuning() {
        let storage = MouseEnhancerMemoryStorage()
        let store = MouseEnhancerStore(storage: storage)

        store.setMouseScrollStep(500)
        store.setMouseScrollGain(9)
        store.setTrackpadScrollStep(30)
        store.setTrackpadScrollGain(0.05)

        XCTAssertEqual(store.configuration.mouseScrollStep, 120)
        XCTAssertEqual(store.configuration.mouseScrollGain, 5)
        XCTAssertEqual(store.configuration.trackpadScrollStep, 30)
        XCTAssertEqual(store.configuration.trackpadScrollGain, 0.1)
        XCTAssertEqual(storage.values["mouse-enhancer.scroll-tuning.mouse.step"] as? Double, 120)

        let reloaded = MouseEnhancerStore(storage: storage)
        XCTAssertEqual(reloaded.configuration.mouseScrollStep, 120)
        XCTAssertEqual(reloaded.configuration.mouseScrollGain, 5)
        XCTAssertEqual(reloaded.configuration.trackpadScrollStep, 30)
        XCTAssertEqual(reloaded.configuration.trackpadScrollGain, 0.1)
    }

    func testScrollTuningSliderCommitUpdatesRunningSession() {
        let session = MockMouseEnhancerSession()
        let plugin = makePlugin(session: session, accessibilityTrusted: true)

        plugin.handleSettingsAction(.setNumber(
            controlID: "mouse-scroll-step",
            value: 40,
            phase: .committed
        ))
        plugin.handleSettingsAction(.setNumber(
            controlID: "mouse-scroll-gain",
            value: 2,
            phase: .committed
        ))

        XCTAssertEqual(session.activatedConfigurations.count, 1)
        XCTAssertTrue(session.activatedConfigurations[0].hasMouseScrollTuning)
        let configuration = session.updatedConfigurations.last
        XCTAssertEqual(configuration?.mouseScrollStep, 40)
        XCTAssertEqual(configuration?.mouseScrollGain, 2)
    }

    private func makePlugin(
        storage: MouseEnhancerMemoryStorage? = nil,
        session: MockMouseEnhancerSession? = nil,
        middleClickSession: MockMouseEnhancerMiddleClickSession? = nil,
        hostVersion: String = "1.1.6",
        accessibilityTrusted: Bool = true,
        requestAccessibilityTrust: Bool = true,
        inputMonitoringStatus: MouseEnhancerInputMonitoringAuthorizationStatus = .granted
    ) -> MouseEnhancerPlugin {
        let storage = storage ?? MouseEnhancerMemoryStorage()
        return MouseEnhancerPlugin(
            context: PluginRuntimeContext(pluginID: "mouse-enhancer", storage: storage),
            session: session ?? MockMouseEnhancerSession(),
            makeMiddleClickSession: {
                middleClickSession ?? MockMouseEnhancerMiddleClickSession()
            },
            hostVersion: hostVersion,
            accessibilityTrusted: { accessibilityTrusted },
            requestAccessibilityTrust: { _ in requestAccessibilityTrust },
            inputMonitoringAuthorizationStatus: { inputMonitoringStatus },
            openURL: { _ in }
        )
    }
}
