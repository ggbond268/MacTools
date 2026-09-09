import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteTextInputInteractionTests: XCTestCase {
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
    let recents: CommandPaletteRecentStore
    var dismissals = 0

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        recents = CommandPaletteRecentStore(userDefaults: defaults)
        let host = PluginHost(plugins: [provider], shortcutStore: ShortcutStore(userDefaults: defaults),
                              pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
                              preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                              globalShortcutManager: GlobalShortcutManager())
        let view = UnifiedSearchPaletteView(
            pluginHost: host, launchAtLoginController: LaunchAtLoginController(),
            appearanceUserDefaults: defaults, recentStore: recents,
            availableSize: CGSize(width: 720, height: 620), presentationOrigin: nil,
            focusRequestID: 1, resetRequestID: nil, quickSelectionRequest: nil, showsCustomShadow: false,
            actions: UnifiedSearchPaletteActions(dismiss: {}, dismissAfterSuccessfulExecution: { [weak self] in
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
    func searchField() async throws -> NSTextField {
        for _ in 0..<60 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let field = views.compactMap({ $0 as? NSTextField }).first(where: {
                $0.accessibilityIdentifier() == "mactools.unified-search.field"
            }) { return field }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "mactools.unified-search.field"
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
private final class PaletteInputProvider: MacToolsPlugin, PluginActionProviding, PluginActionInputProviding {
    let metadata = PluginMetadata(id: "palette-fixture", title: "Fixture", iconName: "text.bubble", iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    let key = ActionKey(providerID: "palette-fixture", actionID: "ask")
    var messages: [String] = []
    var releases = 0
    var actionDefinitions: [ActionDefinition] {
        [.init(key: key, title: "Ask Fixture", description: "", systemImage: "text.bubble", parameters: [
            .init(id: "message", title: "Message", kind: .string, privacy: .sensitive, portability: .localOnly),
        ], capabilities: [.foregroundInteractive])]
    }
    var actionInputDescriptors: [ActionInputDescriptor] {
        [.init(key: key, parameterID: "message", placeholder: "Message", destination: "Fixture · New Conversation", submitTitle: "Send", aliases: ["ask fixture"])]
    }
    func prepareActionInput(_ descriptor: ActionInputDescriptor) async throws -> ActionInputSession { .init(destination: descriptor.destination) }
    func releaseActionInput(_ session: ActionInputSession) { releases += 1 }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if case let .string(message)? = invocation.reference.parameters["message"] { messages.append(message) }
        return ActionExecutionHandle { .succeeded() }
    }
}
