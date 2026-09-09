import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteAliasStoreTests: XCTestCase {
    func testCustomAliasPersistsResolvesExactTextAndResets() throws {
        let suite = "AliasStoreTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = item("siri", alias: "ask siri")
        let store = CommandPaletteAliasStore(defaults: defaults)
        try store.set("问 Siri", for: input, items: [input])
        let reloaded = CommandPaletteAliasStore(defaults: defaults)
        let resolver = CommandPaletteAliasResolver(items: [input], overrides: reloaded.overrides)
        XCTAssertNil(resolver.resolve("ask siri hello"))
        XCTAssertEqual(resolver.resolve("问 SIRI  你好\n👋 ")?.message, " 你好\n👋 ")
        try reloaded.set(nil, for: input, items: [input])
        XCTAssertEqual(CommandPaletteAliasStore(defaults: defaults).aliases(for: input), ["ask siri"])
    }

    func testInvalidConflictingAndStaleEditsPreservePreviousAlias() throws {
        let suite = "AliasStoreTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = item("siri", alias: "ask siri")
        let other = item("other", alias: "ask other")
        let store = CommandPaletteAliasStore(defaults: defaults)
        try store.set("siri", for: input, items: [input, other])
        for invalid in ["", " ask", "ask ", "ask\n", String(repeating: "a", count: 65), "ASK OTHER", "ask", "ask other now"] {
            XCTAssertThrowsError(try store.set(invalid, for: input, items: [input, other]))
            XCTAssertEqual(store.aliases(for: input), ["siri"])
        }
        XCTAssertThrowsError(try store.set("hello", for: input, items: [other]))
        try store.set("ASK SIRI", for: other, items: [input, other])
        XCTAssertThrowsError(try store.set(nil, for: input, items: [input, other]), "Reset must validate conflicts too")
    }

    func testLaterProviderConflictIsBlockedByResolver() throws {
        let suite = "AliasStoreTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = item("siri", alias: "ask siri")
        let store = CommandPaletteAliasStore(defaults: defaults)
        try store.set("ask", for: input, items: [input])
        let resolver = CommandPaletteAliasResolver(items: [input, item("other", alias: "ask other")], overrides: store.overrides)
        XCTAssertEqual(resolver.resolve("ask other hello")?.isAmbiguous, true)
    }

    func testProviderOptOutDisablesSavedOverride() throws {
        let suite = "AliasStoreTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = item("siri", alias: "ask siri")
        let store = CommandPaletteAliasStore(defaults: defaults)
        try store.set("hey siri", for: input, items: [input])
        let optedOut = ActionInputItem(descriptor: .init(key: input.id, parameterID: "message", placeholder: "", destination: "New", submitTitle: "Send", aliases: []),
                                       definition: input.definition, generation: UUID())
        XCTAssertTrue(store.aliases(for: optedOut).isEmpty)
        XCTAssertNil(CommandPaletteAliasResolver(items: [optedOut], overrides: store.overrides).resolve("hey siri message"))
    }

    private func item(_ provider: String, alias: String) -> ActionInputItem {
        let key = ActionKey(providerID: provider, actionID: "ask")
        return .init(descriptor: .init(key: key, parameterID: "message", placeholder: "", destination: "New", submitTitle: "Send", aliases: [alias]),
                     definition: .init(key: key, title: provider, description: "", systemImage: "sparkles"), generation: UUID())
    }
}
