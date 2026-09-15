import Foundation
import IOKit.ps
import XCTest
@testable import MacTools

final class MenuBarSystemStatusReaderTests: XCTestCase {
    func testBatteryUsesInternalBatteryAndNormalizesCapacity() {
        let ups: [String: Any] = [
            kIOPSTypeKey: kIOPSUPSType,
            kIOPSCurrentCapacityKey: 10,
            kIOPSMaxCapacityKey: 100,
        ]
        let internalBattery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 75,
            kIOPSMaxCapacityKey: 150,
            kIOPSIsChargingKey: true,
        ]

        XCTAssertEqual(
            MenuBarSystemStatusReader.battery(from: [ups, internalBattery]),
            .level(fraction: 0.5, isCharging: true)
        )
        var overfull = internalBattery
        overfull[kIOPSCurrentCapacityKey] = 160
        XCTAssertEqual(
            MenuBarSystemStatusReader.battery(from: [overfull]),
            .level(fraction: 1, isCharging: true)
        )
        XCTAssertEqual(MenuBarSystemStatusReader.battery(from: [ups]), .notPresent)
    }

    func testBatteryDistinguishesAbsentAndUnavailableReadings() {
        XCTAssertEqual(MenuBarSystemStatusReader.battery(from: nil), .unavailable)
        XCTAssertEqual(MenuBarSystemStatusReader.battery(from: []), .notPresent)
        XCTAssertEqual(
            MenuBarSystemStatusReader.battery(from: [[
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSIsPresentKey: false,
            ]]),
            .notPresent
        )
        for (current, maximum) in [(10.0, 0.0), (-1.0, 100.0), (.nan, 100.0), (1.0, .infinity)] {
            XCTAssertEqual(
                MenuBarSystemStatusReader.battery(from: [[
                    kIOPSTypeKey: kIOPSInternalBatteryType,
                    kIOPSCurrentCapacityKey: current,
                    kIOPSMaxCapacityKey: maximum,
                ]]),
                .unavailable
            )
        }
    }

    func testBatteryRecognizesExternalPowerWhileFullyChargedOrChargingIsPaused() {
        for capacity in [100, 80] {
            let battery = MenuBarSystemStatusReader.battery(from: [[
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSCurrentCapacityKey: capacity,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: false,
                kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            ]])

            XCTAssertEqual(
                battery,
                .level(fraction: Double(capacity) / 100, isCharging: false, isExternalPowerConnected: true)
            )
            let snapshot = MenuBarSystemStatusSnapshot(battery: battery)
            XCTAssertTrue(snapshot.isExternalPowerConnected)
            XCTAssertFalse(snapshot.isCharging)
        }
    }

    func testBatteryDoesNotReportExternalPowerWhenUnplugged() {
        let battery = MenuBarSystemStatusReader.battery(from: [[
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 80,
            kIOPSMaxCapacityKey: 100,
            kIOPSIsChargingKey: false,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
        ]])

        XCTAssertEqual(battery, .level(fraction: 0.8, isCharging: false))
        XCTAssertFalse(MenuBarSystemStatusSnapshot(battery: battery).isExternalPowerConnected)
    }

    func testSnapshotInfersExternalPowerFromActiveCharging() {
        let snapshot = MenuBarSystemStatusSnapshot(battery: .level(fraction: 0.5, isCharging: true))

        XCTAssertTrue(snapshot.isExternalPowerConnected)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertEqual(snapshot.batteryFraction, 0.5)
        XCTAssertFalse(MenuBarSystemStatusSnapshot.unknown.isExternalPowerConnected)
        XCTAssertFalse(MenuBarSystemStatusSnapshot(battery: .notPresent).isExternalPowerConnected)
    }

    func testWiFiMapsSignalStrengthToFourDots() {
        for (rssi, level) in [(-40, 4), (-55, 4), (-56, 3), (-65, 3), (-66, 2),
                              (-75, 2), (-76, 1), (-85, 1), (-86, 0), (-100, 0)] {
            XCTAssertEqual(
                MenuBarSystemStatusReader.wifi(isPowered: true, isAssociated: true, rssi: rssi),
                .connected(level: level),
                "RSSI: \(rssi)"
            )
        }
    }

    func testWiFiDoesNotTreatMissingRSSIAsFullSignal() {
        XCTAssertEqual(
            MenuBarSystemStatusReader.wifi(isPowered: false, isAssociated: false, rssi: 0),
            .off
        )
        XCTAssertEqual(
            MenuBarSystemStatusReader.wifi(isPowered: true, isAssociated: false, rssi: 0),
            .disconnected
        )
        for rssi in [0, 1, -128] {
            XCTAssertEqual(
                MenuBarSystemStatusReader.wifi(isPowered: true, isAssociated: true, rssi: rssi),
                .unavailable
            )
        }
    }
}
