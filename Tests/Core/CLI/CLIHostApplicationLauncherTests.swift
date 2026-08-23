import XCTest
@testable import MacTools

final class CLIHostApplicationLauncherTests: XCTestCase {
    private let applicationURL = URL(fileURLWithPath: "/Applications/MacTools.app")

    func testAwaitsSuccessfulLaunchCompletion() async throws {
        let callback = expectation(description: "Launch callback completed")
        let launcher = CLIHostApplicationLauncher { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                completion(.success(()))
                callback.fulfill()
            }
        }

        try await launcher.launch(applicationURL: applicationURL, timeout: 1)

        await fulfillment(of: [callback], timeout: 1)
    }

    func testNonReturningLaunchCallbackIsBoundedByTimeout() async {
        let launcher = CLIHostApplicationLauncher { _, _ in }
        let startedAt = Date()

        do {
            try await launcher.launch(applicationURL: applicationURL, timeout: 0.05)
            XCTFail("Expected launch timeout")
        } catch {
            XCTAssertEqual(error as? CLIHostApplicationLaunchError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testLaunchFailureIsPropagated() async {
        let launcher = CLIHostApplicationLauncher { _, completion in
            completion(.failure(CLIHostApplicationLaunchError.failed("denied")))
        }

        do {
            try await launcher.launch(applicationURL: applicationURL, timeout: 1)
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(
                error as? CLIHostApplicationLaunchError,
                .failed("denied")
            )
        }
    }
}
