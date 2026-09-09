import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteInputModelTests: XCTestCase {
    func testMarkedTextBlocksSubmissionUntilCompositionFinishes() async throws {
        let fixture = try InputModelFixture()
        defer { fixture.close() }
        let model = CommandPaletteInputModel()
        model.compose(fixture.item, message: "Hello ", registry: fixture.host.actionInputRegistry)
        try await finishPreparing(model)
        model.isComposingText = true
        XCTAssertFalse(model.canSubmit)
        model.submit(fixture.item, message: model.message, host: fixture.host, onStarted: {})
        XCTAssertTrue(fixture.provider.invocations.isEmpty)
        XCTAssertFalse(model.isBusy)
        model.message = "Hello 你好"
        model.isComposingText = false
        XCTAssertTrue(model.canSubmit)
        model.submit(fixture.item, message: model.message, host: fixture.host, onStarted: {})
        try await finishPreparing(model)
        XCTAssertEqual(fixture.provider.invocations.first?.reference.parameters["message"], .string("Hello 你好"))
        XCTAssertEqual(fixture.provider.releases, 1)
    }

    func testInlineRejectsResolvedDestinationDifferentFromPreview() async throws {
        let fixture = try InputModelFixture()
        defer { fixture.close() }
        let model = CommandPaletteInputModel()
        model.submit(fixture.item, message: "Hello", host: fixture.host, onStarted: {})
        try await finishPreparing(model)
        XCTAssertTrue(fixture.provider.invocations.isEmpty)
        XCTAssertNotNil(model.feedback)
        XCTAssertEqual(fixture.provider.releases, 1)
    }

    func testComposerCanSubmitToTheResolvedDestinationItDisplays() async throws {
        let fixture = try InputModelFixture()
        defer { fixture.close() }
        let model = CommandPaletteInputModel()
        model.compose(fixture.item, message: "Hello", registry: fixture.host.actionInputRegistry)
        try await finishPreparing(model)
        XCTAssertEqual(model.destination, "Account B")
        model.submit(fixture.item, message: model.message, host: fixture.host, onStarted: {})
        try await finishPreparing(model)
        XCTAssertEqual(fixture.provider.invocations.count, 1)
        XCTAssertEqual(fixture.provider.invocations.first?.reference.parameters["account"], .string("account-b"))
        XCTAssertEqual(fixture.provider.releases, 1)
    }

    private func finishPreparing(_ model: CommandPaletteInputModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }
}

@MainActor
private final class InputModelFixture {
    let provider = InputModelProvider()
    let suite = "CommandPaletteInputModelTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let host: PluginHost
    var item: ActionInputItem { host.actionInputRegistry.items[0] }

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        host = PluginHost(plugins: [provider], shortcutStore: ShortcutStore(userDefaults: defaults),
                          pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
                          preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                          globalShortcutManager: GlobalShortcutManager())
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class InputModelProvider: MacToolsPlugin, PluginActionProviding, PluginActionInputProviding {
    let metadata = PluginMetadata(id: "input-fixture", title: "Input", iconName: "text.bubble", iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    let key = ActionKey(providerID: "input-fixture", actionID: "send")
    var invocations: [ActionInvocation] = []
    var releases = 0
    var actionDefinitions: [ActionDefinition] {
        [.init(key: key, title: "Send", description: "", systemImage: "text.bubble", parameters: [
            .init(id: "message", title: "Message", kind: .string, privacy: .sensitive, portability: .localOnly),
            .init(id: "account", title: "Account", kind: .string, privacy: .sensitive, portability: .localOnly),
        ], capabilities: [.foregroundInteractive])]
    }
    var actionInputDescriptors: [ActionInputDescriptor] {
        [.init(key: key, parameterID: "message", placeholder: "Message", destination: "Account A", submitTitle: "Send")]
    }
    func prepareActionInput(_ descriptor: ActionInputDescriptor) async throws -> ActionInputSession {
        .init(destination: "Account B", parameters: try ActionParameterSet(["account": .string("account-b")]))
    }
    func releaseActionInput(_ session: ActionInputSession) { releases += 1 }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        invocations.append(invocation)
        return ActionExecutionHandle { .succeeded() }
    }
}
