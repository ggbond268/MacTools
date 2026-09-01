import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit
import MacToolsPluginKit
import MultitouchSupport
import OSLog

@MainActor
protocol MultitouchFrameListening: AnyObject {
    var deviceCount: Int { get }
    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool
    func stop()
}

@MainActor
protocol TrackpadListenerLeaseManaging: AnyObject {
    var shouldRetryAfterFailedAcquisition: Bool { get }
    func acquire() -> Bool
    func release()
}

struct TrackpadListenerProcessPolicy {
    static func allowsAcquisition(
        isDisabledByEnvironment: Bool,
        bundleIdentifier: String,
        currentBundleURL: URL,
        productName: String,
        homeDirectory: URL,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard !isDisabledByEnvironment else { return false }

        let isDevelopmentApp = bundleIdentifier.hasSuffix(".dev")
            || productName.hasSuffix(" Dev")
        guard isDevelopmentApp else { return true }

        let installedBundleURL = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("\(productName).app", isDirectory: true)
        guard fileExists(installedBundleURL.path) else {
            // Keep direct Xcode runs usable before the developer has installed a stable Debug app.
            return true
        }

        return installedBundleURL.resolvingSymlinksInPath().standardizedFileURL
            == currentBundleURL.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
final class TrackpadInterprocessListenerLease: TrackpadListenerLeaseManaging {
    static let disabledEnvironmentKey = "MACTOOLS_DISABLE_TRACKPAD_LISTENER"

    private let lockPath: String
    private let isAcquisitionAllowed: Bool
    private var fileDescriptor: Int32 = -1
    var shouldRetryAfterFailedAcquisition: Bool { isAcquisitionAllowed }

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        isAcquisitionAllowed: Bool? = nil
    ) {
        lockPath = temporaryDirectory
            .appendingPathComponent("mactools.trackpad-gestures.listener.lock")
            .path
        self.isAcquisitionAllowed = isAcquisitionAllowed ?? Self.defaultAcquisitionPolicy(
            bundleIdentifier: bundleIdentifier
        )
    }

    deinit {
        if fileDescriptor >= 0 {
            _ = flock(fileDescriptor, LOCK_UN)
            Darwin.close(fileDescriptor)
        }
    }

    func acquire() -> Bool {
        guard isAcquisitionAllowed else { return false }
        guard fileDescriptor < 0 else { return true }
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        fileDescriptor = descriptor
        return true
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func defaultAcquisitionPolicy(bundleIdentifier: String) -> Bool {
        let productName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        return TrackpadListenerProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: ProcessInfo.processInfo.environment[
                disabledEnvironmentKey
            ] == "1",
            bundleIdentifier: bundleIdentifier,
            currentBundleURL: Bundle.main.bundleURL,
            productName: productName,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileExists: FileManager.default.fileExists(atPath:)
        )
    }
}

@MainActor
private final class TrackpadInProcessListenerLease: TrackpadListenerLeaseManaging {
    var shouldRetryAfterFailedAcquisition: Bool { true }
    func acquire() -> Bool { true }
    func release() {}
}

final class MultitouchFrameCallbackGate: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadContactFrame) -> Void

    private struct Registration {
        let deviceIDsByCallbackSource: [UInt64: UInt64]
        let handler: Handler
    }

    private let lock = NSLock()
    private var registration: Registration?

    func activate(
        deviceIDsByCallbackSource: [UInt64: UInt64],
        handler: @escaping Handler
    ) {
        lock.withLock {
            registration = Registration(
                deviceIDsByCallbackSource: deviceIDsByCallbackSource,
                handler: handler
            )
        }
    }

    func invalidate() {
        lock.withLock {
            registration = nil
        }
    }

    @discardableResult
    func deliver(_ frame: TrackpadContactFrame) -> Bool {
        lock.withLock {
            guard let registration,
                  let stableDeviceID = registration.deviceIDsByCallbackSource[frame.deviceID]
            else {
                return false
            }
            // Keep registration valid through delivery so stop() cannot release the device after
            // admission but before its frame reaches the session-level generation gate.
            registration.handler(TrackpadContactFrame(
                deviceID: stableDeviceID,
                timestamp: frame.timestamp,
                contacts: frame.contacts
            ))
            return true
        }
    }
}

final class MultitouchCallbackContextRegistry: @unchecked Sendable {
    static let shared = MultitouchCallbackContextRegistry()

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var gates: [UInt: MultitouchFrameCallbackGate] = [:]

    private init() {}

    func insert(_ gate: MultitouchFrameCallbackGate) -> UnsafeMutableRawPointer {
        lock.withLock {
            var token = nextToken
            while token == 0 || gates[token] != nil {
                token &+= 1
            }
            nextToken = token &+ 1
            if nextToken == 0 {
                nextToken = 1
            }
            gates[token] = gate
            return UnsafeMutableRawPointer(bitPattern: token)!
        }
    }

