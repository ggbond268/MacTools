import XCTest
@testable import MacTools
@testable import EjectDiskPlugin

@MainActor
final class EjectDiskPluginTests: XCTestCase {
    func testMetadataIdentifiesEjectDiskPlugin() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.metadata.id, "eject-disk")
        XCTAssertEqual(plugin.metadata.title, "推出磁盘")
    }

    func testControlStyleIsButton() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "推出")
    }

    func testGetEjectableVolumesExcludesNonRemovableDirectories() throws {
        // 内部卷上的普通目录不应被当成可推出卷（旧的"名字+是否目录"启发式会误报）。
        let root = NSTemporaryDirectory().appending("eject-test-\(UUID().uuidString)")
        let child = (root as NSString).appendingPathComponent("RegularFolder")
        try FileManager.default.createDirectory(atPath: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = try EjectDiskPlugin.getEjectableVolumes(from: root)
        XCTAssertFalse(result.contains("RegularFolder"))
    }

    func testInitialStateHasEjectedOffAndIsDisabled() {
        let plugin = EjectDiskPlugin()

        let state = plugin.primaryPanelState
        XCTAssertFalse(state.isOn)
        XCTAssertFalse(state.isEnabled)
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = EjectDiskPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testPluginHostIncludesEjectDiskWhenProvided() {
        let host = makePluginHostForTests(plugins: [EjectDiskPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "eject-disk" })
    }

    func testPluginDescriptionMatches() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "推出所有可移动磁盘")
    }

    func testSubtitleShowsNoEjectableDiskWhenCountIsZero() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "无可推出的磁盘")
    }
}
