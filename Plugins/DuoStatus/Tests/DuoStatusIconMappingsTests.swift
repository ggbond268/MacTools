import XCTest
@testable import DuoStatusPlugin

final class DuoStatusIconMappingsTests: XCTestCase {
    // MARK: - Volume dots

    func testVolumeStepsBoundaries() {
        for (scalar, steps) in [(0.0, 0), (0.01, 1), (0.25, 1), (0.26, 2), (0.5, 2),
                                (0.51, 3), (0.75, 3), (0.76, 4), (1.0, 4)] {
            XCTAssertEqual(
                DuoStatusIconMappings.volumeSteps(scalar: scalar, isMuted: false),
                steps,
                "scalar: \(scalar)"
            )
        }
    }

    func testVolumeStepsClampsOutOfRangeValues() {
        XCTAssertEqual(DuoStatusIconMappings.volumeSteps(scalar: 1.4, isMuted: false), 4)
        XCTAssertEqual(DuoStatusIconMappings.volumeSteps(scalar: -0.5, isMuted: false), 0)
    }

    func testVolumeStepsTreatsMissingMutedAndNonFiniteAsSilent() {
        XCTAssertEqual(DuoStatusIconMappings.volumeSteps(scalar: nil, isMuted: false), 0)
        XCTAssertEqual(DuoStatusIconMappings.volumeSteps(scalar: .nan, isMuted: false), 0)
        XCTAssertEqual(DuoStatusIconMappings.volumeSteps(scalar: .infinity, isMuted: false), 0)
        XCTAssertEqual(DuoStatusIconMappings.volumeSteps(scalar: 0.9, isMuted: true), 0)
    }

    func testBottomIndicatorUsesTheSelectedQuantity() {
        var snapshot = DuoSystemStatusSnapshot.unknown
        snapshot.wifi = .connected(level: 3)
        snapshot.volume = DuoSystemStatusSnapshot.Volume(scalar: 0.9)
        var options = DuoStatusIconOptions.default

        XCTAssertEqual(DuoStatusIconMappings.bottomIndicatorSteps(snapshot: snapshot, options: options), 3)
        options.bottomIndicator = .volume
        XCTAssertEqual(DuoStatusIconMappings.bottomIndicatorSteps(snapshot: snapshot, options: options), 4)
    }

    // MARK: - Volume bar

    func testVolumeBarFollowsTheScalarAndStaysEmptyWhenSilent() {
        XCTAssertEqual(DuoStatusIconMappings.volumeBarFraction(scalar: 0.37, isMuted: false), 0.37)
        XCTAssertEqual(DuoStatusIconMappings.volumeBarFraction(scalar: 1.4, isMuted: false), 1)
        XCTAssertEqual(DuoStatusIconMappings.volumeBarFraction(scalar: -0.2, isMuted: false), 0)
        XCTAssertEqual(DuoStatusIconMappings.volumeBarFraction(scalar: 0.8, isMuted: true), 0)
        XCTAssertEqual(DuoStatusIconMappings.volumeBarFraction(scalar: nil, isMuted: false), 0)
        XCTAssertEqual(DuoStatusIconMappings.volumeBarFraction(scalar: .nan, isMuted: false), 0)
    }

    func testVolumeBarAppliesOnlyToTheVolumeIndicator() {
        var options = DuoStatusIconOptions.default
        options.volumeStyle = .bar
        XCTAssertFalse(DuoStatusIconMappings.usesVolumeBar(options: options), "Wi-Fi signal always uses dots")
        options.bottomIndicator = .volume
        XCTAssertTrue(DuoStatusIconMappings.usesVolumeBar(options: options))
    }

    // MARK: - Battery colour ladder

    func testStatusColorsCanBeTurnedOffEntirely() {
        var options = DuoStatusIconOptions.default
        options.usesBatteryStatusColors = false
        let critical = DuoSystemStatusSnapshot.Battery.level(
            fraction: 0.05, isCharging: true, isExternalPowerConnected: true, isLowPowerMode: true
        )
        XCTAssertEqual(DuoStatusIconMappings.batteryColorRole(critical, options: options), .foreground)
    }

    func testCriticalOutranksChargingAndLowPowerMode() {
        let options = DuoStatusIconOptions.default
        let battery = DuoSystemStatusSnapshot.Battery.level(
            fraction: 0.08, isCharging: true, isExternalPowerConnected: true, isLowPowerMode: true
        )
        XCTAssertEqual(DuoStatusIconMappings.batteryColorRole(battery, options: options), .critical)
    }

    func testLowPowerModeOutranksCharging() {
        let options = DuoStatusIconOptions.default
        let battery = DuoSystemStatusSnapshot.Battery.level(
            fraction: 0.5, isCharging: true, isExternalPowerConnected: true, isLowPowerMode: true
        )
        XCTAssertEqual(DuoStatusIconMappings.batteryColorRole(battery, options: options), .lowPower)
    }

