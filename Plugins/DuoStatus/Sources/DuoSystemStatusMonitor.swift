import AppKit
import Combine
import CoreAudio
import Foundation
import IOKit.ps
import Network
import OSLog

// The scoped refresh, the CoreAudio event monitor, and the network-path
// snapshot are adapted from Status Trio
// (https://github.com/lingyired/status-trio, Apache-2.0).

private let duoStatusMonitorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
    category: "DuoSystemStatusMonitor"
)

// MARK: - Network path monitoring

@MainActor
protocol DuoNetworkPathMonitoring: AnyObject {
    var onChange: (@Sendable (DuoNetworkPathSnapshot) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

@MainActor
final class SystemDuoNetworkPathMonitor: DuoNetworkPathMonitoring {
    var onChange: (@Sendable (DuoNetworkPathSnapshot) -> Void)?
    private let monitor = NWPathMonitor()

    func start(queue: DispatchQueue) {
        let onChange = onChange
        monitor.pathUpdateHandler = { path in
            let status: DuoSystemStatusSnapshot.Network = switch path.status {
            case .satisfied: .connected
            case .unsatisfied: .disconnected
            case .requiresConnection: .requiresConnection
            @unknown default: .unknown
            }
            onChange?(DuoNetworkPathSnapshot(
                status: status,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
                isExpensive: path.isExpensive
            ))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        onChange = nil
    }
}

// MARK: - Audio event monitoring

/// Delivers "something about the default output changed" on the main actor.
/// Implementations own their CoreAudio listener registrations.
@MainActor
protocol DuoStatusAudioEventMonitoring: AnyObject {
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
    /// Re-targets device listeners when the default output device moved.
    func reconcile()
    func stop()
}

@MainActor
final class DuoStatusCoreAudioEventMonitor: DuoStatusAudioEventMonitoring {
    private struct Registration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var defaultDeviceRegistration: Registration?
    private var deviceRegistrations: [Registration] = []
    private var registeredDeviceID: AudioDeviceID?
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var isRunning = false

    init() {}

    isolated deinit {
        stop()
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.onChange = onChange
        registerDefaultDeviceListener()
        reconcile()
    }

    func reconcile() {
        guard isRunning else { return }
        let currentDeviceID = DuoStatusCoreAudio.validDefaultOutputDevice()
        guard currentDeviceID != registeredDeviceID || deviceRegistrations.isEmpty else { return }
        removeDeviceListeners()
        registeredDeviceID = currentDeviceID
        if let currentDeviceID {
            registerDeviceListeners(for: currentDeviceID)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let defaultDeviceRegistration {
            remove(defaultDeviceRegistration)
            self.defaultDeviceRegistration = nil
        }
        removeDeviceListeners()
        registeredDeviceID = nil
        onChange = nil
    }

    private func registerDefaultDeviceListener() {
        guard defaultDeviceRegistration == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultDeviceDidChange()
            }
        }
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        defaultDeviceRegistration = add(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            block: block
        )
    }

    private func registerDeviceListeners(for deviceID: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.volumeDidChange()
            }
        }
        for element in DuoStatusCoreAudio.outputElements {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                guard DuoStatusCoreAudio.hasProperty(
                    objectID: deviceID,
                    selector: selector,
                    scope: kAudioObjectPropertyScopeOutput,
                    element: element
                ) else { continue }
                let address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
                if let registration = add(objectID: deviceID, address: address, block: block) {
                    deviceRegistrations.append(registration)
                }
            }
        }
    }

    private func defaultDeviceDidChange() {
        guard isRunning else { return }
        reconcile()
        onChange?()
    }

    private func volumeDidChange() {
        guard isRunning else { return }
        onChange?()
    }

    private func add(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> Registration? {
        var mutableAddress = address
        let status = AudioObjectAddPropertyListenerBlock(objectID, &mutableAddress, .main, block)
        guard status == noErr else {
            duoStatusMonitorLogger.error(
                "Failed to add CoreAudio listener selector=\(address.mSelector, privacy: .public) element=\(address.mElement, privacy: .public) status=\(status, privacy: .public)"
            )
            return nil
        }
        return Registration(objectID: objectID, address: address, block: block)
    }

    private func removeDeviceListeners() {
        for registration in deviceRegistrations {
            remove(registration)
        }
        deviceRegistrations.removeAll()
    }

    private func remove(_ registration: Registration) {
        var address = registration.address
        let status = AudioObjectRemovePropertyListenerBlock(
            registration.objectID,
            &address,
            .main,
            registration.block
        )
        if status != noErr {
            duoStatusMonitorLogger.error(
                "Failed to remove CoreAudio listener selector=\(address.mSelector, privacy: .public) element=\(address.mElement, privacy: .public) status=\(status, privacy: .public)"
            )
        }
    }
}

