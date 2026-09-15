import AppKit
import Combine
import Foundation
import XCTest
@testable import MacTools

final class MenuBarSystemStatusMonitorTests: XCTestCase {
    @MainActor
    func testRestartUsesFreshPathMonitorAndIgnoresOldCallbacks() async {
        let first = MenuBarNetworkPathMonitorFake()
        let second = MenuBarNetworkPathMonitorFake()
        var monitors = [first, second]
        let status = MenuBarLocalSystemStatus(battery: .notPresent, wifi: .off)
        let monitor = MenuBarSystemStatusMonitor(
            reader: { status },
            networkMonitorFactory: { monitors.removeFirst() },
            notificationSourceFactory: { _ in nil },
            workspaceNotificationCenter: NotificationCenter()
        )
        monitor.start()
        monitor.start()
        XCTAssertEqual(first.startCount, 1)
        await waitUntil { monitor.snapshot.battery == .notPresent }
        let oldCallback = first.onChange
        first.onChange?(.connected, .ethernet)
        await waitUntil { monitor.snapshot.connectionKind == .ethernet }

        monitor.stop()
        monitor.stop()
        XCTAssertEqual(first.cancelCount, 1)
        monitor.start()
        XCTAssertEqual(second.startCount, 1)
        oldCallback?(.connected, .wifi)
        await Task.yield()
        XCTAssertEqual(monitor.snapshot.network, .unknown)
        XCTAssertNil(monitor.snapshot.connectionKind)

        second.onChange?(.connected, .ethernet)
        await waitUntil { monitor.snapshot.connectionKind == .ethernet }
        second.onChange?(.disconnected, nil)
        await waitUntil { monitor.snapshot.network == .disconnected }
        XCTAssertNil(monitor.snapshot.connectionKind)
        monitor.stop()
    }

    @MainActor
    func testStopDiscardsInFlightLocalReadingWithoutBlockingMainActor() async {
        let reader = BlockingMenuBarStatusReader()
        let monitor = MenuBarSystemStatusMonitor(
            reader: { reader.read() },
            networkMonitorFactory: { MenuBarNetworkPathMonitorFake() },
            notificationSourceFactory: { _ in nil },
            workspaceNotificationCenter: NotificationCenter()
        )
        var publishedBatteryLevels: [Double] = []
        let subscription = monitor.$snapshot.sink { snapshot in
            if let fraction = snapshot.batteryFraction {
                publishedBatteryLevels.append(fraction)
            }
        }
        monitor.start()
        await waitUntil { reader.hasStarted }
        XCTAssertFalse(reader.ranOnMainThread)
        monitor.stop()
        monitor.start()
        reader.release()
        await waitUntil { monitor.snapshot.batteryFraction == 0.9 }
        XCTAssertEqual(publishedBatteryLevels, [0.9])
        withExtendedLifetime(subscription) {}
        monitor.stop()
    }

    @MainActor
    func testDeinitRemovesPowerSourceAndWakeObserver() async throws {
        var context = CFRunLoopSourceContext()
        let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
        let network = MenuBarNetworkPathMonitorFake()
        let center = NotificationCenter()
        var monitor: MenuBarSystemStatusMonitor? = MenuBarSystemStatusMonitor(
            reader: { MenuBarLocalSystemStatus(battery: .notPresent, wifi: .off) },
            networkMonitorFactory: { network },
            notificationSourceFactory: { _ in source },
            workspaceNotificationCenter: center
        )
        weak var weakMonitor = monitor
        monitor?.start()
        await waitUntil { monitor?.snapshot.battery == .notPresent }
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))

        monitor = nil

        XCTAssertNil(weakMonitor)
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
        XCTAssertFalse(CFRunLoopSourceIsValid(source))
        XCTAssertEqual(network.cancelCount, 1)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
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

@MainActor
private final class MenuBarNetworkPathMonitorFake: MenuBarNetworkPathMonitoring {
    var onChange: (@Sendable (
        MenuBarSystemStatusSnapshot.Network,
        MenuBarSystemStatusSnapshot.ConnectionKind?
    ) -> Void)?
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

private final class BlockingMenuBarStatusReader: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var readCount = 0
    private var wasOnMainThread = false

    var hasStarted: Bool { lock.withLock { readCount > 0 } }
    var ranOnMainThread: Bool { lock.withLock { wasOnMainThread } }

    func read() -> MenuBarLocalSystemStatus {
        let count = lock.withLock {
            readCount += 1
            wasOnMainThread = wasOnMainThread || Thread.isMainThread
            return readCount
        }
        if count == 1 {
            _ = semaphore.wait(timeout: .now() + 5)
        }
        return MenuBarLocalSystemStatus(
            battery: .level(fraction: count == 1 ? 0.1 : 0.9, isCharging: false),
            wifi: .connected(level: 4)
        )
    }

    func release() {
        semaphore.signal()
    }
}
