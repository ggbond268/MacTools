import Foundation
import MacToolsPluginKit

@MainActor
final class AutomationDefinitionStore {
    struct Snapshot: Equatable {
        let workflows: [WorkflowDefinition]
        let rules: [AutomationRule]
    }

    struct LoadResult {
        let snapshot: Snapshot
        let workflowError: String?
        let ruleError: String?

        var isValid: Bool { workflowError == nil && ruleError == nil }
    }

    private struct CombinedEnvelope: Codable {
        let formatVersion: Int
        let workflows: [WorkflowDefinition]
        let rules: [AutomationRule]
    }

    private struct LegacyWorkflowEnvelope: Codable {
        let formatVersion: Int
        let workflows: [WorkflowDefinition]
    }

    private struct LegacyRuleEnvelope: Codable {
        let formatVersion: Int
        let rules: [AutomationRule]
    }

    private enum DefaultsKey {
        static let combined = "automation.definitions.v1"
        static let workflows = "automation.workflows.v1"
        static let rules = "automation.rules.v1"
    }

    private static let currentFormatVersion = 1
    private static let maximumCombinedPayloadByteCount = 3 * 1_024 * 1_024 + 4_096

    let userDefaults: UserDefaults
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let setCombinedValue: (Any?) -> Void

    init(
        userDefaults: UserDefaults,
        setCombinedValue: ((Any?) -> Void)? = nil,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.userDefaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
        self.setCombinedValue = setCombinedValue ?? { value in
            if let value {
                userDefaults.set(value, forKey: DefaultsKey.combined)
            } else {
                userDefaults.removeObject(forKey: DefaultsKey.combined)
            }
        }
    }

    func sharesStorage(with other: AutomationDefinitionStore) -> Bool {
        userDefaults === other.userDefaults
    }

    func load() -> LoadResult {
        if userDefaults.object(forKey: DefaultsKey.combined) != nil {
            return loadCombined()
        }
        return loadLegacy()
    }

    func replaceWorkflows(_ workflows: [WorkflowDefinition]) -> Bool {
        let current = load()
        guard current.isValid else { return false }
        return replace(
            Snapshot(workflows: workflows, rules: current.snapshot.rules),
            allowsRecovery: false
        )
    }

    func replaceRules(_ rules: [AutomationRule]) -> Bool {
        let current = load()
        guard current.isValid else { return false }
        return replace(
            Snapshot(workflows: current.snapshot.workflows, rules: rules),
            allowsRecovery: false
        )
    }

    func replace(_ snapshot: Snapshot, allowsRecovery: Bool) -> Bool {
        let previous = load()
        if !allowsRecovery { guard previous.isValid else { return false } }
        guard WorkflowStore.validationFailure(snapshot.workflows) == nil,
              AutomationRuleStore.validationFailure(snapshot.rules) == nil else {
            return false
        }
        do {
            let workflowData = try encoder.encode(
                LegacyWorkflowEnvelope(
                    formatVersion: WorkflowDefinition.currentFormatVersion,
                    workflows: snapshot.workflows
                )
            )
            let ruleData = try encoder.encode(
                LegacyRuleEnvelope(
                    formatVersion: AutomationRule.currentFormatVersion,
                    rules: snapshot.rules
                )
            )
            guard workflowData.count <= WorkflowStore.maximumPayloadByteCount,
                  ruleData.count <= AutomationRuleStore.maximumPayloadByteCount else {
                return false
            }
            let data = try encoder.encode(
                CombinedEnvelope(
                    formatVersion: Self.currentFormatVersion,
                    workflows: snapshot.workflows,
                    rules: snapshot.rules
                )
            )
            guard data.count <= Self.maximumCombinedPayloadByteCount else { return false }

            let previousValue = userDefaults.object(forKey: DefaultsKey.combined)
            setCombinedValue(data)
            guard userDefaults.data(forKey: DefaultsKey.combined) == data else {
                _ = restore(previousValue, forKey: DefaultsKey.combined)
                return false
            }
            if !previous.isValid || previous.snapshot != snapshot {
                preferencesBackupChangeReporter?.didPersist(.automationDefinitions)
            }
            return true
        } catch {
            return false
        }
    }

