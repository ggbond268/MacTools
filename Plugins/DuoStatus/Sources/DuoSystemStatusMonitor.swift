import AppKit
import Combine
import Foundation
import IOKit.ps
import Network

@MainActor
protocol DuoNetworkPathMonitoring: AnyObject {
    var onChange: (@Sendable (
        DuoSystemStatusSnapshot.Network,
        DuoSystemStatusSnapshot.ConnectionKind?
    ) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

@MainActor
final class SystemDuoNetworkPathMonitor: DuoNetworkPathMonitoring {
    var onChange: (@Sendable (
        DuoSystemStatusSnapshot.Network,
        DuoSystemStatusSnapshot.ConnectionKind?
    ) -> Void)?
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
            let connectionKind: DuoSystemStatusSnapshot.ConnectionKind?
            if status != .connected {
                connectionKind = nil
            } else if path.usesInterfaceType(.wiredEthernet) {
                connectionKind = .ethernet
            } else if path.usesInterfaceType(.wifi) {
                connectionKind = .wifi
            } else {
                connectionKind = .other
            }
            onChange?(status, connectionKind)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        onChange = nil
    }
}

@MainActor
protocol DuoSystemStatusMonitoring: AnyObject {
    var snapshot: DuoSystemStatusSnapshot { get }
    var onChange: ((DuoSystemStatusSnapshot) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

@MainActor
final class DuoSystemStatusMonitor: ObservableObject, DuoSystemStatusMonitoring {
    typealias LocalReader = @Sendable () -> DuoLocalSystemStatus
    typealias NotificationSourceFactory = (UnsafeMutableRawPointer) -> CFRunLoopSource?

    @Published private(set) var snapshot: DuoSystemStatusSnapshot = .unknown
    var onChange: ((DuoSystemStatusSnapshot) -> Void)?

    private let reader: LocalReader
    private let networkMonitorFactory: () -> any DuoNetworkPathMonitoring
    private let notificationSourceFactory: NotificationSourceFactory
    private let workspaceNotificationCenter: NotificationCenter
    private let refreshInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.mactools.duo-status", qos: .utility)
    private var networkMonitor: (any DuoNetworkPathMonitoring)?
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var isRunning = false
    private var generation: UInt64 = 0
    private var isReading = false
    private var needsRefresh = false

    init(
        reader: @escaping LocalReader = DuoSystemStatusReader.read,
        networkMonitorFactory: @escaping () -> any DuoNetworkPathMonitoring = {
            SystemDuoNetworkPathMonitor()
        },
        notificationSourceFactory: @escaping NotificationSourceFactory = { context in
            IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let monitor = Unmanaged<DuoSystemStatusMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in monitor.refresh() }
            }, context)?.takeRetainedValue()
        },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        refreshInterval: TimeInterval = 15
    ) {
        self.reader = reader
        self.networkMonitorFactory = networkMonitorFactory
        self.notificationSourceFactory = notificationSourceFactory
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.refreshInterval = max(refreshInterval, 1)
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let currentGeneration = generation
        publish(.unknown)

        let networkMonitor = networkMonitorFactory()
        self.networkMonitor = networkMonitor
        networkMonitor.onChange = { [weak self] network, connectionKind in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == currentGeneration else { return }
                var updated = self.snapshot
                updated.network = network
                updated.connectionKind = connectionKind
                self.publish(updated)
                self.refresh()
            }
        }
        networkMonitor.start(queue: queue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = notificationSourceFactory(context) {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
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
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        isReading = false
        needsRefresh = false
    }

    func refresh() {
        guard isRunning else { return }
        guard !isReading else {
            needsRefresh = true
            return
        }
        isReading = true
        let currentGeneration = generation
        let reader = reader
        queue.async { [weak self] in
            let reading = reader()
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == currentGeneration else { return }
                self.isReading = false
                var updated = self.snapshot
                updated.battery = reading.battery
                updated.wifi = reading.wifi
                self.publish(updated)
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.refresh()
                }
            }
        }
    }

    private func publish(_ updated: DuoSystemStatusSnapshot) {
        guard updated != snapshot else { return }
        snapshot = updated
        onChange?(updated)
    }
}
