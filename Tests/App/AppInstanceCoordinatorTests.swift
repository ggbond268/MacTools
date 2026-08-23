import XCTest
@testable import MacTools

@MainActor
final class AppInstanceCoordinatorTests: XCTestCase {
    func testShowSettingsCommandUsesTheCurrentProtocolVersion() {
        let command = AppInstanceCommand.showSettingsRequest()

        XCTAssertEqual(command.version, AppInstanceCommand.currentVersion)
        XCTAssertEqual(command.command, AppInstanceCommand.showSettings)
        XCTAssertTrue(command.isSupported)
    }

    func testProbeCommandUsesTheCurrentProtocolVersionWithoutRequestingUI() {
        let command = AppInstanceCommand.probeRequest()

        XCTAssertEqual(command.version, AppInstanceCommand.currentVersion)
        XCTAssertEqual(command.command, AppInstanceCommand.probe)
        XCTAssertTrue(command.urlStrings.isEmpty)
        XCTAssertTrue(command.isSupported)
    }

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

    func testOpenURLsCommandAcceptsOnlyNonEmptyValidURLs() {
        let command = AppInstanceCommand.openURLsRequest([
            URL(string: "mactools://app/search")!,
        ])

        XCTAssertEqual(command.command, AppInstanceCommand.openURLs)
        XCTAssertTrue(command.isSupported)
        XCTAssertFalse(
            AppInstanceCommand(
                version: AppInstanceCommand.currentVersion,
                command: AppInstanceCommand.openURLs,
                urlStrings: [],
                requestID: UUID()
            ).isSupported
        )
    }

    func testVersionOneSettingsCommandWithoutURLsRemainsDecodable() throws {
        let legacyPayload = """
        {"version":1,"command":"show-settings","requestID":"00000000-0000-0000-0000-000000000001"}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(AppInstanceCommand.self, from: legacyPayload)

        XCTAssertTrue(command.isSupported)
        XCTAssertTrue(command.urlStrings.isEmpty)
    }

    func testOpenURLsCommandPreservesAURLLargerThanOneMegabyte() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://right-click/open-terminal?directory=/tmp/\(String(repeating: "x", count: 1_100_000))")
        )
        let command = AppInstanceCommand.openURLsRequest([url])
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(AppInstanceCommand.self, from: data)

        XCTAssertEqual(decoded.urlStrings, [url.absoluteString])
        XCTAssertTrue(decoded.isSupported)

        let callbackBox = CallbackBox()
        callbackBox.setHandler { _ in .accepted }
        XCTAssertEqual(callbackBox.response(for: data), .accepted)
    }

    func testExpiredSharedDeadlineDoesNotStartAnotherForwardingAttempt() async {
        let transport = FakeAppInstanceTransport(
            claimsPrimary: false,
            sendResult: .timedOut
        )
        let coordinator = AppInstanceCoordinator(
            bundleIdentifier: "com.example.mactools.expired-url-forwarding",
            transport: transport
        )

        let result = await coordinator.forwardURLs(
            [URL(string: "mactools://app/search")!],
            deadline: .distantPast
        )

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(transport.sendCount, 0)
    }

    func testSettingsRecoveryDeadlineReservesTimeForURLForwarding() {
        let forwardingDeadline = Date().addingTimeInterval(10)
        let settingsDeadline = AppInstanceCoordinator.makeSettingsRecoveryDeadline(
            forwardingDeadline: forwardingDeadline
        )

        XCTAssertEqual(
            forwardingDeadline.timeIntervalSince(settingsDeadline),
            0.5,
            accuracy: 0.001
        )
    }

    func testCallbackRejectsPayloadAboveSafetyLimit() {
        let callbackBox = CallbackBox()
        let oversizedData = Data(count: AppInstanceCommand.maximumPayloadSize + 1)

        XCTAssertEqual(callbackBox.response(for: oversizedData), .invalid)
    }

    func testSecondaryRejectsOversizedURLsBeforeTransportSend() async throws {
        let transport = FakeAppInstanceTransport(
            claimsPrimary: false,
            sendResult: .timedOut
        )
        let coordinator = AppInstanceCoordinator(
            bundleIdentifier: "com.example.mactools.oversized-url-forwarding",
            transport: transport
        )
        let oversizedURL = try XCTUnwrap(
            URL(string: "mactools://right-click/open-terminal?directory=/tmp/\(String(repeating: "x", count: AppInstanceCommand.maximumPayloadSize))")
        )

        let result = await coordinator.forwardURLs([oversizedURL])

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(transport.sendCount, 0)
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

    func testTransportIsInjectableForDeterministicOwnershipTests() async {
        let transport = FakeAppInstanceTransport(claimsPrimary: true)
        let coordinator = AppInstanceCoordinator(
            bundleIdentifier: "com.example.mactools.injected-transport",
            transport: transport
        )

        let claimedPrimary = await coordinator.claimPrimaryPortIfPossible()
        XCTAssertTrue(claimedPrimary)
        await coordinator.invalidate()
        XCTAssertTrue(transport.wasInvalidated)
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

    func testCallbackRejectsMalformedAndUnsupportedMessages() throws {
        let callbackBox = CallbackBox()
        XCTAssertEqual(callbackBox.response(for: Data("not-json".utf8)), .invalid)

        let unsupported = AppInstanceCommand(
            version: AppInstanceCommand.currentVersion + 1,
            command: AppInstanceCommand.showSettings,
            requestID: UUID()
        )
        XCTAssertEqual(
            callbackBox.response(for: try JSONEncoder().encode(unsupported)),
            .unsupported
        )
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

    func testPassiveSecondaryLaunchProbesPrimaryWithoutRequestingSettings() async {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let receivedCommand = LockedValue<String?>(nil)
        await primary.setCommandHandler { command in
            receivedCommand.set(command.command)
            return .accepted
        }
        defer { Task { await primary.invalidate() } }

        let primaryClaimed = await primary.claimPrimaryPortIfPossible()
        XCTAssertTrue(primaryClaimed)

        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let disposition = await secondary.resolveSecondaryLaunch(requestSettings: false)

        XCTAssertEqual(disposition, .secondary(.acknowledged))
        XCTAssertEqual(receivedCommand.value, AppInstanceCommand.probe)
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

    func testSecondaryForwardsLargeURLBatchAsOneIdempotentCommand() async {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let receivedCommands = LockedValue<[AppInstanceCommand]>([])
        await primary.setCommandHandler { command in
            receivedCommands.set([command])
            return .accepted
        }
        defer { Task { await primary.invalidate() } }

        let primaryClaimed = await primary.claimPrimaryPortIfPossible()
        XCTAssertTrue(primaryClaimed)

        let urls = (0..<8).map { index in
            URL(string: "mactools://app/search?value=\(String(repeating: "x", count: 200_000))\(index)")!
        }
        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        let forwardingResult = await secondary.forwardURLs(urls)

        XCTAssertEqual(forwardingResult, .acknowledged)
        XCTAssertEqual(receivedCommands.value.count, 1)
        XCTAssertEqual(receivedCommands.value[0].urlStrings, urls.map(\.absoluteString))
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
