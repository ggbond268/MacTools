import CoreGraphics
import MacToolsPluginKit
import XCTest
@testable import MacTools
@testable import DisplayBrightnessPlugin

/// Exercises the gamma original-transfer-table load/restore chain through the
/// injected CoreGraphics seams, without a live display. The restore path is a
/// safety boundary: dimming mutates the per-display gamma table system-wide,
/// so cleanup must put back exactly the table captured before the first write.
final class GammaBrightnessBackendRestoreTests: XCTestCase {
    private final class GammaTableFake: @unchecked Sendable {
        struct WriteCall: Equatable {
            let sampleCount: UInt32
            let red: [CGGammaValue]
            let green: [CGGammaValue]
            let blue: [CGGammaValue]
        }

        var capacity: UInt32
        var originalRed: [CGGammaValue]
        var originalGreen: [CGGammaValue]
        var originalBlue: [CGGammaValue]
        /// When set, the fake reports this sample count from the read call
        /// instead of echoing the requested capacity.
        var reportedSampleCount: UInt32?
        var readResult: CGError = .success
        var writeResult: CGError = .success
        private(set) var readCallCount = 0
        private(set) var writeCalls: [WriteCall] = []

        init(
            capacity: UInt32 = 4,
            originalRed: [CGGammaValue] = [0, 0.25, 0.5, 1],
            originalGreen: [CGGammaValue] = [0, 0.3, 0.6, 0.9],
            originalBlue: [CGGammaValue] = [0.1, 0.2, 0.4, 0.8]
        ) {
            self.capacity = capacity
            self.originalRed = originalRed
            self.originalGreen = originalGreen
            self.originalBlue = originalBlue
        }

        func makeBackend(display: DisplayInfo) -> GammaBrightnessBackend? {
            GammaBrightnessBackend(
                display: display,
                tableCapacity: { [self] _ in
                    capacity
                },
                readTransferTable: { [self] _, requestedCapacity, red, green, blue, sampleCount in
                    readCallCount += 1
                    guard readResult == .success else {
                        return readResult
                    }

                    let provided = reportedSampleCount ?? requestedCapacity
                    let filledCount = Int(min(provided, requestedCapacity))
                    for index in 0..<filledCount {
                        red?[index] = originalRed[index]
                        green?[index] = originalGreen[index]
                        blue?[index] = originalBlue[index]
                    }
                    sampleCount?.pointee = provided
                    return .success
                },
                writeTransferTable: { [self] _, sampleCount, red, green, blue in
                    writeCalls.append(
                        WriteCall(
                            sampleCount: sampleCount,
                            red: Array(UnsafeBufferPointer(start: red, count: Int(sampleCount))),
                            green: Array(UnsafeBufferPointer(start: green, count: Int(sampleCount))),
                            blue: Array(UnsafeBufferPointer(start: blue, count: Int(sampleCount)))
                        )
                    )
                    return writeResult
                }
            )
        }
    }

    private func makeBackend(
        fake: GammaTableFake,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> GammaBrightnessBackend {
        let display = makeTestDisplay(id: 7, name: "Fake Display")
        return try XCTUnwrap(fake.makeBackend(display: display), file: file, line: line)
    }

    func testInitFailsWhenCapacityIsZero() {
        let fake = GammaTableFake(capacity: 0)

        XCTAssertNil(fake.makeBackend(display: makeTestDisplay(id: 7, name: "Fake Display")))
        XCTAssertEqual(fake.readCallCount, 0)
        XCTAssertTrue(fake.writeCalls.isEmpty)
    }

    func testWriteLoadsOriginalTableOnceAndScalesFromCache() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)

        try backend.writeBrightness(0.5)
        try backend.writeBrightness(0.25)

        XCTAssertEqual(fake.readCallCount, 1)
        XCTAssertEqual(fake.writeCalls.count, 2)

