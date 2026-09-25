import AppKit
import Combine
import Foundation
import XCTest
@testable import DuoStatusPlugin

final class DuoSystemStatusMonitorTests: XCTestCase {
    @MainActor
    func testStartReadsOffMainActorAndSkipsVolumeByDefault() async {
        let reader = DuoStatusReaderFake(
            battery: .level(fraction: 0.64, isCharging: false),
            wifi: DuoWiFiReading(state: .connected(level: 3), signalLevel: 3),
            volume: DuoSystemStatusSnapshot.Volume(scalar: 0.5)
        )
        let fixture = Fixture(reader: reader)
        var published: [DuoSystemStatusSnapshot] = []
        fixture.monitor.onChange = { published.append($0) }

        fixture.monitor.start()
        fixture.monitor.start()
        XCTAssertEqual(fixture.network.startCount, 1)

        await waitUntil { fixture.monitor.snapshot.batteryFraction == 0.64 }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(fixture.monitor.snapshot.wifi, .connected(level: 3))
        XCTAssertEqual(fixture.monitor.snapshot.wifiLevel, 3)
        XCTAssertFalse(reader.ranOnMainThread)

        // Audio is opt-in: no listener and no CoreAudio read without an option that needs it.
        XCTAssertEqual(fixture.audio.startCount, 0)
        XCTAssertEqual(reader.volumeReadCount, 0)
        XCTAssertEqual(fixture.monitor.snapshot.volume, .unknown)

        fixture.monitor.refresh()
        await waitUntil { reader.batteryReadCount >= 2 }
        await Task.yield()
        XCTAssertEqual(published.count, 1, "identical reading must not re-publish")
        fixture.monitor.stop()
    }

    @MainActor
    func testRefreshScopeGainsAndDropsVolumeWithTheOptionsThatNeedIt() async {
        let reader = DuoStatusReaderFake(volume: DuoSystemStatusSnapshot.Volume(scalar: 0.4))
        let fixture = Fixture(reader: reader)
        fixture.monitor.start()
        await waitUntil { reader.batteryReadCount >= 1 }
        XCTAssertEqual(fixture.audio.startCount, 0)
        XCTAssertEqual(reader.volumeReadCount, 0)

        fixture.monitor.setRefreshScope([.battery, .wifi, .volume])
        await waitUntil { fixture.monitor.snapshot.volume.scalar == 0.4 }
        XCTAssertEqual(fixture.audio.startCount, 1)
        XCTAssertEqual(fixture.audio.stopCount, 0)

        // Repeating the same scope must not churn the CoreAudio registrations.
        fixture.monitor.setRefreshScope([.battery, .wifi, .volume])
        XCTAssertEqual(fixture.audio.startCount, 1)

        let audioCallback = fixture.audio.onChange
        let volumeReadsBeforeDrop = reader.volumeReadCount
        fixture.monitor.setRefreshScope([.battery, .wifi])

        XCTAssertEqual(fixture.audio.stopCount, 1)
        XCTAssertEqual(fixture.monitor.snapshot.volume, .unknown, "stale audio state must not survive")

        // A late listener callback can no longer pull CoreAudio back in.
        audioCallback?()
        fixture.monitor.refresh()
        await waitUntil { reader.batteryReadCount >= 2 }
        await Task.yield()
        XCTAssertEqual(reader.volumeReadCount, volumeReadsBeforeDrop)
        fixture.monitor.stop()
    }

    @MainActor
    func testRefreshScopeSetBeforeStartInstallsAudioMonitorOnStart() async {
        let reader = DuoStatusReaderFake(volume: DuoSystemStatusSnapshot.Volume(scalar: 0.8))
        let fixture = Fixture(reader: reader)
        fixture.monitor.setRefreshScope([.battery, .wifi, .volume])
        XCTAssertEqual(fixture.audio.startCount, 0, "nothing starts while the monitor is stopped")

        fixture.monitor.start()
        XCTAssertEqual(fixture.audio.startCount, 1)
        await waitUntil { fixture.monitor.snapshot.volume.scalar == 0.8 }
        fixture.monitor.stop()
        XCTAssertEqual(fixture.audio.stopCount, 1)
    }

