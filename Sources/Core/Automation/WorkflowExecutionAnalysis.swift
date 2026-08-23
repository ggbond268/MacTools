import Foundation
import MacToolsPluginKit

struct WorkflowExecutionAnalysisResult: Equatable {
    let availability: ActionAvailability
    let supportsBackground: Bool
    let supportsUnattendedExecution: Bool
    let requiresConfirmation: Bool
    let allowsExternalInvocation: Bool
}

enum WorkflowExecutionLimits {
    static let maximumDepth = 8
}

@MainActor
enum WorkflowExecutionAnalysis {
    static func analyze(
        workflowID: UUID,
        store: WorkflowStore,
        definition: (ActionKey) -> ActionDefinition?,
        availability: ((ActionReference) -> ActionAvailability)? = nil
    ) -> WorkflowExecutionAnalysisResult {
        analyze(
            workflowID: workflowID,
            store: store,
            definition: definition,
            availability: availability,
            visiting: [],
            depth: 0
        )
    }

    static func structuralStartError(
        workflowID: UUID,
        store: WorkflowStore
    ) -> WorkflowStartError? {
        structuralStartError(
            workflowID: workflowID,
            store: store,
            visiting: [],
            depth: 0
        )
    }

    static func allLeafActions(
        in workflowID: UUID,
        store: WorkflowStore,
        satisfy predicate: (ActionReference) -> Bool
    ) -> Bool {
        allLeafActions(
            in: workflowID,
            store: store,
            satisfy: predicate,
            visiting: [],
            depth: 0
        )
    }

    static func nestedWorkflowID(for key: ActionKey) -> UUID? {
        guard key.providerID == AutomationController.providerID,
              key.actionID.hasPrefix("workflow.") else {
            return nil
        }
        return UUID(uuidString: String(key.actionID.dropFirst("workflow.".count)))
    }

    private static func analyze(
        workflowID: UUID,
        store: WorkflowStore,
        definition: (ActionKey) -> ActionDefinition?,
        availability: ((ActionReference) -> ActionAvailability)?,
        visiting: Set<UUID>,
        depth: Int
    ) -> WorkflowExecutionAnalysisResult {
        guard depth < WorkflowExecutionLimits.maximumDepth else {
            return unavailable(FeatureL10n.string("工作流嵌套层级已达上限。"))
        }
        guard !visiting.contains(workflowID) else {
            return unavailable(FeatureL10n.string("检测到递归工作流调用。"))
        }
        guard let workflow = store.workflow(id: workflowID) else {
            return unavailable(FeatureL10n.string("找不到工作流。"))
        }
        guard workflow.isEnabled else {
            return unavailable(FeatureL10n.string("工作流已停用。"))
        }
        guard !workflow.steps.isEmpty else {
            return unavailable(FeatureL10n.string("工作流尚未添加步骤。"))
        }

        var nextVisiting = visiting
        nextVisiting.insert(workflowID)
        var supportsBackground = true
        var supportsUnattendedExecution = true
        var requiresConfirmation = false
        var allowsExternalInvocation = true

        for step in workflow.steps {
            if let nestedID = nestedWorkflowID(for: step.reference.key) {
                let nested = analyze(
                    workflowID: nestedID,
                    store: store,
                    definition: definition,
                    availability: availability,
                    visiting: nextVisiting,
                    depth: depth + 1
                )
                guard nested.availability.isAvailable else { return nested }
                supportsBackground = supportsBackground && nested.supportsBackground
                supportsUnattendedExecution = supportsUnattendedExecution
                    && nested.supportsUnattendedExecution
                requiresConfirmation = requiresConfirmation || nested.requiresConfirmation
                allowsExternalInvocation = allowsExternalInvocation
                    && nested.allowsExternalInvocation
                continue
            }

            guard let actionDefinition = definition(step.reference.key) else {
                return unavailable(FeatureL10n.string("工作流包含不可用操作。"))
            }
            if let availability {
                let current = availability(step.reference)
                guard current.isAvailable else {
                    return unavailable(
                        current.reason ?? FeatureL10n.string("工作流包含不可用操作。")
                    )
                }
            }
            supportsBackground = supportsBackground
                && actionDefinition.capabilities.contains(.background)
            supportsUnattendedExecution = supportsUnattendedExecution
                && actionDefinition.risk != .confirmationRequired
                && actionDefinition.capabilities.contains(.automatic)
            requiresConfirmation = requiresConfirmation
                || actionDefinition.risk == .confirmationRequired
            allowsExternalInvocation = allowsExternalInvocation
                && actionDefinition.externalInvocationPolicy != .unavailable
                && !ActionRegistry.containsSensitiveParameters(
                    step.reference,
                    for: actionDefinition
                )
        }

        return WorkflowExecutionAnalysisResult(
            availability: .available,
            supportsBackground: supportsBackground,
            supportsUnattendedExecution: supportsUnattendedExecution,
            requiresConfirmation: requiresConfirmation,
            allowsExternalInvocation: allowsExternalInvocation
        )
    }

