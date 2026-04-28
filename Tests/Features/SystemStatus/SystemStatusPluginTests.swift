import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class SystemStatusPluginTests: XCTestCase {
    private let suiteName = "SystemStatusPluginTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPluginDescriptorUsesFourByTwoSpan() {
        let plugin = SystemStatusPlugin()

        XCTAssertEqual(plugin.metadata.id, "system-status")
        XCTAssertEqual(plugin.metadata.title, "系统状态")
        XCTAssertEqual(plugin.componentDescriptor.span, .fourByTwo)
    }

    func testDefaultPluginHostIncludesSystemStatusComponentOnly() {
        let host = PluginHost()

        XCTAssertTrue(host.componentItems.contains { $0.id == "system-status" })
        XCTAssertFalse(host.panelItems.contains { $0.id == "system-status" })

        let managementItem = host.featureManagementItems.first { $0.id == "system-status" }
        XCTAssertEqual(managementItem?.presentation, .componentPanel)
    }

    func testSystemStatusLayoutUsesFourColumnTwoRowOrder() {
        XCTAssertEqual(SystemStatusComponentLayout.columns, 4)
        XCTAssertEqual(SystemStatusComponentLayout.rows, 2)
        XCTAssertEqual(
            SystemStatusComponentLayout.orderedMetricKinds,
            [.cpu, .memory, .disk, .battery, .network, .topProcesses]
        )
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .cpu), SystemStatusGridPosition(row: 0, column: 0))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .memory), SystemStatusGridPosition(row: 0, column: 1))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .disk), SystemStatusGridPosition(row: 0, column: 2))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .battery), SystemStatusGridPosition(row: 0, column: 3))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .network), SystemStatusGridPosition(row: 1, column: 0))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .topProcesses), SystemStatusGridPosition(row: 1, column: 2))
    }
}
