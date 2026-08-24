import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionExecutorTests: XCTestCase {
    func testExecutorAppliesAvailabilityModeAndExternalPoliciesBeforeBegin() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let foregroundOnly = makeActionDefinition(
            externalPolicy: .unavailable,
            capabilities: [.foregroundInteractive]
        )
        registry.synchronize([provider.registration(definition: foregroundOnly)])
        let executor = ActionExecutor(registry: registry)
        let reference = ActionReference(key: foregroundOnly.key)

        let backgroundOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .workflow, mode: .background)
        )
        XCTAssertEqual(backgroundOutcome, .rejected(.backgroundExecutionUnsupported))

        let runLinkOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .runLink, mode: .foreground)
        )
        XCTAssertEqual(runLinkOutcome, .rejected(.externalInvocationUnavailable))

        provider.availability = .unavailable("未连接显示器")
        let unavailableOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground)
        )
        XCTAssertEqual(unavailableOutcome, .rejected(.unavailable("未连接显示器")))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testRunLinkRejectsSuppliedSensitiveParameterBeforeProviderBegins() async throws {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(parameters: [
            ActionParameterDefinition(
                id: "token",
                title: "Token",
                kind: .string,
                privacy: .sensitive
            ),
        ])
        registry.synchronize([provider.registration(definition: definition)])
        let reference = ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["token": .string("secret")])
        )

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(reference: reference, source: .runLink, mode: .foreground)
        )

        XCTAssertEqual(outcome, .rejected(.externalInvocationUnavailable))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testExecutorConfirmsThenRevalidatesProviderGeneration() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])

        let confirmation = ActionExecutorConfirmationService {
            let changed = ActionDefinition(
                key: definition.key,
                title: "已变化",
                description: definition.description,
                systemImage: definition.systemImage,
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive]
            )
            registry.synchronize([provider.registration(definition: changed)])
            return true
        }
        let executor = ActionExecutor(registry: registry, confirmationService: confirmation)

        let outcome = await executor.execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            )
        )
        XCTAssertEqual(outcome, .rejected(.providerChanged))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testExecutorConfirmsThenRejectsChangedProviderExecutionRevision() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Confirm",
                message: "Run this payload?",
                confirmButtonTitle: "Run"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])
        let confirmation = ActionExecutorConfirmationService {
            provider.executionRevision &+= 1
            return true
        }

        let outcome = await ActionExecutor(
            registry: registry,
            confirmationService: confirmation
        ).execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .actionGrid,
            mode: .foreground
        ))

        XCTAssertEqual(outcome, .rejected(.providerChanged))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAppIntentExecutionEnforcesProviderExposurePolicy() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        provider.exposurePolicy = .excluded
        let definition = makeActionDefinition()
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .appIntent,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .rejected(.systemExposureUnavailable))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAppIntentExecutionRechecksExposurePolicyAfterConfirmation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Confirm",
                message: "Continue?",
                confirmButtonTitle: "Continue"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])
        let confirmation = ActionExecutorConfirmationService {
            provider.exposurePolicy = .excluded
            return true
        }

        let outcome = await ActionExecutor(
            registry: registry,
            confirmationService: confirmation
        ).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .appIntent,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .rejected(.systemExposureUnavailable))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAutomaticRuleRejectsInteractiveConfirmationWithoutRequestingIt() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Confirm",
                message: "Continue?",
                confirmButtonTitle: "Continue"
            ),
            capabilities: [.background]
        )
        registry.synchronize([provider.registration(definition: definition)])
        var confirmationCount = 0
        let confirmation = ActionExecutorConfirmationService {
            confirmationCount += 1
            return true
        }

        let outcome = await ActionExecutor(
            registry: registry,
            confirmationService: confirmation
        ).execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .automaticRule,
            mode: .background
        ))

        XCTAssertEqual(outcome, .rejected(.confirmationRequiredForAutomaticExecution))
        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAutomaticRuleRequiresExplicitProviderOptIn() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive]
        )
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .automaticRule,
                mode: .background
            )
        )

        XCTAssertEqual(outcome, .rejected(.automaticExecutionUnsupported))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testDefaultConcurrencyPolicyRejectsOverlappingInvocation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(timeout: 86_400)
        var continuation: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = {
            await withCheckedContinuation { continuation = $0 }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        while continuation == nil { await Task.yield() }

        let overlapping = await executor.execute(invocation)

        XCTAssertEqual(overlapping, .rejected(.actionAlreadyRunning))
        XCTAssertEqual(provider.beginCount, 1)
        continuation?.resume(returning: .succeeded())
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded()))
    }

    func testSerializedConcurrencyWaitsForPriorInvocation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            concurrencyPolicy: .serialize,
            timeout: 86_400
        )
        var continuations: [CheckedContinuation<ActionExecutionResult, Never>] = []
        provider.operation = {
            await withCheckedContinuation { continuations.append($0) }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        while continuations.isEmpty { await Task.yield() }
        let second = Task { @MainActor in await executor.execute(invocation) }
        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertEqual(provider.beginCount, 1)

        continuations.removeFirst().resume(returning: .succeeded(message: "first"))
        while continuations.isEmpty { await Task.yield() }
        continuations.removeFirst().resume(returning: .succeeded(message: "second"))

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded(message: "first")))
        XCTAssertEqual(secondOutcome, .completed(.succeeded(message: "second")))
    }

    func testSerializedAppIntentRechecksExposureAfterWaiting() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            concurrencyPolicy: .serialize,
            timeout: 86_400
        )
        var continuation: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = {
            await withCheckedContinuation { continuation = $0 }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .appIntent,
            mode: .foreground
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        while continuation == nil { await Task.yield() }
        let second = Task { @MainActor in await executor.execute(invocation) }
        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertEqual(provider.beginCount, 1)

        provider.exposurePolicy = .excluded
        continuation?.resume(returning: .succeeded())

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded()))
        XCTAssertEqual(secondOutcome, .rejected(.systemExposureUnavailable))
        XCTAssertEqual(provider.beginCount, 1)
    }

    func testAllowConcurrentPolicyStartsOverlappingInvocations() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            concurrencyPolicy: .allowConcurrent,
            timeout: 86_400
        )
        var continuations: [CheckedContinuation<ActionExecutionResult, Never>] = []
        provider.operation = {
            await withCheckedContinuation { continuations.append($0) }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        let second = Task { @MainActor in await executor.execute(invocation) }
        while continuations.count < 2 { await Task.yield() }

        XCTAssertEqual(provider.beginCount, 2)
        continuations.removeFirst().resume(returning: .succeeded())
        continuations.removeFirst().resume(returning: .succeeded())
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded()))
        XCTAssertEqual(secondOutcome, .completed(.succeeded()))
    }

    func testConfirmationAndExecutionUseIndependentTimeouts() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let confirmationDefinition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: confirmationDefinition)])
        let slowConfirmation = ActionExecutorConfirmationService {
            try? await Task.sleep(for: .seconds(5))
            return true
        }
        let confirmationExecutor = ActionExecutor(
            registry: registry,
            confirmationService: slowConfirmation,
            confirmationTimeout: .milliseconds(10)
        )

        let confirmationOutcome = await confirmationExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: confirmationDefinition.key),
                source: .manual,
                mode: .foreground
            )
        )
        XCTAssertEqual(confirmationOutcome, .rejected(.confirmationTimedOut))

        let shortAction = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive, .cancellable],
            timeout: 0.01
        )
        provider.operation = {
            try? await Task.sleep(for: .seconds(5))
            return .succeeded()
        }
        registry.synchronize([provider.registration(definition: shortAction)])
        let executionExecutor = ActionExecutor(registry: registry)
        let executionOutcome = await executionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: shortAction.key),
                source: .workflow,
                mode: .background
            )
        )
        XCTAssertEqual(executionOutcome, .rejected(.executionTimedOut))
        XCTAssertTrue(provider.didCancel)
    }

    func testSuccessfulExecutionReturnsProviderResult() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        provider.operation = { .succeeded(message: "完成") }
        let definition = makeActionDefinition()
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .actionGrid,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .completed(.succeeded(message: "完成")))
        XCTAssertEqual(provider.beginCount, 1)
    }

    func testDisplayChangingActionPreparesPresentationBeforeProviderBegin() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        var didPrepare = false
        provider.onBegin = {
            XCTAssertTrue(didPrepare)
        }
        let definition = makeActionDefinition(
            capabilities: [
                .background,
                .foregroundInteractive,
                .changesDisplayConfiguration,
            ]
        )
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(
            registry: registry,
            presentationPreparation: { didPrepare = true }
        )

        let outcome = await executor.execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        ))

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertTrue(didPrepare)
    }

    func testOrdinaryBackgroundActionDoesNotInterruptActiveEditing() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        var preparationCount = 0
        let definition = makeActionDefinition(capabilities: [.background])
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(
            registry: registry,
            presentationPreparation: { preparationCount += 1 }
        )

        _ = await executor.execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        ))

        XCTAssertEqual(preparationCount, 0)
    }

    func testPerInvocationConfirmationServiceCannotSkipExecutorRevalidation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .unifiedSearch,
            mode: .foreground
        )

        let rejected = await executor.execute(invocation)
        let approved = await executor.execute(
            invocation,
            confirmationService: ApprovedActionConfirmationService()
        )

        XCTAssertEqual(rejected, .rejected(.confirmationDenied))
        XCTAssertEqual(approved, .completed(.succeeded()))
        XCTAssertEqual(provider.beginCount, 1)
    }

    func testMatchingApprovalRejectsAChangedConfirmation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let reference = ActionReference(key: makeActionDefinition().key)
        let firstConfirmation = ActionConfirmation(
            title: "First",
            message: "Approve the first action",
            confirmButtonTitle: "First"
        )
        let changedDefinition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Changed",
                message: "Approve the changed action",
                confirmButtonTitle: "Changed"
            )
        )
        registry.synchronize([provider.registration(definition: changedDefinition)])
        let service = MatchingApprovedActionConfirmationService(
            expectedRequest: ActionConfirmationRequest(
                reference: reference,
                confirmation: firstConfirmation,
                source: .unifiedSearch
            )
        )

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: reference,
                source: .unifiedSearch,
                mode: .foreground
            ),
            confirmationService: service
        )

        XCTAssertEqual(outcome, .rejected(.confirmationDenied))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testCancellationReturnsPromptlyForNonCooperativeOperation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive, .cancellable],
            timeout: 86_400
        )
        provider.operation = {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    continuation.resume(returning: .succeeded())
                }
            }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let task = Task { @MainActor in
            await executor.execute(
                ActionInvocation(
                    reference: ActionReference(key: definition.key),
                    source: .workflow,
                    mode: .background
                )
            )
        }
        await Task.yield()

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .completed(.cancelled))
        XCTAssertTrue(provider.didCancel)
    }

    func testNonCancellableActionTimesOutWithoutInvokingProviderCancellation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive],
            timeout: 0.001
        )
        provider.operation = {
            try? await Task.sleep(for: .milliseconds(40))
            return .succeeded(message: "finished")
        }
        registry.synchronize([provider.registration(definition: definition)])
        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .workflow,
                mode: .background
            )
        )

        XCTAssertEqual(outcome, .rejected(.executionTimedOut))
        XCTAssertFalse(provider.didCancel)
    }

    func testContinuingExecutionReturnsAfterStartAndOutlivesCallerTask() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [
                .background,
                .foregroundInteractive,
                .cancellable,
                .reportsProgress,
            ],
            timeout: 86_400
        )
        var continuation: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = {
            await withCheckedContinuation { continuation = $0 }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .actionGrid,
            mode: .foreground
        )

        let caller = Task { @MainActor in
            await executor.startContinuing(
                invocation,
                expectedDefinition: definition
            )
        }
        let outcome = await caller.value
        caller.cancel()
        for _ in 0 ..< 100 where continuation == nil {
            await Task.yield()
        }

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(executor.continuingExecutionCountForTests, 1)
        XCTAssertFalse(provider.didCancel)

        continuation?.resume(returning: .succeeded())
        for _ in 0 ..< 100 where executor.continuingExecutionCountForTests != 0 {
            await Task.yield()
        }

        XCTAssertEqual(executor.continuingExecutionCountForTests, 0)
        XCTAssertFalse(provider.didCancel)
    }

    func testSurfaceIndependentExecutionOutlivesCompletionObserverCancellation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive, .cancellable],
            timeout: 86_400
        )
        var continuation: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = {
            await withCheckedContinuation { continuation = $0 }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        var observedCompletion: ActionExecutionOutcome?

        let start = await executor.startSurfaceIndependentTrackingCompletion(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            ),
            expectedDefinition: definition,
            completionObserver: { observedCompletion = $0 }
        )
        let observer = Task { @MainActor () -> ActionExecutionOutcome? in
            guard let completion = start.completion else { return nil }
            for await outcome in completion {
                return outcome
            }
            return nil
        }
        observer.cancel()
        _ = await observer.value

        XCTAssertEqual(start.outcome, .started)
        XCTAssertEqual(executor.surfaceIndependentExecutionCountForTests, 1)
        XCTAssertFalse(provider.didCancel)

        for _ in 0 ..< 100 where continuation == nil {
            await Task.yield()
        }
        continuation?.resume(returning: .succeeded())
        for _ in 0 ..< 100 where executor.surfaceIndependentExecutionCountForTests != 0 {
            await Task.yield()
        }

        XCTAssertEqual(executor.surfaceIndependentExecutionCountForTests, 0)
        XCTAssertFalse(provider.didCancel)
        XCTAssertEqual(observedCompletion, .completed(.succeeded()))
    }

    func testSurfaceIndependentPreparationCancelsBeforeProviderStart() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Confirm",
                message: "Continue?",
                confirmButtonTitle: "Continue"
            ),
            capabilities: [.foregroundInteractive]
        )
        registry.synchronize([provider.registration(definition: definition)])
        var confirmationStarted = false
        let confirmation = ActionExecutorConfirmationService {
            confirmationStarted = true
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            return true
        }
        let executor = ActionExecutor(registry: registry, confirmationService: confirmation)
        let caller = Task { @MainActor in
            await executor.startSurfaceIndependentTrackingCompletion(
                ActionInvocation(
                    reference: ActionReference(key: definition.key),
                    source: .unifiedSearch,
                    mode: .foreground
                ),
                expectedDefinition: definition
            )
        }
        for _ in 0 ..< 100 where !confirmationStarted {
            await Task.yield()
        }

        caller.cancel()
        let start = await caller.value

        XCTAssertTrue(confirmationStarted)
        XCTAssertEqual(start.outcome, .cancelled)
        XCTAssertNil(start.completion)
        XCTAssertEqual(provider.beginCount, 0)
        XCTAssertEqual(executor.surfaceIndependentExecutionCountForTests, 0)
    }

    func testContinuingExecutionCompletesConfirmationBeforeStarting() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Confirm",
                message: "Run the workflow?",
                confirmButtonTitle: "Run"
            ),
            capabilities: [.foregroundInteractive, .cancellable, .reportsProgress]
        )
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).startContinuing(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .actionGrid,
                mode: .foreground
            ),
            expectedDefinition: definition
        )

        XCTAssertEqual(outcome, .rejected(.confirmationDenied))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testContinuingExecutionRejectsAChangedExpectedDefinitionBeforeBegin() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.foregroundInteractive, .cancellable, .reportsProgress]
        )
        registry.synchronize([provider.registration(definition: definition)])
        let changedDefinition = ActionDefinition(
            key: definition.key,
            title: "Changed",
            description: definition.description,
            systemImage: definition.systemImage,
            capabilities: definition.capabilities
        )

        let outcome = await ActionExecutor(registry: registry).startContinuing(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            ),
            expectedDefinition: changedDefinition
        )

        XCTAssertEqual(outcome, .rejected(.providerChanged))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testExecutionHandleLatchesCancellationBeforeStartingAndOnlyCancelsOnce() async {
        var startCount = 0
        var cancelCount = 0
        let handle = ActionExecutionHandle(
            operation: {
                startCount += 1
                return .succeeded()
            },
            cancel: { cancelCount += 1 }
        )

        handle.cancel()
        handle.cancel()
        let result = await handle.result()

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    func testExecutionHandleKeepsCancellationLatchedWhenOperationIgnoresTaskCancellation() async {
        let handle = ActionExecutionHandle {
            try? await Task.sleep(for: .milliseconds(20))
            return .succeeded(message: "late success")
        }
        let resultTask = Task { @MainActor in await handle.result() }
        await Task.yield()

        handle.cancel()

        let result = await resultTask.value
        XCTAssertEqual(result, .cancelled)
    }
}

