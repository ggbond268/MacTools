import XCTest
import MacToolsPluginKit
@testable import ZshConfigPlugin

final class ZshConfigTests: XCTestCase {
    @MainActor
    func testPanelEntryRequestsSettingsWithoutHostSpecificRouting() throws {
        let plugin = ZshConfigPlugin()
        var requests = 0
        plugin.requestSettingsPresentation = { requests += 1 }
        let items = plugin.panelItems
        guard case let .row(row) = items.first?.content else { return XCTFail("Missing row") }
        row.action(.invokeAction(controlID: "execute"))
        XCTAssertEqual(requests, 1)
        plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(requests, 2, "The shared widget action must open the same settings page")
        plugin.handleAction(.invokeAction(controlID: "unknown"))
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(items.map(\.id), ["control", "quick-control"])
        XCTAssertNil(items.last?.initialPlacement)
    }

    @MainActor
    func testPublishesOptionalAutomationRequirement() {
        let plugin = ZshConfigPlugin()

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["automation"])
        let state = plugin.permissionState(for: "automation")
        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
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
