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
private final class MockMultitouchDeviceSession: MultitouchDeviceSessionManaging {
    var onRecognized: ((TrackpadGesture, UInt64) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    private(set) var isActive = false
    var deviceCount = 1
    private(set) var activations: [Set<TrackpadGesture>] = []
    private(set) var updates: [Set<TrackpadGesture>] = []
    private(set) var deactivateCount = 0
    private(set) var middleClickGestureUpdates: [Set<TrackpadGesture>] = []
    private(set) var resolvedMiddleClicks: [(TrackpadGesture, UInt64)] = []
    private(set) var nativeClickResolutionUpdates: [[TrackpadGesture: TrackpadNativeClickResolution]] = []
    private(set) var typingProtectionUpdates: [(Bool, TimeInterval)] = []
    var activationSucceeds = true
    var resolvesMiddleClicks = false

    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        activations.append(gestures)
        isActive = activationSucceeds
        return activationSucceeds
    }

    func update(gestures: Set<TrackpadGesture>) {
        updates.append(gestures)
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
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution? {
        resolvedMiddleClicks.append((gesture, deviceID))
        guard resolvesMiddleClicks else {
            return nativeClickResolutionUpdates.last?[gesture] == .consume ? .consume : nil
        }
        return nativeClickResolutionUpdates.last?[gesture]
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingProtectionUpdates.append((isEnabled, gracePeriod))
    }

    func deactivate() {
        deactivateCount += 1
        isActive = false
    }

    func recognize(_ gesture: TrackpadGesture) {
        onRecognized?(gesture, 1)
    }

    func reportAvailability(_ available: Bool) {
        isActive = available
        onAvailabilityChange?(available)
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

    func testOrdinaryMultiFingerShortcutDoesNotConsumeNativeClick() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertNil(fixture.session.nativeClickResolutionUpdates.last?[.fourFingerTap])
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
        fixture.session.recognize(.threeFingerTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .threeFingerTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)

        fixture.session.recognize(.fiveFingerDoubleTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .fiveFingerDoubleTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
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

    func testTypingSuppressionRemembersContactFrameQueuedBeforeKeyDown() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let recognitionBarrier = TrackpadRecognitionFrameBarrier()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            recognitionBeforeFrameProcessing: { recognitionBarrier.pauseIfArmed() },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
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

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testSessionIgnoresMacToolsGeneratedShortcutKeysForTypingProtection() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
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

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testKeyDownInvalidatesRecognitionQueuedForMainActorDelivery() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
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
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
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
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))

        // Move beyond the fail-safe window created by the passed-through stale-click probe,
        // then prove the current generation still accepts fresh frames.
        clock.value = 0.40
        driver.send(makeThreeContactFrame(), usingStart: 1)
        clock.value = 0.41
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        session.deactivate()
    }

    func testSessionDeactivationBalancesRewrittenMiddleButtonDown() throws {
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
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))

        session.deactivate()

        XCTAssertEqual(releaseCount, 1)
    }

    func testEventTapDisableBalancesRewrittenMiddleButtonDown() throws {
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
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))

        session.simulateEventTapDisableForTests()

        XCTAssertEqual(releaseCount, 1)
        session.deactivate()
    }

    private func makeMiddleClickSession(
        driver: MockMultitouchFrameListener,
        now: @escaping @Sendable () -> TimeInterval,
        releaseMiddleButton: @escaping @Sendable @MainActor () -> Void
    ) -> MultitouchDeviceSession {
        MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: now,
            synthesizeMiddleClick: {},
            releaseMiddleButton: releaseMiddleButton,
            postMiddleClickEvent: { _ in },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
    }

    private func makeThreeContactFrame() -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [
                .init(identifier: 1, x: 0.2, y: 0.5),
                .init(identifier: 2, x: 0.5, y: 0.5),
                .init(identifier: 3, x: 0.8, y: 0.5),
            ]
        )
    }

    private func makeMouseEvent(type: CGEventType) -> CGEvent? {
        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        )
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
