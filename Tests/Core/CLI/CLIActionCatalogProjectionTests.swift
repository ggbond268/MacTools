import MacToolsPluginKit
import XCTest
@testable import MacTools

final class CLIActionCatalogProjectionTests: XCTestCase {
    func testUniqueEntriesKeepsOneStableActionPerKeyInCatalogOrder() throws {
        let enabled = try ActionParameterSet(["enabled": .boolean(true)])
        let disabled = try ActionParameterSet(["enabled": .boolean(false)])
        let appearanceKey = ActionKey(providerID: "appearance", actionID: "set-enabled")
        let otherKey = ActionKey(providerID: "appearance", actionID: "toggle")
        let entries = [
            ActionCatalogEntry(
                reference: ActionReference(key: appearanceKey, parameters: enabled),
                title: "Enable Dark Mode"
            ),
            ActionCatalogEntry(
                reference: ActionReference(key: appearanceKey, parameters: disabled),
                title: "Enable Light Mode"
            ),
            ActionCatalogEntry(
                reference: ActionReference(key: otherKey),
                title: "Toggle Appearance"
            )
        ]

        let projected = CLIActionCatalogProjection.uniqueEntries(entries)

        XCTAssertEqual(projected.map(\.reference.key), [appearanceKey, otherKey])
        XCTAssertEqual(projected.map(\.title), ["Enable Dark Mode", "Toggle Appearance"])
    }

    func testUniqueEntriesDoesNotMergeMatchingActionIDsAcrossProviders() {
        let firstKey = ActionKey(providerID: "first", actionID: "set-enabled")
        let secondKey = ActionKey(providerID: "second", actionID: "set-enabled")
        let entries = [
            ActionCatalogEntry(reference: ActionReference(key: firstKey), title: "First"),
            ActionCatalogEntry(reference: ActionReference(key: secondKey), title: "Second")
        ]

        XCTAssertEqual(
            CLIActionCatalogProjection.uniqueEntries(entries).map(\.reference.key),
            [firstKey, secondKey]
        )
    }
}