    private func loadCombined() -> LoadResult {
        guard let data = userDefaults.data(forKey: DefaultsKey.combined),
              data.count <= Self.maximumCombinedPayloadByteCount else {
            return invalidCombined("definition-payload-too-large-or-invalid")
        }
        do {
            let envelope = try decoder.decode(CombinedEnvelope.self, from: data)
            guard envelope.formatVersion == Self.currentFormatVersion,
                  WorkflowStore.validationFailure(envelope.workflows) == nil,
                  AutomationRuleStore.validationFailure(envelope.rules) == nil else {
                return invalidCombined("invalid-definition-format")
            }
            return LoadResult(
                snapshot: Snapshot(workflows: envelope.workflows, rules: envelope.rules),
                workflowError: nil,
                ruleError: nil
            )
        } catch {
            return invalidCombined("invalid-definition-payload")
        }
    }

    private func loadLegacy() -> LoadResult {
        let workflows = loadLegacyWorkflows()
        let rules = loadLegacyRules()
        return LoadResult(
            snapshot: Snapshot(workflows: workflows.value, rules: rules.value),
            workflowError: workflows.error,
            ruleError: rules.error
        )
    }

    private func loadLegacyWorkflows() -> (value: [WorkflowDefinition], error: String?) {
        guard let data = userDefaults.data(forKey: DefaultsKey.workflows) else {
            return ([], nil)
        }
        guard data.count <= WorkflowStore.maximumPayloadByteCount else {
            return ([], "workflow-payload-too-large")
        }
        do {
            let envelope = try decoder.decode(LegacyWorkflowEnvelope.self, from: data)
            guard envelope.formatVersion == WorkflowDefinition.currentFormatVersion,
                  WorkflowStore.validationFailure(envelope.workflows) == nil else {
                return ([], "invalid-workflow-format")
            }
            return (envelope.workflows, nil)
        } catch {
            return ([], "invalid-workflow-payload")
        }
    }

    private func loadLegacyRules() -> (value: [AutomationRule], error: String?) {
        guard let data = userDefaults.data(forKey: DefaultsKey.rules) else {
            return ([], nil)
        }
        guard data.count <= AutomationRuleStore.maximumPayloadByteCount else {
            return ([], "rule-payload-too-large")
        }
        do {
            let envelope = try decoder.decode(LegacyRuleEnvelope.self, from: data)
            guard envelope.formatVersion == AutomationRule.currentFormatVersion,
                  AutomationRuleStore.validationFailure(envelope.rules) == nil else {
                return ([], "invalid-rule-format")
            }
            return (envelope.rules, nil)
        } catch {
            return ([], "invalid-rule-payload")
        }
    }

    private func invalidCombined(_ error: String) -> LoadResult {
        LoadResult(
            snapshot: Snapshot(workflows: [], rules: []),
            workflowError: error,
            ruleError: error
        )
    }

    private func restore(_ value: Any?, forKey key: String) -> Bool {
        precondition(key == DefaultsKey.combined)
        setCombinedValue(value)
        switch (userDefaults.object(forKey: key), value) {
        case (nil, nil):
            return true
        case let (actual as Data, expected as Data):
            return actual == expected
        default:
            return false
        }
    }
}

private struct WorkflowHistoryEnvelope: Codable {
    let formatVersion: Int
    let runs: [WorkflowRun]
}

/// Foundation documents UserDefaults access as thread-safe. The wrapper makes that guarantee
/// explicit while the main actor reads definitions and the history actor persists run snapshots.
private final class WorkflowHistoryDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private actor WorkflowHistoryPersistence {
    private let defaults: WorkflowHistoryDefaults
    private let key: String
    private let maximumPayloadByteCount: Int
    private let encoder = JSONEncoder()
    private var latestRevision = 0

    init(defaults: WorkflowHistoryDefaults, key: String, maximumPayloadByteCount: Int) {
        self.defaults = defaults
        self.key = key
        self.maximumPayloadByteCount = maximumPayloadByteCount
    }