    func gate(for refcon: UnsafeMutableRawPointer?) -> MultitouchFrameCallbackGate? {
        guard let refcon else { return nil }
        return lock.withLock { gates[UInt(bitPattern: refcon)] }
    }

    func remove(_ refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        _ = lock.withLock {
            gates.removeValue(forKey: UInt(bitPattern: refcon))
        }
    }
}

final class MultitouchFrameDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginGeneration() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    @discardableResult
    func deliver(
        generation expectedGeneration: UInt64,
        _ body: @Sendable () -> Void
    ) -> Bool {
        lock.withLock {
            guard generation == expectedGeneration else { return false }
            // Invalidation must wait through both snapshot mutation and recognition enqueue.
            body()
            return true
        }
    }

    func invalidate(_ body: () -> Void) {
        lock.withLock {
            generation &+= 1
            body()
        }
    }
}

final class TrackpadContactOccupancyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeDeviceIDs = Set<UInt64>()

    func observe(_ frame: TrackpadContactFrame) {
        lock.withLock {
            if frame.contacts.isEmpty {
                activeDeviceIDs.remove(frame.deviceID)
            } else {
                activeDeviceIDs.insert(frame.deviceID)
            }
        }
    }

    func snapshot() -> Set<UInt64> {
        lock.withLock { activeDeviceIDs }
    }

    func reset() {
        lock.withLock { activeDeviceIDs.removeAll() }
    }
}

final class TrackpadRecognitionDeliveryRelay: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadGesture, UInt64, UInt64) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func activate(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ gesture: TrackpadGesture, deviceID: UInt64, generation: UInt64) {
        let currentHandler: Handler? = lock.withLock { self.handler }
        currentHandler?(gesture, deviceID, generation)
    }
}

enum MultitouchDeviceTransport: String, Equatable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case external
    case unknown
}

struct MultitouchDeviceDescriptor: Equatable, Sendable {
    let deviceID: UInt64
    let isBuiltIn: Bool?
    let transport: MultitouchDeviceTransport
}

struct MultitouchDeviceEntry {
    let device: MTDevice
    let descriptor: MultitouchDeviceDescriptor
}

final class MultitouchDeviceCollection: @unchecked Sendable {
    let entries: [MultitouchDeviceEntry]
    private let lifetimeOwner: AnyObject?

    init(entries: [MultitouchDeviceEntry], lifetimeOwner: AnyObject? = nil) {
        self.entries = entries
        self.lifetimeOwner = lifetimeOwner
    }
}

struct MultitouchDeviceDiagnostics: Equatable, Sendable {
    let descriptor: MultitouchDeviceDescriptor
    let deliveredFrameCount: UInt64
    let lastFrameTimestamp: TimeInterval?
}

final class MultitouchDeviceDiagnosticsTracker: @unchecked Sendable {
    private struct State {
        let descriptor: MultitouchDeviceDescriptor
        var deliveredFrameCount: UInt64
        var lastFrameTimestamp: TimeInterval?
    }

    private let lock = NSLock()
    private var states: [UInt64: State] = [:]

    func configure(_ descriptors: [MultitouchDeviceDescriptor]) {
        lock.withLock {
            states = Dictionary(uniqueKeysWithValues: descriptors.map {
                ($0.deviceID, State(
                    descriptor: $0,
                    deliveredFrameCount: 0,
                    lastFrameTimestamp: nil
                ))
            })
        }
    }

    @discardableResult
    func observe(_ frame: TrackpadContactFrame) -> Bool {
        lock.withLock {
            guard var state = states[frame.deviceID] else { return false }
            let isFirstFrame = state.deliveredFrameCount == 0
            state.deliveredFrameCount &+= 1
            state.lastFrameTimestamp = frame.timestamp
            states[frame.deviceID] = state
            return isFirstFrame
        }
    }

    func snapshot() -> [MultitouchDeviceDiagnostics] {
        lock.withLock {
            states.values
                .map {
                    MultitouchDeviceDiagnostics(
                        descriptor: $0.descriptor,
                        deliveredFrameCount: $0.deliveredFrameCount,
                        lastFrameTimestamp: $0.lastFrameTimestamp
                    )
                }
                .sorted { $0.descriptor.deviceID < $1.descriptor.deviceID }
        }
    }

    func transportLabel(for deviceID: UInt64) -> String {
        lock.withLock {
            states[deviceID]?.descriptor.transport.rawValue
                ?? MultitouchDeviceTransport.unknown.rawValue
        }
    }

    func reset() {
        lock.withLock { states.removeAll() }
    }
}

protocol MultitouchRuntimeProviding: AnyObject {
    func createDeviceCollection() -> MultitouchDeviceCollection?
    func register(
        _ device: MTDevice,
        callback: MTFrameCallbackWithRefconFunction,
        refcon: UnsafeMutableRawPointer
    )
    func unregister(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction)
    func start(_ device: MTDevice)
    func stop(_ device: MTDevice)
}

