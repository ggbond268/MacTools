import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class AutomationControllerTests: XCTestCase {

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testEnabledWorkflowPublishesStableOrdinaryActionAndDisabledWorkflowDisappears() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider()
        registry.synchronize([provider.registration])
        let executor = ActionExecutor(registry: registry)
        let store = WorkflowStore(userDefaults: defaults)
        let controller = AutomationController(store: store, registry: registry, executor: executor)
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)

        let enabledRegistration = controller.actionRegistration()
        XCTAssertEqual(enabledRegistration.definitions.map(\.key), [workflow.actionKey])
        XCTAssertEqual(enabledRegistration.catalogEntries.map(\.reference), [workflow.actionReference])
        XCTAssertEqual(enabledRegistration.definitions.first?.externalInvocationPolicy, .allowed)
        XCTAssertTrue(
            enabledRegistration.definitions.first?.capabilities.contains(.cancellable) == true
        )
        XCTAssertTrue(
            enabledRegistration.definitions.first?.capabilities.contains(.reportsProgress) == true
        )

        controller.setWorkflowEnabled(false, id: workflow.id)
        XCTAssertTrue(controller.actionRegistration().definitions.isEmpty)
        XCTAssertNotNil(controller.workflows.first { $0.id == workflow.id })
    }

    func testPublishedActionExecutesThroughSharedExecutorAndRecordsSource() async throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider()
        let executor = ActionExecutor(registry: registry)
        let store = WorkflowStore(userDefaults: defaults)
        let controller = AutomationController(store: store, registry: registry, executor: executor)
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)
        registry.synchronize([provider.registration, controller.actionRegistration()])

        let outcome = await executor.execute(
            ActionInvocation(
                reference: workflow.actionReference,
                source: .globalShortcut,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertEqual(provider.invocationCount, 1)
        XCTAssertEqual(
            store.history(workflowID: workflow.id).first?.source,
            .publishedAction(.globalShortcut)
        )
    }

    func testAppIntentExposureRejectsExcludedLeafThroughNestedWorkflows() throws {
        let suite = "AutomationControllerTests.app-intents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider()
        provider.appIntentExposurePolicy = .excluded
        registry.synchronize([provider.registration])
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let child = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: child.id, reference: provider.reference)
        let parent = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: parent.id, reference: child.actionReference)
        registry.synchronize([provider.registration, controller.actionRegistration()])

        XCTAssertEqual(
            registry.exposurePolicy(for: child.actionReference, on: .appIntents),
            .excluded
        )
        XCTAssertEqual(
            registry.exposurePolicy(for: parent.actionReference, on: .appIntents),
            .excluded
        )

        provider.appIntentExposurePolicy = .automatic
        XCTAssertEqual(
            registry.exposurePolicy(for: child.actionReference, on: .appIntents),
            .automatic
        )
        XCTAssertEqual(
            registry.exposurePolicy(for: parent.actionReference, on: .appIntents),
            .automatic
        )
    }

    func testNestedRestrictedActionDisablesWorkflowRunLinksWithoutDisablingLocalRuns() throws {
        let suite = "AutomationControllerTests.external.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider(
            externalInvocationPolicy: .unavailable
        )
        registry.synchronize([provider.registration])
        let store = WorkflowStore(userDefaults: defaults)
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let child = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: child.id, reference: provider.reference)
        let parent = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: parent.id, reference: child.actionReference)

        let registration = controller.actionRegistration()
        XCTAssertEqual(
            registration.definitions.first { $0.key == child.actionKey }?
                .externalInvocationPolicy,
            .unavailable
        )
        XCTAssertEqual(
            registration.definitions.first { $0.key == parent.actionKey }?
                .externalInvocationPolicy,
            .unavailable
        )
        XCTAssertTrue(registration.availability(parent.actionReference).isAvailable)
    }

    func testNestedSensitiveParameterDisablesWorkflowRunLinksWithoutDisablingLocalRuns() throws {
        let suite = "AutomationControllerTests.sensitive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider()
        let key = ActionKey(providerID: "automation-sensitive", actionID: "authenticate")
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["token": .string("secret")])
        )
        let sensitiveRegistration = ActionProviderRegistration(
            providerID: key.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: key,
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
            begin: { _ in .success(ActionExecutionHandle(operation: { .succeeded() })) }
        )
        registry.synchronize([sensitiveRegistration])
        let store = WorkflowStore(userDefaults: defaults)
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let child = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: child.id, reference: reference)
        let parent = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: parent.id, reference: child.actionReference)

        let registration = controller.actionRegistration()

        XCTAssertEqual(
            registration.definitions.first { $0.key == child.actionKey }?
                .externalInvocationPolicy,
            .unavailable
        )
        XCTAssertEqual(
            registration.definitions.first { $0.key == parent.actionKey }?
                .externalInvocationPolicy,
            .unavailable
        )
        XCTAssertTrue(registration.availability(parent.actionReference).isAvailable)
    }

    func testRuleManagementKeepsMultipleIndependentRulesForWorkflow() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let executor = ActionExecutor(registry: registry)
        let workflowStore = WorkflowStore(userDefaults: defaults)
        let ruleStore = AutomationRuleStore(userDefaults: defaults)
        let controller = AutomationController(
            store: workflowStore,
            ruleStore: ruleStore,
            registry: registry,
            executor: executor
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        let first = try XCTUnwrap(controller.createRule(workflowID: workflow.id))
        let second = try XCTUnwrap(controller.duplicateRule(id: first.id))
        var updated = second
        updated.name = "接入显示器"
        updated.trigger = .display(DisplayAutomationTrigger(event: .connected))
        updated.conditions = [.power(PowerAutomationCondition(source: .adapter))]

        controller.saveRule(updated)

        XCTAssertEqual(controller.rules(workflowID: workflow.id).count, 2)
        XCTAssertEqual(controller.rules(workflowID: workflow.id).last?.name, "接入显示器")
        controller.deleteRule(id: first.id)
        XCTAssertEqual(controller.rules(workflowID: workflow.id).map(\.id), [second.id])
    }

    func testDeletingWorkflowAlsoDeletesItsRulesAcrossRelaunch() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let executor = ActionExecutor(registry: registry)
        let workflowStore = WorkflowStore(userDefaults: defaults)
        let ruleStore = AutomationRuleStore(userDefaults: defaults)
        let controller = AutomationController(
            store: workflowStore,
            ruleStore: ruleStore,
            registry: registry,
            executor: executor
        )
        let deleted = try XCTUnwrap(controller.createWorkflow())
        let retained = try XCTUnwrap(controller.createWorkflow())
        _ = try XCTUnwrap(controller.createRule(workflowID: deleted.id))
        let retainedRule = try XCTUnwrap(controller.createRule(workflowID: retained.id))

        controller.deleteWorkflow(id: deleted.id)

        XCTAssertNil(workflowStore.workflow(id: deleted.id))
        XCTAssertEqual(ruleStore.rules().map(\.id), [retainedRule.id])
        let reloadedRules = AutomationRuleStore(userDefaults: defaults).rules()
        XCTAssertEqual(reloadedRules.map(\.id), [retainedRule.id])
    }

    func testRejectedCombinedDefinitionWritePreservesWorkflowAndRulesOnDelete() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var rejectsWrites = false
        let definitionStore = AutomationDefinitionStore(
            userDefaults: defaults,
            setCombinedValue: { value in
                guard !rejectsWrites else { return }
                if let value {
                    defaults.set(value, forKey: "automation.definitions.v1")
                } else {
                    defaults.removeObject(forKey: "automation.definitions.v1")
                }
            }
        )
        let workflowStore = WorkflowStore(definitionStore: definitionStore)
        let ruleStore = AutomationRuleStore(definitionStore: definitionStore)
        let registry = ActionRegistry()
        let controller = AutomationController(
            store: workflowStore,
            ruleStore: ruleStore,
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        let rule = try XCTUnwrap(controller.createRule(workflowID: workflow.id))
        rejectsWrites = true

        XCTAssertFalse(controller.deleteWorkflow(id: workflow.id))
        XCTAssertEqual(WorkflowStore(userDefaults: defaults).workflows().map(\.id), [workflow.id])
        XCTAssertEqual(AutomationRuleStore(userDefaults: defaults).rules().map(\.id), [rule.id])
    }

    func testActiveRunCanBeCancelledThroughControllerSurface() async throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = CancellableAutomationControllerTestProvider()
        registry.synchronize([provider.registration])
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)
        let runID = try XCTUnwrap(controller.startWorkflow(id: workflow.id))

        let didStart = await waitUntil {
            provider.beginCount == 1
                && controller.activeRunIDs(for: workflow.id) == [runID]
        }
        XCTAssertTrue(didStart)
        XCTAssertEqual(controller.activeRunIDs(for: workflow.id), [runID])

        controller.cancel(runID: runID)
        let didCancel = await waitUntil {
            !controller.activeRunIDs.contains(runID)
                && controller.recentRuns(workflowID: workflow.id).first?.status == .cancelled
                && provider.cancelCount == 1
        }

        XCTAssertTrue(didCancel)
        XCTAssertFalse(controller.activeRunIDs.contains(runID))
        XCTAssertEqual(controller.recentRuns(workflowID: workflow.id).first?.status, .cancelled)
        XCTAssertEqual(provider.cancelCount, 1)
    }

    func testDeletingActiveWorkflowCancelsProviderAndFinalizesRun() async throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = CancellableAutomationControllerTestProvider()
        registry.synchronize([provider.registration])
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)
        let runID = try XCTUnwrap(controller.startWorkflow(id: workflow.id))
        let didStart = await waitUntil {
            provider.beginCount == 1
                && controller.activeRunIDs(for: workflow.id) == [runID]
        }
        XCTAssertTrue(didStart)

        XCTAssertTrue(controller.deleteWorkflow(id: workflow.id))
        let didCancel = await waitUntil {
            !controller.activeRunIDs.contains(runID)
                && controller.history.first { $0.id == runID }?.status == .cancelled
                && provider.cancelCount == 1
        }

        XCTAssertTrue(didCancel)
        XCTAssertNil(controller.workflows.first { $0.id == workflow.id })
        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertEqual(
            controller.history.first { $0.id == runID }?.status,
            .cancelled
        )
    }

}

