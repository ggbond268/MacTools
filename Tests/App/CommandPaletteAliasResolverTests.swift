import MacToolsPluginKit
import XCTest
@testable import MacTools

final class CommandPaletteAliasResolverTests: XCTestCase {
    func testExplicitAliasPreservesExactSuffix() {
        let resolver = CommandPaletteAliasResolver(items: [item()])
        let input = "ASK SIRI  中文 👋\nKeep CASE; $(echo no)"
        XCTAssertEqual(resolver.resolve(input)?.message, " 中文 👋\nKeep CASE; $(echo no)")
        XCTAssertFalse(resolver.resolve(input)!.isAmbiguous)
        XCTAssertNil(resolver.resolve("ask siriously hello"))
        XCTAssertNil(resolver.resolve("please ask siri hello"))
        XCTAssertNil(resolver.resolve(" ask siri hello"))
        XCTAssertNil(resolver.resolve("ask siri\thello"))
    }

    func testBareAliasAndEmptyMessageAreDistinct() {
        let resolver = CommandPaletteAliasResolver(items: [item()])
        XCTAssertNotNil(resolver.resolve("ask siri"))
        XCTAssertNil(resolver.resolve("ask siri")?.message)
        XCTAssertEqual(resolver.resolve("ask siri ")?.message, "")
    }

    func testConflictingAndPrefixAliasesDoNotChooseAnAction() {
        for alias in ["ASK SIRI", "ask siri new", "ask"] {
            let resolver = CommandPaletteAliasResolver(items: [item(), item(action: "other", alias: alias)])
            XCTAssertEqual(resolver.resolve("ask siri new hello")?.isAmbiguous, true)
        }
    }

    func testInvalidAliasesAreIgnoredAndUnicodeCaseMappingPreservesRange() {
        XCTAssertFalse(CommandPaletteAliasResolver.isValid(" ask siri"))
        XCTAssertFalse(CommandPaletteAliasResolver.isValid("ask\nsiri"))
        let resolver = CommandPaletteAliasResolver(items: [item(alias: "Straße")])
        XCTAssertEqual(resolver.resolve("STRASSE 中文")?.message, "中文")
    }

    private func item(action: String = "ask", alias: String = "ask siri") -> ActionInputItem {
        let key = ActionKey(providerID: "siri", actionID: action)
        return ActionInputItem(descriptor: .init(key: key, parameterID: "message", placeholder: "", destination: "New", submitTitle: "Send", aliases: [alias]),
                               definition: .init(key: key, title: "Ask", description: "", systemImage: "sparkles"), generation: UUID())
    }
}
