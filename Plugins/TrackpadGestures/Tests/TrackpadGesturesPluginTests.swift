import AppKit
import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
import MultitouchSupport
@testable import TrackpadGesturesPlugin

@MainActor
private final class MutableBool {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private final class LockedTestBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedNativeEventResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Bool] = []

    var values: [Bool] { lock.withLock { storedValues } }

    func append(_ value: Bool) {
        lock.withLock { storedValues.append(value) }
    }
}

private final class SendableCGEvent: @unchecked Sendable {
    let value: CGEvent

    init(_ value: CGEvent) {
        self.value = value
    }
}

private final class TrackpadFrameDeliveryBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryStarted = DispatchSemaphore(value: 0)
    private let allowDeliveryToFinish = DispatchSemaphore(value: 0)
    private let invalidationStarted = DispatchSemaphore(value: 0)
    private var storedEvents: [String] = []

    var events: [String] { lock.withLock { storedEvents } }

    func pauseDelivery() {
        deliveryStarted.signal()
        allowDeliveryToFinish.wait()
        lock.withLock { storedEvents.append("delivery") }
    }

    func waitForDelivery() -> DispatchTimeoutResult {
        deliveryStarted.wait(timeout: .now() + 1)
    }

    func startInvalidation() {
        invalidationStarted.signal()
    }

    func waitForInvalidationAttempt() -> DispatchTimeoutResult {
        invalidationStarted.wait(timeout: .now() + 1)
    }

    func finishDelivery() {
        allowDeliveryToFinish.signal()
    }

    func recordReset() {
        lock.withLock { storedEvents.append("reset") }
    }
}

private final class FakeMultitouchRuntime: MultitouchRuntimeProviding {
    private struct Registration {
        let deviceSourceID: UInt
        let callback: MTFrameCallbackWithRefconFunction
        let refcon: UnsafeMutableRawPointer
        var isActive: Bool
    }

    private var retainedDevices: [NSObject]
    private var descriptors: [MultitouchDeviceDescriptor]
    private var registrations: [Registration] = []
    private(set) weak var collectionLifetimeOwner: NSObject?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(deviceCount: Int) {
        var retainedDevices: [NSObject] = []
        var descriptors: [MultitouchDeviceDescriptor] = []
        retainedDevices.reserveCapacity(deviceCount)
        descriptors.reserveCapacity(deviceCount)

        for index in 0 ..< deviceCount {
            retainedDevices.append(NSObject())
            let transport: MultitouchDeviceTransport = index == 0 ? .builtIn : .bluetooth
            descriptors.append(MultitouchDeviceDescriptor(
                deviceID: UInt64(index + 1),
                isBuiltIn: index == 0,
                transport: transport
            ))
        }

        self.retainedDevices = retainedDevices
        self.descriptors = descriptors
    }

    init(descriptors: [MultitouchDeviceDescriptor]) {
        retainedDevices = descriptors.map { _ in NSObject() }
        self.descriptors = descriptors
    }

    func replaceDevices(with descriptors: [MultitouchDeviceDescriptor]) {
        retainedDevices = descriptors.map { _ in NSObject() }
        self.descriptors = descriptors
    }

    func createDeviceCollection() -> MultitouchDeviceCollection? {
        let owner = NSObject()
        collectionLifetimeOwner = owner
        return MultitouchDeviceCollection(
            entries: zip(retainedDevices, descriptors).map { object, descriptor in
                MultitouchDeviceEntry(
                    device: unsafeBitCast(object, to: MTDevice.self),
                    descriptor: descriptor
                )
            },
            lifetimeOwner: owner
        )
    }

    func register(
        _ device: MTDevice,
        callback: MTFrameCallbackWithRefconFunction,
        refcon: UnsafeMutableRawPointer
    ) {
        registerCount += 1
        registrations.append(Registration(
            deviceSourceID: callbackSourceID(device),
            callback: callback,
            refcon: refcon,
            isActive: true
        ))
    }

    func unregister(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction) {
        unregisterCount += 1
        let sourceID = callbackSourceID(device)
        guard let index = registrations.lastIndex(where: {
            $0.deviceSourceID == sourceID && $0.isActive
        }) else { return }
        registrations[index].isActive = false
    }

    func start(_ device: MTDevice) {
        startCount += 1
    }

    func stop(_ device: MTDevice) {
        stopCount += 1
    }

    func emitFrame(
        deviceIndex: Int,
        timestamp: TimeInterval,
        registrationOrdinal: Int? = nil
    ) {
        let device = unsafeBitCast(retainedDevices[deviceIndex], to: MTDevice.self)
        let sourceID = callbackSourceID(device)
        let matchingRegistrations = registrations.filter { $0.deviceSourceID == sourceID }
        let registration: Registration?
        if let registrationOrdinal {
            registration = matchingRegistrations.indices.contains(registrationOrdinal)
                ? matchingRegistrations[registrationOrdinal]
                : nil
        } else {
            registration = matchingRegistrations.last(where: \.isActive)
        }
        registration?.callback(device, nil, 0, timestamp, 0, registration?.refcon)
    }

    func resolvedCallbackGate(
        deviceIndex: Int,
        registrationOrdinal: Int
    ) -> MultitouchFrameCallbackGate? {
        let device = unsafeBitCast(retainedDevices[deviceIndex], to: MTDevice.self)
        let sourceID = callbackSourceID(device)
        let matchingRegistrations = registrations.filter { $0.deviceSourceID == sourceID }
        guard matchingRegistrations.indices.contains(registrationOrdinal) else { return nil }
        return MultitouchCallbackContextRegistry.shared.gate(
            for: matchingRegistrations[registrationOrdinal].refcon
        )
    }

    private func callbackSourceID(_ device: MTDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }
}

private final class LockedFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [TrackpadContactFrame] = []

    func append(_ frame: TrackpadContactFrame) {
        lock.withLock { frames.append(frame) }
    }

    var snapshot: [TrackpadContactFrame] {
        lock.withLock { frames }
    }
}

private final class TrackpadRecognitionFrameBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let framePaused = DispatchSemaphore(value: 0)
    private let continueFrame = DispatchSemaphore(value: 0)
    private var shouldPauseNextFrame = false

    func arm() {
        lock.withLock { shouldPauseNextFrame = true }
    }

    func pauseIfArmed() {
        let shouldPause = lock.withLock {
            guard shouldPauseNextFrame else { return false }
            shouldPauseNextFrame = false
            return true
        }
        guard shouldPause else { return }
        framePaused.signal()
        continueFrame.wait()
    }

    func waitUntilPaused() -> DispatchTimeoutResult {
        framePaused.wait(timeout: .now() + 1)
    }

    func resume() {
        continueFrame.signal()
    }
}

private struct TrackpadRestoreTransactionFixture: Codable {
    let mappings: Data?
    let ignoresGesturesWhileTyping: Bool?
    let typingGracePeriod: TimeInterval?
}

@MainActor
private final class TrackpadGestureMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class MockMultitouchDeviceSession: MultitouchDeviceSessionManaging,
    MultitouchDeviceTestingSessionManaging {
    var onRecognized: ((
        TrackpadGesture,
        UInt64,
        TimeInterval?,
        TrackpadGestureRecognitionEvidence?
    ) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    var onTestingSnapshot: ((TrackpadGestureTestSnapshot) -> Void)?
    var onTestingReset: (() -> Void)?
    var testingDeviceDescriptors: [MultitouchDeviceDescriptor] = []
    private(set) var isActive = false
    var deviceCount = 1
    private(set) var activations: [Set<TrackpadGesture>] = []
    private(set) var updates: [Set<TrackpadGesture>] = []
    private(set) var deactivateCount = 0
    private(set) var middleClickGestureUpdates: [Set<TrackpadGesture>] = []
    private(set) var resolvedMiddleClicks: [(TrackpadGesture, UInt64)] = []
    private(set) var nativeClickResolutionUpdates: [[TrackpadGesture: TrackpadNativeClickResolution]] = []
    private(set) var typingProtectionUpdates: [(Bool, TimeInterval)] = []
    private(set) var configurationDeliveryInvalidationCount = 0
    var activationSucceeds = true
    var resolvesMiddleClicks = false
    var acceptsNativeClickResolution = true
    private(set) var testingModeUpdates: [TrackpadGestureTestingMode?] = []
    private(set) var currentTestingMode: TrackpadGestureTestingMode?

    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        activations.append(gestures)
        isActive = activationSucceeds
        return activationSucceeds
    }

    func update(gestures: Set<TrackpadGesture>) {
        updates.append(gestures)
    }

    func invalidatePendingDeliveriesForConfigurationChange() {
        configurationDeliveryInvalidationCount += 1
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        middleClickGestureUpdates.append(gestures)
    }

    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool {
        resolvedMiddleClicks.append((gesture, deviceID))
        return resolvesMiddleClicks
    }

    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {
        nativeClickResolutionUpdates.append(resolutions)
        middleClickGestureUpdates.append(Set(resolutions.compactMap { gesture, resolution in
            resolution == .middleClick ? gesture : nil
        }))
    }

    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64,
        evidence: TrackpadGestureRecognitionEvidence?
    ) -> TrackpadNativeClickResolution? {
        resolvedMiddleClicks.append((gesture, deviceID))
        guard acceptsNativeClickResolution else { return nil }
        guard resolvesMiddleClicks else {
            return nativeClickResolutionUpdates.last?[gesture] == .consume ? .consume : nil
        }
        return nativeClickResolutionUpdates.last?[gesture]
    }

    func updateTestingMode(_ mode: TrackpadGestureTestingMode?) {
        currentTestingMode = mode
        testingModeUpdates.append(mode)
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingProtectionUpdates.append((isEnabled, gracePeriod))
    }

    func deactivate() {
        deactivateCount += 1
        isActive = false
        currentTestingMode = nil
    }

    func recognize(_ gesture: TrackpadGesture, deviceID: UInt64 = 1) {
        onRecognized?(gesture, deviceID, nil, nil)
    }

    func reportAvailability(_ available: Bool) {
        isActive = available
        onAvailabilityChange?(available)
    }

    func reportTestingSnapshot(_ snapshot: TrackpadGestureTestSnapshot) {
        onTestingSnapshot?(snapshot)
    }

    func reportTestingReset() {
        onTestingReset?()
    }
}

@MainActor
private final class MockTrackpadGestureActionExecutor: TrackpadGestureActionExecuting {
    private(set) var actions: [TrackpadGestureAction] = []
    func execute(_ action: TrackpadGestureAction) { actions.append(action) }
}

@MainActor
private final class MockMultitouchFrameListener: MultitouchFrameListening {
    var deviceCount = 1
    var connectedDeviceIDs: Set<UInt64> = [1]
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable (TrackpadContactFrame) -> Void)?
    private var retainedHandlers: [@Sendable (TrackpadContactFrame) -> Void] = []

    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        startCount += 1
        self.handler = startSucceeds ? handler : nil
        if startSucceeds {
            retainedHandlers.append(handler)
        }
        return startSucceeds
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func send(_ frame: TrackpadContactFrame, usingStart index: Int? = nil) {
        if let index {
            retainedHandlers[index](frame)
        } else {
            handler?(frame)
        }
    }

    func currentHandlerForTests() -> (@Sendable (TrackpadContactFrame) -> Void)? {
        handler
    }
}

@MainActor
private final class MockTrackpadListenerLease: TrackpadListenerLeaseManaging {
    var acquireSucceeds = true
    var shouldRetryAfterFailedAcquisition = true
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private var isHeld = false

    func acquire() -> Bool {
        acquireCount += 1
        guard acquireSucceeds else { return false }
        isHeld = true
        return true
    }

    func release() {
        guard isHeld else { return }
        isHeld = false
        releaseCount += 1
    }
}

@MainActor
final class TrackpadGestureStoreTests: XCTestCase {
    func testCanonicalSettingsOrderGroupsGestureFamilies() {
        XCTAssertEqual(TrackpadGesture.configurableCases, [
            .tipTapLeftOneFixed,
            .tipTapRightOneFixed,
            .tipTapLeftTwoFixed,
            .tipTapMiddleTwoFixed,
            .tipTapRightTwoFixed,
            .threeFingerTap,
            .fourFingerTap,
            .fiveFingerTap,
            .threeFingerDoubleTap,
            .fourFingerDoubleTap,
            .fiveFingerDoubleTap,
            .twoFingerClick,
            .threeFingerClick,
            .threeFingerLongTouch,
            .fourFingerLongTouch,
            .fiveFingerLongTouch,
        ])
        XCTAssertEqual(TrackpadGesture.threeFingerTap.settingsOrder, 5)
        XCTAssertEqual(TrackpadGesture.threeFingerClick.settingsOrder, 12)
    }

