import AppKit
import SwiftUI
import XCTest
@testable import MacTools

final class MenuBarPanelLayoutTests: XCTestCase {
    func testBaseWidthRemainsFixedForCompactPanelPresentation() {
        XCTAssertEqual(MenuBarPanelLayout.baseWidth, 296)
    }

    func testSurfaceWidthStaysAtBaseCardWidthWhenSecondaryPanelIsVisible() {
        XCTAssertEqual(
            MenuBarPanelLayout.surfaceWidth,
            MenuBarPanelLayout.baseWidth - (MenuBarPanelLayout.outerPadding * 2)
        )
    }

    func testWidthUsesBaseWidthWhenNoSecondaryPanelIsVisible() {
        let item = makeItem(controlStyle: .disclosure, isExpanded: true, secondaryPanel: nil)

        XCTAssertEqual(MenuBarPanelLayout.width(for: [item]), MenuBarPanelLayout.baseWidth)
    }

    func testWidthAddsSecondaryPanelWidthForExpandedDisclosurePanel() {
        let item = makeItem(
            controlStyle: .disclosure,
            isExpanded: true,
            secondaryPanel: PluginPanelSecondaryPanel(title: "Studio Display", controls: [])
        )

        XCTAssertEqual(MenuBarPanelLayout.width(for: [item]), MenuBarPanelLayout.baseWidth)
    }

    func testWidthIgnoresSecondaryPanelForCollapsedDisclosurePanel() {
        let item = makeItem(
            controlStyle: .disclosure,
            isExpanded: false,
            secondaryPanel: PluginPanelSecondaryPanel(title: "Studio Display", controls: [])
        )

        XCTAssertEqual(MenuBarPanelLayout.width(for: [item]), MenuBarPanelLayout.baseWidth)
    }

    func testWidthUsesBaseWidthForExpandedSliderOnlyDisclosureDetail() {
        let sliderControl = PluginPanelControl(
            id: "display.2.brightness",
            kind: .slider,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: "Studio Display",
            sliderValue: 0.72,
            sliderBounds: 0...1,
            sliderStep: 0.01,
            valueLabel: "72%",
            isEnabled: true
        )
        let item = PluginPanelItem(
            id: "display-brightness",
            title: "显示器亮度",
            iconName: "sun.max",
            iconTint: Color(nsColor: .systemYellow),
            controlStyle: .disclosure,
            menuActionBehavior: .keepPresented,
            description: "快速调节每个显示器的亮度",
            helpText: "快速调节每个显示器的亮度",
            descriptionTone: .secondary,
            isOn: false,
            isExpanded: true,
            isEnabled: true,
            detail: PluginPanelDetail(primaryControls: [sliderControl], secondaryPanel: nil)
        )

        XCTAssertEqual(MenuBarPanelLayout.width(for: [item]), MenuBarPanelLayout.baseWidth)
    }

    private func makeItem(
        controlStyle: PluginControlStyle,
        isExpanded: Bool,
        secondaryPanel: PluginPanelSecondaryPanel?
    ) -> PluginPanelItem {
        PluginPanelItem(
            id: "display-resolution",
            title: "显示器分辨率",
            iconName: "display",
            iconTint: Color(nsColor: .systemBlue),
            controlStyle: controlStyle,
            menuActionBehavior: .keepPresented,
            description: "查看并切换每个显示器的分辨率",
            helpText: "查看并切换每个显示器的分辨率",
            descriptionTone: .secondary,
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            detail: PluginPanelDetail(primaryControls: [], secondaryPanel: secondaryPanel)
        )
    }
}

@MainActor
final class HoverSecondaryPanelCoordinatorTests: XCTestCase {
    func testSwitchingActivationClearsPreviousAnchor() {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let firstActivation = makeActivation(optionID: "2")
        let secondActivation = makeActivation(optionID: "3")

        coordinator.hoverBegan(
            pluginID: firstActivation.pluginID,
            controlID: firstActivation.controlID,
            optionID: firstActivation.optionID
        )
        coordinator.updateRowFrame(
            CGRect(x: 10, y: 20, width: 30, height: 40),
            for: firstActivation
        )

        coordinator.hoverBegan(
            pluginID: secondActivation.pluginID,
            controlID: secondActivation.controlID,
            optionID: secondActivation.optionID
        )

        XCTAssertEqual(coordinator.activeActivation, secondActivation)
        XCTAssertNil(coordinator.selectedRowFrame)
    }

