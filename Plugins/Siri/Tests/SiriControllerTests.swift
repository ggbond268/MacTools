import MacToolsPluginKit
import XCTest
@testable import SiriPlugin

@MainActor
final class SiriControllerTests: XCTestCase {
    func testDifferentPromptsCannotOverlapAndSuccessRequiresVerification() async throws {
        let client = FakeSiriClient()
        let controller = SiriController(client: client)
        let first = try XCTUnwrap(controller.start("first"))
        XCTAssertNil(controller.start("second"))
        let result = await first.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.phase, .sent)
        XCTAssertFalse(controller.isBusy)
        let calls = await client.calls
        XCTAssertEqual(calls, ["prepare", "enter", "submit", "verify", "finish"])
    }

    func testExistingDraftStopsBeforeWritingAndReleasesLease() async throws {
        let client = FakeSiriClient(failure: .existingDraft, failingStep: "prepare")
        let controller = SiriController(client: client)
        _ = await controller.start("hello")?.result()
        XCTAssertEqual(controller.failure, .existingDraft)
        XCTAssertFalse(controller.isBusy)
        let calls = await client.calls
        XCTAssertEqual(calls, ["prepare", "finish"])
    }

    func testAmbiguousDeliveryNeverRetriesSubmit() async throws {
        let client = FakeSiriClient(failure: .timedOut, failingStep: "verify")
        let controller = SiriController(client: client)
        _ = await controller.start("hello")?.result()
        XCTAssertEqual(controller.phase, .uncertain)
        let calls = await client.calls
        XCTAssertEqual(calls.filter { $0 == "submit" }.count, 1)
        XCTAssertFalse(controller.isBusy)
    }

    func testCancelBeforeOperationNeverEntersMessage() async throws {
        let client = FakeSiriClient()
        let controller = SiriController(client: client)
        let handle = try XCTUnwrap(controller.start("hello"))
        handle.cancel()
        for _ in 0..<100 where controller.isBusy { await Task.yield() }
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.phase, .cancelled)
        let calls = await client.calls
        XCTAssertFalse(calls.contains("submit"))
    }


}

private actor FakeSiriClient: SiriClient {
    let failure: SiriFailure?
    let failingStep: String?
    var calls: [String] = []
    init(failure: SiriFailure? = nil, failingStep: String? = nil) {
        self.failure = failure; self.failingStep = failingStep
    }
    func step(_ name: String) throws {
        calls.append(name)
        if name == failingStep, let failure { throw failure }
    }
    func prepareNewConversation() async throws { try step("prepare") }
    func enter(_ message: String) async throws { try step("enter") }
    func submit(_ message: String) async throws { try step("submit") }
    func verify(_ message: String) async throws { try step("verify") }
    func finish() async { calls.append("finish") }
}
