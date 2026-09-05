import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class WorkflowRunnerTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "WorkflowRunnerTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRunnerExecutesSeriallyHonorsDelayAndContinuesAfterConfiguredFailure() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.provider.results["first"] = .failed(message: "provider-private-detail")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(
                    reference: harness.reference("first"),
                    delaySeconds: 0.5,
                    errorPolicy: .continueRunning
                ),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let result = await execution.actionHandle.result()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(result, .failed(message: FeatureL10n.string("部分步骤失败。")))
        XCTAssertEqual(harness.provider.invocations.map(\.reference.key.actionID), ["first", "second"])
        XCTAssertEqual(harness.sleeper.requestedSeconds, [0.5])
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.stepResults.map(\.status), [.failed, .succeeded])
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
                .contains("provider-private-detail")
        )
    }

    func testEachDelayRunsImmediatelyBeforeItsStep() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        var events: [String] = []
        harness.sleeper.onSleep = { events.append("wait \($0)") }
        harness.provider.onBegin["first"] = { events.append("run first") }
        harness.provider.onBegin["second"] = { events.append("run second") }
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first"), delaySeconds: 1),
                WorkflowStep(reference: harness.reference("second"), delaySeconds: 2),
            ]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        _ = await execution.actionHandle.result()

        XCTAssertEqual(events, ["wait 1.0", "run first", "wait 2.0", "run second"])
    }

    func testPublishedWorkflowPreservesAppIntentSourceForLeafActions() async throws {
        let harness = try makeHarness(actionIDs: ["first"])
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("first"))]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .publishedAction(.appIntent),
            mode: .foreground
        ).get()
        _ = await execution.actionHandle.result()

        XCTAssertEqual(harness.provider.invocations.map(\.source), [.appIntent])
    }

    func testAutomaticRunPreservesUnattendedSourceForLeafActions() async throws {
        let harness = try makeHarness(actionIDs: ["first"])
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("first"))]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ).get()
        _ = await execution.actionHandle.result()

        XCTAssertEqual(harness.provider.invocations.map(\.source), [.automaticRule])
    }

    func testSameWorkflowCannotStartTwiceUntilTrackedRunFinishes() async throws {
        let harness = try makeHarness(actionIDs: ["slow"])
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("slow"))]
        )
        let first = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        guard case let .failure(error) = harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ) else {
            return XCTFail("Expected duplicate workflow run to be rejected")
        }
        XCTAssertEqual(error, .alreadyRunning)

        first.actionHandle.cancel()
        let result = await first.actionHandle.result()
        XCTAssertEqual(result, .cancelled)
    }

    func testAutomaticRunPreservesUnattendedSourceThroughNestedWorkflows() async throws {
        let harness = try makeHarness(actionIDs: ["first"])
        let child = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("first"))]
        )
        let parent = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: child.actionReference)]
        )
        let controller = AutomationController(
            store: harness.store,
            registry: harness.registry,
            executor: harness.executor,
            runner: harness.runner
        )
        harness.registry.synchronize([
            harness.provider.registration(),
            controller.actionRegistration(),
        ])

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ).get()
        _ = await execution.actionHandle.result()

        XCTAssertEqual(harness.provider.invocations.map(\.source), [.automaticRule])
    }

    func testExecutedSensitiveParametersAreRedactedFromPersistedHistory() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "sensitive-history", actionID: "authenticate")
        let secret = "history-execution-secret-\(UUID().uuidString)"
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["token": .string(secret)])
        )
        let definition = ActionDefinition(
            key: key,
            title: "Authenticate",
            description: "",
            systemImage: "key",
            parameters: [
                ActionParameterDefinition(
                    id: "token",
                    title: "Token",
                    kind: .string,
                    privacy: .sensitive
                ),
            ],
            capabilities: [.background]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [
                    ActionCatalogEntry(reference: reference, title: "Authenticate \(secret)"),
                ],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let executor = ActionExecutor(registry: registry)
        let runner = WorkflowRunner(store: store, registry: registry, executor: executor)
        let workflow = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: reference)]
        )

        let execution = try runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        _ = await execution.actionHandle.result()
        let run = try XCTUnwrap(store.history(workflowID: workflow.id).first)

        XCTAssertEqual(
            run.stepResults.first?.actionReference,
            ActionReference(key: key, schemaVersion: reference.schemaVersion)
        )
        XCTAssertFalse(
            String(
                decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")),
                as: UTF8.self
            ).contains(secret)
        )
    }

    func testStopOnErrorSkipsRemainingSteps() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.provider.results["first"] = .failed(message: "failure")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first"), errorPolicy: .stop),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        _ = await execution.actionHandle.result()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(harness.provider.invocations.map(\.reference.key.actionID), ["first"])
        XCTAssertEqual(run.stepResults.map(\.status), [.failed, .skipped])
    }

    func testCancellationDuringDelayMarksCurrentAndRemainingSteps() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.sleeper.shouldBlock = true
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first"), delaySeconds: 10),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let resultTask = Task { @MainActor in await execution.actionHandle.result() }
        await harness.sleeper.waitUntilSleeping()

        execution.actionHandle.cancel()
        let result = await resultTask.value
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.cancelled, .skipped])
        XCTAssertTrue(harness.provider.invocations.isEmpty)
    }

    func testCancellationBeforeResultReleasesAllRunnerBookkeeping() throws {
        let harness = try makeHarness(actionIDs: ["first"])
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("first"))]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        execution.actionHandle.cancel()

        XCTAssertTrue(harness.runner.bookkeepingRunIDs.isEmpty)
        XCTAssertTrue(harness.provider.invocations.isEmpty)
    }

    func testCancellationDuringFinalNonCancellableActionCancelsPersistedRun() async throws {
        let harness = try makeHarness(
            actionIDs: ["slow"],
            nonCancellableActionIDs: ["slow"]
        )
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("slow"))]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let resultTask = Task { @MainActor in await execution.actionHandle.result() }
        await harness.provider.waitUntilNonCooperativeActionStarts()

        execution.actionHandle.cancel()
        harness.provider.resumeNonCooperativeActions(with: .succeeded())
        let result = await resultTask.value
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.succeeded])
        XCTAssertEqual(harness.provider.invocations.count, 1)
        XCTAssertTrue(harness.provider.cancelledActionIDs.isEmpty)
    }

    func testCLIWorkflowCancellationCancelsNonCancellableLeafAndSkipsRemainingSteps() async throws {
        let harness = try makeHarness(
            actionIDs: ["slow", "second"],
            nonCancellableActionIDs: ["slow"]
        )
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("slow")),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .publishedAction(.cli),
            mode: .background
        ).get()
        let resultTask = Task { @MainActor in await execution.actionHandle.result() }
        await harness.provider.waitUntilNonCooperativeActionStarts()

        execution.actionHandle.cancel()
        let result = await resultTask.value
        harness.provider.resumeNonCooperativeActions()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.cancelled, .skipped])
        XCTAssertEqual(harness.provider.invocations.map(\.reference.key.actionID), ["slow"])
        XCTAssertTrue(harness.provider.cancelledActionIDs.contains("slow"))
    }

    func testCLIWorkflowTimeoutCancelsNonCancellableLeafAndSkipsRemainingSteps() async throws {
        let harness = try makeHarness(
            actionIDs: ["slow", "second"],
            nonCancellableActionIDs: ["slow"]
        )
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("slow")),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )
        let controller = AutomationController(
            store: harness.store,
            registry: harness.registry,
            executor: harness.executor,
            runner: harness.runner
        )
        harness.registry.synchronize([
            harness.provider.registration(),
            controller.actionRegistration(),
        ])
        let definition = try XCTUnwrap(harness.registry.definition(for: workflow.actionKey))

        let outcome = await harness.executor.executeForCLI(
            ActionInvocation(
                reference: workflow.actionReference,
                source: .cli,
                mode: .background
            ),
            expectedDefinition: definition,
            deadline: ContinuousClock.now.advanced(by: .seconds(1))
        )
        for _ in 0 ..< 1_000 {
            let run = harness.store.history(workflowID: workflow.id).first
            if harness.provider.cancelledActionIDs.contains("slow"), run?.status == .cancelled {
                break
            }
            await Task.yield()
        }
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)
        harness.provider.resumeNonCooperativeActions()

        XCTAssertEqual(outcome, .rejected(.executionTimedOut))
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.cancelled, .skipped])
        XCTAssertEqual(harness.provider.invocations.map(\.reference.key.actionID), ["slow"])
        XCTAssertTrue(harness.provider.cancelledActionIDs.contains("slow"))
    }

    func testCancellationDuringFailedStopTerminalPersistenceCancelsHistory() async throws {
        let checkpoint = WorkflowRunnerTerminalCheckpoint()
        let harness = try makeHarness(
            actionIDs: ["fail"],
            terminalCheckpoint: checkpoint
        )
        harness.provider.results["fail"] = .failed(message: "failure")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("fail"), errorPolicy: .stop)]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let resultTask = Task { @MainActor in await execution.actionHandle.result() }
        await checkpoint.waitUntilReached()

        execution.actionHandle.cancel()
        checkpoint.resume()

        let result = await resultTask.value
        XCTAssertEqual(result, .cancelled)
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.failed])
    }

    func testCancellationDuringUnavailableStopTerminalPersistenceCancelsHistory() async throws {
        let checkpoint = WorkflowRunnerTerminalCheckpoint()
        let harness = try makeHarness(
            actionIDs: ["missing-version"],
            terminalCheckpoint: checkpoint
        )
        let unavailableReference = ActionReference(
            key: harness.reference("missing-version").key,
            schemaVersion: 99
        )
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: unavailableReference, errorPolicy: .stop)]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let resultTask = Task { @MainActor in await execution.actionHandle.result() }
        await checkpoint.waitUntilReached()

        execution.actionHandle.cancel()
        checkpoint.resume()

        let result = await resultTask.value
        XCTAssertEqual(result, .cancelled)
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.unavailable])
    }

    func testNonCooperativeActionStillTimesOutAndReceivesCancellation() async throws {
        let harness = try makeHarness(actionIDs: ["slow"], timeout: 0.01)
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("slow"))]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        let result = await execution.actionHandle.result()
        harness.provider.resumeNonCooperativeActions()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(
            result,
            .failed(message: FeatureL10n.string("工作流在失败步骤处停止。"))
        )
        XCTAssertEqual(run.stepResults.first?.status, .timedOut)
        XCTAssertTrue(harness.provider.cancelledActionIDs.contains("slow"))
    }

    func testMissingProviderDuringRunStopsAndPreservesStepReference() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.provider.onBegin["first"] = {
            harness.registry.synchronize([])
        }
        let second = harness.reference("second")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first")),
                WorkflowStep(reference: second),
            ]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        _ = await execution.actionHandle.result()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(run.stepResults.map(\.status), [.succeeded, .unavailable])
        XCTAssertEqual(harness.store.workflow(id: workflow.id)?.steps[1].reference, second)
    }

    func testPublishedWorkflowActionsRejectIndirectRecursiveInvocation() async throws {
        let harness = try makeHarness(actionIDs: [])
        let first = try saveWorkflow(in: harness.store, steps: [])
        let second = try harness.store.upsert(
            WorkflowDefinition(name: "第二个工作流")
        ).get()
        var firstRecursive = first
        firstRecursive.steps = [WorkflowStep(reference: second.actionReference)]
        _ = try harness.store.upsert(firstRecursive).get()
        var secondRecursive = second
        secondRecursive.steps = [WorkflowStep(reference: first.actionReference)]
        _ = try harness.store.upsert(secondRecursive).get()
        let controller = AutomationController(
            store: harness.store,
            registry: harness.registry,
            executor: harness.executor,
            runner: harness.runner
        )
        harness.registry.synchronize([controller.actionRegistration()])

        let outcome = await harness.executor.execute(
            ActionInvocation(
                reference: first.actionReference,
                source: .unifiedSearch,
                mode: .foreground
            )
        )

        guard case let .rejected(.unavailable(reason)) = outcome else {
            return XCTFail("Expected recursive workflow rejection, got \(outcome)")
        }
        XCTAssertEqual(reason, FeatureL10n.string("检测到递归工作流调用。"))
        XCTAssertTrue(harness.store.history().isEmpty)

        guard case let .failure(startError) = harness.runner.makeExecutionHandle(
            workflowID: first.id,
            source: .manual,
            mode: .foreground
        ) else {
            return XCTFail("Expected recursive workflow preflight rejection")
        }
        XCTAssertEqual(startError, .recursiveInvocation)
        XCTAssertTrue(harness.store.history().isEmpty)
    }

    func testTestRunCanExecuteDisabledWorkflowButManualRunCannot() throws {
        let harness = try makeHarness(actionIDs: ["run"])
        let workflow = try saveWorkflow(
            in: harness.store,
            enabled: false,
            steps: [WorkflowStep(reference: harness.reference("run"))]
        )

        if case let .failure(error) = harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ) {
            XCTAssertEqual(error, .workflowDisabled)
        } else {
            XCTFail("Manual run should be rejected")
        }
        guard case .success = harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .test,
            mode: .foreground
        ) else {
            return XCTFail("Test run should be allowed")
        }
    }

    func testBackgroundRunRejectsNestedForegroundOnlyActionBeforeStarting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "foreground-only", actionID: "show")
        registry.synchronize([ActionProviderRegistration(
            providerID: key.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: key,
                title: "Show",
                description: "",
                systemImage: "rectangle.on.rectangle",
                capabilities: [.foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in .success(ActionExecutionHandle(operation: { .succeeded() })) }
        )])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: ActionReference(key: key))]
        )
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )).get()
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )

        guard case let .failure(error) = runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ) else {
            return XCTFail("Expected background preflight rejection")
        }
        XCTAssertEqual(error, .backgroundExecutionUnsupported)
        XCTAssertTrue(store.history().isEmpty)
    }

    func testAutomaticRunRejectsNestedConfirmationRequiredActionBeforeStarting() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "confirmation-required", actionID: "run")
        var invocationCount = 0
        let confirmationRegistration = ActionProviderRegistration(
            providerID: key.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: key,
                title: "Confirm",
                description: "",
                systemImage: "exclamationmark.shield",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: "Confirm",
                    message: "Confirm action",
                    confirmButtonTitle: "Run"
                ),
                capabilities: [.background, .foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in
                invocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
        registry.synchronize([confirmationRegistration])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: ActionReference(key: key))]
        )
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )).get()
        let executor = ActionExecutor(
            registry: registry,
            confirmationService: ApprovedActionConfirmationService()
        )
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: executor
        )
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: executor,
            runner: runner
        )
        registry.synchronize([
            confirmationRegistration,
            controller.actionRegistration(),
        ])

        guard case let .failure(error) = runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ) else {
            return XCTFail("Expected unattended preflight rejection")
        }
        XCTAssertEqual(error, .confirmationRequiredForAutomaticExecution)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertTrue(store.history().isEmpty)

        let manual = try runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .manual,
            mode: .background
        ).get()
        let manualResult = await manual.actionHandle.result()
        XCTAssertEqual(manualResult, .succeeded())
        XCTAssertEqual(invocationCount, 1)
    }

    func testAutomaticRunRejectsActionThatBecomesInteractiveAfterPreflight() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: ["slow"], timeout: 30)
        provider.nonCooperativeActionIDs.insert("slow")
        let changingKey = ActionKey(providerID: "changing-confirmation", actionID: "run")
        var changingBeginCount = 0

        func changingRegistration(risk: ActionRisk) -> ActionProviderRegistration {
            ActionProviderRegistration(
                providerID: changingKey.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [ActionDefinition(
                    key: changingKey,
                    title: "Changing action",
                    description: "",
                    systemImage: "exclamationmark.shield",
                    risk: risk,
                    confirmation: risk == .confirmationRequired
                        ? ActionConfirmation(
                            title: "Confirm",
                            message: "Confirm action",
                            confirmButtonTitle: "Run"
                        )
                        : nil,
                    capabilities: [.automatic, .background]
                )],
                catalogEntries: [],
                availability: { _ in .available },
                begin: { _ in
                    changingBeginCount += 1
                    return .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            )
        }

        registry.synchronize([provider.registration(), changingRegistration(risk: .safe)])
        let workflow = try saveWorkflow(
            in: store,
            steps: [
                WorkflowStep(reference: ActionReference(key: provider.definitions[0].key)),
                WorkflowStep(reference: ActionReference(key: changingKey)),
            ]
        )
        var confirmationCount = 0
        let executor = ActionExecutor(
            registry: registry,
            confirmationService: ActionExecutorConfirmationService {
                confirmationCount += 1
                return true
            }
        )
        let runner = WorkflowRunner(store: store, registry: registry, executor: executor)
        let execution = try runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ).get()
        let resultTask = Task { @MainActor in
            await execution.actionHandle.result()
        }
        await provider.waitUntilNonCooperativeActionStarts()

        registry.synchronize([
            provider.registration(),
            changingRegistration(risk: .confirmationRequired),
        ])
        provider.resumeNonCooperativeActions(with: .succeeded())
        let result = await resultTask.value

        XCTAssertEqual(
            result,
            .failed(message: FeatureL10n.string("工作流在失败步骤处停止。"))
        )
        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(changingBeginCount, 0)
        XCTAssertEqual(provider.invocations.map(\.source), [.automaticRule])
    }

    func testRunLinkSourceRemainsExternalThroughNestedWorkflows() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: ["allowed"], timeout: 30)
        let key = ActionKey(providerID: "restricted-leaf", actionID: "run")
        var invocationCount = 0
        let restricted = ActionProviderRegistration(
            providerID: key.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: key,
                title: "Restricted",
                description: "",
                systemImage: "lock",
                externalInvocationPolicy: .unavailable,
                capabilities: [.background, .foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in
                invocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
        registry.synchronize([provider.registration(), restricted])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: ActionReference(key: key))]
        )
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [
                WorkflowStep(reference: ActionReference(key: provider.definitions[0].key)),
                WorkflowStep(reference: child.actionReference),
            ]
        )).get()
        let executor = ActionExecutor(registry: registry)
        let runner = WorkflowRunner(store: store, registry: registry, executor: executor)
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: executor,
            runner: runner
        )
        registry.synchronize([
            provider.registration(),
            restricted,
            controller.actionRegistration(),
        ])

        let outcome = await executor.execute(ActionInvocation(
            reference: parent.actionReference,
            source: .runLink,
            mode: .foreground
        ))

        XCTAssertEqual(outcome, .rejected(.externalInvocationUnavailable))
        XCTAssertTrue(provider.invocations.isEmpty)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertTrue(store.history().isEmpty)
    }

    func testRunLinkRejectsNestedSensitiveParameterBeforeAnyStepRuns() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: ["safe"], timeout: 30)
        let sensitiveKey = ActionKey(providerID: "sensitive-leaf", actionID: "authenticate")
        let sensitiveReference = ActionReference(
            key: sensitiveKey,
            parameters: try ActionParameterSet(["token": .string("secret")])
        )
        var sensitiveInvocationCount = 0
        let sensitiveRegistration = ActionProviderRegistration(
            providerID: sensitiveKey.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: sensitiveKey,
                title: "Authenticate",
                description: "",
                systemImage: "key",
                parameters: [ActionParameterDefinition(
                    id: "token",
                    title: "Token",
                    kind: .string,
                    privacy: .sensitive
                )],
                capabilities: [.background, .foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in
                sensitiveInvocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
        registry.synchronize([provider.registration(), sensitiveRegistration])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: sensitiveReference)]
        )
        let parent = try saveWorkflow(
            in: store,
            steps: [
                WorkflowStep(reference: ActionReference(key: provider.definitions[0].key)),
                WorkflowStep(reference: child.actionReference),
            ]
        )
        let executor = ActionExecutor(registry: registry)
        let runner = WorkflowRunner(store: store, registry: registry, executor: executor)
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: executor,
            runner: runner
        )
        registry.synchronize([
            provider.registration(),
            sensitiveRegistration,
            controller.actionRegistration(),
        ])

        let outcome = await executor.execute(ActionInvocation(
            reference: parent.actionReference,
            source: .runLink,
            mode: .foreground
        ))

        XCTAssertEqual(outcome, .rejected(.externalInvocationUnavailable))
        XCTAssertTrue(provider.invocations.isEmpty)
        XCTAssertEqual(sensitiveInvocationCount, 0)
        XCTAssertTrue(store.history().isEmpty)
    }

    func testRunLinkRechecksNestedExternalPolicyWhenExecutionStarts() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: ["first"], timeout: 30)
        let restrictedKey = ActionKey(providerID: "changing-leaf", actionID: "run")

        func restrictedRegistration(
            policy: ActionExternalInvocationPolicy
        ) -> ActionProviderRegistration {
            ActionProviderRegistration(
                providerID: restrictedKey.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [ActionDefinition(
                    key: restrictedKey,
                    title: "Changing Leaf",
                    description: "",
                    systemImage: "lock",
                    externalInvocationPolicy: policy,
                    capabilities: [.background, .foregroundInteractive]
                )],
                catalogEntries: [],
                availability: { _ in .available },
                begin: { _ in
                    XCTFail("Restricted leaf must not begin")
                    return .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            )
        }

        registry.synchronize([
            provider.registration(),
            restrictedRegistration(policy: .allowed),
        ])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: ActionReference(key: restrictedKey))]
        )
        let parent = try saveWorkflow(
            in: store,
            steps: [
                WorkflowStep(reference: ActionReference(key: provider.definitions[0].key)),
                WorkflowStep(reference: child.actionReference),
            ]
        )
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let execution = try runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .publishedAction(.runLink),
            mode: .foreground
        ).get()

        registry.synchronize([
            provider.registration(),
            restrictedRegistration(policy: .unavailable),
        ])
        let result = await execution.actionHandle.result()

        XCTAssertEqual(
            result,
            .failed(message: FeatureL10n.string("此操作不能通过运行链接调用。"))
        )
        XCTAssertTrue(provider.invocations.isEmpty)
        XCTAssertTrue(store.history().isEmpty)
    }

    func testWorkflowDepthLimitIsPreflightedBeforeHistoryOrActions() throws {
        let harness = try makeHarness(actionIDs: ["run"])
        let supported = try nestedWorkflow(
            in: harness.store,
            depth: WorkflowExecutionLimits.maximumDepth,
            leafReference: harness.reference("run")
        )
        let tooDeep = try nestedWorkflow(
            in: harness.store,
            depth: WorkflowExecutionLimits.maximumDepth + 1,
            leafReference: harness.reference("run")
        )

        XCTAssertTrue(WorkflowExecutionAnalysis.analyze(
            workflowID: supported.id,
            store: harness.store,
            definition: harness.registry.definition(for:)
        ).availability.isAvailable)
        XCTAssertFalse(WorkflowExecutionAnalysis.analyze(
            workflowID: tooDeep.id,
            store: harness.store,
            definition: harness.registry.definition(for:)
        ).availability.isAvailable)

        guard case let .failure(error) = harness.runner.makeExecutionHandle(
            workflowID: tooDeep.id,
            source: .manual,
            mode: .foreground
        ) else {
            return XCTFail("Expected depth preflight rejection")
        }
        XCTAssertEqual(error, .maximumDepthExceeded)
        XCTAssertTrue(harness.provider.invocations.isEmpty)
        XCTAssertTrue(harness.store.history().isEmpty)
    }

    private struct Harness {
        let registry: ActionRegistry
        let provider: WorkflowRunnerTestProvider
        let store: WorkflowStore
        let sleeper: WorkflowRunnerTestSleeper
        let executor: ActionExecutor
        let runner: WorkflowRunner

        func reference(_ actionID: String) -> ActionReference {
            ActionReference(
                key: ActionKey(providerID: WorkflowRunnerTestProvider.providerID, actionID: actionID)
            )
        }
    }

    private func makeHarness(
        actionIDs: [String],
        timeout: Double = 30,
        nonCancellableActionIDs: Set<String> = [],
        terminalCheckpoint: WorkflowRunnerTerminalCheckpoint? = nil
    ) throws -> Harness {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(
            actionIDs: actionIDs,
            timeout: timeout,
            nonCancellableActionIDs: nonCancellableActionIDs
        )
        registry.synchronize([provider.registration()])
        let executor = ActionExecutor(
            registry: registry,
            confirmationService: ApprovedActionConfirmationService(),
            confirmationTimeout: .milliseconds(50)
        )
        let sleeper = WorkflowRunnerTestSleeper()
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: executor,
            sleeper: sleeper,
            terminalPersistenceCheckpoint: {
                await terminalCheckpoint?.suspend()
            }
        )
        return Harness(
            registry: registry,
            provider: provider,
            store: store,
            sleeper: sleeper,
            executor: executor,
            runner: runner
        )
    }

    private func saveWorkflow(
        in store: WorkflowStore,
        enabled: Bool = true,
        steps: [WorkflowStep]
    ) throws -> WorkflowDefinition {
        try store.upsert(
            WorkflowDefinition(name: "测试工作流", isEnabled: enabled, steps: steps)
        ).get()
    }

    private func nestedWorkflow(
        in store: WorkflowStore,
        depth: Int,
        leafReference: ActionReference
    ) throws -> WorkflowDefinition {
        var current = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: leafReference)]
        )
        for index in 1 ..< depth {
            current = try store.upsert(WorkflowDefinition(
                name: "Nested \(index)",
                steps: [WorkflowStep(reference: current.actionReference)]
            )).get()
        }
        return current
    }
}