@MainActor
private final class AutomationControllerTestProvider {
    let reference: ActionReference
    private(set) var invocationCount = 0
    let capabilities: ActionExecutionCapabilities
    let externalInvocationPolicy: ActionExternalInvocationPolicy
    let risk: ActionRisk
    var availability: ActionAvailability = .available
    var appIntentExposurePolicy: ActionExposurePolicy = .automatic

    init(
        providerID: String = "automation-controller-tests",
        actionID: String = "run",
        capabilities: ActionExecutionCapabilities = [
            .automatic,
            .background,
            .foregroundInteractive,
        ],
        externalInvocationPolicy: ActionExternalInvocationPolicy = .allowed,
        risk: ActionRisk = .safe
    ) {
        self.reference = ActionReference(
            key: ActionKey(providerID: providerID, actionID: actionID)
        )
        self.capabilities = capabilities
        self.externalInvocationPolicy = externalInvocationPolicy
        self.risk = risk
    }

    var registration: ActionProviderRegistration {
        let definition = ActionDefinition(
            key: reference.key,
            title: "运行",
            description: "",
            systemImage: "bolt",
            risk: risk,
            confirmation: risk == .confirmationRequired
                ? ActionConfirmation(
                    title: "Confirm",
                    message: "Confirm action",
                    confirmButtonTitle: "Run"
                )
                : nil,
            externalInvocationPolicy: externalInvocationPolicy,
            capabilities: capabilities
        )
        return ActionProviderRegistration(
            providerID: reference.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [ActionCatalogEntry(reference: reference, title: "运行")],
            availability: { [weak self] _ in self?.availability ?? .unavailable("Missing") },
            exposurePolicy: { [weak self] _, surface in
                surface == .appIntents
                    ? self?.appIntentExposurePolicy ?? .excluded
                    : .automatic
            },
            begin: { [weak self] _ in
                self?.invocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
    }
}

@MainActor
private final class CancellableAutomationControllerTestProvider {
    let reference = ActionReference(
        key: ActionKey(providerID: "automation-controller-tests", actionID: "wait")
    )
    private(set) var cancelCount = 0
    private(set) var beginCount = 0

    var registration: ActionProviderRegistration {
        let definition = ActionDefinition(
            key: reference.key,
            title: "等待",
            description: "",
            systemImage: "hourglass",
            capabilities: [.background, .foregroundInteractive, .cancellable]
        )
        return ActionProviderRegistration(
            providerID: reference.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [ActionCatalogEntry(reference: reference, title: "等待")],
            availability: { _ in .available },
            begin: { [weak self] _ in
                self?.beginCount += 1
                return .success(
                    ActionExecutionHandle(
                        operation: {
                            do {
                                try await Task.sleep(for: .seconds(60))
                                return .succeeded()
                            } catch {
                                return .cancelled
                            }
                        },
                        cancel: { self?.cancelCount += 1 }
                    )
                )
            }
        )
    }
}
