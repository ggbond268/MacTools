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
        XCTAssertNotNil(plugin.rowState.errorMessage)
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

    func testTuningClampsIntegerOverflowAndPreservesUnscaledDeltas() {
        let input = MouseScrollDeltas(
            deltaAxis1: .max,
            deltaAxis2: .min,
            pointDeltaAxis1: .max,
            pointDeltaAxis2: .min,
            fixedPointDeltaAxis1: 1,
            fixedPointDeltaAxis2: -1
        )
        let result = MouseScrollTuning(step: 40, gain: 5).apply(input)

        XCTAssertEqual(result.deltaAxis1, .max)
        XCTAssertEqual(result.deltaAxis2, .min)
        XCTAssertEqual(result.pointDeltaAxis1, .max)
        XCTAssertEqual(result.pointDeltaAxis2, .min)
        XCTAssertEqual(result.fixedPointDeltaAxis1, 5)
        XCTAssertEqual(result.fixedPointDeltaAxis2, -5)
        XCTAssertEqual(MouseScrollTuning(step: 40, gain: 1).apply(input), input)
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

    func testGlideAccumulatorAccumulatesSameDirectionAndResetsOnReverse() {
        var accumulator = MouseScrollGlideAccumulator()

        accumulator.add(tickY: 40, tickX: 0)
        accumulator.add(tickY: 30, tickX: 0)
        XCTAssertEqual(accumulator.bufferY, 70)
        XCTAssertEqual(accumulator.currentY, 0)

        accumulator.add(tickY: -25, tickX: 0)
        XCTAssertEqual(accumulator.bufferY, -25)
        XCTAssertEqual(accumulator.currentY, 0)

        accumulator.add(tickY: 0, tickX: 12)
        XCTAssertEqual(accumulator.bufferY, 0)
        XCTAssertEqual(accumulator.bufferX, 12)

        accumulator.reset()
        XCTAssertTrue(accumulator.isDrained)
    }

    func testGlideAccumulatorAdvanceDecaysTowardBufferAndDrains() {
        var accumulator = MouseScrollGlideAccumulator()
        accumulator.add(tickY: 120, tickX: 0)

        var emitted = 0.0
        var frames = 0
        while !accumulator.isDrained && frames < 10_000 {
            let frame = accumulator.advance(framePeriod: 1.0 / 60.0, duration: 1.5)
            emitted += frame.y
            XCTAssertGreaterThanOrEqual(frame.y, 0)
            XCTAssertEqual(frame.y, frame.y.rounded())
            frames += 1
        }

        XCTAssertTrue(accumulator.isDrained)
        XCTAssertEqual(emitted, 120)
        // The glide spans a few multiples of the configured duration, not a
        // couple of frames and not forever.
        let elapsed = Double(frames) / 60.0
        XCTAssertTrue((1.0...4.0).contains(elapsed), "drain took \(elapsed)s")
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
