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

    func testDifferentHeightsStartNewRowsWhileEqualHeightsShareRemainingWidth() {
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
                ComponentGridPlacement(id: "b", row: 1, column: 0, span: .oneByTwo, yOffset: 14),
                ComponentGridPlacement(id: "c", row: 1, column: 1, span: .twoByTwo, yOffset: 14)
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

    func testThousandTallCopiesKeepRowPackingGeometry() {
        let span = PluginPanelWidgetSpan(width: 4, height: 50)!
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

    func testCompactControlsFillFiveColumnsThenWrap() throws {
        let span = try XCTUnwrap(PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact))
        let placements = ComponentGridPlacementEngine.placements(for: (0..<13).map { ("icon-\($0)", span) })
        for (index, placement) in placements.enumerated() {
            let frame = PanelLayoutDestination.frame(placement)
            XCTAssertEqual(frame.minX, CGFloat(index % 5) * 62.8, accuracy: 0.001)
            XCTAssertEqual(frame.minY, CGFloat(index / 5) * 74, accuracy: 0.001)
            XCTAssertEqual(frame.width, 52.8, accuracy: 0.001)
            XCTAssertEqual(frame.height, 64)
            XCTAssertLessThanOrEqual(frame.maxX, ComponentPanelLayout.gridWidth + 0.001)
        }
        XCTAssertEqual(PanelLayoutDestination.frame(placements[4]).maxX, ComponentPanelLayout.gridWidth, accuracy: 0.001)
    }

    func testEqualHeightCompactControlsShareRowsWithCardsWithoutResizingThem() throws {
        let compact = try XCTUnwrap(PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact))
        let placements = ComponentGridPlacementEngine.placements(for: [
            ("half", PluginPanelWidgetSpan(width: 2, height: 8)!),
            ("icon-a", compact), ("icon-b", compact),
            ("full", PluginPanelWidgetSpan(width: 4, height: 12)!), ("quarter", .oneByOne)
        ])
        let frames = placements.map(PanelLayoutDestination.frame)
        for (frame, width) in zip(frames, [148, 52.8, 52.8, 304, 70]) {
            XCTAssertEqual(frame.width, width, accuracy: 0.001)
        }
        XCTAssertEqual(frames[1].minY, 0)
        XCTAssertEqual(frames[2].minY, 0)
        XCTAssertGreaterThanOrEqual(frames[1].minX - frames[0].maxX, ComponentPanelLayout.horizontalSpacing)
        XCTAssertEqual(frames[2].minX - frames[1].maxX, PluginPanelWidgetLayoutMetrics.compactSpacing, accuracy: 0.001)
        XCTAssertEqual(frames[3].minY, frames[0].maxY + ComponentPanelLayout.verticalSpacing)
        for (index, frame) in frames.enumerated() {
            XCTAssertLessThanOrEqual(frame.maxX, ComponentPanelLayout.gridWidth)
            for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
        }
    }

    func testWidgetsAfterFullWidthCardDoNotReserveHolesAboveIt() throws {
        let compact = try XCTUnwrap(PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact))
        let full = try XCTUnwrap(PluginPanelWidgetSpan(width: 4, height: 12))
        let placements = ComponentGridPlacementEngine.placements(for: [
            ("before", compact), ("full", full), ("after-a", compact), ("after-b", compact)
        ])
        let frames = placements.map(PanelLayoutDestination.frame)
        XCTAssertEqual(frames[2].minX, 0)
        XCTAssertEqual(frames[3].minX, 62.8, accuracy: 0.001)
        XCTAssertEqual(frames[2].minY, frames[1].maxY + ComponentPanelLayout.verticalSpacing)
        XCTAssertEqual(frames[2].minY, frames[3].minY)
        XCTAssertGreaterThanOrEqual(placements[2].row, placements[1].row + full.height)
    }

    func testMixedGridStandardCardsAtTrailingEdgeStayInsidePanel() throws {
        let compact = try XCTUnwrap(PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact))
        for width in 1...3 {
            let leading = try XCTUnwrap(PluginPanelWidgetSpan(width: 4 - width, height: 8))
            let trailing = try XCTUnwrap(PluginPanelWidgetSpan(width: width, height: 8))
            let placements = ComponentGridPlacementEngine.placements(for: [
                ("leading", leading), ("trailing", trailing), ("compact", compact)
            ])
            let frame = PanelLayoutDestination.frame(placements[1])
            XCTAssertEqual(frame.minY, 0)
            XCTAssertEqual(frame.maxX, ComponentPanelLayout.gridWidth, accuracy: 0.001)
            XCTAssertEqual(frame.width, ComponentPanelLayout.itemWidth(for: trailing), accuracy: 0.001)
        }
    }

    func testEverySupportedWidthPacksWithoutOverflowOrOverlapInMixedOrders() {
        let spans = [PluginPanelWidgetGrid.standard, .compact].flatMap { grid in
            (1...grid.rawValue).flatMap { width in
                [1, 8, 17].map { PluginPanelWidgetSpan(width: width, height: $0, grid: grid)! }
            }
        }
        for offset in spans.indices {
            for reversed in [false, true] {
                let rotated = Array(spans[offset...] + spans[..<offset])
                let order = reversed ? Array(rotated.reversed()) : rotated
                let items = order.enumerated().map { (id: String($0.offset), span: $0.element) }
                let placements = ComponentGridPlacementEngine.placements(for: items)
                XCTAssertEqual(placements, ComponentGridPlacementEngine.placements(for: items))
                let frames = placements.map(PanelLayoutDestination.frame)
                for (index, frame) in frames.enumerated() {
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertGreaterThanOrEqual(frame.minY, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, ComponentPanelLayout.gridWidth + 0.001)
                    XCTAssertEqual(frame.width, ComponentPanelLayout.itemWidth(for: items[index].span))
                    for other in frames.dropFirst(index + 1) {
                        XCTAssertFalse(frame.intersects(other))
                        if frame.minY < other.maxY && other.minY < frame.maxY {
                            let gap = max(frame.minX - other.maxX, other.minX - frame.maxX)
                            XCTAssertGreaterThanOrEqual(gap, ComponentPanelLayout.horizontalSpacing - 0.001)
                        }
                    }
                }
            }
        }
    }

    func testIncrementalPlacementMatchesFullPackingWithoutMutatingPreview() {
        let compact = PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact)!
        let items: [(id: String, span: PluginPanelWidgetSpan)] = [
            ("half", .twoByTwo), ("icon", compact), ("full", .fourByTwo), ("last", compact)
        ]
        var state = ComponentGridPlacementEngine.State(hasCompactItems: true)
        let expected = ComponentGridPlacementEngine.placements(for: items)
        for (index, item) in items.enumerated() {
            XCTAssertEqual(state.next(id: item.id, span: item.span), expected[index])
            XCTAssertEqual(state.next(id: item.id, span: item.span), expected[index])
            XCTAssertEqual(state.append(id: item.id, span: item.span), expected[index])
        }
    }

    @MainActor
    func testLayoutCacheInvalidatesWhenOnlyGridDensityChanges() throws {
        let cache = ComponentGridLayoutCache()
        let standard = PluginPanelWidgetSpan(width: 1, height: 9)!
        let compact = PluginPanelWidgetSpan(width: 1, height: 9, grid: .compact)!
        let before = cache.placements(for: (0..<6).map { makeItem(id: "\($0)", span: standard) })
        let after = cache.placements(for: (0..<6).map { makeItem(id: "\($0)", span: compact) })
        XCTAssertGreaterThan(before[4].yOffset, 0)
        XCTAssertEqual(after[4].yOffset, 0)
        XCTAssertGreaterThan(after[5].yOffset, 0)
        XCTAssertEqual(PanelLayoutDestination.frame(after[4]).maxX, ComponentPanelLayout.gridWidth, accuracy: 0.001)
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

    private func makeItem(id: String, span: PluginPanelWidgetSpan) -> PluginPanelWidgetSnapshot {
        PluginPanelWidgetSnapshot(
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
        coordinator.toggle(placementID: "first", detailID: "cpu")
        coordinator.updatePresentationFrame(id: "first", frame: first)
        coordinator.toggle(placementID: "second", detailID: "cpu")
        XCTAssertEqual(coordinator.state.selection?.placementID, "second")
        XCTAssertNil(coordinator.state.selectedCardFrame)
        coordinator.updatePresentationFrame(id: "first", frame: first)
        XCTAssertNil(coordinator.state.selectedCardFrame)
        coordinator.updatePresentationFrame(id: "second", frame: second)
        XCTAssertEqual(coordinator.state.selectedCardFrame, second)
    }

    func testSwitchingDetailsWithinSameComponentPreservesAnchorFrame() {
        let coordinator = ComponentDetailCoordinator()
        let anchorFrame = CGRect(x: 20, y: 40, width: 300, height: 500)

        coordinator.toggle(placementID: "system-status", detailID: "cpu")
        coordinator.updatePresentationFrame(id: "system-status", frame: anchorFrame)
        coordinator.toggle(placementID: "system-status", detailID: "gpu")

        XCTAssertEqual(
            coordinator.state.selection,
            ComponentDetailCoordinator.Selection(placementID: "system-status", detailID: "gpu")
        )
        XCTAssertEqual(coordinator.state.selectedCardFrame, anchorFrame)
    }

    func testClickingSelectedDetailAgainDismissesSelectionAndAnchor() {
        let coordinator = ComponentDetailCoordinator()
        let anchorFrame = CGRect(x: 20, y: 40, width: 300, height: 500)

        coordinator.toggle(placementID: "system-status", detailID: "cpu")
        coordinator.updatePresentationFrame(id: "system-status", frame: anchorFrame)
        coordinator.toggle(placementID: "system-status", detailID: "cpu")

        XCTAssertNil(coordinator.state.selection)
        XCTAssertNil(coordinator.state.selectedCardFrame)
    }

    func testSwitchingComponentsClearsAnchorUntilNewComponentIsMeasured() {
        let coordinator = ComponentDetailCoordinator()
        let anchorFrame = CGRect(x: 20, y: 40, width: 300, height: 500)

        coordinator.toggle(placementID: "system-status", detailID: "cpu")
        coordinator.updatePresentationFrame(id: "system-status", frame: anchorFrame)
        coordinator.toggle(placementID: "another-component", detailID: "summary")

        XCTAssertEqual(
            coordinator.state.selection,
            ComponentDetailCoordinator.Selection(
                placementID: "another-component",
                detailID: "summary"
            )
        )
        XCTAssertNil(coordinator.state.selectedCardFrame)
    }
}
