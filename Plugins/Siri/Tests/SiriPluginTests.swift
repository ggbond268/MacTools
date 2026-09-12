import MacToolsPluginKit
import XCTest
@testable import SiriPlugin

@MainActor
final class SiriPluginTests: XCTestCase {
    func testPanelOpensInputWhenIdleAndCancelsWhenBusy() async throws {
        let client = SiriPanelTestClient()
        let plugin = SiriPlugin(client: client)
        var requests: [ActionKey] = []
        plugin.requestActionInput = { requests.append($0) }
        let idleTitle = plugin.primaryPanelDescriptor.buttonTitle
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(requests, [plugin.actionDefinitions[0].key])
        let callsBeforeSend = await client.calls
        XCTAssertTrue(callsBeforeSend.isEmpty, "Opening the composer must not launch Siri or create a chat")
        let handle = try XCTUnwrap(plugin.controller.start("test message"))
        XCTAssertNotEqual(plugin.primaryPanelDescriptor.buttonTitle, idleTitle)
        plugin.handleAction(.invokeAction(controlID: "execute"))
        _ = await handle.result()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(plugin.controller.phase, .cancelled)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, idleTitle)
    }

    func testFailedSendKeepsExplanationAndCanOpenInputAgain() async throws {
        let plugin = SiriPlugin(client: SiriPanelTestClient(failsVerification: true))
        _ = await plugin.controller.start("test message")?.result()
        XCTAssertEqual(plugin.controller.phase, .uncertain)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        var requests = 0
        plugin.requestActionInput = { _ in requests += 1 }
        plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage, "Opening input must not erase uncertain delivery guidance")
    }

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

private actor SiriPanelTestClient: SiriClient {
    let failsVerification: Bool
    var calls: [String] = []
    init(failsVerification: Bool = false) { self.failsVerification = failsVerification }
    func prepareNewConversation() async throws { calls.append("prepare") }
    func enter(_ message: String) async throws { calls.append("enter") }
    func submit(_ message: String) async throws { calls.append("submit") }
    func verify(_ message: String) async throws {
        calls.append("verify")
        if failsVerification { throw SiriFailure.timedOut }
    }
    func finish() async { calls.append("finish") }
}
