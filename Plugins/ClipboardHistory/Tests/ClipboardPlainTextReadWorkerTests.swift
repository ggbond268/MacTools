import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardPlainTextReadWorkerTests: XCTestCase {
    func testCancellingStalledReadDoesNotReleaseItsPhysicalSlot() async throws {
        let worker = ClipboardPlainTextReadWorker()
        let probe = ClipboardPlainTextReadProbe()
        let first = Task { await worker.read { probe.read() } }
        for _ in 0..<1_000 where !probe.hasEntered {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(probe.hasEntered)
        first.cancel()
        let second = Task { await worker.read { probe.read() } }
        XCTAssertEqual(probe.callCount, 1)
        probe.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .changed)
        XCTAssertEqual(secondResult, .payload(.plainText("read")))
        XCTAssertEqual(probe.maximumConcurrentReads, 1)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testCancelledQueuedReadNeverAsksPasteboardOwnerForContent() async throws {
        let worker = ClipboardPlainTextReadWorker()
        let probe = ClipboardPlainTextReadProbe()
        let first = Task { await worker.read { probe.read() } }
        for _ in 0..<1_000 where !probe.hasEntered {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(probe.hasEntered)
        let cancelled = Task { await worker.read { probe.read() } }
        cancelled.cancel()
        probe.release()
        _ = await first.value
        let result = await cancelled.value
        XCTAssertEqual(result, .changed)
        XCTAssertEqual(probe.callCount, 1)
    }
}

private final class ClipboardPlainTextReadProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var calls = 0
    private var active = 0
    private var maximumActive = 0

    var hasEntered: Bool { condition.withLock { entered } }
    var callCount: Int { condition.withLock { calls } }
    var maximumConcurrentReads: Int { condition.withLock { maximumActive } }

    func read() -> ClipboardPasteboardReadResult {
        condition.lock()
        defer { condition.unlock() }
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        entered = true
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
        active -= 1
        return .payload(.plainText("read"))
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
