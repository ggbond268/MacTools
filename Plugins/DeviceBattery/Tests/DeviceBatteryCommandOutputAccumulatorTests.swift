import Foundation
import XCTest
@testable import DeviceBatteryPlugin

final class DeviceBatteryCommandOutputAccumulatorTests: XCTestCase {
    func testFiltersUTF8LinesDeliveredOneByteAtATime() {
        let accumulator = DeviceBatteryCommandOutputAccumulator(lineFilter: { $0.hasPrefix("keep") })
        for byte in "keep 👋\nskip 🌍\nkeep 中文\n".utf8 {
            accumulator.append(Data([byte]))
        }

        XCTAssertEqual(accumulator.output(), "keep 👋\nkeep 中文\n")
    }

    func testPreservesUnterminatedUTF8LineAcrossAppends() {
        let accumulator = DeviceBatteryCommandOutputAccumulator(lineFilter: { $0.hasPrefix("keep") })
        let bytes = Data("keep 👋".utf8)
        accumulator.append(Data(bytes.dropLast(2)))
        accumulator.append(Data(bytes.suffix(2)))

        XCTAssertEqual(accumulator.output(), "keep 👋\n")
        XCTAssertEqual(accumulator.output(), "keep 👋\n", "Finishing again must not append the trailing line twice")
    }
}
