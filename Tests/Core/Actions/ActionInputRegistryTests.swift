import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class ActionInputRegistryTests: XCTestCase {
    func testLatePreparationAfterTimeoutReleasesItsSession() async throws {
        let provider = InputTestProvider()
        var continuation: CheckedContinuation<Void, Never>?
        provider.waitForPreparation = {
            await withCheckedContinuation { continuation = $0 }
        }
        let registry = ActionInputRegistry(preparationTimeout: .milliseconds(20))
        registry.synchronize([provider])
        do {
            _ = try await registry.prepare(XCTUnwrap(registry.items.first))
            XCTFail("Preparation should time out")
        } catch {}
        continuation?.resume()
        for _ in 0..<100 where provider.releases == 0 { await Task.yield() }
        XCTAssertEqual(provider.releases, 1)
    }

    func testComposerPreservesMessageAndReleasesOnReset() async throws {
        let provider = InputTestProvider()
        let registry = ActionInputRegistry()
        registry.synchronize([provider])
        let model = CommandPaletteInputModel()
        let item = try XCTUnwrap(registry.items.first)
        model.compose(item, message: "  Hello 👋\n", registry: registry)
        for _ in 0..<100 where model.isBusy { await Task.yield() }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.message, "  Hello 👋\n")
        XCTAssertTrue(model.canSubmit)
        model.reset()
        XCTAssertNil(model.item)
        XCTAssertEqual(model.message, "")
        XCTAssertEqual(provider.releases, 1)
    }

    func testIncompleteInputNeverEntersExecutableCatalog() async throws {
        let provider = InputTestProvider()
        let registry = ActionInputRegistry()
        registry.synchronize([provider])
        XCTAssertTrue(provider.actionCatalogEntries.isEmpty)
        let item = try XCTUnwrap(registry.items.first)
        let session = try await registry.prepare(item)
        let message = "  Hi 👋\nsecond line "
        let reference = try registry.reference(session, message: message)
        XCTAssertEqual(reference.parameters["message"], .string(message))
        XCTAssertNil(ActionRegistry.parameterValidationFailure(reference.parameters, for: item.definition))
        session.release()
        session.release()
        XCTAssertEqual(provider.releases, 1)
        XCTAssertThrowsError(try registry.reference(session, message: message))
    }

    func testProviderReplacementAndSchemaChangeInvalidatePreparedInput() async throws {
        let provider = InputTestProvider()
        let registry = ActionInputRegistry()
        registry.synchronize([provider])
        let item = try XCTUnwrap(registry.items.first)
        let prepared = try await registry.prepare(item)
        registry.synchronize([InputTestProvider()])
        XCTAssertFalse(registry.contains(item))
        XCTAssertThrowsError(try registry.reference(prepared, message: "Hello"))
        prepared.release()
        XCTAssertEqual(provider.releases, 1)
    }

    func testInvalidDescriptorAndPreparedParametersAreRejected() async throws {
        let provider = InputTestProvider()
        let registry = ActionInputRegistry()
        provider.parameterID = "missing"
        registry.synchronize([provider])
        XCTAssertTrue(registry.items.isEmpty)
        provider.parameterID = "message"
        provider.fixed = try ActionParameterSet(["message": .string("injected")])
        registry.synchronize([provider])
        do {
            _ = try await registry.prepare(XCTUnwrap(registry.items.first))
            XCTFail("Provider must not prefill the editable parameter")
        } catch {}
        XCTAssertEqual(provider.releases, 1)
    }

    func testEmptyAndOversizedUnicodeInputRejectedWithoutTrimmingValidInput() async throws {
        let provider = InputTestProvider()
        let registry = ActionInputRegistry()
        registry.synchronize([provider])
        let session = try await registry.prepare(XCTUnwrap(registry.items.first))
        defer { session.release() }
        XCTAssertThrowsError(try registry.reference(session, message: " \n\t"))
        XCTAssertThrowsError(try registry.reference(session, message: String(repeating: "👋", count: 1_025)))
        XCTAssertNoThrow(try registry.reference(session, message: String(repeating: "👋", count: 1_024)))
    }
}

@MainActor
private final class InputTestProvider: MacToolsPlugin, PluginActionProviding, PluginActionInputProviding {
    let metadata = PluginMetadata(id: "test-input", title: "Test", iconName: "text.bubble", iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var releases = 0
    var parameterID = "message"
    var fixed = ActionParameterSet.empty
    var waitForPreparation: (@MainActor () async -> Void)?
    let key = ActionKey(providerID: "test-input", actionID: "ask")
    var actionDefinitions: [ActionDefinition] {
        [.init(key: key, title: "Ask", description: "", systemImage: "text.bubble",
               parameters: [.init(id: "message", title: "Message", kind: .string, privacy: .sensitive, portability: .localOnly)])]
    }
    var actionInputDescriptors: [ActionInputDescriptor] {
        [.init(key: key, parameterID: parameterID, placeholder: "", destination: "Test", submitTitle: "Send")]
    }
    func prepareActionInput(_ descriptor: ActionInputDescriptor) async throws -> ActionInputSession {
        await waitForPreparation?()
        return .init(destination: "Test", parameters: fixed)
    }
    func releaseActionInput(_ session: ActionInputSession) { releases += 1 }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle { ActionExecutionHandle { .succeeded() } }
}
