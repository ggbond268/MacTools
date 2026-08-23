import AppKit
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class RunLinkExecutionCoordinatorTests: XCTestCase {
    private let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
    private var originalPreference: String?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        PluginRuntimeLocalization.source.setPreference("en")
    }

    override func tearDown() {
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        originalPreference = nil
        super.tearDown()
    }

    func testSuccessfulInvocationUsesExecutorAndPresentsSanitizedFeedback() async throws {
        let setup = try makeSetup()
        setup.provider.operation = { .succeeded(message: "private provider detail") }

        _ = await setup.coordinator.execute(.direct(setup.reference.key))

        XCTAssertEqual(setup.provider.beginCount, 1)
        XCTAssertEqual(
            setup.feedback.values,
            [
                RunLinkExecutionFeedback(
                    tone: .success,
                    title: "Action Completed",
                    message: "Run Link executed successfully."
                ),
            ]
        )
        XCTAssertFalse(setup.feedback.values[0].message.contains("private"))
    }

    func testProgressReportingInvocationReturnsAfterDurableStart() async throws {
        let setup = try makeSetup(capabilities: [.background, .reportsProgress])
        var completion: CheckedContinuation<ActionExecutionResult, Never>?
        setup.provider.operation = {
            await withCheckedContinuation { completion = $0 }
        }

        let disposition = await setup.coordinator.execute(.direct(setup.reference.key))

        XCTAssertEqual(setup.provider.beginCount, 1)
        XCTAssertNotNil(disposition.completion)
        XCTAssertEqual(
            setup.feedback.values,
            [
                RunLinkExecutionFeedback(
                    tone: .progress,
                    title: "Action Started",
                    message: "The action will continue running in the background."
                ),
            ]
        )
        while completion == nil {
            await Task.yield()
        }
        completion?.resume(returning: .succeeded())
        await disposition.completion?.value
    }

    func testConfirmAlwaysUsesInjectedConfirmationAndHonorsDenial() async throws {
        let denied = try makeSetup(
            risk: .confirmationRequired,
            externalPolicy: .confirmAlways,
            confirmationResult: false
        )

        _ = await denied.coordinator.execute(.direct(denied.reference.key))

        XCTAssertEqual(denied.confirmation.requests.count, 1)
        XCTAssertEqual(denied.provider.beginCount, 0)
        XCTAssertEqual(denied.feedback.values.last?.title, "The action could not start.")
        XCTAssertEqual(denied.feedback.values.last?.message, "The action was cancelled.")
    }

    func testUnknownDisallowedAndProviderFailureNeverExposeProviderDetails() async throws {
        let setup = try makeSetup()
        setup.provider.operation = { .failed(message: "secret-token-123") }

        _ = await setup.coordinator.execute(.direct(setup.reference.key))
        _ = await setup.coordinator.execute(
            .direct(ActionKey(providerID: "missing-provider", actionID: "missing-action"))
        )

        XCTAssertEqual(setup.feedback.values.count, 2)
        XCTAssertFalse(setup.feedback.values.map(\.message).joined().contains("secret-token-123"))
        XCTAssertEqual(setup.feedback.values[0].message, "The action could not be completed.")
        XCTAssertEqual(setup.feedback.values[1].title, "Run Link Unavailable")
    }

    func testDeferredRoutingRejectionsUseSanitizedNonmodalFeedback() throws {
        let setup = try makeSetup()

        setup.coordinator.presentRoutingRejection(.actionAlreadyRunning)
        setup.coordinator.presentRoutingRejection(.recursiveActionInvocation)

        XCTAssertEqual(
            setup.feedback.values,
            [
                RunLinkExecutionFeedback(
                    tone: .failure,
                    title: "Run Link Unavailable",
                    message: "This action is already queued or running."
                ),
                RunLinkExecutionFeedback(
                    tone: .failure,
                    title: "Run Link Unavailable",
                    message: "A recursive Run Link was blocked."
                ),
            ]
        )
    }

    func testClipboardUsesIsolatedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.declareTypes([.string], owner: nil)

        ActionRunLinkClipboard.copy("mactools://app/actions/test/run", pasteboard: pasteboard)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "mactools://app/actions/test/run"
        )
    }

    func testSystemFeedbackUsesOneVisibleAccessibleHUDWithoutNotificationPermission() {
        let presenter = SystemRunLinkFeedbackPresenter(dismissDelay: .seconds(30))
        defer { presenter.dismiss() }

        presenter.present(
            RunLinkExecutionFeedback(tone: .success, title: "Done", message: "Action succeeded.")
        )
        presenter.present(
            RunLinkExecutionFeedback(tone: .failure, title: "Failed", message: "Action unavailable.")
        )

        let panels = NSApp.windows.filter {
            $0.identifier == SystemRunLinkFeedbackPresenter.panelIdentifier && $0.isVisible
        }
        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual(panels.first?.accessibilityLabel(), "Failed and Action unavailable.")
    }

    func testWindowLayoutHeadlessFeedbackIsCompactAndOptInOnSuccess() {
        XCTAssertNil(WindowLayoutActionFeedback.feedback(
            actionTitle: "Left Half",
            outcome: .completed(.succeeded())
        ))

        let feedback = WindowLayoutActionFeedback.feedback(
            actionTitle: "Left Half",
            outcome: .completed(.succeeded(message: "Left Half"))
        )
        XCTAssertEqual(
            feedback,
            RunLinkExecutionFeedback(
                tone: .success,
                title: "Left Half",
                message: "Left Half",
                presentation: .compact,
                dismissDelay: .milliseconds(1_100)
            )
        )
        XCTAssertEqual(feedback?.accessibilityLabel, "Left Half")
    }

    func testWindowLayoutHeadlessFailureAlwaysProducesStandardFeedback() {
        XCTAssertEqual(
            WindowLayoutActionFeedback.feedback(
                actionTitle: "Next Desktop",
                outcome: .completed(.failed(message: "No adjacent Desktop."))
            ),
            RunLinkExecutionFeedback(
                tone: .failure,
                title: "Next Desktop",
                message: "No adjacent Desktop."
            )
        )
    }

    func testCancellingSystemConfirmationDismissesPresentationAndResumesOnce() async {
        var response: ((Bool) -> Void)?
        var dismissCount = 0
        let session = AppActionConfirmationSheetSession(
            start: { response = $0 },
            dismiss: { dismissCount += 1 }
        )
        let task = Task { @MainActor in await session.response() }

        while response == nil {
            await Task.yield()
        }
        task.cancel()

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(dismissCount, 1)
        response?(true)
        XCTAssertEqual(dismissCount, 1)
    }

    private struct Setup {
        let provider: ActionExecutorTestProvider
        let reference: ActionReference
        let confirmation: RecordingRunLinkConfirmationService
        let feedback: RecordingRunLinkFeedbackPresenter
        let coordinator: RunLinkExecutionCoordinator
    }

    private func makeSetup(
        risk: ActionRisk = .safe,
        externalPolicy: ActionExternalInvocationPolicy = .allowed,
        capabilities: ActionExecutionCapabilities = [.foregroundInteractive],
        confirmationResult: Bool = true
    ) throws -> Setup {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: risk,
            confirmation: risk == .confirmationRequired
                ? ActionConfirmation(
                    title: "确认",
                    message: "继续？",
                    confirmButtonTitle: "继续"
                )
                : nil,
            externalPolicy: externalPolicy,
            capabilities: capabilities
        )
        let reference = ActionReference(key: definition.key)
        registry.synchronize([provider.registration(definition: definition)])
        let suite = "RunLinkExecutionCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = ActionRunLinkService(
            registry: registry,
            presetStore: ActionInvocationPresetStore(userDefaults: defaults),
            scheme: "mactools"
        )
        let confirmation = RecordingRunLinkConfirmationService(result: confirmationResult)
        let feedback = RecordingRunLinkFeedbackPresenter()
        let coordinator = RunLinkExecutionCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runLinkService: service,
            confirmationService: confirmation,
            feedbackPresenter: feedback
        )
        return Setup(
            provider: provider,
            reference: reference,
            confirmation: confirmation,
            feedback: feedback,
            coordinator: coordinator
        )
    }
}

@MainActor
private final class RecordingRunLinkConfirmationService: ActionConfirmationRequesting {
    let result: Bool
    private(set) var requests: [ActionConfirmationRequest] = []

    init(result: Bool) {
        self.result = result
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        requests.append(request)
        return result
    }
}

@MainActor
private final class RecordingRunLinkFeedbackPresenter: RunLinkFeedbackPresenting {
    private(set) var values: [RunLinkExecutionFeedback] = []

    func present(_ feedback: RunLinkExecutionFeedback) {
        values.append(feedback)
    }
}
