import XCTest
@testable import MacTools

@MainActor
final class AppInstanceCoordinatorTests: XCTestCase {

    func testCommandRejectsUnknownVersionAndCommand() {
        XCTAssertFalse(
            AppInstanceCommand(
                version: AppInstanceCommand.currentVersion + 1,
                command: AppInstanceCommand.showSettings,
                requestID: UUID()
            ).isSupported
        )
        XCTAssertFalse(
            AppInstanceCommand(
                version: AppInstanceCommand.currentVersion,
                command: "open-url",
                requestID: UUID()
            ).isSupported
        )
    }

    func testCallbackRejectsPayloadAboveSafetyLimit() {
        let callbackBox = CallbackBox()
        let oversizedData = Data(count: AppInstanceCommand.maximumPayloadSize + 1)

        XCTAssertEqual(callbackBox.response(for: oversizedData), .invalid)
    }

    func testRepeatedAcceptedCommandDoesNotRunHandlerTwice() throws {
        let callbackBox = CallbackBox()
        let receivedRequestCount = LockedCounter()
        callbackBox.setHandler { _ in
            receivedRequestCount.increment()
            return .accepted
        }
        let data = try JSONEncoder().encode(AppInstanceCommand.showSettingsRequest())

        XCTAssertEqual(callbackBox.response(for: data), .accepted)
        XCTAssertEqual(callbackBox.response(for: data), .accepted)
        XCTAssertEqual(receivedRequestCount.value, 1)
    }

    func testForwardingStopsWhenItsOwningTaskIsCancelled() async {
        let transport = FakeAppInstanceTransport(
            claimsPrimary: false,
            sendResult: .timedOut
        )
        let coordinator = AppInstanceCoordinator(
            bundleIdentifier: "com.example.mactools.cancelled-forwarding",
            transport: transport
        )
        let startedAt = Date()
        let forwardingTask = Task {
            await coordinator.resolveSecondaryLaunch(requestSettings: false)
        }

        try? await Task.sleep(for: .milliseconds(50))
        forwardingTask.cancel()

        let disposition = await forwardingTask.value
        XCTAssertEqual(disposition, .secondary(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertLessThan(transport.sendCount, 4)
    }

    func testSecondaryForwardsSettingsRequestToThePrimary() async {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let receivedRequestCount = LockedCounter()
        await primary.setCommandHandler { _ in
            receivedRequestCount.increment()
            return .accepted
        }
        defer { Task { await primary.invalidate() } }

        let primaryClaimed = await primary.claimPrimaryPortIfPossible()
        XCTAssertTrue(primaryClaimed)

        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let disposition = await secondary.resolveSecondaryLaunch(requestSettings: true)
        XCTAssertEqual(disposition, .secondary(.acknowledged))
        XCTAssertEqual(receivedRequestCount.value, 1)
    }

    func testSecondaryForwardsDeepLinksToThePrimary() async {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let receivedURLs = LockedValue<[String]>([])
        await primary.setCommandHandler { command in
            receivedURLs.set(command.urlStrings)
            return .accepted
        }
        defer { Task { await primary.invalidate() } }

        let primaryClaimed = await primary.claimPrimaryPortIfPossible()
        XCTAssertTrue(primaryClaimed)

        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let urls = [URL(string: "mactools://app/search")!]
        let forwardingResult = await secondary.forwardURLs(urls)
        XCTAssertEqual(forwardingResult, .acknowledged)
        XCTAssertEqual(receivedURLs.value, urls.map(\.absoluteString))
    }

    func testSecondaryRetriesUntilThePrimaryIsReady() async {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let receivedRequestCount = LockedCounter()
        await primary.setCommandHandler { _ in
            receivedRequestCount.increment()
            return receivedRequestCount.value == 1 ? .notReady : .accepted
        }
        defer { Task { await primary.invalidate() } }

        let primaryClaimed = await primary.claimPrimaryPortIfPossible()
        XCTAssertTrue(primaryClaimed)

        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let disposition = await secondary.resolveSecondaryLaunch(requestSettings: false)
        XCTAssertEqual(disposition, .secondary(.acknowledged))
        XCTAssertEqual(receivedRequestCount.value, 2)
    }

    func testAReplacementBecomesPrimaryAfterPortInvalidation() async {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)

        let primaryClaimed = await primary.claimPrimaryPortIfPossible()
        XCTAssertTrue(primaryClaimed)
        await primary.invalidate()

        let replacement = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        defer { Task { await replacement.invalidate() } }
        let replacementClaimed = await replacement.claimPrimaryPortIfPossible()
        XCTAssertTrue(replacementClaimed)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ storage: Value) {
        self.storage = storage
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}

private final class FakeAppInstanceTransport: AppInstanceTransport {
    private let claimsPrimary: Bool
    private let sendResult: AppInstanceTransportResult
    private(set) var wasInvalidated = false
    private(set) var sendCount = 0

    init(
        claimsPrimary: Bool,
        sendResult: AppInstanceTransportResult = .rejected
    ) {
        self.claimsPrimary = claimsPrimary
        self.sendResult = sendResult
    }

    func registerLocalPort(name _: String, callbackBox _: CallbackBox) -> Bool {
        claimsPrimary
    }

    func send(
        name _: String,
        messageID _: Int32,
        data _: Data,
        sendTimeout _: CFTimeInterval,
        receiveTimeout _: CFTimeInterval
    ) -> AppInstanceTransportResult {
        sendCount += 1
        return sendResult
    }

    func invalidate() {
        wasInvalidated = true
    }
}
