import XCTest
@testable import BatteryChargeLimitPlugin

final class BatteryForceDischargePolicyTests: XCTestCase {
    private enum TestError: Error {
        case rejected
    }

    func testCandidatesUsePreferredOrderAndKeySpecificValues() {
        XCTAssertEqual(
            BatteryForceDischargePolicy.candidates,
            [
                .init(key: BatteryForceDischargePolicy.tahoeAdapterKey, enabledValue: 0x08),
                .init(key: BatteryForceDischargePolicy.secondaryAdapterKey, enabledValue: 0x20),
                .init(key: BatteryForceDischargePolicy.legacyAdapterKey, enabledValue: 0x01),
            ]
        )
        XCTAssertEqual(
            BatteryForceDischargePolicy.availableCandidates(hasKey: { $0 == "CH0J" }),
            [.init(key: "CH0J", enabledValue: 0x20)]
        )
    }

    func testActiveStateDistinguishesInactiveActiveAndUnknownValues() {
        XCTAssertEqual(
            BatteryForceDischargePolicy.activeState(for: 0, enabledValue: 0x08),
            false
        )
        XCTAssertEqual(
            BatteryForceDischargePolicy.activeState(for: 0x08, enabledValue: 0x08),
            true
        )
        XCTAssertNil(BatteryForceDischargePolicy.activeState(for: 0x02, enabledValue: 0x08))
        XCTAssertNil(BatteryForceDischargePolicy.activeState(for: nil, enabledValue: 0x08))
    }

    func testCH0JUsesItsOwnActiveBit() {
        let candidate = BatteryForceDischargePolicy.Candidate(key: "CH0J", enabledValue: 0x20)

        XCTAssertEqual(
            BatteryForceDischargePolicy.activeState(for: 0x20, enabledValue: candidate.enabledValue),
            true
        )
        XCTAssertNil(
            BatteryForceDischargePolicy.activeState(for: 0x01, enabledValue: candidate.enabledValue)
        )
    }

    func testEnableStopsAfterFirstSuccessfulCandidate() throws {
        var writes: [String] = []

        try BatteryForceDischargePolicy.enable(BatteryForceDischargePolicy.candidates) { candidate in
            writes.append(candidate.key)
        }

        XCTAssertEqual(writes, ["CHIE"])
    }

    func testEnableFallsBackAfterCandidateFailure() throws {
        var writes: [String] = []

        try BatteryForceDischargePolicy.enable(BatteryForceDischargePolicy.candidates) { candidate in
            writes.append(candidate.key)
            if candidate.key == "CHIE" {
                throw TestError.rejected
            }
        }

        XCTAssertEqual(writes, ["CHIE", "CH0J"])
    }

    func testDisableIgnoresFailureForReadableInactiveCompatibilityKey() throws {
        var values: [String: UInt8] = ["CHIE": 0x08, "CH0J": 0x00, "CH0I": 0x00]
        var clears: [String] = []

        try BatteryForceDischargePolicy.disable(
            BatteryForceDischargePolicy.candidates,
            isActive: { candidate in
                BatteryForceDischargePolicy.activeState(
                    for: values[candidate.key],
                    enabledValue: candidate.enabledValue
                )
            },
            clear: { candidate in
                clears.append(candidate.key)
                if candidate.key == "CH0J" {
                    throw TestError.rejected
                }
                values[candidate.key] = 0
            }
        )

        XCTAssertEqual(clears, ["CHIE", "CH0J", "CH0I"])
        XCTAssertEqual(values["CHIE"], 0)
    }

    func testDisableFailsWhenActiveKeyCannotBeCleared() {
        var values: [String: UInt8] = ["CHIE": 0x08, "CH0J": 0x00, "CH0I": 0x00]
        var clears: [String] = []

        XCTAssertThrowsError(
            try BatteryForceDischargePolicy.disable(
                BatteryForceDischargePolicy.candidates,
                isActive: { candidate in
                    BatteryForceDischargePolicy.activeState(
                        for: values[candidate.key],
                        enabledValue: candidate.enabledValue
                    )
                },
                clear: { candidate in
                    clears.append(candidate.key)
                    if candidate.key == "CHIE" {
                        throw TestError.rejected
                    }
                    values[candidate.key] = 0
                }
            )
        ) { error in
            guard let error = error as? BatteryForceDischargePolicyError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case let .activeKeyClearFailed(key, _) = error else {
                return XCTFail("Expected active-key cleanup failure, got: \(error)")
            }
            XCTAssertEqual(key, "CHIE")
        }

        XCTAssertEqual(clears, ["CHIE", "CH0J", "CH0I"])
    }

    func testDisableFailsWhenUnknownKeyCannotBeCleared() {
        var values: [String: UInt8] = ["CHIE": 0x02, "CH0J": 0x00, "CH0I": 0x00]

        XCTAssertThrowsError(
            try BatteryForceDischargePolicy.disable(
                BatteryForceDischargePolicy.candidates,
                isActive: { candidate in
                    BatteryForceDischargePolicy.activeState(
                        for: values[candidate.key],
                        enabledValue: candidate.enabledValue
                    )
                },
                clear: { candidate in
                    if candidate.key == "CHIE" {
                        throw TestError.rejected
                    }
                    values[candidate.key] = 0
                }
            )
        ) { error in
            guard let error = error as? BatteryForceDischargePolicyError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case let .indeterminateKeyClearFailed(key, _) = error else {
                return XCTFail("Expected indeterminate-key cleanup failure, got: \(error)")
            }
            XCTAssertEqual(key, "CHIE")
        }
    }
}
