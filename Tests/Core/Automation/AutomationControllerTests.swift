import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class AutomationControllerTests: XCTestCase {
    func testActionPickerAccessibilityExposesUnavailableReason() {
        XCTAssertEqual(
            WorkflowActionPickerAccessibility(availability: .available).value,
            FeatureL10n.string("可用")
        )
        XCTAssertEqual(
            WorkflowActionPickerAccessibility(
                availability: .unavailable("需要辅助功能权限。")
            ).value,
            "需要辅助功能权限。"
        )
        XCTAssertEqual(
            WorkflowActionPickerAccessibility(
                availability: ActionAvailability(isAvailable: false)
            ).value,
            FeatureL10n.string("不可用")
        )
        XCTAssertEqual(
            WorkflowActionPickerAccessibility(
                availability: .available,
                requiresConfirmation: true
            ).value,
            FeatureL10n.joined([
                FeatureL10n.string("可用"),
                FeatureL10n.string("执行前需要确认。"),
            ])
        )
    }

    func testRuleSummariesUseCompleteMessagesAcrossLocales() {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let calendar = AutomationTrigger.calendar(
            CalendarAutomationTrigger(phase: .starts)
        )
        let display = AutomationTrigger.display(
            DisplayAutomationTrigger(event: .disconnected)
        )
        let expectations: [(String, String, String)] = [
            (
                "en",
                "When Calendar event starts · Run Demo",
                "When Display disconnected and conditions match (2) · Run Demo"
            ),
            (
                "de",
                "Wenn Kalenderereignis beginnt · Demo ausführen",
                "Wenn Monitor getrennt und Bedingungen erfüllt sind (2) · Demo ausführen"
            ),
            (
                "ar",
                "عند بدء حدث التقويم · تشغيل Demo",
                "عند قطع اتصال الشاشة مع استيفاء الشروط (2) · تشغيل Demo"
            ),
        ]

        for (language, calendarSummary, displaySummary) in expectations {
            PluginRuntimeLocalization.source.setPreference(language)
            XCTAssertEqual(
                withoutBidirectionalIsolation(AutomationRuleSummaryFormatter.summary(
                    trigger: calendar,
                    conditionCount: 0,
                    workflowName: "Demo"
                )),
                calendarSummary
            )
            XCTAssertEqual(
                withoutBidirectionalIsolation(AutomationRuleSummaryFormatter.summary(
                    trigger: display,
                    conditionCount: 2,
                    workflowName: "Demo"
                )),
                displaySummary
            )
        }
    }

    private func withoutBidirectionalIsolation(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
    }

    func testExistingErrorRelocalizesOnSameControllerInstance() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )

        PluginRuntimeLocalization.source.setPreference("zh-Hans")
        controller.renameWorkflow(id: UUID(), name: "Missing")
        XCTAssertEqual(controller.lastErrorMessage, "找不到工作流。")

        PluginRuntimeLocalization.source.setPreference("en")
        XCTAssertEqual(controller.lastErrorMessage, "The workflow could not be found.")

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(controller.lastErrorMessage, "لا يمكن العثور على سير العمل.")
    }

    func testConfirmationRequiredAutomaticRuleReasonIsLocalized() {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let expectations: [(String, String)] = [
            (
                "en",
                "The workflow contains actions that require confirmation and cannot run automatically."
            ),
            (
                "zh-Hans",
                "工作流包含需要确认的操作，无法自动运行。"
            ),
            (
                "ar",
                "يحتوي سير العمل على إجراءات تتطلب التأكيد ولا يمكن تشغيله تلقائيًا."
            ),
        ]

        for (language, expected) in expectations {
            PluginRuntimeLocalization.source.setPreference(language)
            XCTAssertEqual(
                AutomationRunSkipReason
                    .confirmationRequiredForAutomaticExecution
                    .localizedText,
                expected
            )
        }
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

    func testWorkflowCapabilitiesReflectNestedBackgroundSupport() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider(
            capabilities: [.foregroundInteractive]
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

        let definitions = controller.actionRegistration().definitions

        XCTAssertFalse(
            try XCTUnwrap(definitions.first { $0.key == child.actionKey })
                .capabilities.contains(.background)
        )
        XCTAssertFalse(
            try XCTUnwrap(definitions.first { $0.key == parent.actionKey })
                .capabilities.contains(.background)
        )
        XCTAssertFalse(controller.supportsAutomaticRules(workflowID: parent.id))
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

    func testAutomaticRuleAvailabilityExplainsEveryIneligibleWorkflow() throws {
        let suite = "AutomationControllerTests.eligibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let background = AutomationControllerTestProvider(actionID: "background")
        let foreground = AutomationControllerTestProvider(
            providerID: "automation-controller-foreground-tests",
            actionID: "foreground",
            capabilities: [.foregroundInteractive]
        )
        let confirmation = AutomationControllerTestProvider(
            providerID: "automation-controller-confirmation-tests",
            actionID: "confirm",
            risk: .confirmationRequired
        )
        registry.synchronize([
            background.registration,
            foreground.registration,
            confirmation.registration,
        ])
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )

        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: UUID()).reason,
            FeatureL10n.string("找不到工作流。")
        )
        let empty = try XCTUnwrap(controller.createWorkflow())
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: empty.id).reason,
            FeatureL10n.string("工作流尚未添加步骤。")
        )
        controller.setWorkflowEnabled(false, id: empty.id)
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: empty.id).reason,
            FeatureL10n.string("工作流已停用。")
        )

        let interactive = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: interactive.id, reference: foreground.reference)
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: interactive.id).reason,
            FeatureL10n.string("此工作流包含需要交互的操作，不能由自动规则在后台运行。")
        )

        let confirmationRequired = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(
            workflowID: confirmationRequired.id,
            reference: confirmation.reference
        )
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: confirmationRequired.id).reason,
            FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
        )

        let nestedConfirmation = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(
            workflowID: nestedConfirmation.id,
            reference: confirmationRequired.actionReference
        )
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: nestedConfirmation.id).reason,
            FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
        )

        let missing = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(
            workflowID: missing.id,
            reference: ActionReference(
                key: ActionKey(providerID: "missing", actionID: "action")
            )
        )
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: missing.id).reason,
            FeatureL10n.string("工作流包含不可用操作。")
        )

        let unavailable = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: unavailable.id, reference: background.reference)
        background.availability = .unavailable("Device disconnected")
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: unavailable.id).reason,
            "Device disconnected"
        )
        background.availability = .available
        XCTAssertTrue(controller.automaticRuleAvailability(workflowID: unavailable.id).isAvailable)

        let first = try XCTUnwrap(controller.createWorkflow())
        let second = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: first.id, reference: second.actionReference)
        controller.addStep(workflowID: second.id, reference: first.actionReference)
        XCTAssertEqual(
            controller.automaticRuleAvailability(workflowID: first.id).reason,
            FeatureL10n.string("检测到递归工作流调用。")
        )
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

    func testRejectedCombinedDefinitionWritePreservesBothCollectionsOnRestore() throws {
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
        let replacement = WorkflowDefinition(name: "Replacement")
        rejectsWrites = true

        XCTAssertFalse(controller.restorePreferences(workflows: [replacement], rules: []))
        XCTAssertEqual(WorkflowStore(userDefaults: defaults).workflows().map(\.id), [workflow.id])
        XCTAssertEqual(AutomationRuleStore(userDefaults: defaults).rules().map(\.id), [rule.id])
    }

    func testMoveWorkflowUpdatesPublishedOrderAndPersists() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let first = try XCTUnwrap(controller.createWorkflow())
        let second = try XCTUnwrap(controller.createWorkflow())

        controller.moveWorkflow(id: second.id, offset: -1)

        XCTAssertEqual(controller.workflows.map(\.id), [second.id, first.id])
        XCTAssertEqual(
            WorkflowStore(userDefaults: defaults).workflows().map(\.id),
            [second.id, first.id]
        )
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

        await waitUntil { controller.activeRunIDs(for: workflow.id) == [runID] }

        controller.cancel(runID: runID)
        await waitUntil { !controller.activeRunIDs.contains(runID) }

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
        await waitUntil { controller.activeRunIDs(for: workflow.id) == [runID] }

        XCTAssertTrue(controller.deleteWorkflow(id: workflow.id))
        await waitUntil { !controller.activeRunIDs.contains(runID) }

        XCTAssertNil(controller.workflows.first { $0.id == workflow.id })
        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertEqual(
            controller.history.first { $0.id == runID }?.status,
            .cancelled
        )
    }

    func testDeletingWorkflowImmediatelyAfterStartPreventsItsFirstAction() async throws {
        let suite = "AutomationControllerTests.immediate-delete.\(UUID().uuidString)"
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

        XCTAssertTrue(controller.deleteWorkflow(id: workflow.id))
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertTrue(controller.activeRunIDs(for: workflow.id).isEmpty)
        XCTAssertFalse(controller.activeRunIDs.contains(runID))
        XCTAssertEqual(provider.beginCount, 0)
        XCTAssertEqual(provider.cancelCount, 0)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
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
