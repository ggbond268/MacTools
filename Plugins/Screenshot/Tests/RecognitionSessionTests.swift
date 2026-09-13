import XCTest
import CoreGraphics
@testable import ScreenshotPlugin

final class RecognitionSessionTests: XCTestCase {

    @MainActor
    func testOnlyLatestRequestCanPublishEvenWhenResultsArriveOutOfOrder() async throws {
        let stub = RecognitionStub()
        let session = RecognitionSession(recognize: { try await stub.recognize($0, $1) })
        let image = try makeImage()
        var published: [String] = []
        let first = session.start(image, kind: .text) { result in
            published += (try? result.get().lines) ?? []
        }
        await stub.waitForRequests(1)
        let second = session.start(image, kind: .barcode) { result in
            published += (try? result.get().lines) ?? []
        }
        await stub.waitForRequests(2)
        await stub.complete(1, with: .success(RecognitionResult(lines: ["new"])))
        await second.value
        await stub.complete(0, with: .success(RecognitionResult(lines: ["old"])))
        await first.value
        XCTAssertTrue(published == ["new"])
        let kinds = await stub.kinds
        XCTAssertTrue(kinds == [.text, .barcode])
    }

    @MainActor
    func testCancelDropsLateSuccessAndFailure() async throws {
        let results: [Result<RecognitionResult, Error>] = [
            .success(RecognitionResult(lines: ["old"])), .failure(RecognitionFailure.failed),
        ]
        for result in results {
            let stub = RecognitionStub()
            let session = RecognitionSession(recognize: { try await stub.recognize($0, $1) })
            var callbacks = 0
            let task = session.start(try makeImage(), kind: .text) { _ in callbacks += 1 }
            await stub.waitForRequests(1)
            session.cancel()
            session.cancel()
            await stub.complete(0, with: result)
            await task.value
            XCTAssertTrue(callbacks == 0)
        }
    }

    @MainActor
    func testCurrentFailureIsReportedAndNextRequestCanSucceed() async throws {
        let stub = RecognitionStub()
        let session = RecognitionSession(recognize: { try await stub.recognize($0, $1) })
        var failed = false
        let first = session.start(try makeImage(), kind: .text) { result in
            if case .failure = result { failed = true }
        }
        await stub.waitForRequests(1)
        await stub.complete(0, with: .failure(RecognitionFailure.failed))
        await first.value
        XCTAssertTrue(failed)

        var lines: [String] = []
        let second = session.start(try makeImage(), kind: .text) { result in
            lines = (try? result.get().lines) ?? []
        }
        await stub.waitForRequests(2)
        await stub.complete(1, with: .success(RecognitionResult(lines: ["recovered"])))
        await second.value
        XCTAssertTrue(lines == ["recovered"])
    }

    @MainActor
    func testReleasingSessionDoesNotPublishPendingResult() async throws {
        let stub = RecognitionStub()
        var session: RecognitionSession? = RecognitionSession(recognize: { try await stub.recognize($0, $1) })
        var callbacks = 0
        let image = try makeImage()
        let task = try XCTUnwrap(session).start(image, kind: .text) { _ in callbacks += 1 }
        await stub.waitForRequests(1)
        session = nil
        await stub.complete(0, with: .success(RecognitionResult(lines: ["late"])))
        await task.value
        XCTAssertTrue(callbacks == 0)
    }

    private func makeImage() throws -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return try XCTUnwrap(context?.makeImage())
    }
}

private enum RecognitionFailure: Error { case failed }

private actor RecognitionStub {
    private var requests: [CheckedContinuation<RecognitionResult, Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var kinds: [RecognitionKind] = []

    func recognize(_ image: CGImage, _ kind: RecognitionKind) async throws -> RecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            kinds.append(kind)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with result: Result<RecognitionResult, Error>) {
        requests[index].resume(with: result)
    }
}