final class MultitouchSupportRuntime: MultitouchRuntimeProviding, @unchecked Sendable {
    typealias CreateDeviceListFunction = @convention(c) () -> Unmanaged<CFMutableArray>?
    typealias RegisterCallbackFunction = @convention(c) (
        MTDevice,
        MTFrameCallbackWithRefconFunction,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias UnregisterCallbackFunction = @convention(c) (
        MTDevice,
        MTFrameCallbackWithRefconFunction
    ) -> Void
    typealias StartDeviceFunction = @convention(c) (MTDevice, Int32) -> Void
    typealias StopDeviceFunction = @convention(c) (MTDevice) -> Void
    typealias GetDeviceIDFunction = @convention(c) (
        MTDevice,
        UnsafeMutablePointer<UInt64>
    ) -> Int32
    typealias IsBuiltInFunction = @convention(c) (MTDevice) -> Bool
    typealias GetServiceFunction = @convention(c) (MTDevice) -> io_service_t

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let libraryHandle: UnsafeMutableRawPointer
    private let createDeviceListFunction: CreateDeviceListFunction
    private let registerCallbackFunction: RegisterCallbackFunction
    private let unregisterCallbackFunction: UnregisterCallbackFunction
    private let startDeviceFunction: StartDeviceFunction
    private let stopDeviceFunction: StopDeviceFunction
    private let getDeviceIDFunction: GetDeviceIDFunction?
    private let isBuiltInFunction: IsBuiltInFunction?
    private let getServiceFunction: GetServiceFunction?

    static func load() -> MultitouchSupportRuntime? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            return nil
        }
        guard
            let createDeviceList: CreateDeviceListFunction = loadSymbol(
                "MTDeviceCreateList", from: handle
            ),
            let registerCallback: RegisterCallbackFunction = loadSymbol(
                "MTRegisterContactFrameCallbackWithRefcon", from: handle
            ),
            let unregisterCallback: UnregisterCallbackFunction = loadSymbol(
                "MTUnregisterContactFrameCallback", from: handle
            ),
            let startDevice: StartDeviceFunction = loadSymbol("MTDeviceStart", from: handle),
            let stopDevice: StopDeviceFunction = loadSymbol("MTDeviceStop", from: handle)
        else {
            dlclose(handle)
            return nil
        }
        return MultitouchSupportRuntime(
            libraryHandle: handle,
            createDeviceListFunction: createDeviceList,
            registerCallbackFunction: registerCallback,
            unregisterCallbackFunction: unregisterCallback,
            startDeviceFunction: startDevice,
            stopDeviceFunction: stopDevice,
            getDeviceIDFunction: loadSymbol("MTDeviceGetDeviceID", from: handle),
            isBuiltInFunction: loadSymbol("MTDeviceIsBuiltIn", from: handle),
            getServiceFunction: loadSymbol("MTDeviceGetService", from: handle)
        )
    }

    private static func loadSymbol<Function>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> Function? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }

    private init(
        libraryHandle: UnsafeMutableRawPointer,
        createDeviceListFunction: CreateDeviceListFunction,
        registerCallbackFunction: RegisterCallbackFunction,
        unregisterCallbackFunction: UnregisterCallbackFunction,
        startDeviceFunction: StartDeviceFunction,
        stopDeviceFunction: StopDeviceFunction,
        getDeviceIDFunction: GetDeviceIDFunction?,
        isBuiltInFunction: IsBuiltInFunction?,
        getServiceFunction: GetServiceFunction?
    ) {
        self.libraryHandle = libraryHandle
        self.createDeviceListFunction = createDeviceListFunction
        self.registerCallbackFunction = registerCallbackFunction
        self.unregisterCallbackFunction = unregisterCallbackFunction
        self.startDeviceFunction = startDeviceFunction
        self.stopDeviceFunction = stopDeviceFunction
        self.getDeviceIDFunction = getDeviceIDFunction
        self.isBuiltInFunction = isBuiltInFunction
        self.getServiceFunction = getServiceFunction
    }

    deinit {
        dlclose(libraryHandle)
    }

    func createDeviceCollection() -> MultitouchDeviceCollection? {
        guard let retainedList = createDeviceListFunction()?.takeRetainedValue() else {
            return nil
        }
        let devices = retainedList as? [MTDevice] ?? []
        let entries = devices.map { device in
            MultitouchDeviceEntry(
                device: device,
                descriptor: descriptor(for: device)
            )
        }
        return MultitouchDeviceCollection(
            entries: entries,
            lifetimeOwner: retainedList
        )
    }

    func register(
        _ device: MTDevice,
        callback: MTFrameCallbackWithRefconFunction,
        refcon: UnsafeMutableRawPointer
    ) {
        registerCallbackFunction(device, callback, refcon)
    }

    func unregister(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction) {
        unregisterCallbackFunction(device, callback)
    }

    func start(_ device: MTDevice) {
        startDeviceFunction(device, 0)
    }

    func stop(_ device: MTDevice) {
        stopDeviceFunction(device)
    }

    private func descriptor(for device: MTDevice) -> MultitouchDeviceDescriptor {
        let service = getServiceFunction?(device) ?? 0
        let isBuiltIn = isBuiltInFunction?(device)
        return MultitouchDeviceDescriptor(
            deviceID: stableDeviceID(for: device, service: service),
            isBuiltIn: isBuiltIn,
            transport: transport(for: service, isBuiltIn: isBuiltIn)
        )
    }

    private func stableDeviceID(for device: MTDevice, service: io_service_t) -> UInt64 {
        var deviceID: UInt64 = 0
        if let getDeviceIDFunction,
           getDeviceIDFunction(device, &deviceID) == 0,
           deviceID != 0 {
            return deviceID
        }
        if service != 0,
           IORegistryEntryGetRegistryEntryID(service, &deviceID) == KERN_SUCCESS,
           deviceID != 0 {
            return deviceID
        }
        return Self.callbackSourceID(device)
    }

    private func transport(
        for service: io_service_t,
        isBuiltIn: Bool?
    ) -> MultitouchDeviceTransport {
        if isBuiltIn == true {
            return .builtIn
        }
        guard service != 0,
              let value = IORegistryEntrySearchCFProperty(
                  service,
                  kIOServicePlane,
                  "Transport" as CFString,
                  kCFAllocatorDefault,
                  IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
              ) as? String
        else {
            return isBuiltIn == false ? .external : .unknown
        }
        let normalized = value.lowercased()
        if normalized.contains("bluetooth") {
            return .bluetooth
        }
        if normalized.contains("usb") {
            return .usb
        }
        return isBuiltIn == false ? .external : .unknown
    }

    private static func callbackSourceID(_ device: MTDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }
}

