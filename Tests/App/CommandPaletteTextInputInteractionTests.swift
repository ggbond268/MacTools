import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteTextInputInteractionTests: XCTestCase {
    func testNativeInlineCompositionBlocksReturnUntilCommittedTextIsCurrent() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let field = try await fixture.searchField()
        try fixture.type("ask fixture Hello ", into: field)
        await fixture.settle()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        await fixture.settle()
        XCTAssertTrue(editor.hasMarkedText())
        let coordinator = try XCTUnwrap(field.delegate as? CommandPaletteSearchField.Coordinator)
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await fixture.settle()
        XCTAssertTrue(fixture.provider.messages.isEmpty)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        await fixture.settle()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(field.stringValue, "ask fixture Hello 你")
        try fixture.pressReturn(in: field)
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, ["Hello 你"])
    }

    func testNewAliasConflictBlocksAlreadyVisibleInlineAction() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let field = try await fixture.searchField()
        try fixture.type("ask fixture Keep this", into: field)
        await fixture.settle()
        let conflicting = PaletteInputProvider(id: "conflicting-fixture")
        fixture.host.actionInputRegistry.synchronize([fixture.provider, conflicting])
        fixture.host.objectWillChange.send()
        await fixture.settle()
        try fixture.pressReturn(in: field)
        await fixture.settle()
        XCTAssertTrue(fixture.provider.messages.isEmpty)
        XCTAssertTrue(conflicting.messages.isEmpty)
        XCTAssertEqual(field.stringValue, "ask fixture Keep this")
    }

    func testNewAliasConflictAlsoBlocksBareAliasComposerEntry() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let field = try await fixture.searchField()
        try fixture.type("ask fixture", into: field)
        await fixture.settle()
        let conflicting = PaletteInputProvider(id: "conflicting-fixture")
        fixture.host.actionInputRegistry.synchronize([fixture.provider, conflicting])
        fixture.host.objectWillChange.send()
        await fixture.settle()
        try fixture.pressReturn(in: field)
        await fixture.settle()
        XCTAssertNil(fixture.messageEditor)
        XCTAssertEqual(fixture.provider.preparations, 0)
        XCTAssertTrue(fixture.provider.messages.isEmpty)
    }

    func testPanelRequestRoutesToComposerWithoutSendingAndRejectsForeignAction() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let router = AppWindowRouter(pluginHost: fixture.host, appUpdater: AppUpdater(startingUpdater: false),
                                     menuBarIconSettings: MenuBarIconSettings(userDefaults: fixture.defaults),
                                     menuBarIconGallery: MenuBarIconGalleryLibrary(),
                                     launchAtLoginController: LaunchAtLoginController(),
                                     appearanceUserDefaults: fixture.defaults)
        defer { router.dismissCommandPalette() }
        var requests: [AppPresentationRequest] = []
        fixture.host.appPresentationHandler = { request in
            requests.append(request)
            if case let .composeActionInput(item) = request { router.showCommandPalette(input: item) }
        }
        fixture.provider.requestActionInput?(ActionKey(providerID: "foreign", actionID: "ask"))
        XCTAssertTrue(requests.isEmpty)
        fixture.provider.requestActionInput?(fixture.provider.key)
        await fixture.settle()
        let content = try XCTUnwrap(router.commandPalettePanel?.contentView)
        let editor = try XCTUnwrap(fixture.descendants(content).compactMap { $0 as? NSTextView }.first {
            $0.accessibilityIdentifier() == "mactools.action-input.message"
        })
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(fixture.provider.messages.isEmpty)
        editor.insertText("From the panel", replacementRange: NSRange(location: 0, length: 0))
        await fixture.settle()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, ["From the panel"])
    }

    func testInlineReturnExecutesExactSuffixWithoutOpeningComposer() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let search = try await fixture.searchField()
        try fixture.type("ask fixture   Hello 👋", into: search)
        await fixture.settle()
        XCTAssertTrue(fixture.provider.messages.isEmpty, "Recognizing an alias must not execute it")
        XCTAssertNil(fixture.messageEditor)
        try fixture.pressReturn(in: search)
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, ["  Hello 👋"])
        XCTAssertEqual(fixture.dismissals, 1)
        XCTAssertTrue(fixture.recents.references.isEmpty, "Prompt content must never become a recent action")
    }

    func testTabCompletesSelectedActionUsingCustomTriggerWithoutPreparingOrSending() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let item = try XCTUnwrap(fixture.host.actionInputRegistry.items.first)
        try fixture.host.setActionInputAlias("hey fixture", for: item)
        let field = try await fixture.searchField()
        try fixture.type("ask", into: field)
        await fixture.settle()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        await fixture.settle()
        XCTAssertEqual(field.stringValue, "hey fixture ")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 12, length: 0))
        XCTAssertEqual(fixture.provider.preparations, 0)
        XCTAssertTrue(fixture.provider.messages.isEmpty)
        XCTAssertNil(fixture.messageEditor)
        editor.insertText("你好 👋", replacementRange: editor.selectedRange())
        await fixture.settle()
        try fixture.pressReturn(in: field)
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, ["你好 👋"])
    }

    func testTabDoesNotCompleteMarkedTextOrReplaceAnInlineMessage() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let field = try await fixture.searchField()
        try fixture.type("ask", into: field)
        await fixture.settle()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let coordinator = try XCTUnwrap(field.delegate as? CommandPaletteSearchField.Coordinator)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        editor.unmarkText()
        try fixture.type("ask fixture keep this", into: field)
        await fixture.settle()
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(field.stringValue, "ask fixture keep this")
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertTrue(fixture.provider.messages.isEmpty)
    }

    func testSettingsFieldCommitsCustomTriggerWithNativeReturn() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let item = try XCTUnwrap(fixture.host.actionInputRegistry.items.first)
        fixture.window.contentView = NSHostingView(rootView:
            CommandPaletteAliasSettingsRow(pluginHost: fixture.host, item: item).padding())
        let field = try await fixture.searchField(identifier: "mactools.action-input.alias")
        try fixture.type("hey fixture", into: field)
        try fixture.pressReturn(in: field)
        await fixture.settle()
        XCTAssertEqual(fixture.host.actionInputAliases.aliases(for: item), ["hey fixture"])
        XCTAssertEqual(CommandPaletteAliasStore(defaults: fixture.defaults).aliases(for: item), ["hey fixture"])
        XCTAssertTrue(fixture.provider.messages.isEmpty)
    }

    func testCustomTriggerUpdatesOpenPaletteAndSendsExactSuffix() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let search = try await fixture.searchField()
        try fixture.type("ask fixture old", into: search)
        let item = try XCTUnwrap(fixture.host.actionInputRegistry.items.first)
        try fixture.host.setActionInputAlias("hey fixture", for: item)
        await fixture.settle()
        XCTAssertNil(fixture.host.commandPaletteAliasResolver.resolve("ask fixture old"))
        try fixture.type("HEY FIXTURE  你好 👋", into: search)
        await fixture.settle()
        try fixture.pressReturn(in: search)
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, [" 你好 👋"])
        XCTAssertEqual(fixture.dismissals, 1)
        XCTAssertTrue(fixture.recents.references.isEmpty)
    }

    func testChangingTriggerPreservesOpenComposerAndItsDraft() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let search = try await fixture.searchField()
        try fixture.type("ask fixture", into: search)
        await fixture.settle()
        try fixture.pressReturn(in: search)
        await fixture.settle()
        let editor = try XCTUnwrap(fixture.messageEditor)
        editor.insertText("Keep my draft", replacementRange: NSRange(location: 0, length: 0))
        await fixture.settle()
        let item = try XCTUnwrap(fixture.host.actionInputRegistry.items.first)
        try fixture.host.setActionInputAlias("new phrase", for: item)
        await fixture.settle()
        XCTAssertEqual(editor.string, "Keep my draft")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, ["Keep my draft"])
        XCTAssertEqual(fixture.provider.releases, 1)
    }

    func testBackAfterTriggerChangeDoesNotRetainRemovedInlineAlias() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let search = try await fixture.searchField()
        try fixture.type("ask fixture", into: search)
        await fixture.settle()
        try fixture.pressReturn(in: search)
        await fixture.settle()
        let editor = try XCTUnwrap(fixture.messageEditor)
        let item = try XCTUnwrap(fixture.host.actionInputRegistry.items.first)
        try fixture.host.setActionInputAlias("new phrase", for: item)
        await fixture.settle()
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await fixture.settle()
        XCTAssertNil(fixture.messageEditor)
        let field = try await fixture.searchField()
        fixture.window.makeFirstResponder(field)
        let searchEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        searchEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await fixture.settle()
        XCTAssertEqual(fixture.dismissals, 1, "Escape should dismiss ordinary search instead of clearing a stale alias")
    }

    func testBareAliasReturnOpensComposerAndSecondReturnSends() async throws {
        let fixture = try PaletteFixture()
        defer { fixture.close() }
        let search = try await fixture.searchField()
        try fixture.type("ask fixture", into: search)
        await fixture.settle()
        try fixture.pressReturn(in: search)
        await fixture.settle()
        let editor = try XCTUnwrap(fixture.messageEditor)
        XCTAssertTrue(fixture.provider.messages.isEmpty)
        editor.insertText("Hi\n第二行", replacementRange: NSRange(location: 0, length: 0))
        await fixture.settle()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await fixture.settle()
        XCTAssertEqual(fixture.provider.messages, ["Hi\n第二行"])
        XCTAssertEqual(fixture.dismissals, 1)
        XCTAssertEqual(fixture.provider.releases, 1)
    }
}

