import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class IPOverviewFeatureRowModelTests: XCTestCase {
    func testIPValuesUsePluginIdentityForEveryPlacement() {
        let coordinator = PluginPanelCoordinator()
        let metadata = PluginMetadata(id: IPOverviewFeatureRowContract.pluginID, title: "IP Overview",
            iconName: "network", iconTint: .blue, order: 0, defaultDescription: "Addresses")
        let controls = [IPOverviewFeatureRowContract.copyLocalIPv4ActionID,
                        IPOverviewFeatureRowContract.copyPublicIPv4ActionID].map {
            PluginPanelControl(id: $0, kind: .actionRow, options: [], selectedOptionID: nil,
                dateValue: nil, minimumDate: nil, displayedComponents: nil, datePickerStyle: nil,
                sectionTitle: nil, actionTitle: "192.0.2.1", isEnabled: true)
        }
        let definition = PluginPanelItem.row(id: "control",
            descriptor: .init(controlStyle: .disclosure, menuActionBehavior: .keepPresented),
            state: .init(subtitle: "", isOn: false, isEnabled: true, isAvailable: true,
                         detail: .init(controls: controls), errorMessage: nil), action: { _ in })
        let item = PanelCatalogItem(key: .init(pluginID: metadata.id, itemID: definition.id),
            pluginTitle: metadata.title, metadata: metadata, definition: definition)
        for _ in 0..<2 {
            let snapshot = coordinator.rowSnapshot(item, id: UUID().uuidString.lowercased())!
            XCTAssertNotEqual(snapshot.id, metadata.id)
            XCTAssertEqual(IPOverviewFeatureRowModel.values(for: snapshot).map(\.text), ["192.0.2.1", "192.0.2.1"])
        }
    }
}