@MainActor
final class MultitouchDeviceDriver: MultitouchFrameListening, @unchecked Sendable {
    private var deviceCollection: MultitouchDeviceCollection?
    private var devices: [MultitouchDeviceEntry] = []
    private var callbackContext: UnsafeMutableRawPointer?
    private var callbackGate: MultitouchFrameCallbackGate?
    private let runtime: (any MultitouchRuntimeProviding)?
    nonisolated private let diagnosticsTracker = MultitouchDeviceDiagnosticsTracker()

    nonisolated private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MultitouchDeviceDriver"
    )

    nonisolated private static let activeDriverLock = NSLock()
    nonisolated(unsafe) private static var activeDriver: MultitouchDeviceDriver?

    init(runtime: (any MultitouchRuntimeProviding)? = MultitouchSupportRuntime.load()) {
        self.runtime = runtime
    }

    private nonisolated static let touchCallback: MTFrameCallbackWithRefconFunction = {
        device, touches, touchCount, timestamp, _, refcon in
        guard touchCount >= 0,
              let callbackGate = MultitouchCallbackContextRegistry.shared.gate(for: refcon)
        else {
            return
        }

        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let deviceID = UInt64(UInt(bitPattern: pointer))
        let count = Int(touchCount)
        var contacts: [TrackpadContactSnapshot] = []
        contacts.reserveCapacity(count)
        if let touches {
            for index in 0..<count {
                let touch = touches[index]
                // MTPathStage raw values 3 and 4 are make-touch and touching. Break/hover contacts
                // remain in the private callback briefly and must not be treated as active fingers.
                guard touch.stage.rawValue == 3 || touch.stage.rawValue == 4 else {
                    continue
                }
                contacts.append(TrackpadContactSnapshot(
                    identifier: Int(touch.identifier),
                    x: Double(touch.normalizedVector.position.x),
                    y: Double(touch.normalizedVector.position.y)
                ))
            }
        }

        callbackGate.deliver(TrackpadContactFrame(
            deviceID: deviceID,
            timestamp: timestamp,
            contacts: contacts
        ))
    }

    var deviceCount: Int { devices.count }
    var deviceDiagnostics: [MultitouchDeviceDiagnostics] {
        diagnosticsTracker.snapshot()
    }

    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        guard let runtime else {
            logger.error("multitouch runtime is unavailable")
            return false
        }
        if let previous = Self.takeActiveDriver(), previous !== self {
            previous.stop()
        }
        stop()
        guard let collection = runtime.createDeviceCollection(),
              !collection.entries.isEmpty
        else {
            logger.error("multitouch runtime returned no devices")
            return false
        }
        deviceCollection = collection
        devices = Self.entriesWithUniqueIDs(collection.entries)
        let deviceIDsByCallbackSource = Dictionary(uniqueKeysWithValues: devices.map {
            (Self.callbackSourceID($0.device), $0.descriptor.deviceID)
        })
        diagnosticsTracker.configure(devices.map(\.descriptor))
        let diagnosticsTracker = diagnosticsTracker
        let logger = logger
        let callbackGate = MultitouchFrameCallbackGate()
        callbackGate.activate(
            deviceIDsByCallbackSource: deviceIDsByCallbackSource
        ) { frame in
            if diagnosticsTracker.observe(frame) {
                logger.info("received first multitouch frame transport=\(diagnosticsTracker.transportLabel(for: frame.deviceID), privacy: .public)")
            }
            handler(frame)
        }
        let callbackContext = MultitouchCallbackContextRegistry.shared.insert(callbackGate)
        self.callbackGate = callbackGate
        self.callbackContext = callbackContext
        Self.setActiveDriver(self)
        for entry in devices {
            runtime.register(
                entry.device,
                callback: Self.touchCallback,
                refcon: callbackContext
            )
            runtime.start(entry.device)
        }
        let builtInCount = devices.count { $0.descriptor.isBuiltIn == true }
        let externalCount = devices.count { $0.descriptor.isBuiltIn == false }
        logger.info("registered multitouch callbacks deviceCount=\(self.devices.count, privacy: .public) builtIn=\(builtInCount, privacy: .public) external=\(externalCount, privacy: .public)")
        return true
    }

    func stop() {
        callbackGate?.invalidate()
        MultitouchCallbackContextRegistry.shared.remove(callbackContext)
        callbackContext = nil
        Self.activeDriverLock.withLock {
            if Self.activeDriver === self {
                Self.activeDriver = nil
            }
        }
        devices.forEach { entry in
            runtime?.unregister(entry.device, callback: Self.touchCallback)
            runtime?.stop(entry.device)
        }
        devices.removeAll()
        deviceCollection = nil
        callbackGate = nil
        diagnosticsTracker.reset()
    }

    private nonisolated static func callbackSourceID(_ device: MTDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private static func entriesWithUniqueIDs(
        _ entries: [MultitouchDeviceEntry]
    ) -> [MultitouchDeviceEntry] {
        var allocatedIDs = Set<UInt64>()
        return entries.map { entry in
            var deviceID = entry.descriptor.deviceID
            if deviceID == 0 || allocatedIDs.contains(deviceID) {
                deviceID = callbackSourceID(entry.device) | (UInt64(1) << 63)
                while deviceID == 0 || allocatedIDs.contains(deviceID) {
                    deviceID &+= 1
                }
            }
            allocatedIDs.insert(deviceID)
            return MultitouchDeviceEntry(
                device: entry.device,
                descriptor: MultitouchDeviceDescriptor(
                    deviceID: deviceID,
                    isBuiltIn: entry.descriptor.isBuiltIn,
                    transport: entry.descriptor.transport
                )
            )
        }
    }

    private static func takeActiveDriver() -> MultitouchDeviceDriver? {
        activeDriverLock.withLock {
            defer { activeDriver = nil }
            return activeDriver
        }
    }

    private static func setActiveDriver(_ driver: MultitouchDeviceDriver) {
        activeDriverLock.withLock {
            activeDriver = driver
        }
    }
}