@MainActor
private final class PaletteFixture {
    let provider = PaletteInputProvider()
    let defaults: UserDefaults
    let suite = "CommandPaletteTextInputInteractionTests-\(UUID().uuidString)"
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 720, height: 620),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let host: PluginHost
    let recents: CommandPaletteRecentStore
    var dismissals = 0

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        recents = CommandPaletteRecentStore(userDefaults: defaults)
        host = PluginHost(plugins: [provider], shortcutStore: ShortcutStore(userDefaults: defaults),
                              pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
                              preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                              globalShortcutManager: GlobalShortcutManager())
        let view = UnifiedSearchPaletteView(
            pluginHost: host, launchAtLoginController: LaunchAtLoginController(),
            appearanceUserDefaults: defaults, recentStore: recents,
            availableSize: CGSize(width: 720, height: 620), presentationOrigin: nil,
            focusRequestID: 1, resetRequestID: nil, quickSelectionRequest: nil, showsCustomShadow: false,
            actions: UnifiedSearchPaletteActions(dismiss: { [weak self] in self?.dismissals += 1 }, dismissAfterSuccessfulExecution: { [weak self] in
                self?.dismissals += 1
            }, navigate: { _, _ in false }, consumeQuickSelection: { _ in false }, setPendingExecutionCancellation: { _ in })
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
    }
    func close() {
        window.contentView = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var views: [NSView] { window.contentView.map(descendants) ?? [] }
    var messageEditor: NSTextView? {
        views.compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "mactools.action-input.message" }
    }
    func searchField(identifier: String = "mactools.unified-search.field") async throws -> NSTextField {
        for _ in 0..<60 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let field = views.compactMap({ $0 as? NSTextField }).first(where: {
                $0.accessibilityIdentifier() == identifier || (identifier == "mactools.action-input.alias" && $0.isEditable)
            }) { return field }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == identifier || (identifier == "mactools.action-input.alias" && $0.isEditable)
        })
    }
    func type(_ text: String, into field: NSTextField) throws {
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    func pressReturn(in field: NSTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
}

@MainActor
private final class PaletteInputProvider: MacToolsPlugin, PluginActionProviding, PluginActionInputProviding, PluginActionInputPresentationRequesting {
    let metadata: PluginMetadata
    var requestActionInput: ((ActionKey) -> Void)?
    init(id: String = "palette-fixture") {
        metadata = PluginMetadata(id: id, title: "Fixture", iconName: "text.bubble", iconTint: .blue, order: 0, defaultDescription: "")
        key = ActionKey(providerID: id, actionID: "ask")
    }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    let key: ActionKey
    var messages: [String] = []
    var releases = 0
    var preparations = 0
    var actionDefinitions: [ActionDefinition] {
        [.init(key: key, title: "Ask Fixture", description: "", systemImage: "text.bubble", parameters: [
            .init(id: "message", title: "Message", kind: .string, privacy: .sensitive, portability: .localOnly),
        ], capabilities: [.foregroundInteractive])]
    }
    var actionInputDescriptors: [ActionInputDescriptor] {
        [.init(key: key, parameterID: "message", placeholder: "Message", destination: "Fixture · New Conversation", submitTitle: "Send", aliases: ["ask fixture"])]
    }
    func prepareActionInput(_ descriptor: ActionInputDescriptor) async throws -> ActionInputSession {
        preparations += 1
        return .init(destination: descriptor.destination)
    }
    func releaseActionInput(_ session: ActionInputSession) { releases += 1 }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if case let .string(message)? = invocation.reference.parameters["message"] { messages.append(message) }
        return ActionExecutionHandle { .succeeded() }
    }
}