    private static func structuralStartError(
        workflowID: UUID,
        store: WorkflowStore,
        visiting: Set<UUID>,
        depth: Int
    ) -> WorkflowStartError? {
        guard depth < WorkflowExecutionLimits.maximumDepth else {
            return .maximumDepthExceeded
        }
        guard !visiting.contains(workflowID) else {
            return .recursiveInvocation
        }
        guard let workflow = store.workflow(id: workflowID) else {
            return nil
        }

        var nextVisiting = visiting
        nextVisiting.insert(workflowID)
        for step in workflow.steps {
            guard let nestedID = nestedWorkflowID(for: step.reference.key) else {
                continue
            }
            if let error = structuralStartError(
                workflowID: nestedID,
                store: store,
                visiting: nextVisiting,
                depth: depth + 1
            ) {
                return error
            }
        }
        return nil
    }

    private static func allLeafActions(
        in workflowID: UUID,
        store: WorkflowStore,
        satisfy predicate: (ActionReference) -> Bool,
        visiting: Set<UUID>,
        depth: Int
    ) -> Bool {
        guard depth < WorkflowExecutionLimits.maximumDepth,
              !visiting.contains(workflowID),
              let workflow = store.workflow(id: workflowID),
              workflow.isEnabled,
              !workflow.steps.isEmpty
        else {
            return false
        }

        var nextVisiting = visiting
        nextVisiting.insert(workflowID)
        return workflow.steps.allSatisfy { step in
            if let nestedID = nestedWorkflowID(for: step.reference.key) {
                return allLeafActions(
                    in: nestedID,
                    store: store,
                    satisfy: predicate,
                    visiting: nextVisiting,
                    depth: depth + 1
                )
            }
            return predicate(step.reference)
        }
    }

    private static func unavailable(_ reason: String) -> WorkflowExecutionAnalysisResult {
        WorkflowExecutionAnalysisResult(
            availability: .unavailable(reason),
            supportsBackground: false,
            supportsUnattendedExecution: false,
            requiresConfirmation: false,
            allowsExternalInvocation: false
        )
    }
}

@MainActor
enum WorkflowPortabilityAnalysis {
    static func portableWorkflowIDs(
        in workflows: [WorkflowDefinition],
        registry: ActionRegistry
    ) -> Set<UUID> {
        portableWorkflowIDs(in: workflows) { registry.portability(of: $0) }
    }

    static func portableWorkflowIDs(
        in workflows: [WorkflowDefinition],
        referencePortability: (ActionReference) -> ActionReferencePortability
    ) -> Set<UUID> {
        let workflowsByID = Dictionary(
            workflows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var memo: [UUID: Bool] = [:]

        func isPortable(_ workflowID: UUID, visiting: Set<UUID>) -> Bool {
            if let cached = memo[workflowID] { return cached }
            guard !visiting.contains(workflowID),
                  let workflow = workflowsByID[workflowID] else {
                memo[workflowID] = false
                return false
            }

            var nextVisiting = visiting
            nextVisiting.insert(workflowID)
            let result = workflow.steps.allSatisfy { step in
                if let nestedID = WorkflowExecutionAnalysis.nestedWorkflowID(
                    for: step.reference.key
                ) {
                    return isPortable(nestedID, visiting: nextVisiting)
                }
                return referencePortability(step.reference) == .portable
            }
            memo[workflowID] = result
            return result
        }

        return Set(workflowsByID.keys.filter { isPortable($0, visiting: []) })
    }
}
