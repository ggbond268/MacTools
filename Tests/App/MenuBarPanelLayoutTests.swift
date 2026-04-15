import AppKit
import SwiftUI
import XCTest
@testable import MacTools

final class MenuBarPanelLayoutTests: XCTestCase {
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

        XCTAssertEqual(
            MenuBarPanelLayout.width(for: [item]),
            MenuBarPanelLayout.baseWidth + MenuBarPanelLayout.panelSpacing + MenuBarPanelLayout.secondaryPanelWidth
        )
    }

    func testWidthIgnoresSecondaryPanelForCollapsedDisclosurePanel() {
        let item = makeItem(
            controlStyle: .disclosure,
            isExpanded: false,
            secondaryPanel: PluginPanelSecondaryPanel(title: "Studio Display", controls: [])
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