@MainActor
protocol MultitouchDeviceSessionManaging: AnyObject {
    var onRecognized: ((TrackpadGesture, UInt64) -> Void)? { get set }
    var onAvailabilityChange: ((Bool) -> Void)? { get set }
    var isActive: Bool { get }
    var deviceCount: Int { get }

    @discardableResult
    func activate(gestures: Set<TrackpadGesture>) -> Bool
    func update(gestures: Set<TrackpadGesture>)
    func updateNativeClickResolutions(_ resolutions: [TrackpadGesture: TrackpadNativeClickResolution])
    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution?
    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval)
    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>)
    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool
    func deactivate()
}

extension MultitouchDeviceSessionManaging {
    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {}
    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution? { nil }
    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {}
    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {}
    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool { false }
}

@MainActor
final class MultitouchDeviceSession: MultitouchDeviceSessionManaging, @unchecked Sendable {
    private typealias CallbackContext = PluginCallbackContext<MultitouchDeviceSession>

    var onRecognized: ((TrackpadGesture, UInt64) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?

    private(set) var isActive = false
    var deviceCount: Int { driver.deviceCount }

    private let driver: any MultitouchFrameListening
    private let listenerLease: any TrackpadListenerLeaseManaging
    nonisolated private let middleClickCandidateTimeline: TrackpadMiddleClickCandidateTimeline
    // The CGEvent tap is delivered synchronously by the main CFRunLoop. That
    // callback runs on the main thread, but it is not entered through Swift's
    // MainActor executor on newer macOS releases. Keep the event processor
    // nonisolated so it can return the native event synchronously without an
    // unsafe MainActor.assumeIsolated hop.
    nonisolated private let middleClickCoordinator: TrackpadMiddleClickCoordinator
    private var nativeClickResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = [:]
    nonisolated private let typingSuppressionGate = TrackpadTypingSuppressionGate()
    nonisolated private let recognitionGeneration: TrackpadGestureRecognitionGeneration
    nonisolated private let frameDeliveryGate = MultitouchFrameDeliveryGate()
    nonisolated private let contactOccupancyTracker = TrackpadContactOccupancyTracker()
    nonisolated private let frameIngestionClock: @Sendable () -> TimeInterval
    nonisolated private let recognitionBeforeFrameProcessing: (@Sendable () -> Void)?
    nonisolated private let recognitionWorker: TrackpadGestureRecognitionWorker

    private var configuredGestures = Set<TrackpadGesture>()
    private var isActivationRequested = false
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapCallbackPointer: UnsafeMutableRawPointer?
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioArrivalIterator: io_iterator_t = 0
    private var ioTerminationIterator: io_iterator_t = 0
    private var ioCallbackPointer: UnsafeMutableRawPointer?
    private var displayCallbackRegistered = false
    private var displayCallbackPointer: UnsafeMutableRawPointer?
    private var restartWorkItem: DispatchWorkItem?
    private let testEventTapStart: (@MainActor () -> Bool)?
    private let testEventTapStop: (@MainActor () -> Void)?
    private let deviceChangeRestartDelay: TimeInterval

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MultitouchDeviceSession"
    )