// MARK: - Monitor

/// Which system reads a refresh performs. Events only re-read what they can have
/// changed, and audio is sampled only while a selected option renders it.
struct DuoSystemStatusRefreshScope: OptionSet, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let battery = DuoSystemStatusRefreshScope(rawValue: 1 << 0)
    static let wifi = DuoSystemStatusRefreshScope(rawValue: 1 << 1)
    static let volume = DuoSystemStatusRefreshScope(rawValue: 1 << 2)
    static let all: DuoSystemStatusRefreshScope = [.battery, .wifi, .volume]
    /// What the plugin needs before any audio-dependent option is enabled.
    static let `default`: DuoSystemStatusRefreshScope = [.battery, .wifi]
}

@MainActor
protocol DuoSystemStatusMonitoring: AnyObject {
    var snapshot: DuoSystemStatusSnapshot { get }
    var onChange: ((DuoSystemStatusSnapshot) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
    /// Safe before `start()`, repeatedly with the same value, and while running.
    func setRefreshScope(_ scope: DuoSystemStatusRefreshScope)
}

@MainActor
final class DuoSystemStatusMonitor: ObservableObject, DuoSystemStatusMonitoring {
    typealias NotificationSourceFactory = (UnsafeMutableRawPointer) -> CFRunLoopSource?

    private struct Reading: Sendable {
        var battery: DuoSystemStatusSnapshot.Battery?
        var wifi: DuoWiFiReading?
        var volume: DuoSystemStatusSnapshot.Volume?
    }

    @Published private(set) var snapshot: DuoSystemStatusSnapshot = .unknown
    var onChange: ((DuoSystemStatusSnapshot) -> Void)?

    private let reader: any DuoSystemStatusReading
    private let networkMonitorFactory: @MainActor () -> any DuoNetworkPathMonitoring
    private let audioEventMonitorFactory: @MainActor () -> any DuoStatusAudioEventMonitoring
    private let notificationSourceFactory: NotificationSourceFactory
    private let workspaceNotificationCenter: NotificationCenter
    private let processInfoNotificationCenter: NotificationCenter
    private let refreshInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.mactools.duo-status", qos: .utility)
    private var networkMonitor: (any DuoNetworkPathMonitoring)?
    private var audioEventMonitor: (any DuoStatusAudioEventMonitoring)?
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var timer: Timer?
    private var latestPath: DuoNetworkPathSnapshot?
    private(set) var refreshScope: DuoSystemStatusRefreshScope = .default
    private var isRunning = false
    private var generation: UInt64 = 0
    private var isReading = false
    private var pendingScope: DuoSystemStatusRefreshScope = []

