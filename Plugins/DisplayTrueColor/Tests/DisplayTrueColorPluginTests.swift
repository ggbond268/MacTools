import XCTest
import MacToolsPluginKit
@testable import DisplayTrueColorPlugin

@MainActor
final class DisplayTrueColorPluginTests: XCTestCase {
    func testPanelStateReflectsSupportedAndUnsupportedDisplays() {
        let enabled = DisplayTrueColorPlugin(
            client: MockTrueToneClient(isSupported: true, isEnabled: true)
        )
        let unsupported = DisplayTrueColorPlugin(
            client: MockTrueToneClient(isSupported: false, isEnabled: nil)
        )

        XCTAssertTrue(enabled.rowState.isOn)
        XCTAssertTrue(enabled.rowState.isEnabled)
        XCTAssertFalse(unsupported.rowState.isOn)
        XCTAssertFalse(unsupported.rowState.isEnabled)
        XCTAssertEqual(unsupported.rowState.subtitle, "不支持")
    }

    func testSwitchUpdatesClientAndPanelState() {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        let plugin = DisplayTrueColorPlugin(client: client)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(client.lastSetEnabled, true)
        XCTAssertTrue(plugin.rowState.isOn)
    }

    func testSwitchIsIgnoredWhenUnsupported() {
        let client = MockTrueToneClient(isSupported: false, isEnabled: nil)
        let plugin = DisplayTrueColorPlugin(client: client)

        plugin.handleAction(.setSwitch(true))

        XCTAssertNil(client.lastSetEnabled)
    }

    func testRefreshReadsExternalState() {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        let plugin = DisplayTrueColorPlugin(client: client)

        client.stubbedEnabled = true
        plugin.refresh()

        XCTAssertTrue(plugin.rowState.isOn)
    }

    func testCanonicalActionUsesTheTrueToneClient() async throws {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        let plugin = DisplayTrueColorPlugin(client: client)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(client.lastSetEnabled, true)
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
    }

    func testCanonicalActionIsUnavailableOnUnsupportedHardware() throws {
        let plugin = DisplayTrueColorPlugin(
            client: MockTrueToneClient(isSupported: false, isEnabled: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    func testCanonicalActionFailsWhenSetterDoesNotChangeTrueTone() async throws {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        client.acceptsWrites = false
        let plugin = DisplayTrueColorPlugin(client: client)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected True Tone write failure, got \(result)")
        }
        XCTAssertFalse(plugin.rowState.isOn)
    }
}

@MainActor
private final class MockTrueToneClient: TrueToneClient {
    private let supported: Bool
    var stubbedEnabled: Bool?
    var acceptsWrites = true
    private(set) var lastSetEnabled: Bool?

    init(isSupported: Bool, isEnabled: Bool?) {
        supported = isSupported
        stubbedEnabled = isEnabled
    }

    var isSupported: Bool { supported }
    var isEnabled: Bool? { stubbedEnabled }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard acceptsWrites else { return false }
        stubbedEnabled = enabled
        lastSetEnabled = enabled
        return true
    }
}
