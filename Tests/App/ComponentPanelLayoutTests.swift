import AppKit
import SwiftUI
import XCTest
@testable import MacTools

final class ComponentPanelLayoutTests: XCTestCase {
    func testPanelWidthUsesFourFixedColumnsWithinExistingPanelWidth() {
        XCTAssertEqual(ComponentPanelLayout.columns, 4)
        XCTAssertEqual(ComponentPanelLayout.cellWidth, 75)
        XCTAssertEqual(ComponentPanelLayout.cellHeight, 104)
        XCTAssertEqual(ComponentPanelLayout.spacing, 10)
        XCTAssertEqual(ComponentPanelLayout.horizontalPadding, 0)
        XCTAssertEqual(ComponentPanelLayout.verticalPadding, 10)
        XCTAssertEqual(
            ComponentPanelLayout.panelWidth,
            ComponentPanelLayout.horizontalPadding * 2
                + ComponentPanelLayout.cellWidth * 4
                + ComponentPanelLayout.spacing * 3
        )
        XCTAssertEqual(ComponentPanelLayout.panelWidth, 330)
    }

    func testGridUsesDedicatedRowHeightForDenseComponents() {
        XCTAssertGreaterThan(ComponentPanelLayout.cellHeight, ComponentPanelLayout.cellWidth)
        XCTAssertEqual(ComponentPanelLayout.itemHeight(for: .oneByOne), ComponentPanelLayout.cellHeight)
        XCTAssertEqual(
            ComponentPanelLayout.yOffset(for: ComponentGridPlacement(id: "a", row: 1, column: 0, span: .oneByOne)),
            ComponentPanelLayout.cellHeight + ComponentPanelLayout.spacing
        )
    }

    func testPreferredHeightForItemsIncludesVerticalPaddingWithoutHeader() {
        let item = makeItem(id: "system", span: .fourByTwo)

        XCTAssertEqual(
            ComponentPanelLayout.preferredPanelHeight(for: [item], screen: nil),
            ComponentPanelLayout.itemHeight(for: .fourByTwo) + ComponentPanelLayout.contentVerticalPadding
        )
    }

    func testFirstFitPlacesMixedSpansDeterministically() {
        let placements = ComponentGridPlacementEngine.placements(
            for: [
                makeItem(id: "a", span: .oneByOne),
                makeItem(id: "b", span: .oneByTwo),
                makeItem(id: "c", span: .twoByTwo)
            ]
        )

        XCTAssertEqual(
            placements,
            [
                ComponentGridPlacement(id: "a", row: 0, column: 0, span: .oneByOne),
                ComponentGridPlacement(id: "b", row: 0, column: 1, span: .oneByTwo),
                ComponentGridPlacement(id: "c", row: 0, column: 2, span: .twoByTwo)
            ]
        )
    }

    func testWideSpansOccupyFourColumnGridAndAllowLaterSingleColumnFill() {
        let placements = ComponentGridPlacementEngine.placements(
            for: [
                makeItem(id: "wide", span: .fourByTwo),
                makeItem(id: "left", span: .oneByOne),
                makeItem(id: "right", span: .twoByOne)
            ]
        )

        XCTAssertEqual(
            placements,
            [
                ComponentGridPlacement(id: "wide", row: 0, column: 0, span: .fourByTwo),
                ComponentGridPlacement(id: "left", row: 2, column: 0, span: .oneByOne),
                ComponentGridPlacement(id: "right", row: 2, column: 1, span: .twoByOne)
            ]
        )
    }

    func testEmptyLayoutUsesEmptyStateHeight() {
        XCTAssertEqual(
            ComponentPanelLayout.gridContentHeight(for: []),
            ComponentPanelLayout.emptyContentHeight
        )
        XCTAssertGreaterThanOrEqual(
            ComponentPanelLayout.preferredPanelHeight(for: [], screen: nil),
            ComponentPanelLayout.minimumPanelHeight
        )
    }

    private func makeItem(id: String, span: PluginComponentSpan) -> PluginComponentItem {
        PluginComponentItem(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            description: id,
            helpText: id,
            descriptionTone: .secondary,
            span: span,
            isActive: false,
            isEnabled: true
        )
    }
}