    @MainActor
    func testPathUpdatePublishesConnectionAndRereadsWiFi() async {
        let reader = DuoStatusReaderFake(wifi: DuoWiFiReading(state: .connected(level: 3), signalLevel: 3))
        let fixture = Fixture(reader: reader)
        fixture.monitor.start()
        await waitUntil { fixture.monitor.snapshot.wifi == .connected(level: 3) }
        let wifiReadsBeforePath = reader.wifiReadCount

        let path = DuoNetworkPathSnapshot(status: .connected, usesWiFi: true, isExpensive: true)
        reader.wifi = DuoWiFiReading(state: .hotspot, signalLevel: 3)
        fixture.network.onChange?(path)

        await waitUntil { fixture.monitor.snapshot.connectionKind == .wifi }
        await waitUntil { fixture.monitor.snapshot.wifi == .hotspot }
        XCTAssertEqual(fixture.monitor.snapshot.network, .connected)
        // The precise state keeps its signal strength so the dots stay accurate.
        XCTAssertEqual(fixture.monitor.snapshot.wifiLevel, 3)
        XCTAssertGreaterThan(reader.wifiReadCount, wifiReadsBeforePath)
        XCTAssertEqual(reader.lastWiFiPath, path)

        fixture.network.onChange?(DuoNetworkPathSnapshot(status: .disconnected))
        await waitUntil { fixture.monitor.snapshot.network == .disconnected }
        XCTAssertNil(fixture.monitor.snapshot.connectionKind)
        fixture.monitor.stop()
    }

    @MainActor
    func testAudioEventOnlyRereadsVolume() async {
        let reader = DuoStatusReaderFake(volume: DuoSystemStatusSnapshot.Volume(scalar: 0.2))
        let fixture = Fixture(reader: reader)
        fixture.monitor.setRefreshScope(.all)
        fixture.monitor.start()
        await waitUntil { fixture.monitor.snapshot.volume.scalar == 0.2 }
        let batteryReads = reader.batteryReadCount
        let wifiReads = reader.wifiReadCount

        reader.volume = DuoSystemStatusSnapshot.Volume(scalar: 0.9, isMuted: true)
        fixture.audio.onChange?()

        await waitUntil { fixture.monitor.snapshot.volume.isMuted }
        XCTAssertEqual(fixture.monitor.snapshot.volume.scalar, 0.9)
        XCTAssertEqual(reader.batteryReadCount, batteryReads)
        XCTAssertEqual(reader.wifiReadCount, wifiReads)
        fixture.monitor.stop()
    }

    @MainActor
    func testRestartUsesFreshPathMonitorAndIgnoresOldCallbacks() async {
        let reader = DuoStatusReaderFake(battery: .notPresent, wifi: DuoWiFiReading(state: .off))
        let fixture = Fixture(reader: reader, networkMonitorCount: 2)
        fixture.monitor.start()
        await waitUntil { fixture.monitor.snapshot.battery == .notPresent }
        let oldCallback = fixture.network.onChange
        oldCallback?(DuoNetworkPathSnapshot(status: .connected, usesWiredEthernet: true))
        await waitUntil { fixture.monitor.snapshot.connectionKind == .ethernet }

        fixture.monitor.stop()
        fixture.monitor.stop()
        XCTAssertEqual(fixture.network.cancelCount, 1)
        fixture.monitor.start()
        XCTAssertEqual(fixture.secondNetwork?.startCount, 1)

        oldCallback?(DuoNetworkPathSnapshot(status: .connected, usesWiFi: true))
        await Task.yield()
        XCTAssertEqual(fixture.monitor.snapshot.network, .unknown)
        XCTAssertNil(fixture.monitor.snapshot.connectionKind)
        fixture.monitor.stop()
    }