    func persist(_ runs: [WorkflowRun], coalesced: Bool, revision: Int) -> Bool {
        guard revision >= latestRevision else { return true }
        latestRevision = revision
        guard coalesced else {
            return write(runs)
        }
        Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            await self?.persistIfCurrent(runs, revision: revision)
        }
        return true
    }

    private func persistIfCurrent(_ runs: [WorkflowRun], revision: Int) {
        guard revision == latestRevision else { return }
        _ = write(runs)
    }

    private func write(_ runs: [WorkflowRun]) -> Bool {
        do {
            let data = try encoder.encode(
                WorkflowHistoryEnvelope(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: runs
                )
            )
            guard data.count <= maximumPayloadByteCount else { return false }
            defaults.value.set(data, forKey: key)
            return defaults.value.data(forKey: key) == data
        } catch {
            return false
        }
    }
}

@MainActor
final class WorkflowStore {
    private struct PortableWorkflowEnvelope: Codable {
        let formatVersion: Int
        let rootWorkflowID: UUID?
        let workflows: [WorkflowDefinition]?
        let workflow: WorkflowDefinition?

        init(rootWorkflowID: UUID, workflows: [WorkflowDefinition]) {
            self.formatVersion = WorkflowDefinition.currentFormatVersion
            self.rootWorkflowID = rootWorkflowID
            self.workflows = workflows
            self.workflow = nil
        }
    }

    private enum DefaultsKey {
        static let history = "automation.history.v1"
    }

    static let maximumWorkflowCount = 128
    static let maximumHistoryCount = 256
    static let maximumPayloadByteCount = 2 * 1_024 * 1_024