@MainActor
final class ActionExecutorConfirmationService: ActionConfirmationRequesting {
    let operation: @MainActor @Sendable () async -> Bool

    init(operation: @escaping @MainActor @Sendable () async -> Bool) {
        self.operation = operation
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        await operation()
    }
}

@MainActor
final class ActionExecutorTestProvider {
    var availability: ActionAvailability = .available
    var exposurePolicy: ActionExposurePolicy = .automatic
    var operation: @MainActor @Sendable () async -> ActionExecutionResult = { .succeeded() }
    var beginCount = 0
    var executionRevision: UInt64 = 0
    var didCancel = false
    var onBegin: (() -> Void)?

    func registration(definition: ActionDefinition) -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: definition.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [
                ActionCatalogEntry(
                    reference: ActionReference(key: definition.key),
                    title: definition.title
                ),
            ],
            executionRevision: { [weak self] in self?.executionRevision ?? .max },
            availability: { [weak self] _ in
                self?.availability ?? .unavailable("missing")
            },
            exposurePolicy: { [weak self] _, _ in
                self?.exposurePolicy ?? .excluded
            },
            begin: { [weak self] _ in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                self.onBegin?()
                self.beginCount += 1
                let operation = self.operation
                return .success(
                    ActionExecutionHandle(
                        operation: operation,
                        cancel: { [weak self] in self?.didCancel = true }
                    )
                )
            }
        )
    }
}
