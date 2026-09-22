import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class WorkflowStoreTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "WorkflowStoreTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCreateUpdateDuplicateAndDeletePreserveStableReferences() throws {
        let store = try makeStore()
        let created = try store.create(name: "演示模式").get()
        let step = WorkflowStep(
            reference: ActionReference(
                key: ActionKey(providerID: "keep-awake", actionID: "set-enabled"),
                parameters: try ActionParameterSet(["enabled": .boolean(true)])
            ),
            delaySeconds: 1.5,
            errorPolicy: .continueRunning
        )
        var updated = created
        updated.steps = [step]
        updated.name = "演示模式 2"

        let saved = try store.upsert(updated).get()
        let duplicate = try store.duplicate(id: saved.id).get()

        XCTAssertEqual(store.workflow(id: saved.id)?.steps, [step])
        XCTAssertNotEqual(duplicate.id, saved.id)
        XCTAssertNotEqual(duplicate.steps.first?.id, step.id)
        XCTAssertEqual(duplicate.steps.first?.reference, step.reference)
        XCTAssertTrue(store.delete(id: saved.id))
        XCTAssertNil(store.workflow(id: saved.id))
        XCTAssertNotNil(store.workflow(id: duplicate.id))
    }

    func testWorkflowOrderMovesAndPersistsAcrossReload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let first = try store.create(name: "第一").get()
        let second = try store.create(name: "第二").get()
        let third = try store.create(name: "第三").get()

        XCTAssertTrue(store.move(id: third.id, offset: -1))
        XCTAssertEqual(store.workflows().map(\.id), [first.id, third.id, second.id])
        XCTAssertFalse(store.move(id: first.id, offset: -1))

        let reloaded = WorkflowStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.workflows().map(\.id), [first.id, third.id, second.id])
    }

    func testInvalidAndCorruptPayloadsFailClosedWithoutDeletingStoredBytes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "automation.workflows.v1"
        let store = WorkflowStore(userDefaults: defaults)

        var invalid = WorkflowDefinition(name: "无效")
        invalid.steps = [
            WorkflowStep(
                reference: ActionReference(
                    key: ActionKey(providerID: "test-provider", actionID: "run")
                ),
                delaySeconds: WorkflowStep.maximumDelaySeconds + 1
            ),
        ]
        XCTAssertEqual(
            store.upsert(invalid),
            .failure(.invalidWorkflow("step-fields"))
        )

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: key)
        XCTAssertTrue(store.workflows().isEmpty)
        XCTAssertEqual(store.workflowLoadError, "invalid-workflow-payload")
        XCTAssertEqual(store.create(name: "不得覆盖"), .failure(.recoveryRequired))
        XCTAssertFalse(store.delete(id: UUID()))
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testUnavailableReferencesRemainStoredAndMigrateWhenProviderReturns() throws {
        let store = try makeStore()
        let key = ActionKey(providerID: "test-provider", actionID: "versioned")
        let legacy = ActionReference(key: key, schemaVersion: 1)
        let workflow = WorkflowDefinition(
            name: "迁移",
            steps: [WorkflowStep(reference: legacy)]
        )
        _ = try store.upsert(workflow).get()
        let registry = ActionRegistry()

        XCTAssertFalse(store.migrateReferences(using: registry))
        XCTAssertEqual(store.workflow(id: workflow.id)?.steps.first?.reference, legacy)

        let provider = WorkflowStoreTestProvider()
        let current = ActionReference(key: key, schemaVersion: 2)
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [
                    ActionDefinition(
                        key: key,
                        parameterSchemaVersion: 2,
                        title: "版本操作",
                        description: "",
                        systemImage: "bolt"
                    ),
                ],
                catalogEntries: [ActionCatalogEntry(reference: current, title: "版本操作")],
                availability: { _ in .available },
                migrate: { reference, version in
                    ActionReference(
                        key: reference.key,
                        schemaVersion: version,
                        parameters: reference.parameters
                    )
                },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])

        XCTAssertTrue(store.migrateReferences(using: registry))
        XCTAssertEqual(store.workflow(id: workflow.id)?.steps.first?.reference, current)
    }

    func testHistoryIsBoundedPrivacySafeAndRunningRecordsRecoverAsInterrupted() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let workflowID = UUID()
        let running = WorkflowRun(
            workflowID: workflowID,
            workflowName: "未完成",
            source: .manual,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let recordedRunningRun = await store.record(running)
        XCTAssertTrue(recordedRunningRun)

        let recovered = WorkflowStore(userDefaults: defaults)
        let run = try XCTUnwrap(recovered.history().first)

        XCTAssertEqual(run.status, .interrupted)
        XCTAssertNotNil(run.finishedAt)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(run), as: UTF8.self).contains("secret")
        )

        for index in 0..<(WorkflowStore.maximumHistoryCount + 5) {
            _ = await recovered.record(
                WorkflowRun(
                    workflowID: workflowID,
                    workflowName: "记录 \(index)",
                    source: .manual
                )
            )
        }
        XCTAssertEqual(recovered.history().count, WorkflowStore.maximumHistoryCount)
    }

    func testPortableExportRejectsSensitiveAndLocalOnlyParameters() throws {
        let store = try makeStore()
        let registry = ActionRegistry()
        let provider = WorkflowStoreTestProvider()
        let key = ActionKey(providerID: "test-provider", actionID: "portable")
        let definition = ActionDefinition(
            key: key,
            title: "导出",
            description: "",
            systemImage: "square.and.arrow.up",
            parameters: [
                ActionParameterDefinition(
                    id: "value",
                    title: "值",
                    kind: .string,
                    privacy: .sensitive,
                    portability: .localOnly
                ),
            ]
        )
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["value": .string("secret")])
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "导出")],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let workflow = try store.upsert(
            WorkflowDefinition(name: "敏感", steps: [WorkflowStep(reference: reference)])
        ).get()

        XCTAssertEqual(store.exportWorkflow(id: workflow.id, registry: registry), .failure(.unsafeForExport))
    }

    func testPortableWorkflowRoundTripCreatesFreshStableIdentity() throws {
        let store = try makeStore()
        let registry = ActionRegistry()
        let provider = WorkflowStoreTestProvider()
        let key = ActionKey(providerID: "test-provider", actionID: "portable")
        let definition = ActionDefinition(
            key: key,
            title: "导出",
            description: "",
            systemImage: "square.and.arrow.up",
            parameters: [
                ActionParameterDefinition(id: "value", title: "值", kind: .string),
            ]
        )
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["value": .string("public")])
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "导出")],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let original = try store.upsert(
            WorkflowDefinition(name: "便携", steps: [WorkflowStep(reference: reference)])
        ).get()
        let data = try store.exportWorkflow(id: original.id, registry: registry).get()

        let imported = try store.importWorkflow(data).get()

        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNotEqual(imported.steps.first?.id, original.steps.first?.id)
        XCTAssertEqual(imported.steps.first?.reference, original.steps.first?.reference)
        XCTAssertEqual(store.workflows().count, 2)
    }

    func testPortableWorkflowExportIncludesNestedWorkflowDependencies() throws {
        let sourceStore = try makeStore()
        let registry = ActionRegistry()
        let provider = WorkflowStoreTestProvider()
        let key = ActionKey(providerID: "test-provider", actionID: "portable-nested")
        let definition = ActionDefinition(
            key: key,
            title: "Portable",
            description: "",
            systemImage: "checkmark"
        )
        let reference = ActionReference(key: key)
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "Portable")],
                availability: { _ in .available },
                begin: { _ in .success(ActionExecutionHandle { .succeeded() }) }
            ),
        ])
        let child = try sourceStore.upsert(
            WorkflowDefinition(name: "Child", steps: [WorkflowStep(reference: reference)])
        ).get()
        let parent = try sourceStore.upsert(
            WorkflowDefinition(name: "Parent", steps: [WorkflowStep(reference: child.actionReference)])
        ).get()

        let data = try sourceStore.exportWorkflow(id: parent.id, registry: registry).get()
        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: "\(suiteName).nested-destination"))
        destinationDefaults.removePersistentDomain(forName: "\(suiteName).nested-destination")
        defer { destinationDefaults.removePersistentDomain(forName: "\(suiteName).nested-destination") }
        let destinationStore = WorkflowStore(userDefaults: destinationDefaults)

        let importedParent = try destinationStore.importWorkflow(data).get()

        XCTAssertEqual(destinationStore.workflows().count, 2)
        let importedChildID = try XCTUnwrap(
            WorkflowExecutionAnalysis.nestedWorkflowID(
                for: try XCTUnwrap(importedParent.steps.first).reference.key
            )
        )
        XCTAssertEqual(destinationStore.workflow(id: importedChildID)?.name, "Child")
    }

    func testPortableWorkflowImportRejectsIncompleteNestedGraph() throws {
        let store = try makeStore()
        let registry = ActionRegistry()
        let child = try store.upsert(WorkflowDefinition(name: "Child")).get()
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )).get()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try store.exportWorkflow(id: parent.id, registry: registry).get()
            ) as? [String: Any]
        )
        let workflows = try XCTUnwrap(json["workflows"] as? [[String: Any]])
        json["workflows"] = workflows.filter {
            ($0["id"] as? String)?.lowercased() != child.id.uuidString.lowercased()
        }

        let damaged = try JSONSerialization.data(withJSONObject: json)

        XCTAssertEqual(store.importWorkflow(damaged), .failure(.invalidImport))
    }

    func testPortableWorkflowImportRejectsCyclicNestedGraph() throws {
        let store = try makeStore()
        let registry = ActionRegistry()
        let child = try store.upsert(WorkflowDefinition(name: "Child")).get()
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )).get()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try store.exportWorkflow(id: parent.id, registry: registry).get()
            ) as? [String: Any]
        )
        var workflows = try XCTUnwrap(json["workflows"] as? [[String: Any]])
        let childIndex = try XCTUnwrap(workflows.firstIndex {
            ($0["id"] as? String)?.lowercased() == child.id.uuidString.lowercased()
        })
        var childJSON = workflows[childIndex]
        var steps = (childJSON["steps"] as? [[String: Any]]) ?? []
        let parentReferenceData = try JSONEncoder().encode(parent.actionReference)
        let parentReferenceJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: parentReferenceData) as? [String: Any]
        )
        steps.append([
            "id": UUID().uuidString,
            "reference": parentReferenceJSON,
            "delaySeconds": 0,
            "errorPolicy": "stop",
        ])
        childJSON["steps"] = steps
        workflows[childIndex] = childJSON
        json["workflows"] = workflows

        let damaged = try JSONSerialization.data(withJSONObject: json)

        XCTAssertEqual(store.importWorkflow(damaged), .failure(.invalidImport))
    }

    private func makeStore() throws -> WorkflowStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return WorkflowStore(userDefaults: defaults)
    }

}

@MainActor
private final class WorkflowStoreTestProvider {}
