import Foundation
import IOKit.ps
import XCTest
@testable import DuoStatusPlugin

final class DuoSystemStatusReaderTests: XCTestCase {
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
            DuoSystemStatusReader.battery(from: [ups, internalBattery]),
            .level(fraction: 0.5, isCharging: true)
        )
        var overfull = internalBattery
        overfull[kIOPSCurrentCapacityKey] = 160
        XCTAssertEqual(
            DuoSystemStatusReader.battery(from: [overfull]),
            .level(fraction: 1, isCharging: true)
        )
        XCTAssertEqual(DuoSystemStatusReader.battery(from: [ups]), .notPresent)
    }

    func testBatteryDistinguishesAbsentAndUnavailableReadings() {
        XCTAssertEqual(DuoSystemStatusReader.battery(from: nil), .unavailable)
        XCTAssertEqual(DuoSystemStatusReader.battery(from: []), .notPresent)
        XCTAssertEqual(
            DuoSystemStatusReader.battery(from: [[
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSIsPresentKey: false,
            ]]),
            .notPresent
        )
        for (current, maximum) in [(10.0, 0.0), (-1.0, 100.0), (.nan, 100.0), (1.0, .infinity)] {
            XCTAssertEqual(
                DuoSystemStatusReader.battery(from: [[
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
            let battery = DuoSystemStatusReader.battery(from: [[
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
            let snapshot = DuoSystemStatusSnapshot(battery: battery)
            XCTAssertTrue(snapshot.isExternalPowerConnected)
            XCTAssertFalse(snapshot.isCharging)
        }
    }

    func testBatteryDoesNotReportExternalPowerWhenUnplugged() {
        let battery = DuoSystemStatusReader.battery(from: [[
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 80,
            kIOPSMaxCapacityKey: 100,
            kIOPSIsChargingKey: false,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
        ]])

        XCTAssertEqual(battery, .level(fraction: 0.8, isCharging: false))
        XCTAssertFalse(DuoSystemStatusSnapshot(battery: battery).isExternalPowerConnected)
    }

    func testSnapshotInfersExternalPowerFromActiveCharging() {
        let snapshot = DuoSystemStatusSnapshot(battery: .level(fraction: 0.5, isCharging: true))

        XCTAssertTrue(snapshot.isExternalPowerConnected)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertEqual(snapshot.batteryFraction, 0.5)
        XCTAssertFalse(DuoSystemStatusSnapshot.unknown.isExternalPowerConnected)
        XCTAssertFalse(DuoSystemStatusSnapshot(battery: .notPresent).isExternalPowerConnected)
    }

    func testWiFiMapsSignalStrengthToFourDots() {
        for (rssi, level) in [(-40, 4), (-55, 4), (-56, 3), (-65, 3), (-66, 2),
                              (-75, 2), (-76, 1), (-85, 1), (-86, 0), (-100, 0)] {
            XCTAssertEqual(
                DuoSystemStatusReader.wifi(isPowered: true, isAssociated: true, rssi: rssi),
                .connected(level: level),
                "RSSI: \(rssi)"
            )
        }
    }

    func testWiFiDoesNotTreatMissingRSSIAsFullSignal() {
        XCTAssertEqual(
            DuoSystemStatusReader.wifi(isPowered: false, isAssociated: false, rssi: 0),
            .off
        )
        XCTAssertEqual(
            DuoSystemStatusReader.wifi(isPowered: true, isAssociated: false, rssi: 0),
            .disconnected
        )
        for rssi in [0, 1, -128] {
            XCTAssertEqual(
                DuoSystemStatusReader.wifi(isPowered: true, isAssociated: true, rssi: rssi),
                .unavailable
            )
        }
    }
}
