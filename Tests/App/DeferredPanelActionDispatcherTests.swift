import XCTest
@testable import MacTools

@MainActor
final class DeferredPanelActionDispatcherTests: XCTestCase {
    func testDeferredActionsKeepPlacementAndPluginIdentitySeparate() {
        let dispatcher = DeferredPanelActionDispatcher()
        let placementID = UUID().uuidString.lowercased()
        dispatcher.deferPanelSwitch(placementID: placementID, isOn: true)
        dispatcher.deferActionInvocation(placementID: placementID, pluginID: "battery-charge-limit",
                                         controlID: "battery-manage-settings")
        var switches: [DeferredPanelActionDispatcher.PanelSwitchAction] = []
        var invocations: [DeferredPanelActionDispatcher.ActionInvocation] = []
        for _ in 0..<2 {
            dispatcher.flush(switchHandler: { switches.append($0) }, invocationHandler: { invocations.append($0) })
        }
        XCTAssertEqual(switches, [.init(placementID: placementID, isOn: true)])
        XCTAssertEqual(invocations, [.init(placementID: placementID, pluginID: "battery-charge-limit",
                                           controlID: "battery-manage-settings")])
    }
}
