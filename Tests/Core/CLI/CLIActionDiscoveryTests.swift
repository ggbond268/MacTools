import Foundation
import MacToolsCLIProtocol
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class CLIActionDiscoveryTests: XCTestCase {
    private let owner = NSObject()

    func testReadinessEmptyAndMissingTargetsAreDistinct() throws {
        let discovery = CLIActionDiscovery(registry: ActionRegistry())
        XCTAssertThrowsError(try discovery.list(.init()))
        discovery.markReady()
        XCTAssertTrue(try discovery.list(.init()).actions.isEmpty)
        XCTAssertThrowsError(try discovery.describe(.init(id: "test/missing")))
    }

    func testUnavailableIsDiscoverableAndRunLinkPolicyIsIndependent() throws {
        let registry = ActionRegistry()
        var available = false
        var excluded = false
        let action = definition("a")
        registry.synchronize([registration([action], availability: { _ in
            available ? .available : .unavailable("private path or parameter")
        }, exposure: { _, surface in surface == CLIActionDiscovery.surface && excluded ? .excluded : .automatic })])
        let discovery = ready(registry)
        XCTAssertEqual(try discovery.list(.init()).actions.map(\.id), ["test/a"])
        XCTAssertEqual(try discovery.availability(.init(id: "test/a")).reason, .providerUnavailable)
        available = true
        XCTAssertTrue(try discovery.availability(.init(id: "test/a")).available)
        excluded = true
        XCTAssertTrue(try discovery.list(.init()).actions.isEmpty)
        XCTAssertThrowsError(try discovery.describe(.init(id: "test/a")))
        XCTAssertThrowsError(try discovery.availability(.init(id: "test/a")))
    }

    func testOnlyPublishedSafeBackgroundAutomaticActionsAreDiscoverable() throws {
        let registry = ActionRegistry()
        let definitions = [definition("safe"), definition("unpublished"),
                           definition("interactive", capabilities: [.foregroundInteractive, .automatic]),
                           definition("manual", capabilities: [.background])]
        registry.synchronize([registration(definitions, entries: [definitions[0], definitions[2], definitions[3]].map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
        })])
        XCTAssertEqual(try ready(registry).list(.init()).actions.map(\.id), ["test/safe"])
    }

    func testParameterizedReferencesHaveDistinctOpaqueIDsAndNoSavedValues() throws {
        let registry = ActionRegistry()
        let action = definition("parameter", parameters: [.init(id: "value", title: "Value", kind: .string)])
        let entries = try ["saved-first-value", "saved-second-value"].map { value in
            ActionCatalogEntry(reference: ActionReference(key: action.key,
                parameters: try ActionParameterSet(["value": .string(value)])), title: value, subtitle: value)
        }
        registry.synchronize([registration([action], entries: entries)])
        let discovery = ready(registry)
        let page = try discovery.list(.init())
        XCTAssertEqual(page.actions.count, 2)
        XCTAssertNotEqual(page.actions[0].id, page.actions[1].id)
        XCTAssertTrue(page.actions.allSatisfy { $0.id.hasPrefix("test/parameter@") })
        XCTAssertThrowsError(try discovery.describe(.init(id: "test/parameter")))
        for summary in page.actions {
            let record = try discovery.describe(.init(id: summary.id))
            let text = String(decoding: try CLIProtocolCodec.encodeResponse(record), as: UTF8.self)
            XCTAssertFalse(text.contains("saved-"))
            XCTAssertEqual(record.parameters.count, 1)
            XCTAssertFalse(record.executionSupported)
        }
    }

    func testSensitiveAndLocalOnlyReferencesAreExcluded() throws {
        let registry = ActionRegistry()
        let sensitive = definition("sensitive", parameters: [.init(id: "value", title: "Value", kind: .string, privacy: .sensitive)])
        let local = definition("local", parameters: [.init(id: "value", title: "Value", kind: .string, portability: .localOnly)])
        let entries = try [sensitive, local].map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key,
                parameters: try ActionParameterSet(["value": .string("secret")])), title: "secret")
        }
        registry.synchronize([registration([sensitive, local], entries: entries)])
        XCTAssertTrue(try ready(registry).list(.init()).actions.isEmpty)
    }

    func testPagingIsOrderedAndRejectsChangedCatalogAndHostRestart() throws {
        let registry = ActionRegistry()
        let definitions = [definition("c"), definition("b"), definition("a")]
        registry.synchronize([registration(definitions)])
        let discovery = ready(registry)
        let first = try discovery.list(.init(pageSize: 1))
        XCTAssertEqual(first.actions.map(\.id), ["test/a"])
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try discovery.list(.init(pageSize: 2, cursor: cursor))
        XCTAssertEqual(second.actions.map(\.id), ["test/b", "test/c"])
        XCTAssertNil(second.nextCursor)
        XCTAssertThrowsError(try ready(registry).list(.init(cursor: cursor)))
        registry.synchronize([registration([definition("b")])])
        XCTAssertThrowsError(try discovery.list(.init(cursor: cursor)))
    }

    func testMetadataIsBoundedAndTerminalControlCharactersAreRemoved() throws {
        let registry = ActionRegistry()
        let action = ActionDefinition(key: .init(providerID: "test", actionID: "a"),
            title: "Title\u{1b}\n", description: String(repeating: "x", count: 5_000),
            systemImage: "bolt", capabilities: [.background, .automatic])
        registry.synchronize([registration([action])])
        let record = try ready(registry).describe(.init(id: "test/a"))
        XCTAssertEqual(record.title, "Title")
        XCTAssertEqual(record.description.utf8.count, CLIDiscoveryLimits.maximumTextBytes)
    }

    func testOversizedCatalogFailsWithoutPartialResults() {
        let registry = ActionRegistry()
        registry.synchronize([registration((0...CLIDiscoveryLimits.maximumCatalogSize).map { definition("a\($0)") })])
        XCTAssertThrowsError(try ready(registry).list(.init()))
    }

    func testWorkflowChecksEveryDependencyIncludingNestedReferencesAndCycles() throws {
        let registry = ActionRegistry()
        let leaf = definition("leaf")
        var excluded = false
        var child = WorkflowDefinition(name: "Child", steps: [.init(reference: .init(key: leaf.key))])
        var parent = WorkflowDefinition(name: "Parent", steps: [.init(reference: child.actionReference)])
        let workflowDefinitions = [child, parent].map {
            ActionDefinition(key: $0.actionKey, title: $0.name, description: "", systemImage: "bolt",
                             capabilities: [.background, .automatic])
        }
        registry.synchronize([
            registration([leaf], exposure: { _, _ in excluded ? .excluded : .automatic }),
            registration(workflowDefinitions, provider: AutomationController.providerID),
        ])
        let discovery = CLIActionDiscovery(registry: registry, workflows: { [child, parent] })
        discovery.markReady()
        XCTAssertEqual(try discovery.list(.init()).actions.count, 3)
        excluded = true
        XCTAssertTrue(try discovery.list(.init()).actions.isEmpty)
        excluded = false
        parent.steps[0].reference = ActionReference(key: child.actionKey, schemaVersion: 999)
        XCTAssertThrowsError(try discovery.describe(.init(id: parent.actionKey.id)))
        parent.steps[0].reference = child.actionReference
        child.steps[0].reference = parent.actionReference
        XCTAssertEqual(try discovery.list(.init()).actions.map(\.id), ["test/leaf"])
    }

    func testWorkflowDepthLimitCountsWorkflowsNotLeafActions() throws {
        let registry = ActionRegistry()
        let leaf = definition("leaf")
        var workflows: [WorkflowDefinition] = []
        var reference = ActionReference(key: leaf.key)
        for depth in 1...(WorkflowExecutionLimits.maximumDepth + 1) {
            let workflow = WorkflowDefinition(name: "Level \(depth)", steps: [.init(reference: reference)])
            workflows.append(workflow)
            reference = workflow.actionReference
        }
        let definitions = workflows.map {
            ActionDefinition(key: $0.actionKey, title: $0.name, description: "", systemImage: "bolt",
                             capabilities: [.background, .automatic])
        }
        registry.synchronize([registration([leaf]), registration(definitions, provider: AutomationController.providerID)])
        let discovery = CLIActionDiscovery(registry: registry, workflows: { workflows })
        discovery.markReady()
        let supportedID = workflows[WorkflowExecutionLimits.maximumDepth - 1].actionKey.id
        let unsupportedID = workflows[WorkflowExecutionLimits.maximumDepth].actionKey.id
        let ids = try discovery.list(.init()).actions.map(\.id)
        XCTAssertTrue(ids.contains(supportedID))
        XCTAssertFalse(ids.contains(unsupportedID))
        XCTAssertEqual(try discovery.describe(.init(id: supportedID)).id, supportedID)
        XCTAssertThrowsError(try discovery.describe(.init(id: unsupportedID)))
    }

    private func ready(_ registry: ActionRegistry) -> CLIActionDiscovery {
        let value = CLIActionDiscovery(registry: registry)
        value.markReady()
        return value
    }

    private func definition(_ id: String, parameters: [ActionParameterDefinition] = [],
                            capabilities: ActionExecutionCapabilities = [.background, .automatic]) -> ActionDefinition {
        ActionDefinition(key: .init(providerID: "test", actionID: id), title: id, description: "Description",
                         systemImage: "bolt", parameters: parameters, externalInvocationPolicy: .unavailable,
                         capabilities: capabilities)
    }

    private func registration(_ definitions: [ActionDefinition], entries: [ActionCatalogEntry]? = nil,
                              provider: String = "test",
                              availability: @escaping (ActionReference) -> ActionAvailability = { _ in .available },
                              exposure: @escaping (ActionReference, ActionExposureSurface) -> ActionExposurePolicy = { _, _ in .automatic }) -> ActionProviderRegistration {
        ActionProviderRegistration(providerID: provider, identity: ObjectIdentifier(owner), definitions: definitions,
            catalogEntries: entries ?? definitions.map { ActionCatalogEntry(reference: .init(key: $0.key), title: $0.title) },
            availability: availability, exposurePolicy: exposure,
            migrate: { _, _ in XCTFail("Discovery must not migrate or persist references"); return nil },
            begin: { _ in XCTFail("Discovery must not execute actions"); return .failure(.providerChanged) })
    }
}