        let secondWrite = try XCTUnwrap(fake.writeCalls.last)
        XCTAssertEqual(secondWrite.sampleCount, 4)
        XCTAssertEqual(secondWrite.red, fake.originalRed.map { $0 * Float(0.25) })
        XCTAssertEqual(secondWrite.green, fake.originalGreen.map { $0 * Float(0.25) })
        XCTAssertEqual(secondWrite.blue, fake.originalBlue.map { $0 * Float(0.25) })
        XCTAssertEqual(try backend.readBrightness(), 0.25)
    }

    func testCleanupRestoresExactOriginalTablePerChannel() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)

        try backend.writeBrightness(0.5)
        backend.cleanup()

        let restoreWrite = try XCTUnwrap(fake.writeCalls.last)
        XCTAssertEqual(restoreWrite.sampleCount, 4)
        XCTAssertEqual(restoreWrite.red, fake.originalRed)
        XCTAssertEqual(restoreWrite.green, fake.originalGreen)
        XCTAssertEqual(restoreWrite.blue, fake.originalBlue)
        XCTAssertEqual(try backend.readBrightness(), 1)
    }

    func testCleanupWithoutPriorLoadDoesNotTouchGamma() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)

        backend.cleanup()

        XCTAssertEqual(fake.readCallCount, 0)
        XCTAssertTrue(fake.writeCalls.isEmpty)
        XCTAssertEqual(try backend.readBrightness(), 1)
    }

    func testCapacityDroppingToZeroFailsWriteWithoutCaching() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)
        fake.capacity = 0

        XCTAssertThrowsError(try backend.writeBrightness(0.5)) { error in
            guard case DisplayBrightnessControllerError.brightnessUnavailable = error else {
                XCTFail("expected brightnessUnavailable, got \(error)")
                return
            }
        }
        XCTAssertEqual(fake.readCallCount, 0)
        XCTAssertTrue(fake.writeCalls.isEmpty)

        // Nothing was cached, so cleanup must stay a no-op.
        backend.cleanup()
        XCTAssertTrue(fake.writeCalls.isEmpty)
    }

    func testReadFailureDoesNotCacheAndNextWriteRetriesLoad() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)
        fake.readResult = .failure

        XCTAssertThrowsError(try backend.writeBrightness(0.5)) { error in
            guard case DisplayBrightnessControllerError.brightnessUnavailable = error else {
                XCTFail("expected brightnessUnavailable, got \(error)")
                return
            }
        }
        XCTAssertEqual(fake.readCallCount, 1)
        XCTAssertTrue(fake.writeCalls.isEmpty)

        backend.cleanup()
        XCTAssertTrue(fake.writeCalls.isEmpty)

        // A failed load must not poison the cache: the next write re-reads.
        fake.readResult = .success
        try backend.writeBrightness(0.5)
        XCTAssertEqual(fake.readCallCount, 2)
        XCTAssertEqual(fake.writeCalls.count, 1)
    }

    func testWriteFailureThrowsAndKeepsStateAndCache() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)
        fake.writeResult = .failure

        XCTAssertThrowsError(try backend.writeBrightness(0.5)) { error in
            guard case DisplayBrightnessControllerError.softwareBrightnessFailed = error else {
                XCTFail("expected softwareBrightnessFailed, got \(error)")
                return
            }
        }
        XCTAssertEqual(try backend.readBrightness(), 1)

        // The original table was captured before the failed write, so a later
        // successful write reuses the cache instead of re-reading a table that
        // may already be dimmed.
        fake.writeResult = .success
        try backend.writeBrightness(0.5)
        XCTAssertEqual(fake.readCallCount, 1)
        XCTAssertEqual(try backend.readBrightness(), 0.5)
    }

    func testCleanupSurvivesWriteFailureAndStillResetsBrightness() throws {
        let fake = GammaTableFake()
        let backend = try makeBackend(fake: fake)

        try backend.writeBrightness(0.5)
        fake.writeResult = .failure
        backend.cleanup()

        let restoreWrite = try XCTUnwrap(fake.writeCalls.last)
        XCTAssertEqual(restoreWrite.red, fake.originalRed)
        XCTAssertEqual(try backend.readBrightness(), 1)
    }

    func testReportedSampleCountSmallerThanCapacityIsHonored() throws {
        let fake = GammaTableFake()
        fake.reportedSampleCount = 3
        let backend = try makeBackend(fake: fake)

        try backend.writeBrightness(1)

        let write = try XCTUnwrap(fake.writeCalls.last)
        XCTAssertEqual(write.sampleCount, 3)
        XCTAssertEqual(write.red, Array(fake.originalRed.prefix(3)))
        XCTAssertEqual(write.green, Array(fake.originalGreen.prefix(3)))
        XCTAssertEqual(write.blue, Array(fake.originalBlue.prefix(3)))
    }

    func testReportedSampleCountLargerThanCapacityIsClampedToBuffer() throws {
        let fake = GammaTableFake()
        fake.reportedSampleCount = 16
        let backend = try makeBackend(fake: fake)

        try backend.writeBrightness(1)

        // A hostile/odd sample count must never make the backend read past the
        // buffers it allocated.
        let write = try XCTUnwrap(fake.writeCalls.last)
        XCTAssertEqual(write.sampleCount, 4)
        XCTAssertEqual(write.red, fake.originalRed)
    }

    func testZeroReportedSampleCountFailsLoadWithoutCachingEmptyTable() throws {
        // A .success read that reports zero samples must be treated as a
        // failed load: caching the empty table would turn every later write
        // and the restore-on-exit into a 0-sample no-op while the backend
        // believes it is controlling brightness.
        let fake = GammaTableFake()
        fake.reportedSampleCount = 0
        let backend = try makeBackend(fake: fake)

        XCTAssertThrowsError(try backend.writeBrightness(0.5)) { error in
            guard case DisplayBrightnessControllerError.brightnessUnavailable = error else {
                XCTFail("expected brightnessUnavailable, got \(error)")
                return
            }
        }
        XCTAssertTrue(fake.writeCalls.isEmpty)

        backend.cleanup()
        XCTAssertTrue(fake.writeCalls.isEmpty)

        // Not cached: once the host reports a sane count again, the next
        // write re-reads and proceeds.
        fake.reportedSampleCount = nil
        try backend.writeBrightness(0.5)
        XCTAssertEqual(fake.readCallCount, 2)
        XCTAssertEqual(fake.writeCalls.count, 1)
    }
}