    init(
        reader: any DuoSystemStatusReading = DuoSystemStatusReader(),
        networkMonitorFactory: @escaping @MainActor () -> any DuoNetworkPathMonitoring = {
            SystemDuoNetworkPathMonitor()
        },
        audioEventMonitorFactory: @escaping @MainActor () -> any DuoStatusAudioEventMonitoring = {
            DuoStatusCoreAudioEventMonitor()
        },
        notificationSourceFactory: @escaping NotificationSourceFactory = { context in
            IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let monitor = Unmanaged<DuoSystemStatusMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in monitor.refresh(.battery) }
            }, context)?.takeRetainedValue()
        },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        processInfoNotificationCenter: NotificationCenter = .default,
        refreshInterval: TimeInterval = 15
    ) {
        self.reader = reader
        self.networkMonitorFactory = networkMonitorFactory
        self.audioEventMonitorFactory = audioEventMonitorFactory
        self.notificationSourceFactory = notificationSourceFactory
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.processInfoNotificationCenter = processInfoNotificationCenter
        self.refreshInterval = max(refreshInterval, 1)
    }

    isolated deinit {
        stop()
    }

    /// CoreAudio listeners are installed only while `.volume` is in scope, and are
    /// torn down again as soon as the options that need them are turned off.
    func setRefreshScope(_ scope: DuoSystemStatusRefreshScope) {
        guard scope != refreshScope else { return }
        let added = scope.subtracting(refreshScope)
        refreshScope = scope
        guard isRunning else { return }
        reconcileAudioEventMonitor()
        if !scope.contains(.volume), snapshot.volume != .unknown {
            // Stop rendering a stale output device once audio leaves the scope.
            var updated = snapshot
            updated.volume = .unknown
            publish(updated)
        }
        if !added.isEmpty {
            refresh(added)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let currentGeneration = generation
        latestPath = nil
        publish(.unknown)

        let networkMonitor = networkMonitorFactory()
        self.networkMonitor = networkMonitor
        networkMonitor.onChange = { [weak self] path in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == currentGeneration else { return }
                self.latestPath = path
                var updated = self.snapshot
                updated.network = path.status
                updated.connectionKind = path.connectionKind
                self.publish(updated)
                // Wi-Fi classification depends on the path (hotspot / no internet).
                self.refresh(.wifi)
            }
        }
        networkMonitor.start(queue: queue)

        reconcileAudioEventMonitor()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = notificationSourceFactory(context) {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            duoStatusMonitorLogger.error("IOPS notification source unavailable; timer refresh remains active")
        }
        powerStateObserver = processInfoNotificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.refresh(.battery)
            }
        }
        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.audioEventMonitor?.reconcile()
                self.refresh()
            }
        }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.refresh()
            }
        }
        timer.tolerance = min(refreshInterval / 5, 3)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        if let powerStateObserver {
            processInfoNotificationCenter.removeObserver(powerStateObserver)
        }
        powerStateObserver = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        audioEventMonitor?.stop()
        audioEventMonitor = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        latestPath = nil
        isReading = false
        pendingScope = []
    }

    func refresh() {
        refresh(.all)
    }

    /// Reads the requested subsystems off the main actor and merges the result.
    /// The request is narrowed to the configured scope, so an option that is off
    /// never triggers its system read. While a read is in flight the scope
    /// accumulates into a single follow-up.
    func refresh(_ requested: DuoSystemStatusRefreshScope) {
        guard isRunning else { return }
        let scope = requested.intersection(refreshScope)
        guard !scope.isEmpty else { return }
        guard !isReading else {
            pendingScope.formUnion(scope)
            return
        }
        isReading = true
        let currentGeneration = generation
        let reader = reader
        let path = latestPath
        queue.async { [weak self] in
            var reading = Reading()
            if scope.contains(.battery) { reading.battery = reader.readBattery() }
            if scope.contains(.wifi) { reading.wifi = reader.readWiFi(path: path) }
            if scope.contains(.volume) { reading.volume = reader.readVolume() }
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == currentGeneration else { return }
                self.isReading = false
                var updated = self.snapshot
                if let battery = reading.battery { updated.battery = battery }
                if let wifi = reading.wifi {
                    updated.wifi = wifi.state
                    updated.wifiSignalLevel = wifi.signalLevel
                }
                if let volume = reading.volume { updated.volume = volume }
                self.publish(updated)
                if !self.pendingScope.isEmpty {
                    let pending = self.pendingScope
                    self.pendingScope = []
                    self.refresh(pending)
                }
            }
        }
    }

    private func reconcileAudioEventMonitor() {
        guard isRunning else { return }
        guard refreshScope.contains(.volume) else {
            audioEventMonitor?.stop()
            audioEventMonitor = nil
            return
        }
        if let audioEventMonitor {
            audioEventMonitor.reconcile()
            return
        }
        let audioEventMonitor = audioEventMonitorFactory()
        self.audioEventMonitor = audioEventMonitor
        let currentGeneration = generation
        audioEventMonitor.start { [weak self] in
            guard let self, self.isRunning, self.generation == currentGeneration else { return }
            self.refresh(.volume)
        }
    }

    private func publish(_ updated: DuoSystemStatusSnapshot) {
        guard updated != snapshot else { return }
        snapshot = updated
        onChange?(updated)
    }
}