    func testOnlyActiveChargingUsesTheChargingRole() {
        let options = DuoStatusIconOptions.default
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(.level(fraction: 0.5, isCharging: true), options: options),
            .charging
        )
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(
                .level(fraction: 0.8, isCharging: false, isExternalPowerConnected: true),
                options: options
            ),
            .foreground,
            "power held at a charge limit keeps the shipping monochrome ring"
        )
    }

    func testDischargingAndAbsentBatteriesStayMonochrome() {
        let options = DuoStatusIconOptions.default
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(.level(fraction: 0.5, isCharging: false), options: options),
            .foreground
        )
        XCTAssertEqual(DuoStatusIconMappings.batteryColorRole(.notPresent, options: options), .foreground)
        XCTAssertEqual(DuoStatusIconMappings.batteryColorRole(.unavailable, options: options), .foreground)
    }

    func testCriticalThresholdIsExclusiveAndFollowsTheOption() {
        var options = DuoStatusIconOptions.default
        options.batteryCriticalThreshold = 20
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(.level(fraction: 0.20, isCharging: false), options: options),
            .foreground,
            "a level exactly at the threshold is not critical yet"
        )
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(.level(fraction: 0.19, isCharging: false), options: options),
            .critical
        )
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(.level(fraction: 0.196, isCharging: false), options: options),
            .critical,
            "the unrounded level decides, even when it would display as 20%"
        )
        options.batteryCriticalThreshold = 50
        XCTAssertEqual(
            DuoStatusIconMappings.batteryColorRole(.level(fraction: 0.45, isCharging: false), options: options),
            .critical
        )
    }

    // MARK: - Top-gap content

    func testGapContentTruthTable() {
        let charging = DuoSystemStatusSnapshot.Battery.level(
            fraction: 0.5, isCharging: true, isExternalPowerConnected: true
        )
        let plugged = DuoSystemStatusSnapshot.Battery.level(
            fraction: 1, isCharging: false, isExternalPowerConnected: true
        )
        let onBattery = DuoSystemStatusSnapshot.Battery.level(fraction: 0.5, isCharging: false)

        var options = DuoStatusIconOptions.default
        // Defaults: charging mark on, percentage off.
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(charging, options: options), .bolt)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(plugged, options: options), .plug)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(onBattery, options: options), .empty)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(.notPresent, options: options), .empty)

        // Percentage on, but the charging mark still wins while connected.
        options.showsBatteryPercentage = true
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(charging, options: options), .bolt)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(plugged, options: options), .plug)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(onBattery, options: options), .percentage)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(.notPresent, options: options), .percentage)

        // Asking for the number while connected replaces the plug, never the bolt.
        options.showsPercentageWhenConnected = true
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(charging, options: options), .bolt)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(plugged, options: options), .percentage)

        // Without the charging mark the gap only ever carries the number.
        options.showsChargingIndicator = false
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(charging, options: options), .percentage)
        options.showsBatteryPercentage = false
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(charging, options: options), .empty)
        XCTAssertEqual(DuoStatusIconMappings.batteryGapContent(plugged, options: options), .empty)
    }

    // MARK: - Bluetooth glyph

    private func bluetoothOptions(prioritizesNetworkErrors: Bool = true) -> DuoStatusIconOptions {
        var options = DuoStatusIconOptions.default
        options.showsBluetoothAudioGlyph = true
        options.bluetoothGlyphPrioritizesNetworkErrors = prioritizesNetworkErrors
        return options
    }

    private let bluetoothVolume = DuoSystemStatusSnapshot.Volume(scalar: 0.5, isBluetoothOutput: true)

    func testBluetoothGlyphNeedsBothTheOptionAndABluetoothOutput() {
        XCTAssertFalse(DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: bluetoothVolume, wifi: .connected(level: 4), network: .connected,
            options: .default
        ))
        XCTAssertFalse(DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: DuoSystemStatusSnapshot.Volume(scalar: 0.5), wifi: .connected(level: 4),
            network: .connected, options: bluetoothOptions()
        ))
        XCTAssertTrue(DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: bluetoothVolume, wifi: .connected(level: 4), network: .connected,
            options: bluetoothOptions()
        ))
    }

    func testNetworkErrorsWinWhenPrioritized() {
        for wifi: DuoSystemStatusSnapshot.WiFi in [.disconnected, .noInternet, .off, .unavailable] {
            XCTAssertFalse(
                DuoStatusIconMappings.shouldUseBluetoothGlyph(
                    volume: bluetoothVolume, wifi: wifi, network: .connected,
                    options: bluetoothOptions()
                ),
                "\(wifi)"
            )
        }
        XCTAssertFalse(DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: bluetoothVolume, wifi: .connected(level: 4), network: .disconnected,
            options: bluetoothOptions()
        ))
    }

    func testPreciseButHealthyStatesStillYieldToBluetooth() {
        for wifi: DuoSystemStatusSnapshot.WiFi in [.hotspot, .temporary, .shared] {
            XCTAssertTrue(
                DuoStatusIconMappings.shouldUseBluetoothGlyph(
                    volume: bluetoothVolume, wifi: wifi, network: .connected,
                    options: bluetoothOptions()
                ),
                "\(wifi)"
            )
        }
        // No path update has arrived yet; that is not a failure.
        XCTAssertTrue(DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: bluetoothVolume, wifi: .connected(level: 2), network: .unknown,
            options: bluetoothOptions()
        ))
    }

    func testBluetoothCanOutrankNetworkErrorsWhenPriorityIsOff() {
        XCTAssertTrue(DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: bluetoothVolume, wifi: .off, network: .disconnected,
            options: bluetoothOptions(prioritizesNetworkErrors: false)
        ))
    }
}