    @MainActor
    func testStopDiscardsInFlightReadingAndRestartReadsFresh() async {
        let reader = DuoStatusBlockingReader()
        let fixture = Fixture(reader: reader)
        var publishedFractions: [Double] = []
        let subscription = fixture.monitor.$snapshot.sink { snapshot in
            if let fraction = snapshot.batteryFraction {
                publishedFractions.append(fraction)
            }
        }

        fixture.monitor.start()
        await waitUntil { reader.hasStarted }
        XCTAssertFalse(reader.ranOnMainThread)
        fixture.monitor.stop()
        fixture.monitor.start()
        reader.release()

        await waitUntil { fixture.monitor.snapshot.batteryFraction == 0.9 }
        XCTAssertEqual(publishedFractions, [0.9])
        withExtendedLifetime(subscription) {}
        fixture.monitor.stop()
    }

    @MainActor
    func testDeinitRemovesPowerSourceAndObservers() async throws {
        var context = CFRunLoopSourceContext()
        let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
        let network = DuoNetworkPathMonitorFake()
        let audio = DuoStatusAudioEventMonitorFake()
        let workspaceCenter = NotificationCenter()
        let processInfoCenter = NotificationCenter()
        var monitor: DuoSystemStatusMonitor? = DuoSystemStatusMonitor(
            reader: DuoStatusReaderFake(battery: .notPresent),
            networkMonitorFactory: { network },
            audioEventMonitorFactory: { audio },
            notificationSourceFactory: { _ in source },
            workspaceNotificationCenter: workspaceCenter,
            processInfoNotificationCenter: processInfoCenter,
            refreshInterval: 60
        )
        weak var weakMonitor = monitor
        monitor?.setRefreshScope(.all)
        monitor?.start()
        await waitUntil { monitor?.snapshot.battery == .notPresent }
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))

        monitor = nil

        XCTAssertNil(weakMonitor)
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
        XCTAssertFalse(CFRunLoopSourceIsValid(source))
        XCTAssertEqual(network.cancelCount, 1)
        XCTAssertEqual(audio.stopCount, 1)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        processInfoCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    // MARK: - Helpers

    @MainActor
    private struct Fixture {
        let monitor: DuoSystemStatusMonitor
        let network: DuoNetworkPathMonitorFake
        let secondNetwork: DuoNetworkPathMonitorFake?
        let audio: DuoStatusAudioEventMonitorFake
        let workspaceCenter: NotificationCenter
        let processInfoCenter: NotificationCenter

        init(
            reader: any DuoSystemStatusReading,
            powerSource: CFRunLoopSource? = nil,
            networkMonitorCount: Int = 1
        ) {
            let network = DuoNetworkPathMonitorFake()
            let secondNetwork = networkMonitorCount > 1 ? DuoNetworkPathMonitorFake() : nil
            let audio = DuoStatusAudioEventMonitorFake()
            let workspaceCenter = NotificationCenter()
            let processInfoCenter = NotificationCenter()
            self.network = network
            self.secondNetwork = secondNetwork
            self.audio = audio
            self.workspaceCenter = workspaceCenter
            self.processInfoCenter = processInfoCenter
            var pending = [network, secondNetwork].compactMap { $0 }
            monitor = DuoSystemStatusMonitor(
                reader: reader,
                networkMonitorFactory: { pending.count > 1 ? pending.removeFirst() : pending[0] },
                audioEventMonitorFactory: { audio },
                notificationSourceFactory: { _ in powerSource },
                workspaceNotificationCenter: workspaceCenter,
                processInfoNotificationCenter: processInfoCenter,
                refreshInterval: 60
            )
        }
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

// MARK: - Fakes

@MainActor
private final class DuoNetworkPathMonitorFake: DuoNetworkPathMonitoring {
    var onChange: (@Sendable (DuoNetworkPathSnapshot) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(queue _: DispatchQueue) {
        startCount += 1
    }

    func cancel() {
        cancelCount += 1
        onChange = nil
    }
}

@MainActor
private final class DuoStatusAudioEventMonitorFake: DuoStatusAudioEventMonitoring {
    private(set) var onChange: (@MainActor @Sendable () -> Void)?
    private(set) var startCount = 0
    private(set) var reconcileCount = 0
    private(set) var stopCount = 0

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func reconcile() {
        reconcileCount += 1
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }
}

private final class DuoStatusReaderFake: DuoSystemStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBattery: DuoSystemStatusSnapshot.Battery
    private var storedWiFi: DuoWiFiReading
    private var storedVolume: DuoSystemStatusSnapshot.Volume
    private var batteryReads = 0
    private var wifiReads = 0
    private var volumeReads = 0
    private var wasOnMainThread = false
    private var storedLastWiFiPath: DuoNetworkPathSnapshot?

    init(
        battery: DuoSystemStatusSnapshot.Battery = .unavailable,
        wifi: DuoWiFiReading = DuoWiFiReading(state: .unavailable),
        volume: DuoSystemStatusSnapshot.Volume = .unknown
    ) {
        storedBattery = battery
        storedWiFi = wifi
        storedVolume = volume
    }

    var wifi: DuoWiFiReading {
        get { lock.withLock { storedWiFi } }
        set { lock.withLock { storedWiFi = newValue } }
    }

    var volume: DuoSystemStatusSnapshot.Volume {
        get { lock.withLock { storedVolume } }
        set { lock.withLock { storedVolume = newValue } }
    }

    var batteryReadCount: Int { lock.withLock { batteryReads } }
    var wifiReadCount: Int { lock.withLock { wifiReads } }
    var volumeReadCount: Int { lock.withLock { volumeReads } }
    var ranOnMainThread: Bool { lock.withLock { wasOnMainThread } }
    var lastWiFiPath: DuoNetworkPathSnapshot? { lock.withLock { storedLastWiFiPath } }

    func readBattery() -> DuoSystemStatusSnapshot.Battery {
        lock.withLock {
            batteryReads += 1
            wasOnMainThread = wasOnMainThread || Thread.isMainThread
            return storedBattery
        }
    }

    func readWiFi(path: DuoNetworkPathSnapshot?) -> DuoWiFiReading {
        lock.withLock {
            wifiReads += 1
            storedLastWiFiPath = path
            wasOnMainThread = wasOnMainThread || Thread.isMainThread
            return storedWiFi
        }
    }

    func readVolume() -> DuoSystemStatusSnapshot.Volume {
        lock.withLock {
            volumeReads += 1
            wasOnMainThread = wasOnMainThread || Thread.isMainThread
            return storedVolume
        }
    }
}

/// Blocks the first battery read until released so a stop/start cycle can be
/// exercised while a read is in flight.
private final class DuoStatusBlockingReader: DuoSystemStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var readCount = 0
    private var wasOnMainThread = false

    var hasStarted: Bool { lock.withLock { readCount > 0 } }
    var ranOnMainThread: Bool { lock.withLock { wasOnMainThread } }

    func readBattery() -> DuoSystemStatusSnapshot.Battery {
        let count = lock.withLock {
            readCount += 1
            wasOnMainThread = wasOnMainThread || Thread.isMainThread
            return readCount
        }
        if count == 1 {
            _ = semaphore.wait(timeout: .now() + 5)
        }
        return .level(fraction: count == 1 ? 0.1 : 0.9, isCharging: false)
    }

    func readWiFi(path _: DuoNetworkPathSnapshot?) -> DuoWiFiReading {
        DuoWiFiReading(state: .connected(level: 4), signalLevel: 4)
    }

    func readVolume() -> DuoSystemStatusSnapshot.Volume {
        DuoSystemStatusSnapshot.Volume(scalar: 0.5)
    }

    func release() {
        semaphore.signal()
    }
}
