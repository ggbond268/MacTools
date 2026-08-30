import XCTest
@testable import ZshConfigPlugin

final class ZshConfigTests: XCTestCase {
    @MainActor
    func testPublishesOptionalAutomationRequirement() {
        let plugin = ZshConfigPlugin()

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["automation"])
        let state = plugin.permissionState(for: "automation")
        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
    }

    func testFileTypesExposeStableFilenamesAndMetadata() throws {
        XCTAssertEqual(ZshConfigFileType.allCases.map(\.filename), [
            ".zshrc",
            ".zshenv",
            ".zprofile",
            ".zlogin",
            ".zlogout",
        ])
        for type in ZshConfigFileType.allCases {
            XCTAssertEqual(type.id, type.rawValue)
            XCTAssertFalse(type.role.isEmpty)
            XCTAssertFalse(type.whenLoaded.isEmpty)
            XCTAssertFalse(type.recommendedUse.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode(ZshConfigFileType.self, from: JSONEncoder().encode(type)), type)
        }
    }

    func testFileStatusFormatsExistingAndMissingSizes() {
        XCTAssertEqual(
            ZshFileStatus(type: .zshrc, exists: false, isWritable: true, byteSize: 0, modifiedDate: nil).formattedSize,
            ""
        )
        XCTAssertEqual(
            ZshFileStatus(type: .zshrc, exists: true, isWritable: true, byteSize: 0, modifiedDate: nil).formattedSize,
            "0 B"
        )
        XCTAssertTrue(
            ZshFileStatus(type: .zshrc, exists: true, isWritable: true, byteSize: 2048, modifiedDate: nil)
                .formattedSize
                .hasSuffix("KB")
        )
    }

    func testSnippetsGenerateRepresentativeContent() {
        let snippets = Dictionary(uniqueKeysWithValues: ZshSnippet.all.map { ($0.id, $0) })

        XCTAssertEqual(snippets["alias"]?.buildContent("gs=git status"), "alias gs='git status'")
        XCTAssertEqual(snippets["export"]?.buildContent("EDITOR=nvim"), "export EDITOR=nvim")
        XCTAssertEqual(snippets["source"]?.buildContent("~/.config/secrets.sh"), "source ~/.config/secrets.sh")
        XCTAssertTrue(snippets["path"]?.buildContent("/opt/homebrew/bin").contains("$PATH") == true)
        XCTAssertTrue(snippets["function"]?.buildContent("mkcd").hasPrefix("mkcd()") == true)
        XCTAssertTrue(snippets["eval"]?.buildContent("rbenv init -").contains("rbenv init -") == true)
    }
}

@MainActor
final class ZshConfigStoreTests: XCTestCase {
    func testInitialStateAndStatusMapArePopulated() {
        let store = ZshConfigStore()

        XCTAssertEqual(store.selectedType, .zshrc)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.statusMap.count, ZshConfigFileType.allCases.count)
    }

    func testSelectResetsUnsavedChangesAndSwitchesType() {
        let store = ZshConfigStore()
        store.editingContent += "\n# test change"
        store.markEdited()

        store.select(.zshenv)

        XCTAssertEqual(store.selectedType, .zshenv)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(store.saveError)
    }

    func testAppendSnippetAddsReadableSpacingAndMarksEdited() {
        let store = ZshConfigStore()
        store.editingContent = "# existing"

        store.appendSnippet("alias gs='git status'")

        XCTAssertTrue(store.editingContent.contains("\n\nalias gs='git status'"))
        XCTAssertTrue(store.hasUnsavedChanges)
    }
}
