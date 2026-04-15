import CoreGraphics
import XCTest
@testable import MacTools

@MainActor
final class DisplayResolutionPluginSidePanelTests: XCTestCase {
    func testNavigationOmitsDisplaysWithoutVisibleModes() throws {
        let controller = MockDisplayResolutionController()
        controller.displays = [
            DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, isMain: true),
            DisplayInfo(id: 4, name: "Projector", isBuiltin: false, isMain: false)
        ]
        controller.modesByDisplayID = [
            2: [makeMode(modeId: 8, width: 1920, height: 1080, isCurrent: true)],
            4: []
        ]

        let plugin = DisplayResolutionPlugin(controller: controller)
        plugin.handlePanelAction(.setDisclosureExpanded(true))

        let navigation = try XCTUnwrap(plugin.panelState.detail?.primaryControls.first)
        XCTAssertEqual(navigation.options.map(\.id), ["2"])
    }

    func testExpandedStateShowsDisplayNavigationAndNoSecondaryPanelByDefault() throws {
        let plugin = makePlugin()
        plugin.handlePanelAction(.setDisclosureExpanded(true))

        let detail = try XCTUnwrap(plugin.panelState.detail)

        XCTAssertEqual(detail.primaryControls.count, 1)
        XCTAssertEqual(detail.primaryControls[0].kind, .navigationList)
        XCTAssertNil(detail.secondaryPanel)
    }

    func testSelectingDisplayShowsSecondaryPanel() throws {
        let plugin = makePlugin()
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))

        let secondary = try XCTUnwrap(plugin.panelState.detail?.secondaryPanel)
        XCTAssertEqual(secondary.title, "Studio Display")
        XCTAssertEqual(secondary.controls.first?.kind, .selectList)
    }

    func testSelectingSameDisplayTwiceClosesSecondaryPanel() {
        let plugin = makePlugin()
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))

        XCTAssertNil(plugin.panelState.detail?.secondaryPanel)
    }

    func testSelectingResolutionInSecondaryPanelAppliesModeOnSelectedDisplay() throws {
        let controller = MockDisplayResolutionController()
        controller.displays = [
            DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, isMain: true),
            DisplayInfo(id: 3, name: "LG UltraFine", isBuiltin: false, isMain: false)
        ]
        controller.modesByDisplayID = [
            2: [
                makeMode(modeId: 8, width: 1920, height: 1080, isCurrent: true),
                makeMode(modeId: 12, width: 2560, height: 1440)
            ],
            3: [
                makeMode(modeId: 12, width: 3008, height: 1692, isCurrent: true)
            ]
        ]

        let plugin = DisplayResolutionPlugin(controller: controller)
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))

        let controlID = try XCTUnwrap(plugin.panelState.detail?.secondaryPanel?.controls.first?.id)
        plugin.handlePanelAction(.setSelection(controlID: controlID, optionID: "12"))

        XCTAssertEqual(controller.applyCalls.count, 1)
        XCTAssertEqual(controller.applyCalls[0].displayID, 2)
        XCTAssertEqual(controller.applyCalls[0].modeId, 12)
    }

    func testCollapsingPluginClearsSelectedDisplay() {
        let plugin = makePlugin()
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))
        plugin.handlePanelAction(.setDisclosureExpanded(false))

        XCTAssertNil(plugin.panelState.detail)
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        XCTAssertNil(plugin.panelState.detail?.secondaryPanel)
    }

    func testMissingSelectedDisplayClearsSecondaryPanel() {
        let controller = MockDisplayResolutionController()
        controller.displays = [
            DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, isMain: true),
            DisplayInfo(id: 3, name: "LG UltraFine", isBuiltin: false, isMain: false)
        ]
        controller.modesByDisplayID = [
            2: [makeMode(modeId: 8, width: 1920, height: 1080, isCurrent: true)],
            3: [makeMode(modeId: 30, width: 3008, height: 1692, isCurrent: true)]
        ]

        let plugin = DisplayResolutionPlugin(controller: controller)
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))

        controller.displays = [
            DisplayInfo(id: 3, name: "LG UltraFine", isBuiltin: false, isMain: false)
        ]

        XCTAssertNil(plugin.panelState.detail?.secondaryPanel)
        XCTAssertNil(plugin.panelState.detail?.primaryControls.first?.selectedOptionID)
        XCTAssertEqual(plugin.panelState.detail?.primaryControls.first?.options.map(\.id), ["3"])
    }

    func testAllFilteredDisplaysDisablePluginAndSuppressDetail() {
        let controller = MockDisplayResolutionController()
        controller.displays = [
            DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, isMain: true)
        ]
        controller.modesByDisplayID = [2: []]

        let plugin = DisplayResolutionPlugin(controller: controller)
        plugin.handlePanelAction(.setDisclosureExpanded(true))

        let state = plugin.panelState

        XCTAssertEqual(state.subtitle, "未检测到可用分辨率")
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isExpanded)
        XCTAssertNil(state.detail)
    }

    func testSelectingDifferentDisplayClearsLastErrorMessage() throws {
        let controller = MockDisplayResolutionController()
        controller.displays = [
            DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, isMain: true),
            DisplayInfo(id: 3, name: "LG UltraFine", isBuiltin: false, isMain: false)
        ]
        controller.modesByDisplayID = [
            2: [
                makeMode(modeId: 8, width: 1920, height: 1080, isCurrent: true),
                makeMode(modeId: 12, width: 2560, height: 1440)
            ],
            3: [
                makeMode(modeId: 30, width: 3008, height: 1692, isCurrent: true)
            ]
        ]
        controller.applyResult = .failure(.modeNotFound(modeId: 12))

        let plugin = DisplayResolutionPlugin(controller: controller)
        plugin.handlePanelAction(.setDisclosureExpanded(true))
        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "2"))

        let controlID = try XCTUnwrap(plugin.panelState.detail?.secondaryPanel?.controls.first?.id)
        plugin.handlePanelAction(.setSelection(controlID: controlID, optionID: "12"))
        XCTAssertNotNil(plugin.panelState.errorMessage)

        plugin.handlePanelAction(.setNavigationSelection(controlID: "display-navigation", optionID: "3"))
        XCTAssertNil(plugin.panelState.errorMessage)
    }

    private func makePlugin() -> DisplayResolutionPlugin {
        let controller = MockDisplayResolutionController()
        controller.displays = [
            DisplayInfo(id: 2, name: "Studio Display", isBuiltin: false, isMain: true),
            DisplayInfo(id: 3, name: "LG UltraFine", isBuiltin: false, isMain: false)
        ]
        controller.modesByDisplayID = [
            2: [
                makeMode(modeId: 8, width: 1920, height: 1080, isCurrent: true),
                makeMode(modeId: 12, width: 2560, height: 1440)
            ],
            3: [
                makeMode(modeId: 30, width: 3008, height: 1692, isCurrent: true)
            ]
        ]
        return DisplayResolutionPlugin(controller: controller)
    }

    private func makeMode(
        modeId: Int32,
        width: Int,
        height: Int,
        isCurrent: Bool = false
    ) -> DisplayResolutionInfo {
        DisplayResolutionInfo(
            modeId: modeId,
            width: width,
            height: height,
            pixelWidth: width * 2,
            pixelHeight: height * 2,
            refreshRate: 60,
            isHiDPI: true,
            isNative: false,
            isDefault: false,
            isCurrent: isCurrent
        )
    }
}

@MainActor
private final class MockDisplayResolutionController: DisplayResolutionControlling {
    struct ApplyCall: Equatable {
        let displayID: CGDirectDisplayID
        let modeId: Int32
    }

    var displays: [DisplayInfo] = []
    var modesByDisplayID: [CGDirectDisplayID: [DisplayResolutionInfo]] = [:]
    var applyCalls: [ApplyCall] = []
    var applyResult: Result<Void, DisplayResolutionError> = .success(())

    func listConnectedDisplays() -> [DisplayInfo] { displays }

    func listAvailableResolutions(for displayID: CGDirectDisplayID) -> [DisplayResolutionInfo] {
        modesByDisplayID[displayID] ?? []
    }

    func applyResolution(
        _ info: DisplayResolutionInfo,
        for displayID: CGDirectDisplayID
    ) -> Result<Void, DisplayResolutionError> {
        applyCalls.append(ApplyCall(displayID: displayID, modeId: info.modeId))
        return applyResult
    }
}