    private let defaults: WorkflowHistoryDefaults
    private var userDefaults: UserDefaults { defaults.value }
    let definitionStore: AutomationDefinitionStore
    private let historyPersistence: WorkflowHistoryPersistence
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var historyCache: [WorkflowRun]?
    private var historyPersistenceRevision = 0
    private var pendingHistoryPersistenceTask: Task<Bool, Never>?
    private(set) var workflowLoadError: String?
    private(set) var historyLoadError: String?

    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.definitionStore = AutomationDefinitionStore(
            userDefaults: userDefaults,
            preferencesBackupChangeReporter: preferencesBackupChangeReporter
        )
        let defaults = WorkflowHistoryDefaults(userDefaults)
        self.defaults = defaults
        self.historyPersistence = WorkflowHistoryPersistence(
            defaults: defaults,
            key: DefaultsKey.history,
            maximumPayloadByteCount: Self.maximumPayloadByteCount
        )
        recoverInterruptedRuns()
    }

    init(definitionStore: AutomationDefinitionStore) {
        self.definitionStore = definitionStore
        let defaults = WorkflowHistoryDefaults(definitionStore.userDefaults)
        self.defaults = defaults
        self.historyPersistence = WorkflowHistoryPersistence(
            defaults: defaults,
            key: DefaultsKey.history,
            maximumPayloadByteCount: Self.maximumPayloadByteCount
        )
        recoverInterruptedRuns()
    }

    func workflows() -> [WorkflowDefinition] {
        let result = definitionStore.load()
        workflowLoadError = result.workflowError
        return result.snapshot.workflows
    }

    func workflow(id: UUID) -> WorkflowDefinition? {
        workflows().first { $0.id == id }
    }

    @discardableResult
    func create(name: String = FeatureL10n.string("新建工作流")) -> Result<WorkflowDefinition, WorkflowStoreError> {
        var stored = workflows()
        guard workflowLoadError == nil else {
            return .failure(.recoveryRequired)
        }
        guard stored.count < Self.maximumWorkflowCount else {
            return .failure(.maximumWorkflowCountReached)
        }
        let workflow = WorkflowDefinition(name: name)
        stored.append(workflow)
        guard replaceWorkflows(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(workflow)
    }

    @discardableResult
    func upsert(_ workflow: WorkflowDefinition) -> Result<WorkflowDefinition, WorkflowStoreError> {
        if let failure = Self.validationFailure(workflow) {
            return .failure(.invalidWorkflow(failure))
        }
        var stored = workflows()
        guard workflowLoadError == nil else {
            return .failure(.recoveryRequired)
        }
        var updated = workflow
        updated.updatedAt = .now
        if let index = stored.firstIndex(where: { $0.id == workflow.id }) {
            stored[index] = updated
        } else {
            guard stored.count < Self.maximumWorkflowCount else {
                return .failure(.maximumWorkflowCountReached)
            }
            stored.append(updated)
        }
        guard replaceWorkflows(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(updated)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var stored = workflows()
        guard workflowLoadError == nil else { return false }
        let oldCount = stored.count
        stored.removeAll { $0.id == id }
        return stored.count != oldCount && replaceWorkflows(stored)
    }

    func duplicate(id: UUID) -> Result<WorkflowDefinition, WorkflowStoreError> {
        let stored = workflows()
        guard workflowLoadError == nil else {
            return .failure(.recoveryRequired)
        }
        guard let source = stored.first(where: { $0.id == id }) else {
            return .failure(.workflowNotFound)
        }
        var copy = WorkflowDefinition(
            name: byteLimited(
                source.name + FeatureL10n.string(" 副本"),
                maximumByteCount: WorkflowDefinition.maximumNameByteCount
            ),
            systemImage: source.systemImage,
            isEnabled: source.isEnabled,
            steps: source.steps.map {
                WorkflowStep(
                    reference: $0.reference,
                    label: $0.label,
                    delaySeconds: $0.delaySeconds,
                    errorPolicy: $0.errorPolicy
                )
            }
        )
        copy.updatedAt = .now
        return upsert(copy)
    }

    @discardableResult
    func move(id: UUID, offset: Int) -> Bool {
        var stored = workflows()
        guard workflowLoadError == nil else { return false }
        guard let source = stored.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let destination = source + offset
        guard stored.indices.contains(destination) else {
            return false
        }
        let workflow = stored.remove(at: source)
        stored.insert(workflow, at: destination)
        return replaceWorkflows(stored)
    }

    private func byteLimited(_ value: String, maximumByteCount: Int) -> String {
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumByteCount else {
                break
            }
            result = candidate
        }
        return result
    }

    @discardableResult
    func replaceWorkflows(_ workflows: [WorkflowDefinition]) -> Bool {
        guard Self.validationFailure(workflows) == nil else {
            return false
        }
        return definitionStore.replaceWorkflows(workflows)
    }

    @discardableResult
    func replaceDefinitions(
        workflows: [WorkflowDefinition],
        rules: [AutomationRule],
        allowsRecovery: Bool
    ) -> Bool {
        definitionStore.replace(
            AutomationDefinitionStore.Snapshot(workflows: workflows, rules: rules),
            allowsRecovery: allowsRecovery
        )
    }

    @discardableResult
    func migrateReferences(using registry: ActionRegistry) -> Bool {
        var stored = workflows()
        guard workflowLoadError == nil else { return false }
        var changed = false
        for workflowIndex in stored.indices {
            for stepIndex in stored[workflowIndex].steps.indices {
                let reference = stored[workflowIndex].steps[stepIndex].reference
                guard case let .success(migrated) = registry.migrate(reference),
                      migrated != reference else {
                    continue
                }
                stored[workflowIndex].steps[stepIndex].reference = migrated
                stored[workflowIndex].updatedAt = .now
                changed = true
            }
        }
        guard changed else {
            return false
        }
        return replaceWorkflows(stored)
    }

    func history(workflowID: UUID? = nil) -> [WorkflowRun] {
        if let historyCache {
            return workflowID.map { id in
                historyCache.filter { $0.workflowID == id }
            } ?? historyCache
        }
        guard let data = userDefaults.data(forKey: DefaultsKey.history) else {
            historyLoadError = nil
            historyCache = []
            return []
        }
        guard data.count <= Self.maximumPayloadByteCount else {
            historyLoadError = "history-payload-too-large"
            return []
        }
        do {
            let envelope = try decoder.decode(WorkflowHistoryEnvelope.self, from: data)
            guard envelope.formatVersion == WorkflowRun.currentFormatVersion,
                  envelope.runs.count <= Self.maximumHistoryCount,
                  Set(envelope.runs.map(\.id)).count == envelope.runs.count,
                  envelope.runs.allSatisfy({ $0.formatVersion == WorkflowRun.currentFormatVersion })
            else {
                historyLoadError = "invalid-history-format"
                return []
            }
            historyLoadError = nil
            let runs = migrateLegacyHistory(envelope.runs)
            historyCache = runs
            if runs != envelope.runs {
                _ = replaceHistory(runs)
            }
            if let workflowID {
                return runs.filter { $0.workflowID == workflowID }
            }
            return runs
        } catch {
            historyLoadError = "invalid-history-payload"
            return []
        }
    }

    enum HistoryPersistenceMode {
        case immediate
        case coalesced
    }

    @discardableResult
    func record(
        _ run: WorkflowRun,
        persistenceMode: HistoryPersistenceMode = .immediate
    ) async -> Bool {
        guard let update = historyUpdate(for: run) else { return false }
        let runs = update.runs
        historyCache = runs
        let revision = nextHistoryPersistenceRevision()
        let persisted = await historyPersistence.persist(
            runs,
            coalesced: persistenceMode == .coalesced,
            revision: revision
        )
        if !persisted,
           persistenceMode == .immediate,
           revision == historyPersistenceRevision {
            historyCache = update.previousRuns
            historyLoadError = "history-persistence-failed"
        }
        return persisted
    }

    @discardableResult
    func recordWithoutWaitingForPersistence(_ run: WorkflowRun) -> Bool {
        guard let update = historyUpdate(for: run) else { return false }
        historyCache = update.runs
        let runs = update.runs
        let revision = nextHistoryPersistenceRevision()
        pendingHistoryPersistenceTask = Task { [historyPersistence] in
            await historyPersistence.persist(
                runs,
                coalesced: false,
                revision: revision
            )
        }
        return true
    }

    func flushPendingHistoryPersistence() async {
        while let task = pendingHistoryPersistenceTask {
            pendingHistoryPersistenceTask = nil
            _ = await task.value
        }
    }

    private func nextHistoryPersistenceRevision() -> Int {
        historyPersistenceRevision += 1
        return historyPersistenceRevision
    }

    private func historyUpdate(
        for run: WorkflowRun
    ) -> (runs: [WorkflowRun], previousRuns: [WorkflowRun])? {
        let sanitizedRun = migrateLegacyHistory([run])[0]
        var runs = history()
        guard historyLoadError == nil else { return nil }
        let previousRuns = runs
        runs.removeAll { $0.id == sanitizedRun.id }
        runs.insert(sanitizedRun, at: 0)
        if runs.count > Self.maximumHistoryCount {
            runs.removeLast(runs.count - Self.maximumHistoryCount)
        }
        while runs.count > 1, !historyPayloadFits(runs) {
            runs.removeLast()
        }
        guard historyPayloadFits(runs) else {
            historyLoadError = "history-payload-too-large"
            return nil
        }
        return (runs, previousRuns)
    }

    private func historyPayloadFits(_ runs: [WorkflowRun]) -> Bool {
        guard let data = try? encoder.encode(
            WorkflowHistoryEnvelope(
                formatVersion: WorkflowRun.currentFormatVersion,
                runs: runs
            )
        ) else {
            return false
        }
        return data.count <= Self.maximumPayloadByteCount
    }

    func exportWorkflow(
        id: UUID,
        registry: ActionRegistry,
        referencePortability: ((ActionReference) -> ActionReferencePortability)? = nil
    ) -> Result<Data, WorkflowStoreError> {
        let stored = workflows()
        guard workflowLoadError == nil else {
            return .failure(.recoveryRequired)
        }
        guard let workflow = stored.first(where: { $0.id == id }) else {
            return .failure(.workflowNotFound)
        }
        guard WorkflowPortabilityAnalysis.portableWorkflowIDs(
            in: stored,
            referencePortability: referencePortability ?? { registry.portability(of: $0) }
        ).contains(workflow.id) else {
            return .failure(.unsafeForExport)
        }
        let exportedWorkflows = workflowDependencies(rootID: workflow.id, in: stored)
        guard !exportedWorkflows.isEmpty else {
            return .failure(.unsafeForExport)
        }
        do {
            let data = try encoder.encode(
                PortableWorkflowEnvelope(
                    rootWorkflowID: workflow.id,
                    workflows: exportedWorkflows
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return .failure(.invalidWorkflow("payload-too-large"))
            }
            return .success(data)
        } catch {
            return .failure(.persistenceFailed)
        }
    }

    func importWorkflow(_ data: Data) -> Result<WorkflowDefinition, WorkflowStoreError> {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(PortableWorkflowEnvelope.self, from: data),
              envelope.formatVersion == WorkflowDefinition.currentFormatVersion else {
            return .failure(.invalidImport)
        }
        let importedWorkflows = envelope.workflows ?? envelope.workflow.map { [$0] } ?? []
        let rootID = envelope.rootWorkflowID ?? envelope.workflow?.id
        guard let rootID,
              importedWorkflows.count <= Self.maximumWorkflowCount,
              Set(importedWorkflows.map(\.id)).count == importedWorkflows.count,
              importedWorkflows.contains(where: { $0.id == rootID }),
              portableWorkflowGraphIsClosed(
                  rootID: rootID,
                  workflows: importedWorkflows
              ),
              Self.validationFailure(importedWorkflows) == nil else {
            return .failure(.invalidImport)
        }

        let existing = workflows()
        guard workflowLoadError == nil else {
            return .failure(.recoveryRequired)
        }
        guard existing.count + importedWorkflows.count <= Self.maximumWorkflowCount else {
            return .failure(.maximumWorkflowCountReached)
        }
        let existingIDs = Set(existing.map(\.id))
        let remappedIDs = Dictionary(uniqueKeysWithValues: importedWorkflows.map { workflow in
            (workflow.id, existingIDs.contains(workflow.id) ? UUID() : workflow.id)
        })
        let remapped = importedWorkflows.map { workflow in
            remapPortableWorkflow(workflow, ids: remappedIDs)
        }
        guard replaceWorkflows(existing + remapped),
              let importedRootID = remappedIDs[rootID],
              let importedRoot = remapped.first(where: { $0.id == importedRootID }) else {
            return .failure(.persistenceFailed)
        }
        return .success(importedRoot)
    }

    private func workflowDependencies(
        rootID: UUID,
        in workflows: [WorkflowDefinition]
    ) -> [WorkflowDefinition] {
        let byID = Dictionary(workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<UUID>()
        var result: [WorkflowDefinition] = []

        func visit(_ id: UUID) {
            guard visited.insert(id).inserted, let workflow = byID[id] else { return }
            for step in workflow.steps {
                if let nestedID = WorkflowExecutionAnalysis.nestedWorkflowID(for: step.reference.key) {
                    visit(nestedID)
                }
            }
            result.append(workflow)
        }

        visit(rootID)
        return result
    }

    private func portableWorkflowGraphIsClosed(
        rootID: UUID,
        workflows: [WorkflowDefinition]
    ) -> Bool {
        let byID = Dictionary(workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<UUID>()
        var visiting = Set<UUID>()

        func visit(_ id: UUID) -> Bool {
            guard let workflow = byID[id], !visiting.contains(id) else { return false }
            if visited.contains(id) { return true }
            visiting.insert(id)
            for step in workflow.steps {
                guard let nestedID = WorkflowExecutionAnalysis.nestedWorkflowID(for: step.reference.key) else {
                    continue
                }
                guard visit(nestedID) else { return false }
            }
            visiting.remove(id)
            visited.insert(id)
            return true
        }

        return visit(rootID) && visited.count == workflows.count
    }

    private func remapPortableWorkflow(
        _ workflow: WorkflowDefinition,
        ids: [UUID: UUID]
    ) -> WorkflowDefinition {
        let isCopy = ids[workflow.id] != workflow.id
        let steps = workflow.steps.map { step in
            var reference = step.reference
            if let nestedID = WorkflowExecutionAnalysis.nestedWorkflowID(for: reference.key),
               let remappedNestedID = ids[nestedID] {
                reference = WorkflowDefinition(id: remappedNestedID, name: "").actionReference
            }
            return WorkflowStep(
                id: isCopy ? UUID() : step.id,
                reference: reference,
                label: step.label,
                delaySeconds: step.delaySeconds,
                errorPolicy: step.errorPolicy
            )
        }
        return WorkflowDefinition(
            id: ids[workflow.id] ?? workflow.id,
            name: workflow.name,
            systemImage: workflow.systemImage,
            isEnabled: workflow.isEnabled,
            steps: steps,
            createdAt: isCopy ? .now : workflow.createdAt,
            updatedAt: isCopy ? .now : workflow.updatedAt,
            formatVersion: workflow.formatVersion
        )
    }

    private func replaceHistory(_ runs: [WorkflowRun]) -> Bool {
        do {
            let data = try encoder.encode(
                WorkflowHistoryEnvelope(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: runs
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return false
            }
            userDefaults.set(data, forKey: DefaultsKey.history)
            let persisted = userDefaults.data(forKey: DefaultsKey.history) == data
            if persisted {
                historyCache = runs
            }
            return persisted
        } catch {
            return false
        }
    }

    private func recoverInterruptedRuns() {
        var runs = history()
        var changed = false
        for index in runs.indices where runs[index].status == .running {
            runs[index].status = .interrupted
            runs[index].finishedAt = .now
            runs[index].summaryLocalizationKey = .interruptedByExit
            runs[index].summary = WorkflowHistoryLocalizationKey.interruptedByExit.localizedText
            changed = true
        }
        if changed {
            _ = replaceHistory(runs)
        }
    }

    private func migrateLegacyHistory(_ storedRuns: [WorkflowRun]) -> [WorkflowRun] {
        let currentStepsByWorkflowID = Dictionary(
            uniqueKeysWithValues: workflows().map { workflow in
                (
                    workflow.id,
                    Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
                )
            }
        )
        var runs = storedRuns
        for runIndex in runs.indices {
            if runs[runIndex].summaryLocalizationKey == nil,
               let summary = runs[runIndex].summary,
               let key = WorkflowHistoryLocalizationKey(rawValue: summary) {
                runs[runIndex].summaryLocalizationKey = key
            }
            for resultIndex in runs[runIndex].stepResults.indices {
                let currentStep = currentStepsByWorkflowID[runs[runIndex].workflowID]?[
                    runs[runIndex].stepResults[resultIndex].stepID
                ]
                let currentLabel = currentStep?.label
                runs[runIndex].stepResults[resultIndex].titleSource =
                    currentLabel?.isEmpty == false
                        && runs[runIndex].stepResults[resultIndex].title == currentLabel
                            ? .custom
                            : .action
                let existingReference = runs[runIndex].stepResults[resultIndex].actionReference
                let presentationReference = ActionReference(
                    key: runs[runIndex].stepResults[resultIndex].actionKey,
                    schemaVersion: existingReference?.schemaVersion
                        ?? currentStep?.reference.schemaVersion
                        ?? 1
                )
                if existingReference != presentationReference {
                    runs[runIndex].stepResults[resultIndex].actionReference = presentationReference
                }
                if runs[runIndex].stepResults[resultIndex].titleSource == .action,
                   runs[runIndex].stepResults[resultIndex].title
                    != runs[runIndex].stepResults[resultIndex].actionKey.id {
                    runs[runIndex].stepResults[resultIndex].title =
                        runs[runIndex].stepResults[resultIndex].actionKey.id
                }
                if runs[runIndex].stepResults[resultIndex].messageLocalizationKey == nil,
                   let message = runs[runIndex].stepResults[resultIndex].message,
                   let key = WorkflowHistoryLocalizationKey(rawValue: message) {
                    runs[runIndex].stepResults[resultIndex].messageLocalizationKey = key
                }
            }
        }
        return runs
    }

    static func validationFailure(_ workflows: [WorkflowDefinition]) -> String? {
        guard workflows.count <= Self.maximumWorkflowCount,
              Set(workflows.map(\.id)).count == workflows.count else {
            return "workflow-count-or-id"
        }
        return workflows.lazy.compactMap(validationFailure).first
    }

    private static func validationFailure(_ workflow: WorkflowDefinition) -> String? {
        let trimmedName = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workflow.formatVersion == WorkflowDefinition.currentFormatVersion,
              !trimmedName.isEmpty,
              workflow.name.utf8.count <= WorkflowDefinition.maximumNameByteCount,
              !workflow.systemImage.isEmpty,
              workflow.systemImage.utf8.count <= 128,
              workflow.steps.count <= WorkflowDefinition.maximumStepCount,
              Set(workflow.steps.map(\.id)).count == workflow.steps.count else {
            return "workflow-fields"
        }
        for step in workflow.steps {
            guard step.delaySeconds.isFinite,
                  (0 ... WorkflowStep.maximumDelaySeconds).contains(step.delaySeconds),
                  (step.label?.utf8.count ?? 0) <= WorkflowStep.maximumLabelByteCount else {
                return "step-fields"
            }
        }
        return nil
    }
}