    private static let wakeRestartDelay: TimeInterval = 10
    private static let recoveryRetryDelay: TimeInterval = 2

    init(
        driver: (any MultitouchFrameListening)? = nil,
        listenerLease: (any TrackpadListenerLeaseManaging)? = nil,
        testEventTapStart: (@MainActor () -> Bool)? = nil,
        testEventTapStop: (@MainActor () -> Void)? = nil,
        deviceChangeRestartDelay: TimeInterval = 2,
        recognitionBeforeFrameProcessing: (@Sendable () -> Void)? = nil,
        middleClickClock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        synthesizeMiddleClick: @escaping () -> Void = {
            TrackpadMiddleClickEventPoster.postClick()
        },
        releaseMiddleButton: @escaping () -> Void = {
            TrackpadMiddleClickEventPoster.postButtonUp(
                eventSourceMarker: TrackpadMiddleClickCoordinator.replayMarker
            )
        },
        postMiddleClickEvent: @escaping (CGEvent) -> Void = {
            $0.post(tap: .cghidEventTap)
        },
        middleClickEventOrigin: @escaping (CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin = { _ in
            .unknown
        }
    ) {
        let candidateTimeline = TrackpadMiddleClickCandidateTimeline()
        let recognitionGeneration = TrackpadGestureRecognitionGeneration()
        let recognitionDeliveryRelay = TrackpadRecognitionDeliveryRelay()
        let recognitionWorker = TrackpadGestureRecognitionWorker(
            generation: recognitionGeneration,
            beforeFrameProcessing: recognitionBeforeFrameProcessing
        ) { gesture, deviceID, generation in
            recognitionDeliveryRelay.deliver(
                gesture,
                deviceID: deviceID,
                generation: generation
            )
        }
        self.driver = driver ?? MultitouchDeviceDriver()
        self.listenerLease = listenerLease
            ?? (driver == nil ? TrackpadInterprocessListenerLease() : TrackpadInProcessListenerLease())
        middleClickCandidateTimeline = candidateTimeline
        self.recognitionGeneration = recognitionGeneration
        self.recognitionWorker = recognitionWorker
        frameIngestionClock = middleClickClock
        self.recognitionBeforeFrameProcessing = recognitionBeforeFrameProcessing
        middleClickCoordinator = TrackpadMiddleClickCoordinator(
            clock: middleClickClock,
            synthesizeMiddleClick: synthesizeMiddleClick,
            releaseMiddleButton: releaseMiddleButton,
            postEvent: postMiddleClickEvent,
            candidateTimeline: candidateTimeline,
            recognizePhysicalClick: { gesture, deviceID in
                recognitionWorker.recognizeNativeClick(gesture, deviceID: deviceID)
            },
            eventOrigin: middleClickEventOrigin
        )
        self.testEventTapStart = testEventTapStart
        self.testEventTapStop = testEventTapStop
        self.deviceChangeRestartDelay = deviceChangeRestartDelay
        recognitionDeliveryRelay.activate { [weak self] gesture, deviceID, generation in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isActive,
                      self.recognitionGeneration.isCurrent(generation) else {
                    return
                }
                self.onRecognized?(gesture, deviceID)
            }
        }
    }

    @discardableResult
    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        configuredGestures = gestures
        isActivationRequested = true
        recognitionWorker.configure(gestures: gestures, reset: true)
        observeSystemWake()
        observeMultitouchDeviceChanges()
        observeDisplayReconfiguration()

