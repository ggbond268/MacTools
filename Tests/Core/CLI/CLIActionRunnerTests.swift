import Foundation
import MacToolsCLIProtocol
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class CLIActionRunnerTests: XCTestCase {
    private let owner = NSObject()

    func testRunsEligibleActionWithCLIBackgroundInvocationAndSanitizesSuccess() async throws {
        let registry = ActionRegistry()
        var invocation: ActionInvocation?
        let definition = makeDefinition()
        install(definition, in: registry) { value in
            invocation = value
            return .success(ActionExecutionHandle {
                .succeeded(message: "Done\n\u{1b}" + String(repeating: "x", count: 2_000))
            })
        }
        let runner = makeRunner(registry)
        let result = try await runner.run(.init(id: definition.key.id, timeoutSeconds: 2))
        XCTAssertEqual(invocation?.source, .cli)
        XCTAssertEqual(invocation?.mode, .background)
        XCTAssertEqual(invocation?.reference.parameters, .empty)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertFalse(try XCTUnwrap(result.message).contains("\n"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.message).utf8.count,
                                 CLIDiscoveryLimits.maximumTextBytes)
    }

    func testProviderFailureDoesNotExposeProviderMessage() async throws {
        let registry = ActionRegistry()
        let definition = makeDefinition()
        install(definition, in: registry) { _ in
            .success(ActionExecutionHandle { .failed(message: "/private/secret") })
        }
        do {
            _ = try await makeRunner(registry).run(.init(id: definition.key.id))
            XCTFail("Expected failure")
        } catch {
            guard case CLIActionRunError.failed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTimeoutCancelsHandleEvenWithoutCancellableCapability() async throws {
        let registry = ActionRegistry()
        var didCancel = false
        let definition = makeDefinition(executionTimeout: 30)
        install(definition, in: registry) { _ in
            .success(ActionExecutionHandle(operation: {
                try? await Task.sleep(for: .seconds(10))
                return .succeeded()
            }, cancel: { didCancel = true }))
        }
        do {
            _ = try await makeRunner(registry).run(.init(id: definition.key.id, timeoutSeconds: 1))
            XCTFail("Expected timeout")
        } catch {
            guard case CLIActionRunError.timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(didCancel)
    }

    func testTaskCancellationCancelsHandle() async throws {
        let registry = ActionRegistry()
        var didCancel = false
        let definition = makeDefinition()
        install(definition, in: registry) { _ in
            .success(ActionExecutionHandle(operation: {
                try? await Task.sleep(for: .seconds(10))
                return .succeeded()
            }, cancel: { didCancel = true }))
        }
        let runner = makeRunner(registry)
        let task = Task { try await runner.run(.init(id: definition.key.id)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(didCancel)
    }

    func testTimeoutIncludesWaitingForSerializedAdmission() async throws {
        let registry = ActionRegistry()
        var executions = 0
        var cancellations = 0
        let definition = makeDefinition(concurrencyPolicy: .serialize)
        install(definition, in: registry) { _ in
            executions += 1
            return .success(ActionExecutionHandle(operation: {
                try? await Task.sleep(for: .seconds(10))
                return .succeeded()
            }, cancel: { cancellations += 1 }))
        }
        let runner = makeRunner(registry)
        let first = Task {
            try await runner.run(.init(id: definition.key.id, timeoutSeconds: 10))
        }
        for _ in 0..<100 where executions == 0 {
            await Task.yield()
        }
        XCTAssertEqual(executions, 1)
        do {
            _ = try await runner.run(.init(id: definition.key.id, timeoutSeconds: 1))
            XCTFail("Expected timeout while waiting for serialized admission")
        } catch {
            guard case CLIActionRunError.timedOut = error else {
                first.cancel()
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(executions, 1)
        first.cancel()
        _ = try? await first.value
        XCTAssertEqual(cancellations, 1)
    }

    private func makeRunner(_ registry: ActionRegistry) -> CLIActionRunner {
        let discovery = CLIActionDiscovery(registry: registry)
        discovery.markReady()
        return CLIActionRunner(discovery: discovery, executor: ActionExecutor(registry: registry))
    }

    private func makeDefinition(
        executionTimeout: Double = 30,
        concurrencyPolicy: ActionConcurrencyPolicy = .rejectWhileRunning
    ) -> ActionDefinition {
        ActionDefinition(
            key: .init(providerID: "test", actionID: "run"),
            title: "Run",
            description: "",
            systemImage: "bolt",
            capabilities: [.background, .automatic],
            concurrencyPolicy: concurrencyPolicy,
            executionTimeoutSeconds: executionTimeout
        )
    }

    private func install(
        _ definition: ActionDefinition,
        in registry: ActionRegistry,
        begin: @escaping (ActionInvocation) -> Result<ActionExecutionHandle, ActionRegistryError>
    ) {
        registry.synchronize([ActionProviderRegistration(
            providerID: definition.key.providerID,
            identity: ObjectIdentifier(owner),
            definitions: [definition],
            catalogEntries: [ActionCatalogEntry(reference: .init(key: definition.key), title: definition.title)],
            availability: { _ in .available },
            exposurePolicy: { _, _ in .automatic },
            migrate: { _, _ in nil },
            begin: begin
        )])
    }
}
