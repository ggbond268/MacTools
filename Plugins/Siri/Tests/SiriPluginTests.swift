import MacToolsPluginKit
import XCTest
@testable import SiriPlugin

@MainActor
final class SiriPluginTests: XCTestCase {
    func testOnlyNewConversationIsExposedAndTextIsNeverAPreset() throws {
        let plugin = SiriPlugin()
        XCTAssertEqual(plugin.metadata.id, "siri")
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["ask-new-conversation"])
        XCTAssertTrue(plugin.actionCatalogEntries.isEmpty)
        XCTAssertEqual(plugin.actionInputDescriptors.first?.aliases, ["ask siri"])
        let parameter = try XCTUnwrap(plugin.actionDefinitions.first?.parameters.first)
        XCTAssertEqual(parameter.privacy, .sensitive)
        XCTAssertEqual(parameter.portability, .localOnly)
        XCTAssertFalse(plugin.actionDefinitions[0].capabilities.contains(.automatic))
        XCTAssertEqual(plugin.actionDefinitions[0].externalInvocationPolicy, .unavailable)
        XCTAssertEqual(plugin.permissionRequirementIDs(for: plugin.actionDefinitions[0].key), ["accessibility"])
    }
}
