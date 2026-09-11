import XCTest
@testable import MacTools

final class MarketplacePluginDetailPresentationTests: XCTestCase {
    func testSparseCatalogItemHasAUsableDetailPresentation() {
        let presentation = MarketplacePluginDetailPresentation(
            item: makeItem(productMetadata: nil),
            target: .init(pluginID: "fan-control")
        )

        XCTAssertEqual(presentation?.item.id, "fan-control")
        XCTAssertNil(presentation?.highlightedAction)
        XCTAssertTrue(presentation?.actionProviders.isEmpty == true)
    }

    func testRichCatalogItemValidatesAndSelectsStaticActionHighlight() throws {
        let presentation = MarketplacePluginDetailPresentation(
            item: makeItem(productMetadata: try richMetadata()),
            target: .init(pluginID: "fan-control", providerID: "fan-control", actionID: "set-speed")
        )

        XCTAssertEqual(
            presentation?.highlightedAction,
            MarketplacePluginActionHighlight(providerID: "fan-control", actionID: "set-speed")
        )
        XCTAssertEqual(presentation?.actionProviders.first?.staticActions.map(\.id), ["set-speed"])
    }

    func testUnknownStaticActionCannotCreateDetailPresentation() throws {
        XCTAssertNil(
            MarketplacePluginDetailPresentation(
                item: makeItem(productMetadata: try richMetadata()),
                target: .init(pluginID: "fan-control", providerID: "fan-control", actionID: "unknown")
            )
        )
    }

    private func makeItem(productMetadata: PluginProductMetadata?) -> PluginManagementItem {
        PluginManagementItem(
            id: "fan-control",
            title: "Fan Control",
            summary: "Control fans.",
            version: "1.0.0",
            state: .available,
            packageURL: nil,
            requiresRestartToFullyUnload: false,
            releaseNotesURL: nil,
            productMetadata: productMetadata
        )
    }

    private func richMetadata() throws -> PluginProductMetadata {
        try JSONDecoder().decode(PluginProductMetadata.self, from: Data("""
        {
          "presentation": null,
          "discovery": null,
          "requirements": null,
          "privacy": null,
          "setup": null,
          "relationships": null,
          "actions": {
            "providers": [{
              "id": "fan-control",
              "kind": "static",
              "dynamicTemplates": [],
              "staticActions": [{
                "id": "set-speed",
                "title": {"en": "Set fan speed"},
                "description": {"en": "Adjust the selected fan."},
                "keywords": ["fan"],
                "systemImage": "fan",
                "parameters": [],
                "parameterSummary": null,
                "permissionIDs": [],
                "risk": "none",
                "surfaces": ["search"],
                "automaticEligible": false,
                "externalInvocation": "never"
              }]
            }]
          }
        }
        """.utf8))
    }
}