        if isActive {
            return true
        }
        guard listenerLease.acquire() else {
            logger.error("multitouch listener is unavailable to this MacTools process")
            onAvailabilityChange?(false)
            if listenerLease.shouldRetryAfterFailedAcquisition {
                scheduleRestart(after: Self.recoveryRetryDelay, reason: "listenerLeaseRetry")
            }
            return false
        }
        guard startEventTap() else {
            logger.error("failed to create event-tap lifecycle monitor")
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "initialRetry")
            return false
        }

        guard startDriver() else {
            logger.error("failed to register or start multitouch contact callbacks")
            stopEventTap()
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "driverRetry")
            return false
        }
        cancelPendingRestart()
        isActive = true
        onAvailabilityChange?(true)
        logger.info("multitouch session started deviceCount=\(self.driver.deviceCount, privacy: .public)")
        return true
    }

    func update(gestures: Set<TrackpadGesture>) {
        configuredGestures = gestures
        recognitionWorker.configure(gestures: gestures)
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        updateNativeClickResolutions(
            Dictionary(uniqueKeysWithValues: gestures.map { ($0, .middleClick) })
        )
    }

    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool {
        resolveNativeClick(for: gesture, deviceID: deviceID) == .middleClick
    }

    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {
        nativeClickResolutions = resolutions
        middleClickCoordinator.updateClickResolutions(resolutions)
    }

    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution? {
        guard let resolution = nativeClickResolutions[gesture] else { return nil }
        middleClickCoordinator.recognize(deviceID: deviceID, resolution: resolution)
        return resolution
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingSuppressionGate.update(isEnabled: isEnabled, gracePeriod: gracePeriod)
    }

    func deactivate() {
        isActivationRequested = false
        cancelPendingRestart()
        removeDisplayReconfigurationObserver()
        removeMultitouchDeviceObserver()
        removeSystemWakeObserver()
        invalidateDriverCallbacks()
        driver.stop()
        stopEventTap()
        listenerLease.release()
        middleClickCoordinator.reset()
        typingSuppressionGate.reset()
        recognitionWorker.configure(gestures: [], reset: true)
        isActive = false
        logger.info("multitouch session stopped")
    }

    private func startEventTap() -> Bool {
        if let testEventTapStart {
            return testEventTapStart()
        }
        if let eventTap, CFMachPortIsValid(eventTap) {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let context = Unmanaged<CallbackContext>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.middleClickCoordinator.reset()
                        session?.typingSuppressionGate.reset()
                        session?.reenableEventTap()
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            return context.withOwner {
                $0.handleEventTapEvent(type: type, event: event)
            } ?? Unmanaged.passUnretained(event)
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: callbackPointer
        ) else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        eventTapCallbackPointer = callbackPointer
        return true
    }

    private func reenableEventTap() {
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        middleClickCoordinator.reset()
        typingSuppressionGate.reset()
        if let testEventTapStop {
            testEventTapStop()
            return
        }
        guard let eventTap else {
            eventTapSource = nil
            releaseEventTapCallbackContext()
            return
        }
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        eventTapSource = nil
        releaseEventTapCallbackContext()
    }

    private func releaseEventTapCallbackContext() {
        guard let eventTapCallbackPointer else { return }
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        Unmanaged<CallbackContext>.fromOpaque(eventTapCallbackPointer).release()
        self.eventTapCallbackPointer = nil
    }

    private func restartListeners(reason: String) {
        guard isActivationRequested else {
            return
        }
        cancelPendingRestart()
        logger.info("restarting listeners reason=\(reason, privacy: .public)")
        isActive = false
        invalidateDriverCallbacks()
        driver.stop()
        stopEventTap()
        recognitionWorker.configure(gestures: configuredGestures, reset: true)
        guard listenerLease.acquire() else {
            logger.error("multitouch listener lease is owned by another MacTools process")
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "listenerLeaseRetry")
            return
        }
        guard startEventTap() else {
            logger.error("event tap could not be restored")
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "eventTapRetry")
            return
        }
        guard startDriver() else {
            logger.error("multitouch contact callbacks could not be restored")
            stopEventTap()
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "driverRetry")
            return
        }
        isActive = true
        onAvailabilityChange?(true)
    }

    private func startDriver() -> Bool {
        let callbackGeneration = frameDeliveryGate.beginGeneration()
        let frameDeliveryGate = frameDeliveryGate
        let candidateTimeline = middleClickCandidateTimeline
        let typingSuppressionGate = typingSuppressionGate
        let contactOccupancyTracker = contactOccupancyTracker
        let frameIngestionClock = frameIngestionClock
        let recognitionWorker = recognitionWorker
        let started = driver.start(handler: {
            [
                frameDeliveryGate,
                candidateTimeline,
                typingSuppressionGate,
                contactOccupancyTracker,
                frameIngestionClock,
                recognitionWorker,
            ] frame in
            frameDeliveryGate.deliver(generation: callbackGeneration) {
                contactOccupancyTracker.observe(frame)
                let now = frameIngestionClock()
                let suppressRecognition = typingSuppressionGate.shouldSuppress(at: now)
                if suppressRecognition {
                    candidateTimeline.reset()
                } else {
                    candidateTimeline.observe(frame: frame, at: now)
                }
                recognitionWorker.process(frame, suppressRecognition: suppressRecognition)
            }
        })
        if !started {
            invalidateDriverCallbacks()
        }
        return started
    }

    private func invalidateDriverCallbacks() {
        frameDeliveryGate.invalidate {
            middleClickCandidateTimeline.reset()
            contactOccupancyTracker.reset()
        }
    }

    private nonisolated func handleEventTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .keyUp {
            if MacToolsSyntheticInputEvent.isMarked(event) {
                return Unmanaged.passUnretained(event)
            }

            let now = frameIngestionClock()
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown {
                typingSuppressionGate.observeKeyDown(keyCode: keyCode, at: now)
            } else {
                typingSuppressionGate.observeKeyUp(keyCode: keyCode, at: now)
            }
            if typingSuppressionGate.shouldSuppress(at: now) {
                recognitionWorker.beginSuppression(
                    activeDeviceIDs: contactOccupancyTracker.snapshot()
                )
                middleClickCoordinator.reset()
            }
            return Unmanaged.passUnretained(event)
        }
        return middleClickCoordinator.handleNativeEvent(type: type, event: event)
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        cancelPendingRestart()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.restartListeners(reason: reason)
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleRestart(after: Self.wakeRestartDelay, reason: "systemWake")
            }
        }
    }

    private func removeSystemWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func observeMultitouchDeviceChanges() {
        guard ioNotificationPort == nil,
              let port = IONotificationPortCreate(kIOMainPortDefault)
        else {
            return
        }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        var arrivalIterator: io_iterator_t = 0
        let arrivalResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.handleMultitouchDeviceChange(reason: "deviceArrived")
                    }
                }
            },
            callbackPointer,
            &arrivalIterator
        )

        guard arrivalResult == KERN_SUCCESS else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            IONotificationPortDestroy(port)
            return
        }

        var terminationIterator: io_iterator_t = 0
        let terminationResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.handleMultitouchDeviceChange(reason: "deviceRemoved")
                    }
                }
            },
            callbackPointer,
            &terminationIterator
        )

        guard terminationResult == KERN_SUCCESS else {
            context.invalidate()
            IOObjectRelease(arrivalIterator)
            IONotificationPortDestroy(port)
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return
        }

        Self.drain(arrivalIterator)
        Self.drain(terminationIterator)
        ioNotificationPort = port
        ioArrivalIterator = arrivalIterator
        ioTerminationIterator = terminationIterator
        ioCallbackPointer = callbackPointer
    }

    private func removeMultitouchDeviceObserver() {
        callbackContext(from: ioCallbackPointer)?.invalidate()
        if ioArrivalIterator != 0 {
            IOObjectRelease(ioArrivalIterator)
            ioArrivalIterator = 0
        }
        if ioTerminationIterator != 0 {
            IOObjectRelease(ioTerminationIterator)
            ioTerminationIterator = 0
        }
        if let ioNotificationPort {
            IONotificationPortDestroy(ioNotificationPort)
            self.ioNotificationPort = nil
        }
        if let ioCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(ioCallbackPointer).release()
            self.ioCallbackPointer = nil
        }
    }

    private func handleMultitouchDeviceChange(reason: String) {
        scheduleRestart(after: deviceChangeRestartDelay, reason: reason)
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return }
            IOObjectRelease(service)
        }
    }

    private nonisolated static let displayCallback: CGDisplayReconfigurationCallBack = {
        _, flags, userInfo in
        let relevant: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]
        guard !flags.intersection(relevant).isEmpty, let userInfo else {
            return
        }
        let context = Unmanaged<CallbackContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        context.withOwner { session in
            DispatchQueue.main.async { [weak session] in
                session?.scheduleRestart(after: 2, reason: "displayReconfigured")
            }
        }
    }

    private func observeDisplayReconfiguration() {
        guard !displayCallbackRegistered else { return }
        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(
            Self.displayCallback,
            callbackPointer
        ) == .success {
            displayCallbackRegistered = true
            displayCallbackPointer = callbackPointer
        } else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        callbackContext(from: displayCallbackPointer)?.invalidate()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayCallback,
            displayCallbackPointer
        )
        displayCallbackRegistered = false
        if let displayCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(displayCallbackPointer).release()
            self.displayCallbackPointer = nil
        }
    }

    private nonisolated func callbackContext(
        from pointer: UnsafeMutableRawPointer?
    ) -> CallbackContext? {
        guard let pointer else { return nil }
        return Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
    }

    #if DEBUG
    func restartImmediatelyForTests() {
        restartListeners(reason: "test")
    }

    func simulateWakeRecoveryForTests() {
        restartListeners(reason: "systemWakeTest")
    }

    func simulateDeviceRecoveryForTests() {
        restartListeners(reason: "deviceReenumeratedTest")
    }

    func simulateDeviceRemovalNotificationForTests() {
        handleMultitouchDeviceChange(reason: "deviceRemovedTest")
    }

    func handleNativeEventForTests(type: CGEventType, event: CGEvent) -> Bool {
        handleEventTapEvent(type: type, event: event) == nil
    }

    func simulateEventTapDisableForTests() {
        middleClickCoordinator.reset()
    }

    func waitForRecognitionForTests() {
        recognitionWorker.waitUntilIdleForTests()
    }
    #endif
}