    func testMiddleClickOverlapFingerCountsCoverShortContactFamilies() {
        XCTAssertEqual(TrackpadGesture.threeFingerTap.middleClickOverlapFingerCount, 3)
        XCTAssertEqual(TrackpadGesture.fourFingerDoubleTap.middleClickOverlapFingerCount, 4)
        XCTAssertEqual(TrackpadGesture.threeFingerClick.middleClickOverlapFingerCount, 3)
        XCTAssertEqual(TrackpadGesture.tipTapLeftTwoFixed.middleClickOverlapFingerCount, 3)

        XCTAssertNil(TrackpadGesture.twoFingerClick.middleClickOverlapFingerCount)
        XCTAssertNil(TrackpadGesture.tipTapLeftOneFixed.middleClickOverlapFingerCount)
        XCTAssertNil(TrackpadGesture.threeFingerLongTouch.middleClickOverlapFingerCount)
    }

    func testEnabledOverlappingTapFingerCountsRequireMatchingEnabledMappings() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let threeFingerTap = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )
        let threeFingerDoubleTap = TrackpadGestureMapping(
            gesture: .threeFingerDoubleTap,
            action: .middleClick
        )
        let fourFingerTap = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )
        var fourFingerDoubleTap = TrackpadGestureMapping(
            gesture: .fourFingerDoubleTap,
            action: .middleClick
        )
        fourFingerDoubleTap.isEnabled = false

        XCTAssertTrue(store.save(threeFingerTap))
        XCTAssertTrue(store.save(threeFingerDoubleTap))
        XCTAssertTrue(store.save(fourFingerTap))
        XCTAssertTrue(store.save(fourFingerDoubleTap))
        XCTAssertEqual(store.enabledOverlappingTapFingerCounts, [3])
        XCTAssertEqual(
            store.enabledOverlappingTapFingerCounts { $0 != .threeFingerDoubleTap },
            []
        )

        XCTAssertTrue(store.setEnabled(false, id: threeFingerTap.id))
        XCTAssertTrue(store.setEnabled(true, id: fourFingerDoubleTap.id))
        XCTAssertEqual(store.enabledOverlappingTapFingerCounts, [4])
    }

    func testMappingViewPreferencesPersistWithoutChangingMappingOrder() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let first = TrackpadGestureMapping(
            gesture: .fiveFingerLongTouch,
            action: .middleClick
        )
        let second = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))

        store.setMappingSort(.actionName)
        store.setMappingStatusFilter(.disabled)
        store.setMappingActionFilter(.middleClick)

        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappingSort, .actionName)
        XCTAssertEqual(reloaded.mappingStatusFilter, .disabled)
        XCTAssertEqual(reloaded.mappingActionFilter, .middleClick)
        XCTAssertEqual(reloaded.mappings.map(\.id), [first.id, second.id])

        reloaded.resetMappingViewPreferences()
        let reset = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reset.mappingSort, .gesture)
        XCTAssertEqual(reset.mappingStatusFilter, .all)
        XCTAssertEqual(reset.mappingActionFilter, .all)
        XCTAssertEqual(reset.mappings.map(\.id), [first.id, second.id])
    }

    func testTypingProtectionDefaultsPersistAndClampGracePeriod() {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)

        XCTAssertTrue(store.ignoresGesturesWhileTyping)
        XCTAssertEqual(store.typingGracePeriod, 0.4)

        store.setIgnoresGesturesWhileTyping(false)
        store.setTypingGracePeriod(2.0)
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertFalse(reloaded.ignoresGesturesWhileTyping)
        XCTAssertEqual(reloaded.typingGracePeriod, 1.0)

        reloaded.setTypingGracePeriod(0)
        XCTAssertEqual(reloaded.typingGracePeriod, 0.2)
    }

    func testAddEditToggleDeleteAndPersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        var mapping = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(shortcut)
        )

        XCTAssertTrue(store.save(mapping))
        mapping.isEnabled = false
        XCTAssertTrue(store.save(mapping))
        XCTAssertFalse(store.mappings[0].isEnabled)

        store.setEnabled(true, id: mapping.id)
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [TrackpadGestureMapping(
            id: mapping.id,
            gesture: mapping.gesture,
            action: mapping.action,
            isEnabled: true
        )])

        reloaded.delete(id: mapping.id)
        XCTAssertTrue(TrackpadGestureStore(storage: storage, legacyMiddleClick: nil).mappings.isEmpty)
    }

    func testSingleKeyMappingPersistsRightCommandIdentity() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let keyTap = KeyboardKeyTap(keyCode: UInt16(kVK_RightCommand))
        let mapping = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .keyTap(keyTap)
        )

        XCTAssertTrue(store.save(mapping))
        XCTAssertEqual(
            TrackpadGestureStore(storage: storage, legacyMiddleClick: nil).mappings,
            [mapping]
        )
    }

    func testUnsupportedSingleKeyMappingIsRejectedAndFilteredFromPersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let invalid = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .keyTap(KeyboardKeyTap(keyCode: .max))
        )
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)

        XCTAssertFalse(store.save(invalid))
        storage.set(try JSONEncoder().encode([invalid]), forKey: "mappings")
        XCTAssertTrue(
            TrackpadGestureStore(storage: storage, legacyMiddleClick: nil).mappings.isEmpty
        )
    }

    func testMappingMutationsPublishOnlyAfterDurablePersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let mapping = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(store.save(mapping))
        storage.blockedSetKeys = ["mappings"]
        var edited = mapping
        edited.action = .action(ActionReference(
            key: ActionKey(providerID: "test", actionID: "blocked-edit")
        ))

        XCTAssertFalse(store.save(edited))
        XCTAssertFalse(store.setEnabled(false, id: mapping.id))
        XCTAssertFalse(store.delete(id: mapping.id))
        XCTAssertEqual(store.mappings, [mapping])
        XCTAssertEqual(store.enabledGestures, [mapping.gesture])

        storage.blockedSetKeys = []
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [mapping])
    }

    func testMacToolsActionPersistsMigratesAndPortableBackupRoundTrips() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let original = ActionReference(
            key: ActionKey(providerID: "example", actionID: "run"),
            schemaVersion: 1
        )
        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .fourFingerLongTouch,
            action: .action(original)
        )))

        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mapping(for: .fourFingerLongTouch)?.action, .action(original))
        let context = TrackpadActionHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { reference in
                ActionReference(
                    key: reference.key,
                    schemaVersion: 2,
                    parameters: reference.parameters
                )
            },
            execute: { _ in }
        )
        XCTAssertTrue(reloaded.migrateActions(using: context))
        guard case let .action(migrated)? = reloaded.mapping(for: .fourFingerLongTouch)?.action else {
            return XCTFail("Expected a canonical action mapping")
        }
        XCTAssertEqual(migrated.schemaVersion, 2)

        let backup = try XCTUnwrap(reloaded.portableBackup())
        let restored = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertEqual(restored.mappings, reloaded.mappings)
    }

    func testPortableBackupFiltersOnlyNonportableCanonicalActions() throws {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let portable = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "portable")
        )
        let local = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "local")
        )
        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .action(portable)
        )))
        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .action(local)
        )))
        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .fiveFingerTap,
            action: .middleClick
        )))
        let context = TrackpadActionHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            canExport: { $0 != local },
            canRestore: { $0 != local },
            execute: { _ in }
        )

        let backup = try XCTUnwrap(store.portableBackup(using: context))
        XCTAssertEqual(store.actionReferences(inPortableBackup: backup), [portable])
        let restored = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        XCTAssertTrue(restored.restorePortableBackup(backup, using: context))
        XCTAssertEqual(Set(restored.mappings.map(\.gesture)), [.threeFingerTap, .fiveFingerTap])

        let unfiltered = try XCTUnwrap(store.portableBackup())
        XCTAssertFalse(restored.restorePortableBackup(unfiltered, using: context))
    }

    func testPortableBackupWriteFailureRollsBackAllSettings() throws {
        let source = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        XCTAssertTrue(source.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        source.setTypingGracePeriod(1.2)
        let backup = try XCTUnwrap(source.portableBackup())

        let storage = TrackpadGestureMemoryStorage()
        let destination = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let original = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(destination.save(original))
        destination.setIgnoresGesturesWhileTyping(false)
        destination.setTypingGracePeriod(0.8)
        storage.blockedSetKeys = ["ignore-while-typing"]

        XCTAssertFalse(destination.restorePortableBackup(backup))
        storage.blockedSetKeys = []
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [original])
        XCTAssertFalse(reloaded.ignoresGesturesWhileTyping)
        XCTAssertEqual(reloaded.typingGracePeriod, 0.8)
    }

    func testPortableRestoreRejectsWrongTypedRawMappingWithoutRemovingIt() throws {
        let source = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        XCTAssertTrue(source.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        let backup = try XCTUnwrap(source.portableBackup())
        let storage = TrackpadGestureMemoryStorage()
        storage.values["mappings"] = "sentinel"
        let destination = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)

        XCTAssertFalse(destination.restorePortableBackup(backup))
        XCTAssertEqual(storage.object(forKey: "mappings") as? String, "sentinel")
    }

    func testInitializationRecoversInterruptedPortableRestoreJournal() throws {
        let storage = TrackpadGestureMemoryStorage()
        let originalStore = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let original = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(originalStore.save(original))
        originalStore.setIgnoresGesturesWhileTyping(false)
        originalStore.setTypingGracePeriod(0.8)
        let transaction = TrackpadRestoreTransactionFixture(
            mappings: storage.data(forKey: "mappings"),
            ignoresGesturesWhileTyping: false,
            typingGracePeriod: 0.8
        )
        storage.values["portable-restore-transaction.v1"] = try JSONEncoder().encode(transaction)
        storage.values["mappings"] = try JSONEncoder().encode([
            TrackpadGestureMapping(gesture: .threeFingerTap, action: .middleClick),
        ])
        storage.values["ignore-while-typing"] = true
        storage.values["typing-grace-period"] = 1.2

        let recovered = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)

        XCTAssertEqual(recovered.mappings, [original])
        XCTAssertFalse(recovered.ignoresGesturesWhileTyping)
        XCTAssertEqual(recovered.typingGracePeriod, 0.8)
        XCTAssertNil(storage.data(forKey: "portable-restore-transaction.v1"))
    }

    func testDuplicateGestureIsRejectedEvenWhenExistingMappingIsDisabled() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let first = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick,
            isEnabled: false
        )
        let duplicate = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 1, modifiers: .command))
        )

        XCTAssertTrue(store.save(first))
        XCTAssertFalse(store.save(duplicate))
        XCTAssertEqual(store.conflictingMapping(for: .fourFingerTap)?.id, first.id)
    }

    func testAvailableGesturesExcludeConfiguredRowsButKeepEditedRowsCurrentGesture() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let first = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .middleClick,
            isEnabled: false
        )
        let second = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))

        XCTAssertFalse(store.availableGestures().contains(.tipTapLeftOneFixed))
        XCTAssertFalse(store.availableGestures().contains(.fourFingerTap))

        let editingFirst = store.availableGestures(excludingID: first.id)
        XCTAssertTrue(editingFirst.contains(.tipTapLeftOneFixed))
        XCTAssertFalse(editingFirst.contains(.fourFingerTap))
        XCTAssertTrue(editingFirst.contains(.fiveFingerLongTouch))
        XCTAssertTrue(editingFirst.contains(.threeFingerDoubleTap))
        XCTAssertTrue(editingFirst.contains(.fourFingerDoubleTap))
        XCTAssertTrue(editingFirst.contains(.fiveFingerDoubleTap))
    }

    func testDoubleTapGesturesCanBePersistedAsMappings() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )

        for gesture in [
            TrackpadGesture.threeFingerDoubleTap,
            .fourFingerDoubleTap,
            .fiveFingerDoubleTap,
        ] {
            XCTAssertTrue(store.save(TrackpadGestureMapping(
                gesture: gesture,
                action: .middleClick
            )))
        }
        XCTAssertEqual(store.mappings.count, 3)
    }

    func testPhysicalClickGesturesCanBePersistedAsMappings() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )

        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .twoFingerClick,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )))
        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .threeFingerClick,
            action: .middleClick
        )))
        XCTAssertEqual(store.mappings.map(\.gesture), [.twoFingerClick, .threeFingerClick])
    }

    func testShortcutReuseLookupAllowsButReportsOtherMappings() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let shortcut = ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        let first = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(shortcut),
            isEnabled: false
        )
        let second = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(shortcut)
        )
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))

        XCTAssertEqual(store.mappings(using: shortcut).map(\.id), [first.id, second.id])
        XCTAssertEqual(
            store.mappings(using: shortcut, excludingID: second.id).map(\.id),
            [first.id]
        )
    }

    func testLegacyMiddleClickMigratesOnceForUnchangedObservedPreferences() {
        let storage = TrackpadGestureMemoryStorage()
        let legacy = LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 5)

        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: legacy)
        XCTAssertEqual(store.mappings.count, 1)
        XCTAssertEqual(store.mappings[0].gesture, .fiveFingerTap)
        XCTAssertEqual(store.mappings[0].action, .middleClick)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
        XCTAssertTrue(store.didPersistPortablePreferencesDuringInitialization)

        let reloaded = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: legacy
        )
        XCTAssertEqual(reloaded.mappings, store.mappings)
        XCTAssertFalse(reloaded.didPersistPortablePreferencesDuringInitialization)
    }

    func testDisabledLegacyMiddleClickMigratesAsDisabledAndPreservesFingerCount() {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: false, fingerCount: 4)
        )

        XCTAssertEqual(store.mappings.count, 1)
        XCTAssertEqual(store.mappings[0].gesture, .fourFingerTap)
        XCTAssertEqual(store.mappings[0].action, .middleClick)
        XCTAssertFalse(store.mappings[0].isEnabled)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testLegacyMiddleClickMergesIntoNonConflictingExistingMappings() throws {
        let storage = TrackpadGestureMemoryStorage()
        let existing = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )
        storage.set(try JSONEncoder().encode([existing]), forKey: "mappings")

        let store = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 4)
        )

        XCTAssertEqual(store.mappings.map(\.gesture), [.tipTapLeftOneFixed, .fourFingerTap])
        XCTAssertEqual(store.mapping(for: .fourFingerTap)?.action, .middleClick)
    }

    func testExistingSameGestureMappingWinsLegacyMigrationCollision() throws {
        let storage = TrackpadGestureMemoryStorage()
        let shortcut = ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        let existing = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .keyboardShortcut(shortcut)
        )
        storage.set(try JSONEncoder().encode([existing]), forKey: "mappings")

        let store = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 3)
        )

        XCTAssertEqual(store.mappings, [existing])
        XCTAssertEqual(store.mapping(for: .threeFingerTap)?.action, .keyboardShortcut(shortcut))
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testReupgradeMigratesLegacyPreferenceCreatedDuringDowngrade() {
        let storage = TrackpadGestureMemoryStorage()

        let firstUpgrade = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertTrue(firstUpgrade.mappings.isEmpty)
        XCTAssertNil(storage.object(forKey: "migration.mouse-enhancer-middle-click.v2"))

        // Simulate the marker written by Trackpad Gestures 1.0.0 before the user downgraded.
        storage.set(true, forKey: "migration.mouse-enhancer-middle-click.v1")
        let reupgrade = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 5)
        )

        XCTAssertEqual(reupgrade.mappings.count, 1)
        XCTAssertEqual(reupgrade.mapping(for: .fiveFingerTap)?.action, .middleClick)
        XCTAssertEqual(reupgrade.mapping(for: .fiveFingerTap)?.isEnabled, true)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testReupgradeUpdatesOnlyMigrationOwnedMappingAfterDowngradeEdit() throws {
        let storage = TrackpadGestureMemoryStorage()
        let initial = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 3)
        )
        let importedID = try XCTUnwrap(initial.mapping(for: .threeFingerTap)?.id)
        let deliberate = TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 17, modifiers: .command))
        )
        XCTAssertTrue(initial.save(deliberate))

        let reupgrade = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: false, fingerCount: 4)
        )

        XCTAssertNil(reupgrade.mapping(for: .threeFingerTap))
        XCTAssertEqual(reupgrade.mapping(for: .fourFingerTap)?.id, importedID)
        XCTAssertEqual(reupgrade.mapping(for: .fourFingerTap)?.action, .middleClick)
        XCTAssertEqual(reupgrade.mapping(for: .fourFingerTap)?.isEnabled, false)
        XCTAssertEqual(reupgrade.mapping(for: .tipTapRightOneFixed), deliberate)
    }

    func testReupgradePreservesUserMappingThatConflictsWithDowngradedLegacyChoice() {
        let storage = TrackpadGestureMemoryStorage()
        let deliberate = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 1, modifiers: [.command, .shift]))
        )
        let initial = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertTrue(initial.save(deliberate))

        let reupgrade = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 4)
        )

        XCTAssertEqual(reupgrade.mappings, [deliberate])
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testLegacyPreferenceReaderDoesNotRemoveDowngradeKeys() throws {
        let suiteName = "TrackpadGestureStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enabledKey = "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        let countKey = "plugin.mouse-enhancer.mouse-enhancer.middle-click.finger-count"
        defaults.set(true, forKey: enabledKey)
        defaults.set(4, forKey: countKey)

        XCTAssertEqual(
            LegacyMiddleClickPreferences.load(from: defaults),
            LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 4)
        )
        XCTAssertEqual(defaults.object(forKey: enabledKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: countKey) as? Int, 4)
    }
}

