import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class ComponentPanelLayoutTests: XCTestCase {
    func testGridUsesCompactRowsForDenseComponents() {
        XCTAssertLessThan(ComponentPanelLayout.cellHeight, ComponentPanelLayout.cellWidth)
        XCTAssertEqual(ComponentPanelLayout.itemHeight(for: .oneByOne), ComponentPanelLayout.cellHeight)
        XCTAssertEqual(
            ComponentPanelLayout.yOffset(for: ComponentGridPlacement(
                id: "a",
                row: 1,
                column: 0,
                span: .oneByOne,
                yOffset: ComponentPanelLayout.cellHeight + ComponentPanelLayout.verticalSpacing
            )),
            ComponentPanelLayout.cellHeight + ComponentPanelLayout.verticalSpacing
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
                ComponentGridPlacement(id: "a", row: 0, column: 0, span: .oneByOne, yOffset: 0),
                ComponentGridPlacement(id: "b", row: 0, column: 1, span: .oneByTwo, yOffset: 0),
                ComponentGridPlacement(id: "c", row: 0, column: 2, span: .twoByTwo, yOffset: 0)
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
                ComponentGridPlacement(id: "wide", row: 0, column: 0, span: .fourByTwo, yOffset: 0),
                ComponentGridPlacement(id: "left", row: 2, column: 0, span: .oneByOne, yOffset: 22),
                ComponentGridPlacement(id: "right", row: 2, column: 1, span: .twoByOne, yOffset: 22)
            ]
        )
    }

    func testThousandTallCopiesKeepFirstFitGeometry() {
        let span = PluginComponentSpan(width: 4, height: 50)!
        let items = (0..<1000).map { (id: "copy-\($0)", span: span) }
        let placements = ComponentGridPlacementEngine.placements(for: items)
        let step = ComponentPanelLayout.itemHeight(for: span) + ComponentPanelLayout.verticalSpacing
        XCTAssertEqual(placements.count, items.count)
        for (index, placement) in placements.enumerated() {
            XCTAssertEqual(placement.id, items[index].id)
            XCTAssertEqual(placement.row, index * 50)
            XCTAssertEqual(placement.column, 0)
            XCTAssertEqual(placement.yOffset, CGFloat(index) * step)
        }
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

@MainActor
final class ComponentDetailCoordinatorTests: XCTestCase {
    func testCopiesOfTheSameComponentKeepSeparateDetailAnchors() {
        let coordinator = ComponentDetailCoordinator()
        let first = CGRect(x: 10, y: 20, width: 100, height: 80)
        let second = CGRect(x: 10, y: 120, width: 100, height: 80)
        coordinator.toggle(pluginID: "status", detailID: "cpu", presentationID: "first")
        coordinator.updatePresentationFrame(id: "first", frame: first)
        coordinator.toggle(pluginID: "status", detailID: "cpu", presentationID: "second")
        XCTAssertEqual(coordinator.state.selection?.presentationID, "second")
        XCTAssertNil(coordinator.state.selectedCardFrame)
        coordinator.updatePresentationFrame(id: "first", frame: first)
        XCTAssertNil(coordinator.state.selectedCardFrame)
        coordinator.updatePresentationFrame(id: "second", frame: second)
        XCTAssertEqual(coordinator.state.selectedCardFrame, second)
    }

    func testSwitchingDetailsWithinSameComponentPreservesAnchorFrame() {
        let coordinator = ComponentDetailCoordinator()
        let anchorFrame = CGRect(x: 20, y: 40, width: 300, height: 500)

        coordinator.toggle(pluginID: "system-status", detailID: "cpu")
        coordinator.updateCardFrame(pluginID: "system-status", frame: anchorFrame)
        coordinator.toggle(pluginID: "system-status", detailID: "gpu")

        XCTAssertEqual(
            coordinator.state.selection,
            ComponentDetailCoordinator.Selection(pluginID: "system-status", detailID: "gpu")
        )
        XCTAssertEqual(coordinator.state.selectedCardFrame, anchorFrame)
    }

    func testClickingSelectedDetailAgainDismissesSelectionAndAnchor() {
        let coordinator = ComponentDetailCoordinator()
        let anchorFrame = CGRect(x: 20, y: 40, width: 300, height: 500)

        coordinator.toggle(pluginID: "system-status", detailID: "cpu")
        coordinator.updateCardFrame(pluginID: "system-status", frame: anchorFrame)
        coordinator.toggle(pluginID: "system-status", detailID: "cpu")

        XCTAssertNil(coordinator.state.selection)
        XCTAssertNil(coordinator.state.selectedCardFrame)
    }

    func testSwitchingComponentsClearsAnchorUntilNewComponentIsMeasured() {
        let coordinator = ComponentDetailCoordinator()
        let anchorFrame = CGRect(x: 20, y: 40, width: 300, height: 500)

        coordinator.toggle(pluginID: "system-status", detailID: "cpu")
        coordinator.updateCardFrame(pluginID: "system-status", frame: anchorFrame)
        coordinator.toggle(pluginID: "another-component", detailID: "summary")

        XCTAssertEqual(
            coordinator.state.selection,
            ComponentDetailCoordinator.Selection(
                pluginID: "another-component",
                detailID: "summary"
            )
        )
        XCTAssertNil(coordinator.state.selectedCardFrame)
    }
}