    func testHoverEndDismissesAfterDelayAndNotifies() async throws {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(10),
            activationDelay: nil
        )
        var dismissedActivation: HoverSecondaryPanelCoordinator.Activation?
        let activation = makeActivation(optionID: "2")

        coordinator.onDismissRequest = { activation in
            dismissedActivation = activation
        }

        coordinator.hoverBegan(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )
        coordinator.updateRowFrame(CGRect(x: 1, y: 2, width: 3, height: 4), for: activation)
        coordinator.hoverEnded(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(coordinator.activeActivation)
        XCTAssertNil(coordinator.selectedRowFrame)
        XCTAssertEqual(dismissedActivation, activation)
    }

    func testPanelHoverCancelsPendingDismissal() async throws {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(20),
            activationDelay: nil
        )
        var dismissCount = 0
        let activation = makeActivation(optionID: "2")

        coordinator.onDismissRequest = { _ in
            dismissCount += 1
        }

        coordinator.hoverBegan(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )
        coordinator.hoverEnded(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )
        coordinator.setPanelHovered(true)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(coordinator.activeActivation)
        XCTAssertEqual(dismissCount, 0)

        coordinator.setPanelHovered(false)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(coordinator.activeActivation)
        XCTAssertEqual(dismissCount, 1)
    }

    func testHoverBeganUsesCachedFrameForNewActivation() {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let activation = makeActivation(optionID: "3")
        let frame = CGRect(x: 30, y: 40, width: 120, height: 48)

        coordinator.updateRowFrame(frame, for: activation)
        coordinator.hoverBegan(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )

        XCTAssertEqual(coordinator.activeActivation, activation)
        XCTAssertEqual(coordinator.selectedRowFrame, frame)
    }

    func testInactiveRowFrameClearDoesNotOverrideCurrentAnchor() {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let firstActivation = makeActivation(optionID: "2")
        let secondActivation = makeActivation(optionID: "3")
        let secondFrame = CGRect(x: 80, y: 60, width: 160, height: 48)

        coordinator.hoverBegan(
            pluginID: firstActivation.pluginID,
            controlID: firstActivation.controlID,
            optionID: firstActivation.optionID
        )
        coordinator.updateRowFrame(
            CGRect(x: 10, y: 20, width: 140, height: 48),
            for: firstActivation
        )

        coordinator.hoverBegan(
            pluginID: secondActivation.pluginID,
            controlID: secondActivation.controlID,
            optionID: secondActivation.optionID
        )
        coordinator.updateRowFrame(secondFrame, for: secondActivation)
        coordinator.updateRowFrame(nil, for: firstActivation)

        XCTAssertEqual(coordinator.activeActivation, secondActivation)
        XCTAssertEqual(coordinator.selectedRowFrame, secondFrame)
    }

    func testTransientHoverEndsBeforeActivationDelayDoesNotOpenOrNotify() async throws {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: .milliseconds(40)
        )
        let activation = makeActivation(optionID: "2")
        var dismissCount = 0
        coordinator.onDismissRequest = { _ in dismissCount += 1 }

        coordinator.hoverBegan(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )
        coordinator.hoverEnded(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertNil(coordinator.activeActivation)
        XCTAssertNil(coordinator.selectedRowFrame)
        XCTAssertEqual(dismissCount, 0)
    }

    func testSustainedHoverActivatesAfterDelay() async throws {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: .milliseconds(10)
        )
        let activation = makeActivation(optionID: "2")
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)

        coordinator.updateRowFrame(frame, for: activation)
        coordinator.hoverBegan(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(coordinator.activeActivation, activation)
        XCTAssertEqual(coordinator.selectedRowFrame, frame)
    }

    private func makeActivation(optionID: String) -> HoverSecondaryPanelCoordinator.Activation {
        HoverSecondaryPanelCoordinator.Activation(
            pluginID: "display-resolution",
            controlID: "display-navigation",
            optionID: optionID
        )
    }
}