@MainActor
final class TrackpadGesturesPluginTests: XCTestCase {
    func testFailedTypingMutationAndIdenticalRestoreDoNotEmitPersistentPreferenceSignal() throws {
        let storage = TrackpadGestureMemoryStorage()
        let plugin = makePlugin(storage: storage).plugin
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        var notifications = 0
        plugin.onPersistentPreferencesChange = { notifications += 1 }
        notifications = 0

        storage.blockedSetKeys = ["ignore-while-typing", "typing-grace-period"]
        if plugin.store.setIgnoresGesturesWhileTyping(false) {
            plugin.configurationDidChange()
        }
        if plugin.store.setTypingGracePeriod(0.8) {
            plugin.configurationDidChange()
        }
        storage.blockedSetKeys = []
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))

        XCTAssertTrue(plugin.store.ignoresGesturesWhileTyping)
        XCTAssertEqual(plugin.store.typingGracePeriod, 0.4)
        XCTAssertEqual(notifications, 0)
    }

    func testActionPickerAccessibilityExposesConfirmationRequirement() {
        XCTAssertNil(TrackpadActionPickerAccessibility(
            isSafe: true,
            confirmationRequiredText: "Confirmation is required before running."
        ).confirmationValue)
        XCTAssertEqual(
            TrackpadActionPickerAccessibility(
                isSafe: false,
                confirmationRequiredText: "Confirmation is required before running."
            ).confirmationValue,
            "Confirmation is required before running."
        )
    }

    func testGestureRawValuesRemainCompatibleWithExistingMappingsAndBackups() {
        XCTAssertEqual(TrackpadGesture.allCases.map(\.rawValue), [
            "tipTapLeftOneFixed",
            "tipTapRightOneFixed",
            "tipTapLeftTwoFixed",
            "tipTapMiddleTwoFixed",
            "tipTapRightTwoFixed",
            "threeFingerTap",
            "fourFingerTap",
            "fiveFingerTap",
            "threeFingerLongTouch",
            "fourFingerLongTouch",
            "fiveFingerLongTouch",
            "threeFingerDoubleTap",
            "fourFingerDoubleTap",
            "fiveFingerDoubleTap",
            "twoFingerClick",
            "threeFingerClick",
        ])
    }

    func testMultitouchRuntimeResolvesRequiredSymbolsDynamically() {
        XCTAssertNotNil(MultitouchSupportRuntime.load())
    }

    func testMultitouchDriverFailsClosedWithoutRuntime() {
        let driver = MultitouchDeviceDriver(runtime: nil)

        XCTAssertFalse(driver.start { _ in })
        XCTAssertEqual(driver.deviceCount, 0)
    }

    func testMultitouchDriverStartsEveryDiscoveredDeviceWithoutSynchronousStatusCheck() {
        let runtime = FakeMultitouchRuntime(deviceCount: 2)
        let driver = MultitouchDeviceDriver(runtime: runtime)

        XCTAssertTrue(driver.start { _ in })
        XCTAssertEqual(driver.deviceCount, 2)
        XCTAssertEqual(runtime.registerCount, 2)
        XCTAssertEqual(runtime.startCount, 2)
        XCTAssertNotNil(runtime.collectionLifetimeOwner)

        driver.stop()
        XCTAssertEqual(runtime.unregisterCount, 2)
        XCTAssertEqual(runtime.stopCount, 2)
        XCTAssertNil(runtime.collectionLifetimeOwner)
    }

    func testMultitouchDriverTranslatesCallbackPointerToStableDeviceIDWithoutClockFiltering() {
        let runtime = FakeMultitouchRuntime(descriptors: [
            MultitouchDeviceDescriptor(
                deviceID: 42,
                isBuiltIn: false,
                transport: .bluetooth
            ),
        ])
        let driver = MultitouchDeviceDriver(runtime: runtime)
        let recorder = LockedFrameRecorder()

        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 0.01)

        XCTAssertEqual(recorder.snapshot.map(\.deviceID), [42])
        XCTAssertEqual(recorder.snapshot.map(\.timestamp), [0.01])
        XCTAssertEqual(driver.deviceDiagnostics, [
            MultitouchDeviceDiagnostics(
                descriptor: MultitouchDeviceDescriptor(
                    deviceID: 42,
                    isBuiltIn: false,
                    transport: .bluetooth
                ),
                deliveredFrameCount: 1,
                lastFrameTimestamp: 0.01
            ),
        ])
        driver.stop()
    }

    func testMultitouchDriverKeepsStableIDWhenRuntimeReturnsANewDevicePointer() {
        let descriptor = MultitouchDeviceDescriptor(
            deviceID: 42,
            isBuiltIn: false,
            transport: .usb
        )
        let runtime = FakeMultitouchRuntime(descriptors: [descriptor])
        let driver = MultitouchDeviceDriver(runtime: runtime)
        let recorder = LockedFrameRecorder()

        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 1)
        driver.stop()

        runtime.replaceDevices(with: [descriptor])
        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 0.001)

        XCTAssertEqual(recorder.snapshot.map(\.deviceID), [42, 42])
        XCTAssertEqual(recorder.snapshot.map(\.timestamp), [1, 0.001])
        driver.stop()
    }

    func testMultitouchDriverSeparatesDuplicateOrUnavailableDeviceIDs() {
        let runtime = FakeMultitouchRuntime(descriptors: [
            MultitouchDeviceDescriptor(deviceID: 0, isBuiltIn: true, transport: .builtIn),
            MultitouchDeviceDescriptor(deviceID: 0, isBuiltIn: false, transport: .bluetooth),
        ])
        let driver = MultitouchDeviceDriver(runtime: runtime)
        let recorder = LockedFrameRecorder()

        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 0.1)
        runtime.emitFrame(deviceIndex: 1, timestamp: 0.2)

        XCTAssertEqual(Set(recorder.snapshot.map(\.deviceID)).count, 2)
        XCTAssertFalse(recorder.snapshot.map(\.deviceID).contains(0))
        driver.stop()
    }

    func testMultitouchDriverRejectsLateCallbackAfterStop() {
        let runtime = FakeMultitouchRuntime(deviceCount: 1)
        let driver = MultitouchDeviceDriver(runtime: runtime)
        let recorder = LockedFrameRecorder()

        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 1)
        driver.stop()
        runtime.emitFrame(deviceIndex: 0, timestamp: 2)

        XCTAssertEqual(recorder.snapshot.map(\.timestamp), [1])
        XCTAssertEqual(runtime.registerCount, 1)
        XCTAssertEqual(runtime.unregisterCount, 1)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testMultitouchDriverRejectsPreviousRegistrationAfterRestartWithReusedDevicePointer() {
        let runtime = FakeMultitouchRuntime(deviceCount: 1)
        let driver = MultitouchDeviceDriver(runtime: runtime)
        let recorder = LockedFrameRecorder()

        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 1)
        driver.stop()

        XCTAssertTrue(driver.start { recorder.append($0) })
        runtime.emitFrame(deviceIndex: 0, timestamp: 2, registrationOrdinal: 0)
        runtime.emitFrame(deviceIndex: 0, timestamp: 3, registrationOrdinal: 1)

        XCTAssertEqual(recorder.snapshot.map(\.timestamp), [1, 3])
        XCTAssertEqual(runtime.registerCount, 2)
        XCTAssertEqual(runtime.unregisterCount, 1)
        driver.stop()
    }

    func testMultitouchDriverDoesNotReactivateGateResolvedBeforeRestart() throws {
        let runtime = FakeMultitouchRuntime(deviceCount: 1)
        let driver = MultitouchDeviceDriver(runtime: runtime)
        let recorder = LockedFrameRecorder()

        XCTAssertTrue(driver.start { recorder.append($0) })
        let oldGate = try XCTUnwrap(runtime.resolvedCallbackGate(
            deviceIndex: 0,
            registrationOrdinal: 0
        ))
        driver.stop()

        XCTAssertTrue(driver.start { recorder.append($0) })
        XCTAssertFalse(oldGate.deliver(TrackpadContactFrame(
            deviceID: 1,
            timestamp: 1,
            contacts: []
        )))
        runtime.emitFrame(deviceIndex: 0, timestamp: 2, registrationOrdinal: 1)

        XCTAssertEqual(recorder.snapshot.map(\.timestamp), [2])
        driver.stop()
    }

    func testMetadataAndEmptyState() {
        let plugin = makePlugin().plugin
        XCTAssertEqual(plugin.metadata.id, "trackpad-gestures")
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "尚未配置手势")
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility", "input-monitoring"])
    }

    func testSettingsPromoteGestureTestingIntoMappingsSection() throws {
        let page = try XCTUnwrap(makePlugin().plugin.settingsPage)
        guard case let .form(sections) = page.body else {
            return XCTFail("Expected form settings")
        }

        XCTAssertEqual(sections.map(\.id), ["mappings", "typing-protection"])
        XCTAssertNotNil(sections.first?.headerAccessory)
    }

    func testLeavingSettingsStopsGestureTesting() throws {
        let fixture = makePlugin()
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange(persistent: false)
        fixture.plugin.store.recordTestGesture(.threeFingerTap)
        let page = try XCTUnwrap(fixture.plugin.settingsPage)

        XCTAssertEqual(fixture.session.activations.last, Set(TrackpadGesture.allCases))
        let deactivateCount = fixture.session.deactivateCount

        page.visibilityHandler?(false)

        XCTAssertFalse(fixture.plugin.store.isTesting)
        XCTAssertNil(fixture.plugin.store.lastTestGesture)
        XCTAssertFalse(fixture.session.isActive)
        XCTAssertEqual(fixture.session.deactivateCount, deactivateCount + 1)
    }

    func testRepeatedTestRecognitionPublishesDistinctAnnouncementEvents() {
        let store = makePlugin().plugin.store

        store.recordTestGesture(.threeFingerTap)
        let firstSequence = store.testRecognitionSequence
        store.recordTestGesture(.threeFingerTap)

        XCTAssertEqual(store.lastTestGesture, .threeFingerTap)
        XCTAssertGreaterThan(store.testRecognitionSequence, firstSequence)
    }

    func testEnabledOverlappingMappingsPublishDeduplicatedSharedGestureClaims() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]))
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fiveFingerLongTouch,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fiveFingerDoubleTap,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerDoubleTap,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerClick,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapLeftTwoFixed,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .twoFingerClick,
            action: .middleClick
        )))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .middleClick
        )))

        XCTAssertEqual(
            fixture.plugin.activeInputGestureClaims.map(\.id),
            ["trackpad.tap.3", "trackpad.tap.4", "trackpad.tap.5"]
        )
        XCTAssertEqual(fixture.plugin.activeInputGestureClaims.count, 3)
    }

    func testTestingPublishesEveryOverlappingSharedGestureClaim() {
        let fixture = makePlugin()

        fixture.plugin.store.setTesting(true)

        XCTAssertEqual(
            fixture.plugin.activeInputGestureClaims.map(\.id),
            ["trackpad.tap.3", "trackpad.tap.4", "trackpad.tap.5"]
        )
    }

    func testEnabledMappingExecutesEveryRepeatedRecognizedAction() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        let mapping = TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .keyboardShortcut(shortcut)
        )
        XCTAssertTrue(fixture.plugin.store.save(mapping))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(fixture.session.activations, [[.tipTapRightOneFixed]])
        fixture.session.recognize(.tipTapRightOneFixed)
        fixture.session.recognize(.tipTapRightOneFixed)
        XCTAssertEqual(fixture.executor.actions, [
            .keyboardShortcut(shortcut),
            .keyboardShortcut(shortcut),
        ])
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapRightOneFixed],
            .consume
        )
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.0, true)
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.1, 0.4)
    }

    func testActionOnlyMappingChangeInvalidatesPendingDeliveriesButRefreshDoesNot() {
        let fixture = makePlugin()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let initialMapping = TrackpadGestureMapping(
            gesture: gesture,
            action: .keyboardShortcut(.init(keyCode: 0, modifiers: [.command]))
        )
        XCTAssertTrue(fixture.plugin.store.save(initialMapping))
        fixture.plugin.configurationDidChange()
        let firstInvalidationCount = fixture.session.configurationDeliveryInvalidationCount
        XCTAssertEqual(fixture.session.nativeClickResolutionUpdates.last?[gesture], .consume)

        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            id: initialMapping.id,
            gesture: gesture,
            action: .keyboardShortcut(.init(keyCode: 1, modifiers: [.command]))
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertEqual(
            fixture.session.configurationDeliveryInvalidationCount,
            firstInvalidationCount + 1
        )
        XCTAssertEqual(fixture.session.nativeClickResolutionUpdates.last?[gesture], .consume)

        fixture.plugin.refresh()
        XCTAssertEqual(
            fixture.session.configurationDeliveryInvalidationCount,
            firstInvalidationCount + 1
        )
    }

    func testTipTapActionExecutesOnlyAfterSessionDeliversCommittedRecognition() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command])
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(shortcut)
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        fixture.session.recognize(.tipTapLeftOneFixed)
        XCTAssertEqual(fixture.executor.actions, [.keyboardShortcut(shortcut)])
        XCTAssertTrue(fixture.session.resolvedMiddleClicks.isEmpty)
    }

    func testMacToolsActionUsesSharedHostExecutorAndConsumesTipTapClick() {
        let fixture = makePlugin()
        let reference = ActionReference(
            key: ActionKey(providerID: "action-grid", actionID: "show")
        )
        var executed: [ActionReference] = []
        fixture.plugin.trackpadActionHostContext = TrackpadActionHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            execute: { executed.append($0) }
        )
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .action(reference)
        )))

        fixture.plugin.configurationDidChange()
        fixture.session.recognize(.tipTapRightOneFixed)

        XCTAssertEqual(executed, [reference])
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapRightOneFixed],
            .consume
        )
    }

    func testConfiguredDoubleTapExecutesItsAction() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fiveFingerDoubleTap,
            action: .keyboardShortcut(shortcut)
        )))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(fixture.session.activations.last, [.fiveFingerDoubleTap])
        fixture.session.recognize(.fiveFingerDoubleTap)
        XCTAssertEqual(fixture.executor.actions, [.keyboardShortcut(shortcut)])
    }

    func testConfiguredGestureExecutesSingleRightCommandTap() {
        let fixture = makePlugin()
        let keyTap = KeyboardKeyTap(keyCode: UInt16(kVK_RightCommand))
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyTap(keyTap)
        )))

        fixture.plugin.configurationDidChange()
        fixture.session.recognize(.fourFingerTap)

        XCTAssertEqual(fixture.executor.actions, [.keyTap(keyTap)])
    }

    func testOrdinaryMultiFingerShortcutConsumesCorrelatedNativeClick() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.fourFingerTap],
            .consume
        )
    }

    func testPhysicalClickShortcutConsumesNativeClickAndExecutesWithoutResolvingTwice() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .twoFingerClick,
            action: .keyboardShortcut(shortcut)
        )))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.twoFingerClick],
            .consume
        )

        fixture.session.recognize(.twoFingerClick)

        XCTAssertEqual(fixture.executor.actions, [.keyboardShortcut(shortcut)])
        XCTAssertTrue(fixture.session.resolvedMiddleClicks.isEmpty)
    }

    func testPhysicalClickMappedToMiddleClickUsesNativeRewriteOnly() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerClick,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.threeFingerClick],
            .middleClick
        )

        fixture.session.recognize(.threeFingerClick)

        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertTrue(fixture.session.resolvedMiddleClicks.isEmpty)
    }

    func testTypingProtectionConfigurationIsForwardedToSession() {
        let fixture = makePlugin()
        fixture.plugin.store.setIgnoresGesturesWhileTyping(false)
        fixture.plugin.store.setTypingGracePeriod(0.8)
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.0, false)
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.1, 0.8)
    }

    func testRepeatedMiddleClickMappingIsResolvedBySessionWithoutSyntheticExecutorDuplicate() {
        let fixture = makePlugin()
        fixture.session.resolvesMiddleClicks = true
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()
        fixture.session.recognize(.threeFingerTap)
        fixture.session.recognize(.threeFingerTap)

        XCTAssertEqual(fixture.session.middleClickGestureUpdates.last, [.threeFingerTap])
        XCTAssertEqual(fixture.session.resolvedMiddleClicks.count, 2)
        XCTAssertEqual(fixture.session.resolvedMiddleClicks.first?.0, .threeFingerTap)
        XCTAssertEqual(fixture.session.resolvedMiddleClicks.first?.1, 1)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testRecognitionAfterDeactivationDoesNotExecuteAction() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        fixture.plugin.deactivate(reason: .disabled)
        fixture.session.recognize(.threeFingerTap)

        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testPermissionLossAtDeliveryStopsSessionAndDoesNotExecuteAction() {
        let accessibilityGranted = MutableBool(true)
        let fixture = makePlugin(accessibilityTrusted: { accessibilityGranted.value })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        accessibilityGranted.value = false
        fixture.session.recognize(.threeFingerTap)

        XCTAssertFalse(fixture.session.isActive)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertNotNil(fixture.plugin.primaryPanelState.errorMessage)
    }

    func testAutomaticListenerRecoveryClearsUnavailableError() {
        let fixture = makePlugin()
        fixture.session.activationSucceeds = false
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertNotNil(fixture.plugin.primaryPanelState.errorMessage)

        fixture.session.reportAvailability(true)

        XCTAssertNil(fixture.plugin.primaryPanelState.errorMessage)
    }

    func testFeatureExtractionReadinessRejectsListenerActivationFailure() {
        let fixture = makePlugin()
        fixture.session.activationSucceeds = false
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertThrowsError(try fixture.plugin.validateFeatureExtractionReadiness()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                fixture.plugin.primaryPanelState.errorMessage
            )
        }
    }

    func testFeatureExtractionReadinessRejectsAsynchronousListenerLoss() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        fixture.session.reportAvailability(false)

        XCTAssertThrowsError(try fixture.plugin.validateFeatureExtractionReadiness())
    }

    func testTestModeRecognizesWithoutExecutingActions() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()

        XCTAssertEqual(fixture.session.activations.last, Set(TrackpadGesture.allCases))
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.twoFingerClick],
            .consume
        )
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.threeFingerClick],
            .consume
        )
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapMiddleTwoFixed],
            .consume
        )
        fixture.session.recognize(.threeFingerTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .threeFingerTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)

        fixture.session.recognize(.fiveFingerDoubleTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .fiveFingerDoubleTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testTestModeDistinguishesTipTapContactPatternFromCommittedRecognition() {
        let fixture = makePlugin()
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        fixture.session.reportTestingSnapshot(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [gesture],
            recognition: nil
        ))

        XCTAssertEqual(fixture.plugin.testingModel.selectedSnapshot?.recognized, [gesture])
        XCTAssertEqual(
            fixture.plugin.testingModel.selectedContactPatternGesture,
            gesture
        )
        XCTAssertNil(fixture.plugin.testingModel.selectedRecognizedGesture)
        XCTAssertNil(fixture.plugin.store.lastTestGesture)

        fixture.session.recognize(gesture)
        XCTAssertNil(fixture.plugin.testingModel.selectedContactPatternGesture)
        XCTAssertEqual(fixture.plugin.testingModel.selectedRecognizedGesture, gesture)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, gesture)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testPracticeModeIgnoresOtherRecognizedGestures() {
        let fixture = makePlugin()
        let practicedGesture = TrackpadGesture.threeFingerTap
        fixture.plugin.store.setTesting(true)
        fixture.plugin.testingModel.begin(.practice(practicedGesture))
        fixture.plugin.configurationDidChange()
        fixture.session.reportTestingSnapshot(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [.fiveFingerTap],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: practicedGesture,
                phase: .tracking,
                anchorContacts: [],
                candidateContacts: [],
                requiredContactCount: 3,
                movementTolerance: 0.045,
                startedAt: nil,
                deadline: nil,
                thresholds: .default,
                rejectionSequence: 0
            )
        ))

        XCTAssertEqual(fixture.plugin.testingModel.selectedSnapshot?.recognized, [])
        fixture.session.recognize(.fiveFingerTap)
        XCTAssertNil(fixture.plugin.store.lastTestGesture)

        fixture.session.recognize(practicedGesture)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, practicedGesture)
        XCTAssertEqual(
            fixture.plugin.testingModel.selectedRecognizedGesture,
            practicedGesture
        )
    }

    func testPermissionRecoveryRestoresActiveTestingMode() {
        let accessibilityGranted = MutableBool(true)
        let fixture = makePlugin(accessibilityTrusted: { accessibilityGranted.value })
        let mode = TrackpadGestureTestingMode.practice(.threeFingerTap)
        fixture.plugin.store.setTesting(true)
        fixture.plugin.testingModel.begin(mode)
        fixture.plugin.configurationDidChange()
        XCTAssertEqual(fixture.session.currentTestingMode, mode)
        fixture.session.reportTestingSnapshot(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [],
            recognition: nil
        ))
        XCTAssertNotNil(fixture.plugin.testingModel.selectedSnapshot)

        accessibilityGranted.value = false
        fixture.plugin.refreshAccessibilityPermission()
        XCTAssertNil(fixture.session.currentTestingMode)
        XCTAssertFalse(fixture.session.isActive)
        XCTAssertNil(fixture.plugin.testingModel.selectedSnapshot)

        accessibilityGranted.value = true
        fixture.plugin.refreshAccessibilityPermission()
        XCTAssertEqual(fixture.session.currentTestingMode, mode)
        XCTAssertTrue(fixture.session.isActive)
    }

    func testPermissionRevocationStopsActiveListener() {
        let accessibilityGranted = MutableBool(true)
        let fixture = makePlugin(accessibilityTrusted: { accessibilityGranted.value })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertTrue(fixture.session.isActive)

        accessibilityGranted.value = false
        fixture.plugin.refreshAccessibilityPermission()
        XCTAssertFalse(fixture.session.isActive)
        XCTAssertNotNil(fixture.plugin.primaryPanelState.errorMessage)
    }

    func testInputMonitoringDenialPreventsActivationAndRequestsGuidance() {
        let fixture = makePlugin(inputMonitoringStatus: { .denied })
        var requestedPermission: String?
        fixture.plugin.requestPermissionGuidance = { requestedPermission = $0 }
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertTrue(fixture.session.activations.isEmpty)
        XCTAssertEqual(requestedPermission, "input-monitoring")
    }

    func testAppReactivationResamplesInputMonitoringGrantAndRevocation() async {
        let inputMonitoringGranted = MutableBool(false)
        let fixture = makePlugin(inputMonitoringStatus: {
            inputMonitoringGranted.value ? .granted : .denied
        })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )))
        fixture.plugin.activate(context: PluginRuntimeContext(pluginID: "trackpad-gestures"))
        XCTAssertFalse(fixture.session.isActive)

        inputMonitoringGranted.value = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        XCTAssertTrue(fixture.session.isActive)

        inputMonitoringGranted.value = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        XCTAssertFalse(fixture.session.isActive)
        fixture.plugin.deactivate(reason: .disabled)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func testDeactivationStopsListenerAndClearsTestMode() {
        let fixture = makePlugin()
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()
        fixture.plugin.deactivate(reason: .disabled)

        XCTAssertFalse(fixture.plugin.store.isTesting)
        XCTAssertFalse(fixture.session.isActive)
    }

    func testUpdateDeactivationAlwaysStopsCallbackBearingSession() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertTrue(fixture.session.isActive)
        fixture.plugin.store.setTesting(true)

        fixture.plugin.deactivate(reason: .updating)

        XCTAssertFalse(fixture.plugin.store.isTesting)
        XCTAssertFalse(fixture.session.isActive)
        XCTAssertEqual(fixture.session.deactivateCount, 1)
    }

    func testSessionRestartsDriverForWakeAndDeviceRecovery() {
        let driver = MockMultitouchFrameListener()
        var tapStarts = 0
        var tapStops = 0
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { tapStarts += 1; return true },
            testEventTapStop: { tapStops += 1 }
        )

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateWakeRecoveryForTests()
        session.simulateDeviceRecoveryForTests()

        XCTAssertEqual(driver.startCount, 3)
        XCTAssertGreaterThanOrEqual(driver.stopCount, 2)
        XCTAssertEqual(tapStarts, 3)
        XCTAssertEqual(tapStops, 2)
        session.deactivate()
    }

    func testLifecycleNotificationsSuppressFramesBeforeDelayedRestart() async {
        for notification in 0 ... 1 {
            let driver = MockMultitouchFrameListener()
            let session = MultitouchDeviceSession(
                driver: driver,
                testEventTapStart: { true },
                testEventTapStop: {},
                wakeRestartDelay: 1,
                deviceChangeRestartDelay: 1
            )
            let unexpectedRecognition = expectation(
                description: "lifecycle notification suppresses old callback \(notification)"
            )
            unexpectedRecognition.isInverted = true
            session.onRecognized = { _, _, _, _ in
                unexpectedRecognition.fulfill()
            }
            var testingResetCount = 0
            session.onTestingReset = {
                testingResetCount += 1
            }

            XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
            session.updateTestingMode(.practice(.threeFingerTap))
            if notification == 0 {
                session.simulateWakeNotificationForTests()
            } else {
                session.simulateDeviceRemovalNotificationForTests()
            }

            XCTAssertEqual(driver.startCount, 1)
            XCTAssertEqual(testingResetCount, 1)
            driver.send(makeThreeContactFrame(timestamp: 0.01), usingStart: 0)
            driver.send(.init(deviceID: 1, timestamp: 0.05, contacts: []), usingStart: 0)
            session.waitForRecognitionForTests()
            await fulfillment(of: [unexpectedRecognition], timeout: 0.05)
            XCTAssertEqual(driver.startCount, 1)
            session.deactivate()
        }
    }

    func testDeviceRecoveryRequiresZeroBeforeRecognizingOnRestartedDevice() async {
        let driver = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            deviceChangeRestartDelay: 0
        )
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(description: "fresh tap after lifecycle reset")
        session.onRecognized = { gesture, _, _, _ in
            recognized.append(gesture)
            freshRecognition.fulfill()
        }

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateDeviceRemovalNotificationForTests()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(driver.startCount, 2)

        driver.send(makeThreeContactFrame(timestamp: 0.10), usingStart: 1)
        driver.send(.init(deviceID: 1, timestamp: 0.17, contacts: []), usingStart: 1)
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        driver.send(makeThreeContactFrame(timestamp: 0.20), usingStart: 1)
        driver.send(.init(deviceID: 1, timestamp: 0.27, contacts: []), usingStart: 1)
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [.threeFingerTap])
        session.deactivate()
    }

    func testLifecycleRestartWaitsForGlobalTwoDeviceBoundaryBeforePhysicalClick() async throws {
        let driver = MockMultitouchFrameListener()
        driver.connectedDeviceIDs = [1, 2]
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.threeFingerClick
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(
            description: "fresh physical click after global contact reset"
        )
        freshRecognition.assertForOverFulfill = true
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { recognizedGesture, _, _, _ in
            recognized.append(recognizedGesture)
            freshRecognition.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let deviceOneContacts = makeThreeContactFrame(timestamp: 0.01).contacts
        let deviceTwoContacts = makeThreeContactFrame(timestamp: 0.02).contacts
        driver.send(.init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: deviceOneContacts
        ))
        driver.send(.init(
            deviceID: 2,
            timestamp: 0.02,
            contacts: deviceTwoContacts
        ))

        session.restartImmediatelyForTests()
        XCTAssertEqual(driver.startCount, 2)

        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: []))
        clock.value = 0.11
        driver.send(.init(deviceID: 2, timestamp: 0.11, contacts: deviceTwoContacts))
        clock.value = 0.12
        driver.send(.init(deviceID: 1, timestamp: 0.12, contacts: deviceOneContacts))
        clock.value = 0.13
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 901))
        ))
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 901))
        ))

        clock.value = 0.20
        driver.send(.init(deviceID: 2, timestamp: 0.20, contacts: []))
        clock.value = 0.21
        driver.send(.init(deviceID: 1, timestamp: 0.21, contacts: deviceOneContacts))
        clock.value = 0.22
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 902))
        ))
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 902))
        ))

        clock.value = 0.30
        driver.send(.init(deviceID: 1, timestamp: 0.30, contacts: []))
        clock.value = 0.40
        driver.send(.init(deviceID: 1, timestamp: 0.40, contacts: deviceOneContacts))
        clock.value = 0.41
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 903))
        ))
        clock.value = 0.42
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 903))
        ))
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [gesture])
    }

    func testLifecycleRestartWaitsForReplacementDeviceZeroBeforePhysicalClick() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.threeFingerClick
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(
            description: "fresh replacement-device click after contact reset"
        )
        freshRecognition.assertForOverFulfill = true
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 2) }
        )
        session.onRecognized = { recognizedGesture, _, _, _ in
            recognized.append(recognizedGesture)
            freshRecognition.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let contacts = makeThreeContactFrame(timestamp: 0.01).contacts
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: contacts))
        driver.connectedDeviceIDs = [2]
        session.restartImmediatelyForTests()
        XCTAssertEqual(driver.startCount, 2)

        clock.value = 0.10
        driver.send(.init(deviceID: 2, timestamp: 0.10, contacts: contacts))
        clock.value = 0.11
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 905))
        ))
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 905))
        ))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 0.20
        driver.send(.init(deviceID: 2, timestamp: 0.20, contacts: []))
        clock.value = 0.30
        driver.send(.init(deviceID: 2, timestamp: 0.30, contacts: contacts))
        clock.value = 0.31
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 906))
        ))
        clock.value = 0.32
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 906))
        ))
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [gesture])
    }

    func testInterprocessListenerLeaseAllowsOnlyOneOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackpadListenerLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = TrackpadInterprocessListenerLease(
            bundleIdentifier: "test.mactools",
            temporaryDirectory: directory,
            isAcquisitionAllowed: true
        )
        let second = TrackpadInterprocessListenerLease(
            bundleIdentifier: "media.jenny.mactools.dev",
            temporaryDirectory: directory,
            isAcquisitionAllowed: true
        )

        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())
        first.release()
        XCTAssertTrue(second.acquire())
        second.release()
    }

    func testInterprocessListenerLeaseNeverLetsATestHostOwnTheProductionListener() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackpadListenerTestHostLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let testHostLease = TrackpadInterprocessListenerLease(
            bundleIdentifier: "test.mactools",
            temporaryDirectory: directory,
            isAcquisitionAllowed: false
        )
        let installedAppLease = TrackpadInterprocessListenerLease(
            bundleIdentifier: "test.mactools",
            temporaryDirectory: directory,
            isAcquisitionAllowed: true
        )

        XCTAssertFalse(testHostLease.acquire())
        XCTAssertTrue(installedAppLease.acquire())
        installedAppLease.release()
    }

    func testListenerProcessPolicyPrefersTheStableInstalledDebugApp() {
        let home = URL(fileURLWithPath: "/Users/developer", isDirectory: true)
        let installedApp = home.appendingPathComponent(
            "Applications/MacTools Dev.app",
            isDirectory: true
        )
        let staleBuild = URL(fileURLWithPath: "/repo/build/Debug/MacTools Dev.app")

        XCTAssertFalse(TrackpadListenerProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: false,
            bundleIdentifier: "com.example.mactools.dev",
            currentBundleURL: staleBuild,
            productName: "MacTools Dev",
            homeDirectory: home,
            fileExists: { $0 == installedApp.path }
        ))
        XCTAssertTrue(TrackpadListenerProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: false,
            bundleIdentifier: "com.example.mactools.dev",
            currentBundleURL: installedApp,
            productName: "MacTools Dev",
            homeDirectory: home,
            fileExists: { $0 == installedApp.path }
        ))
    }

    func testListenerProcessPolicyDoesNotChangeProductionOrFirstRunBehavior() {
        let home = URL(fileURLWithPath: "/Users/developer", isDirectory: true)
        let buildApp = URL(fileURLWithPath: "/repo/build/Debug/MacTools.app")

        XCTAssertTrue(TrackpadListenerProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: false,
            bundleIdentifier: "com.example.mactools",
            currentBundleURL: buildApp,
            productName: "MacTools",
            homeDirectory: home,
            fileExists: { _ in true }
        ))
        XCTAssertTrue(TrackpadListenerProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: false,
            bundleIdentifier: "com.example.mactools.dev",
            currentBundleURL: buildApp,
            productName: "MacTools Dev",
            homeDirectory: home,
            fileExists: { _ in false }
        ))
        XCTAssertFalse(TrackpadListenerProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: true,
            bundleIdentifier: "com.example.mactools",
            currentBundleURL: buildApp,
            productName: "MacTools",
            homeDirectory: home,
            fileExists: { _ in false }
        ))
    }

    func testSessionWaitsForExclusiveListenerLeaseBeforeStartingDeviceCallbacks() {
        let driver = MockMultitouchFrameListener()
        let lease = MockTrackpadListenerLease()
        lease.acquireSucceeds = false
        var tapStarts = 0
        var availability: [Bool] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            listenerLease: lease,
            testEventTapStart: { tapStarts += 1; return true },
            testEventTapStop: {}
        )
        session.onAvailabilityChange = { availability.append($0) }

        XCTAssertFalse(session.activate(gestures: [.threeFingerTap]))
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(tapStarts, 0)
        XCTAssertEqual(availability, [false])

        lease.acquireSucceeds = true
        session.restartImmediatelyForTests()

        XCTAssertTrue(session.isActive)
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(tapStarts, 1)
        XCTAssertEqual(availability, [false, true])
        session.deactivate()
        XCTAssertEqual(lease.releaseCount, 1)
    }

    func testSessionReleasesExclusiveListenerLeaseWhenStartupFails() {
        let driver = MockMultitouchFrameListener()
        driver.startSucceeds = false
        let lease = MockTrackpadListenerLease()
        let session = MultitouchDeviceSession(
            driver: driver,
            listenerLease: lease,
            testEventTapStart: { true },
            testEventTapStop: {}
        )

        XCTAssertFalse(session.activate(gestures: [.threeFingerTap]))
        XCTAssertEqual(lease.acquireCount, 1)
        XCTAssertEqual(lease.releaseCount, 1)
        session.deactivate()
    }

    func testSessionCanRecoverAfterEventTapRestartFailure() {
        let driver = MockMultitouchFrameListener()
        var eventTapResults = [true, false, true]
        var availability: [Bool] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { eventTapResults.removeFirst() },
            testEventTapStop: {}
        )
        session.onAvailabilityChange = { availability.append($0) }

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.restartImmediatelyForTests()
        XCTAssertFalse(session.isActive)

        session.restartImmediatelyForTests()
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(driver.startCount, 2)
        XCTAssertEqual(availability, [true, false, true])
        session.deactivate()
    }

    func testRealSessionPropagatesFrameListenerStartupFailureToExtractionReadiness() {
        let driver = MockMultitouchFrameListener()
        driver.startSucceeds = false
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {}
        )
        let plugin = TrackpadGesturesPlugin(
            context: PluginRuntimeContext(
                pluginID: "trackpad-gestures",
                storage: TrackpadGestureMemoryStorage()
            ),
            legacyMiddleClick: nil,
            session: session,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: { _ in true },
            inputMonitoringStatus: { .granted },
            openURL: { _ in }
        )
        XCTAssertTrue(plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))

        plugin.configurationDidChange()

        XCTAssertFalse(session.isActive)
        XCTAssertThrowsError(try plugin.validateFeatureExtractionReadiness())
        XCTAssertEqual(driver.startCount, 1)

        driver.startSucceeds = true
        session.restartImmediatelyForTests()
        XCTAssertTrue(session.isActive)
        XCTAssertNoThrow(try plugin.validateFeatureExtractionReadiness())
        XCTAssertEqual(driver.startCount, 2)
        plugin.deactivate(reason: .disabled)
    }

    func testEnablingLocalGestureRequestsOwnershipForTrackpadGestures() {
        let (plugin, _, _) = makePlugin()
        let mapping = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick,
            isEnabled: false
        )
        var ownershipRequests: [TrackpadGesture] = []
        plugin.requestTrackpadGestureOwnership = { ownershipRequests.append($0) }
        XCTAssertTrue(plugin.store.save(mapping))

        plugin.configurationDidChange()
        XCTAssertEqual(ownershipRequests, [])

        plugin.store.setEnabled(true, id: mapping.id)
        plugin.configurationDidChange()

        XCTAssertEqual(ownershipRequests, [.threeFingerTap])
    }

    func testExternalTipTapClaimConsumesTheNativeClick() {
        let (plugin, session, _) = makePlugin()
        let gesture = TrackpadGesture.tipTapLeftOneFixed

        plugin.setTrackpadGestureOwnership(localGestures: [], externalGestures: [gesture]) { _, _ in }
        plugin.activate(context: PluginRuntimeContext(pluginID: "trackpad-gestures"))

        XCTAssertEqual(session.nativeClickResolutionUpdates.last?[gesture], .consume)
    }

    func testExternalPhysicalClickClaimConsumesNativeClickAndPublishesMiddleClickConflict() {
        let (plugin, session, _) = makePlugin()
        let gesture = TrackpadGesture.threeFingerClick

        plugin.setTrackpadGestureOwnership(localGestures: [], externalGestures: [gesture]) { _, _ in }
        plugin.activate(context: PluginRuntimeContext(pluginID: "trackpad-gestures"))

        XCTAssertEqual(session.nativeClickResolutionUpdates.last?[gesture], .consume)
        XCTAssertEqual(plugin.activeInputGestureClaims.map(\.id), ["trackpad.tap.3"])
    }

    func testSessionRestartsDriverWhenDeviceRemovalNotificationArrives() async throws {
        let driver = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            deviceChangeRestartDelay: 0
        )

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateDeviceRemovalNotificationForTests()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(driver.startCount, 2)
        XCTAssertGreaterThanOrEqual(driver.stopCount, 1)
        session.deactivate()
    }

    func testSessionCoalescesRepeatedDeviceChangeNotifications() async throws {
        let driver = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            deviceChangeRestartDelay: 0.01
        )

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateDeviceRemovalNotificationForTests()
        session.simulateDeviceRemovalNotificationForTests()
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(driver.startCount, 2)
        session.deactivate()
    }

    func testFrameCallbackGateMapsStableDeviceIDAndAcceptsIndependentDeviceClock() {
        let gate = MultitouchFrameCallbackGate()
        let recorder = LockedFrameRecorder()
        gate.activate(deviceIDsByCallbackSource: [7: 70]) { recorder.append($0) }

        XCTAssertFalse(gate.deliver(TrackpadContactFrame(
            deviceID: 8, timestamp: 11, contacts: []
        )))
        XCTAssertTrue(gate.deliver(TrackpadContactFrame(
            deviceID: 7, timestamp: 0.001, contacts: []
        )))
        XCTAssertEqual(recorder.snapshot.map(\.deviceID), [70])
        XCTAssertEqual(recorder.snapshot.map(\.timestamp), [0.001])

        gate.invalidate()
        XCTAssertFalse(gate.deliver(TrackpadContactFrame(
            deviceID: 7, timestamp: 11, contacts: []
        )))
        XCTAssertEqual(recorder.snapshot.count, 1)
    }

    func testFrameCallbackGateInvalidationWaitsForAdmittedHandler() {
        let gate = MultitouchFrameCallbackGate()
        let barrier = TrackpadFrameDeliveryBarrier()
        let deliveryFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        gate.activate(deviceIDsByCallbackSource: [7: 70]) { _ in barrier.pauseDelivery() }

        DispatchQueue.global().async {
            gate.deliver(TrackpadContactFrame(deviceID: 7, timestamp: 10, contacts: []))
            deliveryFinished.signal()
        }
        XCTAssertEqual(barrier.waitForDelivery(), .success)
        DispatchQueue.global().async {
            barrier.startInvalidation()
            gate.invalidate()
            barrier.recordReset()
            invalidationFinished.signal()
        }
        XCTAssertEqual(barrier.waitForInvalidationAttempt(), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 0.05), .timedOut)

        barrier.finishDelivery()

        XCTAssertEqual(deliveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(barrier.events, ["delivery", "reset"])
    }

    func testFrameDeliveryGateInvalidationWaitsBeforeResettingAdmittedDelivery() {
        let gate = MultitouchFrameDeliveryGate()
        let generation = gate.beginGeneration()
        let barrier = TrackpadFrameDeliveryBarrier()
        let deliveryFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            gate.deliver(generation: generation) {
                barrier.pauseDelivery()
            }
            deliveryFinished.signal()
        }
        XCTAssertEqual(barrier.waitForDelivery(), .success)
        DispatchQueue.global().async {
            barrier.startInvalidation()
            gate.invalidate {
                barrier.recordReset()
            }
            invalidationFinished.signal()
        }
        XCTAssertEqual(barrier.waitForInvalidationAttempt(), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 0.05), .timedOut)

        barrier.finishDelivery()

        XCTAssertEqual(deliveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(barrier.events, ["delivery", "reset"])
        let rejectedDeliveryCount = LockedTestCounter()
        XCTAssertFalse(gate.deliver(generation: generation) {
            rejectedDeliveryCount.increment()
        })
        XCTAssertEqual(rejectedDeliveryCount.value, 0)
    }

    func testLifecycleContactResetRequiresGlobalBoundaryAcrossRecontactingDevices() {
        let gate = TrackpadLifecycleContactResetGate()
        let contacts = makeThreeContactFrame().contacts

        gate.beginSuppression(activeDeviceIDs: [2])
        gate.confirmConnectedDeviceIDs([1, 2])
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: []
        )))
        gate.completeSuppressedFrameProcessing()
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 2,
            timestamp: 0.02,
            contacts: contacts
        )))
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.03,
            contacts: contacts
        )))
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 2,
            timestamp: 0.04,
            contacts: []
        )))
        gate.completeSuppressedFrameProcessing()
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.05,
            contacts: []
        )))
        XCTAssertTrue(gate.isSuppressing)
        gate.completeSuppressedFrameProcessing()
        XCTAssertFalse(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.06,
            contacts: contacts
        )))
    }

    func testLifecycleContactResetRemovesConfirmedDisconnectedDevice() {
        let gate = TrackpadLifecycleContactResetGate()
        let contacts = makeThreeContactFrame().contacts

        gate.beginSuppression(activeDeviceIDs: [1, 2])
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: []
        )))
        gate.completeSuppressedFrameProcessing()
        gate.confirmConnectedDeviceIDs([1])

        XCTAssertFalse(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.02,
            contacts: contacts
        )))
    }

    func testLifecycleContactResetKeepsEmptyEpochActiveUntilFirstZero() {
        let gate = TrackpadLifecycleContactResetGate()
        let contacts = makeThreeContactFrame().contacts

        gate.beginSuppression(activeDeviceIDs: [])
        gate.confirmConnectedDeviceIDs([1, 2])
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: contacts
        )))
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.02,
            contacts: []
        )))
        XCTAssertTrue(gate.isSuppressing)
        gate.completeSuppressedFrameProcessing()
        XCTAssertFalse(gate.shouldSuppress(.init(
            deviceID: 1,
            timestamp: 0.03,
            contacts: contacts
        )))
    }

    func testLifecycleContactResetKeepsReplacementDeviceBlockedUntilZero() {
        let gate = TrackpadLifecycleContactResetGate()
        let contacts = makeThreeContactFrame().contacts

        gate.beginSuppression(activeDeviceIDs: [1])
        gate.confirmConnectedDeviceIDs([2])
        XCTAssertTrue(gate.isSuppressing)
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 2,
            timestamp: 0.01,
            contacts: contacts
        )))
        XCTAssertTrue(gate.shouldSuppress(.init(
            deviceID: 2,
            timestamp: 0.02,
            contacts: []
        )))
        XCTAssertTrue(gate.isSuppressing)
        gate.completeSuppressedFrameProcessing()
        XCTAssertFalse(gate.shouldSuppress(.init(
            deviceID: 2,
            timestamp: 0.03,
            contacts: contacts
        )))
    }

    func testNativePhysicalClickCannotOvertakePublishedContactFrameAdmission() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let admissionBarrier = TrackpadRecognitionFrameBarrier()
        let nativeResults = LockedNativeEventResultRecorder()
        let clickGesture = TrackpadGesture.threeFingerClick
        let tapGesture = TrackpadGesture.threeFingerTap
        var recognized: [TrackpadGesture] = []
        let clickRecognized = expectation(description: "physical click is recognized once")
        clickRecognized.assertForOverFulfill = true
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            recognitionAfterCandidatePublication: {
                admissionBarrier.pauseIfArmed()
            },
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { gesture, _, _, _ in
            recognized.append(gesture)
            if gesture == clickGesture {
                clickRecognized.fulfill()
            }
        }
        session.updateNativeClickResolutions([clickGesture: .consume])
        XCTAssertTrue(session.activate(gestures: [clickGesture, tapGesture]))
        defer {
            admissionBarrier.resume()
            session.deactivate()
        }

        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        session.waitForRecognitionForTests()
        let frameHandler = try XCTUnwrap(driver.currentHandlerForTests())
        let contacts = makeThreeContactFrame(timestamp: 0.10)
        let frameFinished = DispatchSemaphore(value: 0)
        admissionBarrier.arm()
        DispatchQueue.global().async {
            frameHandler(contacts)
            frameFinished.signal()
        }
        XCTAssertEqual(admissionBarrier.waitUntilPaused(), .success)

        let down = SendableCGEvent(try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 904
        )))
        let up = SendableCGEvent(try XCTUnwrap(makeMouseEvent(
            type: .leftMouseUp,
            eventNumber: 904
        )))
        let nativeEventsFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            clock.value = 0.11
            nativeResults.append(session.handleNativeEventForTests(
                type: .leftMouseDown,
                event: down.value
            ))
            clock.value = 0.12
            nativeResults.append(session.handleNativeEventForTests(
                type: .leftMouseUp,
                event: up.value
            ))
            nativeEventsFinished.signal()
        }
        XCTAssertEqual(
            nativeEventsFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )

        admissionBarrier.resume()
        XCTAssertEqual(frameFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(nativeEventsFinished.wait(timeout: .now() + 1), .success)
        clock.value = 0.20
        driver.send(.init(deviceID: 1, timestamp: 0.20, contacts: []))
        session.waitForRecognitionForTests()
        await fulfillment(of: [clickRecognized], timeout: 1)
        await Task.yield()

        XCTAssertEqual(nativeResults.values, [true, true])
        XCTAssertEqual(recognized, [clickGesture])
    }

    func testSessionRecordsCandidateSynchronouslyBeforeNativeEventsAndRecognition() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var postedTypes: [CGEventType] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { postedTypes.append($0.type) },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))

        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.02
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        clock.value = 0.03
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))

        XCTAssertEqual(postedTypes, [.otherMouseDown, .otherMouseUp])
        session.deactivate()
    }

    func testSessionFailsOpenFixedOnlyTipTapWhenNativeDragBegins() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var postedTypes: [CGEventType] = []
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { postedTypes.append($0.type) },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        let eventNumber: Int64 = 907
        clock.value = 0.11
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDown,
                eventNumber: eventNumber
            ))
        ))
        clock.value = 0.111
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDragged,
            event: try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDragged,
                eventNumber: eventNumber
            ))
        ))
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseDragged])

        clock.value = 0.112
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDragged,
            event: try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDragged,
                eventNumber: eventNumber
            ))
        ))
        clock.value = 0.113
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(
                type: .leftMouseUp,
                eventNumber: eventNumber
            ))
        ))
    }

    func testSessionReplaysFailedTipTapBeforeRapidValidRetry() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var postedTypes: [CGEventType] = []
        var acceptedGestures: [TrackpadGesture] = []
        let recognitionCommitted = expectation(description: "TipTap native click committed")
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { postedTypes.append($0.type) },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { recognized, deviceID, _, tipTapEpisodeID in
            XCTAssertEqual(deviceID, 1)
            XCTAssertNotNil(tipTapEpisodeID)
            acceptedGestures.append(recognized)
            recognitionCommitted.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let failedTap = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        driver.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [failedTap]))
        clock.value = 0.111
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.112
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        clock.value = 0.12
        driver.send(.init(deviceID: 1, timestamp: 0.12, contacts: fixed))

        // Do not yield to the main-queue rejection notification. The next native Down must drain
        // the failed episode synchronously before it buffers this rapid retry.
        let validTap = TrackpadContactSnapshot(identifier: 3, x: 0.1, y: 0.5)
        clock.value = 0.13
        driver.send(.init(deviceID: 1, timestamp: 0.13, contacts: fixed + [validTap]))
        clock.value = 0.131
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        clock.value = 0.132
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        clock.value = 0.18
        driver.send(.init(deviceID: 1, timestamp: 0.18, contacts: fixed))
        session.waitForRecognitionForTests()
        await fulfillment(of: [recognitionCommitted], timeout: 1)

        XCTAssertEqual(acceptedGestures, [gesture])
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
    }

    func testSessionUnsafeInventoryCorrelatesQualifiedTipTapNativePair() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { false },
            middleClickEventOrigin: { _ in .unknown }
        )
        let committed = expectation(description: "qualified TipTap is delivered")
        session.onRecognized = { recognizedGesture, deviceID, _, episodeID in
            XCTAssertEqual(recognizedGesture, gesture)
            XCTAssertEqual(deviceID, 1)
            XCTAssertNotNil(episodeID)
            committed.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        driver.send(.init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 2, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.16
        driver.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 1)

        clock.value = 0.17
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 601))
        ))
        clock.value = 0.18
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 601))
        ))
        await fulfillment(of: [committed], timeout: 1)
    }

    func testNoOpConfigurationRefreshPreservesPendingTipTapCommit() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let committed = expectation(description: "pending TipTap survives no-op refresh")
        var recognized: [TrackpadGesture] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { recognizedGesture, _, _, episodeID in
            XCTAssertNotNil(episodeID)
            recognized.append(recognizedGesture)
            committed.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        driver.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [tapping]))
        clock.value = 0.16
        driver.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()

        session.update(gestures: [gesture])
        session.updateNativeClickResolutions([gesture: .consume])
        clock.value = 0.161
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 701))
        ))
        clock.value = 0.162
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 701))
        ))
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertEqual(recognized, [gesture])
    }

    func testSessionReleasesEveryExpiredTipTapWithoutNativePair() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        for index in 0..<3 {
            let downAt = 0.11 + Double(index) * 0.50
            let upAt = downAt + 0.04
            clock.value = downAt
            driver.send(.init(
                deviceID: 1,
                timestamp: downAt,
                contacts: fixed + [
                    .init(identifier: index + 2, x: 0.1, y: 0.5),
                ]
            ))
            clock.value = upAt
            driver.send(.init(deviceID: 1, timestamp: upAt, contacts: fixed))
            session.waitForRecognitionForTests()
            await Task.yield()
            XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 1)

            clock.value = downAt + 0.40
            session.expireMiddleClickStateForTests()
            await Task.yield()
            XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 0)
        }
    }

    func testSessionRestartClearsPendingTipTapWithoutNativePair() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        driver.send(.init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 2, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.15
        driver.send(.init(deviceID: 1, timestamp: 0.15, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 1)

        session.restartImmediatelyForTests()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 0)
    }

    func testSessionConfigurationInvalidationAbandonsPendingTipTapAndAcceptsFreshEpisode() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let freshRecognition = expectation(description: "fresh TipTap commits after configuration")
        var recognized: [TrackpadGesture] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { recognizedGesture, _, _, _ in
            recognized.append(recognizedGesture)
            freshRecognition.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        driver.send(.init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 2, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.15
        driver.send(.init(deviceID: 1, timestamp: 0.15, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 1)

        session.invalidatePendingDeliveriesForConfigurationChange()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 0)
        clock.value = 0.16
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 801))
        ))
        clock.value = 0.17
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 801))
        ))
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 0.20
        driver.send(.init(
            deviceID: 1,
            timestamp: 0.20,
            contacts: fixed + [.init(identifier: 4, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.25
        driver.send(.init(deviceID: 1, timestamp: 0.25, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 1)
        clock.value = 0.251
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 802))
        ))
        clock.value = 0.252
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 802))
        ))
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [gesture])
    }

    func testUnsafeRecognitionOnSecondDevicePreservesFirstDevicePendingTipTap() async throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let allowsContactInference = LockedTestBoolean(true)
        let gesture = TrackpadGesture.tipTapLeftOneFixed
        let committed = expectation(description: "first device TipTap remains pending")
        var recognizedDeviceIDs: [UInt64] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { allowsContactInference.value },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { _, deviceID, _, episodeID in
            XCTAssertNotNil(episodeID)
            recognizedDeviceIDs.append(deviceID)
            committed.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        driver.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [tapping]))
        clock.value = 0.16
        driver.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()

        allowsContactInference.value = false
        clock.value = 0.17
        driver.send(.init(deviceID: 2, timestamp: 0.17, contacts: []))
        driver.send(.init(deviceID: 2, timestamp: 0.18, contacts: fixed))
        clock.value = 0.27
        driver.send(.init(deviceID: 2, timestamp: 0.27, contacts: fixed))
        clock.value = 0.28
        driver.send(.init(deviceID: 2, timestamp: 0.28, contacts: fixed + [tapping]))
        clock.value = 0.33
        driver.send(.init(deviceID: 2, timestamp: 0.33, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()

        clock.value = 0.34
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 702))
        ))
        clock.value = 0.341
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 702))
        ))
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertEqual(recognizedDeviceIDs, [1])
    }

    func testTypingSuppressionRemembersContactFrameQueuedBeforeKeyDown() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let recognitionBarrier = TrackpadRecognitionFrameBarrier()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            recognitionBeforeFrameProcessing: { recognitionBarrier.pauseIfArmed() },
            middleClickClock: { clock.value },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        var recognized: [TrackpadGesture] = []
        let committed = expectation(description: "TipTap committed after typing suppression")
        session.onRecognized = {
            gesture, _, _, _ in
            recognized.append(gesture)
            committed.fulfill()
        }
        session.updateNativeClickResolutions([.tipTapLeftOneFixed: .consume])
        session.updateTypingProtection(isEnabled: true, gracePeriod: 0.4)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer {
            recognitionBarrier.resume()
            session.deactivate()
        }

        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        session.waitForRecognitionForTests()

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        recognitionBarrier.arm()
        clock.value = 0.10
        listener.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        XCTAssertEqual(recognitionBarrier.waitUntilPaused(), .success)

        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        let keyUp = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        ))
        clock.value = 0.11
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))
        clock.value = 0.12
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyUp, event: keyUp))
        recognitionBarrier.resume()
        session.waitForRecognitionForTests()

        clock.value = 0.60
        listener.send(.init(deviceID: 1, timestamp: 0.60, contacts: fixed))
        clock.value = 0.61
        listener.send(.init(deviceID: 1, timestamp: 0.61, contacts: fixed + [tapping]))
        clock.value = 0.66
        listener.send(.init(deviceID: 1, timestamp: 0.66, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 0.70
        listener.send(.init(deviceID: 1, timestamp: 0.70, contacts: []))
        clock.value = 0.80
        listener.send(.init(deviceID: 1, timestamp: 0.80, contacts: fixed))
        clock.value = 0.89
        listener.send(.init(deviceID: 1, timestamp: 0.89, contacts: fixed))
        clock.value = 0.90
        listener.send(.init(deviceID: 1, timestamp: 0.90, contacts: fixed + [tapping]))
        clock.value = 0.95
        listener.send(.init(deviceID: 1, timestamp: 0.95, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertEqual(session.pendingTipTapRecognitionCountForTests, 1)
        clock.value = 0.951
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 301))
        ))
        clock.value = 0.952
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 301))
        ))
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testTypingSuppressionBlocksPhysicalClickUntilContactsReset() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let gesture = TrackpadGesture.threeFingerClick
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(
            description: "physical click recognized after typing contact reset"
        )
        freshRecognition.assertForOverFulfill = true
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { recognizedGesture, _, _, _ in
            recognized.append(recognizedGesture)
            freshRecognition.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        session.updateTypingProtection(isEnabled: true, gracePeriod: 0.4)
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        let occupiedFrame = makeThreeContactFrame(timestamp: 0.10)
        listener.send(occupiedFrame)
        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        let keyUp = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        ))
        clock.value = 0.11
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))
        clock.value = 0.12
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyUp, event: keyUp))

        clock.value = 0.20
        listener.send(.init(
            deviceID: 2,
            timestamp: 0.20,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)]
        ))

        clock.value = 0.60
        listener.send(makeThreeContactFrame(timestamp: 0.60))
        clock.value = 0.61
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 601))
        ))
        clock.value = 0.62
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 601))
        ))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 0.70
        listener.send(.init(deviceID: 1, timestamp: 0.70, contacts: []))
        clock.value = 1.00
        listener.send(makeThreeContactFrame(timestamp: 1.00))
        clock.value = 1.01
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 602))
        ))
        clock.value = 1.02
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 602))
        ))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 1.10
        listener.send(.init(deviceID: 2, timestamp: 1.10, contacts: []))
        clock.value = 1.11
        listener.send(.init(deviceID: 1, timestamp: 1.11, contacts: []))
        clock.value = 1.40
        listener.send(makeThreeContactFrame(timestamp: 1.40))
        clock.value = 1.41
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 603))
        ))
        clock.value = 1.42
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 603))
        ))
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [gesture])
    }

    func testStartingTestingModeWithTypingProtectionDisabledRequiresZeroBeforePhysicalClick()
        async throws {
        try await assertTestingModeTransitionRequiresContactReset(.start)
    }

    func testSwitchingTestingModeWithTypingProtectionDisabledRequiresZeroBeforePhysicalClick()
        async throws {
        try await assertTestingModeTransitionRequiresContactReset(.switchMode)
    }

    func testStoppingTestingModeWithTypingProtectionDisabledRequiresZeroBeforePhysicalClick()
        async throws {
        try await assertTestingModeTransitionRequiresContactReset(.stop)
    }

    func testSessionIgnoresMacToolsGeneratedShortcutKeysForTypingProtection() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        var recognized: [TrackpadGesture] = []
        let committed = expectation(description: "TipTap committed after synthetic key")
        session.onRecognized = {
            gesture, _, _, _ in
            recognized.append(gesture)
            committed.fulfill()
        }
        session.updateNativeClickResolutions([.tipTapLeftOneFixed: .consume])
        session.updateTypingProtection(isEnabled: true, gracePeriod: 1.0)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer { session.deactivate() }

        let generatedKey = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        for marker in [
            MacToolsSyntheticInputEvent.marker,
            MacToolsSyntheticInputEvent.legacyTrackpadGesturesMarker,
            MacToolsSyntheticInputEvent.supersededSharedMarker,
        ] {
            generatedKey.setIntegerValueField(.eventSourceUserData, value: marker)
            clock.value = 0.10
            XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: generatedKey))
        }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        listener.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [tapping]))
        listener.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        clock.value = 0.161
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 401))
        ))
        clock.value = 0.162
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 401))
        ))
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testKeyDownInvalidatesRecognitionQueuedForMainActorDelivery() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _, _, _ in recognized.append(gesture) }
        session.updateNativeClickResolutions([.tipTapLeftOneFixed: .consume])
        session.updateTypingProtection(isEnabled: true, gracePeriod: 0.4)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        listener.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [tapping]))
        listener.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()

        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        clock.value = 0.17
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))
        await Task.yield()

        XCTAssertTrue(recognized.isEmpty)
    }

    func testDisabledTypingProtectionDoesNotSuppressGestureAfterKeyDown() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        var recognized: [TrackpadGesture] = []
        let committed = expectation(description: "TipTap committed with typing protection off")
        session.onRecognized = {
            gesture, _, _, _ in
            recognized.append(gesture)
            committed.fulfill()
        }
        session.updateNativeClickResolutions([.tipTapLeftOneFixed: .consume])
        session.updateTypingProtection(isEnabled: false, gracePeriod: 1.0)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer { session.deactivate() }

        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        session.waitForRecognitionForTests()

        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        clock.value = 0.10
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        listener.send(.init(deviceID: 1, timestamp: 0.20, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.29, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.30, contacts: fixed + [tapping]))
        listener.send(.init(deviceID: 1, timestamp: 0.35, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        clock.value = 0.351
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 501))
        ))
        clock.value = 0.352
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 501))
        ))
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testSessionRejectsRetainedListenerCallbackAfterRestart() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.restartImmediatelyForTests()

        driver.send(makeThreeContactFrame(), usingStart: 0)
        clock.value = 0.01
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 101))
        ))

        // Move beyond the fail-safe window created by the passed-through stale-click probe,
        // reset every contact, then prove the current generation accepts fresh frames.
        clock.value = 0.39
        driver.send(.init(deviceID: 1, timestamp: 0.39, contacts: []), usingStart: 1)
        clock.value = 0.40
        driver.send(makeThreeContactFrame(timestamp: 0.40), usingStart: 1)
        clock.value = 0.41
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 202))
        ))
        session.deactivate()
    }

    func testSessionDeactivationDrainsLongHeldRewrittenOriginalUp() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var releaseCount = 0
        let session = makeMiddleClickSession(
            driver: driver,
            now: { clock.value },
            releaseMiddleButton: { releaseCount += 1 }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))
        clock.value = 0.02
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 101))
        ))

        session.deactivate()

        XCTAssertEqual(releaseCount, 1)
        clock.value = TrackpadMiddleClickCoordinator.nativeClickOwnershipWindow + 0.03
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 101))
        ))
    }

    func testEventTapDisableBalancesRewrittenDownAndSuppressesItsOriginalUp() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var releaseCount = 0
        let session = makeMiddleClickSession(
            driver: driver,
            now: { clock.value },
            releaseMiddleButton: { releaseCount += 1 }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))
        clock.value = 0.02
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 201))
        ))

        session.simulateEventTapDisableForTests()

        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 201))
        ))
        session.deactivate()
    }

    func testLifecycleSuppressionDrainsLongHeldConsumedAndConvertedPairs() throws {
        for (index, resolution) in [
            TrackpadNativeClickResolution.consume,
            .middleClick,
        ].enumerated() {
            for resetCause in 0 ... 3 {
                let driver = MockMultitouchFrameListener()
                let clock = LockedTestClock()
                var releaseCount = 0
                let session = makeMiddleClickSession(
                    driver: driver,
                    now: { clock.value },
                    releaseMiddleButton: { releaseCount += 1 },
                    wakeRestartDelay: 1,
                    deviceChangeRestartDelay: 1
                )
                session.updateNativeClickResolutions([.threeFingerTap: resolution])
                session.updateTypingProtection(isEnabled: true, gracePeriod: 1)
                XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))

                driver.send(makeThreeContactFrame())
                clock.value = 0.01
                XCTAssertEqual(
                    session.resolveNativeClick(for: .threeFingerTap, deviceID: 1),
                    resolution
                )
                let eventNumber = Int64(300 + index * 10 + resetCause)
                clock.value = 0.02
                XCTAssertEqual(
                    session.handleNativeEventForTests(
                        type: .leftMouseDown,
                        event: try XCTUnwrap(makeMouseEvent(
                            type: .leftMouseDown,
                            eventNumber: eventNumber
                        ))
                    ),
                    resolution == .consume
                )

                switch resetCause {
                case 0:
                    session.simulateEventTapDisableForTests()
                case 1:
                    let keyDown = try XCTUnwrap(CGEvent(
                        keyboardEventSource: nil,
                        virtualKey: 0,
                        keyDown: true
                    ))
                    clock.value = 0.03
                    XCTAssertFalse(session.handleNativeEventForTests(
                        type: .keyDown,
                        event: keyDown
                    ))
                case 2:
                    session.simulateWakeNotificationForTests()
                default:
                    session.simulateDeviceRemovalNotificationForTests()
                }

                XCTAssertEqual(
                    releaseCount,
                    resolution == .middleClick ? 1 : 0
                )
                clock.value = TrackpadMiddleClickCoordinator.nativeClickOwnershipWindow + 0.04
                XCTAssertTrue(session.handleNativeEventForTests(
                    type: .leftMouseUp,
                    event: try XCTUnwrap(makeMouseEvent(
                        type: .leftMouseUp,
                        eventNumber: eventNumber
                    ))
                ))
                session.deactivate()
            }
        }
    }

    func testEventTapDisableInvalidatesQueuedFrameRecognition() async {
        let driver = MockMultitouchFrameListener()
        let barrier = TrackpadRecognitionFrameBarrier()
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(description: "fresh gesture after event-tap recovery")
        freshRecognition.assertForOverFulfill = true
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            recognitionBeforeFrameProcessing: { barrier.pauseIfArmed() }
        )
        session.onRecognized = { gesture, _, _, _ in
            recognized.append(gesture)
            freshRecognition.fulfill()
        }
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        defer { session.deactivate() }

        driver.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        driver.send(makeThreeContactFrame(timestamp: 0.01))
        barrier.arm()
        driver.send(.init(deviceID: 1, timestamp: 0.05, contacts: []))
        XCTAssertEqual(barrier.waitUntilPaused(), .success)

        session.simulateEventTapDisableForTests()
        barrier.resume()
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: []))
        driver.send(makeThreeContactFrame(timestamp: 0.11))
        driver.send(.init(deviceID: 1, timestamp: 0.16, contacts: []))
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [.threeFingerTap])
    }

    func testEventTapDisableInvalidatesQueuedPhysicalClickRecognition() async throws {
        let driver = MockMultitouchFrameListener()
        let barrier = TrackpadRecognitionFrameBarrier()
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(description: "fresh physical click after recovery")
        freshRecognition.assertForOverFulfill = true
        let gesture = TrackpadGesture.threeFingerClick
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            recognitionBeforeFrameProcessing: { barrier.pauseIfArmed() },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { value, _, _, _ in
            recognized.append(value)
            freshRecognition.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        barrier.arm()
        driver.send(makeThreeContactFrame(timestamp: 0.01))
        XCTAssertEqual(barrier.waitUntilPaused(), .success)
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 901))
        ))
        session.simulateEventTapDisableForTests()
        barrier.resume()
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        driver.send(.init(deviceID: 1, timestamp: 0.10, contacts: []))
        driver.send(makeThreeContactFrame(timestamp: 0.11))
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 902))
        ))
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 902))
        ))
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [gesture])
    }

    func testNativeClickInventoryCacheFailsClosedUntilBackgroundRefreshCompletes() {
        let verdict = LockedTestBoolean(true)
        let loadCount = LockedTestCounter()
        let cache = TrackpadNativeClickSourceInventoryCache(loadVerdict: {
            loadCount.increment()
            return verdict.value
        })

        XCTAssertFalse(cache.allowsContactInference())
        cache.invalidateAndRefresh()
        XCTAssertFalse(cache.allowsContactInference())
        cache.waitUntilIdleForTests()
        XCTAssertTrue(cache.allowsContactInference())
        XCTAssertEqual(loadCount.value, 1)

        verdict.value = false
        cache.invalidateAndRefresh()
        XCTAssertFalse(cache.allowsContactInference())
        cache.waitUntilIdleForTests()
        XCTAssertFalse(cache.allowsContactInference())
        XCTAssertEqual(loadCount.value, 2)
    }

    func testNativeClickInventoryCacheRequiresContinuousTopologyMonitoring() {
        let loadCount = LockedTestCounter()
        let cache = TrackpadNativeClickSourceInventoryCache(
            requiresMonitoring: true,
            loadVerdict: {
                loadCount.increment()
                return true
            }
        )

        cache.invalidateAndRefresh()
        cache.waitUntilIdleForTests()
        XCTAssertFalse(cache.allowsContactInference())
        XCTAssertEqual(loadCount.value, 0)

        cache.setMonitoringAvailable(true)
        cache.invalidateAndRefresh()
        cache.waitUntilIdleForTests()
        XCTAssertTrue(cache.allowsContactInference())
        XCTAssertEqual(loadCount.value, 1)

        cache.setMonitoringAvailable(false)
        XCTAssertFalse(cache.allowsContactInference())
        cache.invalidateAndRefresh()
        cache.waitUntilIdleForTests()
        XCTAssertFalse(cache.allowsContactInference())
        XCTAssertEqual(loadCount.value, 1)
    }

    func testHIDTopologyInvalidationFailsClosedBeforeDeferredRefresh() throws {
        let cache = TrackpadNativeClickSourceInventoryCache(
            requiresMonitoring: true,
            loadVerdict: { true }
        )
        cache.setMonitoringAvailable(true)
        cache.invalidateAndRefresh()
        cache.waitUntilIdleForTests()
        XCTAssertTrue(cache.allowsContactInference())

        cache.invalidate()

        let event = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertEqual(
            TrackpadNativeEventOriginClassifier.origin(
                for: event,
                allowsContactInference: { cache.allowsContactInference() }
            ),
            .unknown
        )

        cache.invalidateAndRefresh()
        cache.waitUntilIdleForTests()
        XCTAssertTrue(cache.allowsContactInference())
    }

    func testTestingLifecycleResetClearsRawSnapshotsWithoutStoppingPractice() {
        let fixture = makePlugin()
        let mode = TrackpadGestureTestingMode.practice(.threeFingerTap)
        fixture.plugin.store.setTesting(true)
        fixture.plugin.testingModel.begin(mode)
        fixture.session.reportTestingSnapshot(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [],
            recognition: nil
        ))
        XCTAssertNotNil(fixture.plugin.testingModel.selectedSnapshot)

        fixture.session.reportTestingReset()

        XCTAssertNil(fixture.plugin.testingModel.selectedSnapshot)
        XCTAssertEqual(fixture.plugin.testingModel.mode, mode)
    }

    private func makeMiddleClickSession(
        driver: MockMultitouchFrameListener,
        now: @escaping @Sendable () -> TimeInterval,
        releaseMiddleButton: @escaping @Sendable @MainActor () -> Void,
        wakeRestartDelay: TimeInterval = 10,
        deviceChangeRestartDelay: TimeInterval = 2
    ) -> MultitouchDeviceSession {
        MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            wakeRestartDelay: wakeRestartDelay,
            deviceChangeRestartDelay: deviceChangeRestartDelay,
            middleClickClock: now,
            synthesizeMiddleClick: {},
            releaseMiddleButton: releaseMiddleButton,
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
    }

    private enum TestingModeContactResetTransition: String {
        case start
        case switchMode
        case stop
    }

    private func assertTestingModeTransitionRequiresContactReset(
        _ transition: TestingModeContactResetTransition
    ) async throws {
        let listener = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let gesture = TrackpadGesture.threeFingerClick
        var recognized: [TrackpadGesture] = []
        let freshRecognition = expectation(
            description: "fresh physical click after \(transition.rawValue) reset"
        )
        freshRecognition.assertForOverFulfill = true
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.onRecognized = { recognizedGesture, _, _, _ in
            recognized.append(recognizedGesture)
            freshRecognition.fulfill()
        }
        session.updateNativeClickResolutions([gesture: .consume])
        session.updateTypingProtection(isEnabled: false, gracePeriod: 0.4)
        XCTAssertTrue(session.activate(gestures: [gesture]))
        defer { session.deactivate() }

        if transition != .start {
            session.updateTestingMode(.allGestures)
            session.updateTypingProtection(isEnabled: false, gracePeriod: 0.4)
            clock.value = 0.01
            listener.send(.init(deviceID: 1, timestamp: 0.01, contacts: []))
        }

        clock.value = 0.10
        listener.send(makeThreeContactFrame(timestamp: 0.10))
        switch transition {
        case .start:
            session.updateTestingMode(.allGestures)
        case .switchMode:
            session.updateTestingMode(.practice(gesture))
        case .stop:
            session.updateTestingMode(nil)
        }
        session.updateNativeClickResolutions([gesture: .consume])
        session.updateTypingProtection(isEnabled: false, gracePeriod: 0.4)
        session.update(gestures: [gesture])

        clock.value = 0.20
        listener.send(makeThreeContactFrame(timestamp: 0.20))
        clock.value = 0.21
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 901))
        ))
        clock.value = 0.22
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 901))
        ))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 0.60
        listener.send(.init(deviceID: 1, timestamp: 0.60, contacts: []))
        clock.value = 0.70
        listener.send(makeThreeContactFrame(timestamp: 0.70))
        clock.value = 0.71
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 902))
        ))
        clock.value = 0.72
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 902))
        ))
        session.waitForRecognitionForTests()
        await fulfillment(of: [freshRecognition], timeout: 1)
        XCTAssertEqual(recognized, [gesture])
    }

    private func makeThreeContactFrame(timestamp: TimeInterval = 0) -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: 1,
            timestamp: timestamp,
            contacts: [
                .init(identifier: 1, x: 0.2, y: 0.5),
                .init(identifier: 2, x: 0.5, y: 0.5),
                .init(identifier: 3, x: 0.8, y: 0.5),
            ]
        )
    }

    private func makeMouseEvent(type: CGEventType, eventNumber: Int64 = 0) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        )
        event?.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        return event
    }

    private func makePlugin(
        storage: TrackpadGestureMemoryStorage? = nil,
        accessibilityTrusted: @escaping @Sendable @MainActor () -> Bool = { true },
        inputMonitoringStatus: @escaping @Sendable @MainActor () -> TrackpadInputMonitoringStatus = {
            .granted
        }
    ) -> (
        plugin: TrackpadGesturesPlugin,
        session: MockMultitouchDeviceSession,
        executor: MockTrackpadGestureActionExecutor
    ) {
        let session = MockMultitouchDeviceSession()
        let executor = MockTrackpadGestureActionExecutor()
        let plugin = TrackpadGesturesPlugin(
            context: PluginRuntimeContext(
                pluginID: "trackpad-gestures",
                storage: storage ?? TrackpadGestureMemoryStorage()
            ),
            legacyMiddleClick: nil,
            session: session,
            actionExecutor: executor,
            accessibilityTrusted: accessibilityTrusted,
            requestAccessibilityTrust: { _ in accessibilityTrusted() },
            inputMonitoringStatus: inputMonitoringStatus,
            openURL: { _ in }
        )
        return (plugin, session, executor)
    }
}