@MainActor
private final class WorkflowRunnerTerminalCheckpoint {
    private var reached = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        reached = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReached() async {
        while !reached {
            await Task.yield()
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class WorkflowRunnerTestSleeper: WorkflowSleeping {
    private(set) var requestedSeconds: [Double] = []
    var shouldBlock = false
    var onSleep: ((Double) -> Void)?
    private var didStart = false

    func sleep(seconds: Double) async throws {
        requestedSeconds.append(seconds)
        onSleep?(seconds)
        didStart = true
        if shouldBlock {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func waitUntilSleeping() async {
        while !didStart {
            await Task.yield()
        }
    }
}

@MainActor
private final class WorkflowRunnerTestProvider {
    nonisolated static let providerID = "workflow-runner-tests"

    let definitions: [ActionDefinition]
    var results: [String: ActionExecutionResult] = [:]
    var onBegin: [String: () -> Void] = [:]
    var nonCooperativeActionIDs: Set<String> = []
    private(set) var invocations: [ActionInvocation] = []
    private(set) var cancelledActionIDs: Set<String> = []
    private var continuations: [CheckedContinuation<ActionExecutionResult, Never>] = []

    init(
        actionIDs: [String],
        timeout: Double,
        nonCancellableActionIDs: Set<String> = []
    ) {
        definitions = actionIDs.map { actionID in
            ActionDefinition(
                key: ActionKey(providerID: Self.providerID, actionID: actionID),
                title: actionID,
                description: "",
                systemImage: "bolt",
                externalInvocationPolicy: .allowed,
                capabilities: nonCancellableActionIDs.contains(actionID)
                    ? [.automatic, .background, .foregroundInteractive]
                    : [.automatic, .background, .foregroundInteractive, .cancellable],
                executionTimeoutSeconds: timeout
            )
        }
    }

    func registration() -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: Self.providerID,
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: definitions.map {
                ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
            },
            availability: { _ in .available },
            begin: { [weak self] invocation in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                self.invocations.append(invocation)
                let actionID = invocation.reference.key.actionID
                self.onBegin[actionID]?()
                if self.nonCooperativeActionIDs.contains(actionID) {
                    return .success(
                        ActionExecutionHandle(
                            operation: { [weak self] in
                                guard let self else { return .cancelled }
                                return await withCheckedContinuation { continuation in
                                    self.continuations.append(continuation)
                                }
                            },
                            cancel: { [weak self] in
                                self?.cancelledActionIDs.insert(actionID)
                            }
                        )
                    )
                }
                let result = self.results[actionID] ?? .succeeded()
                return .success(ActionExecutionHandle(operation: { result }))
            }
        )
    }

    func waitUntilNonCooperativeActionStarts() async {
        while continuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeNonCooperativeActions(with result: ActionExecutionResult = .cancelled) {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }
}
