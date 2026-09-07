import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditingSessionTests: XCTestCase {
    func testDragPreviewOnlyCommitsOnDropAndUsesOriginalInsertionOffsets() throws {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c", "d"]
        XCTAssertNotNil(session.begin(id: "b", ids: ids))
        session.preview(offset: 4, ids: ids)
        XCTAssertEqual(session.previewIDs(currentIDs: ids), ["a", "c", "d", "b"])
        XCTAssertEqual(session.originalIDs, ids)
        XCTAssertEqual(session.finish(ids: ids), .init(id: "b", offset: 4))
        XCTAssertNil(session.sourceID)
        XCTAssertNil(session.token)
    }

    func testLeavingAndCancellingNeverProducesAMove() {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c"]
        _ = session.begin(id: "c", ids: ids)
        session.preview(offset: 0, ids: ids)
        session.leave()
        XCTAssertEqual(session.previewIDs(currentIDs: ids), ids)
        XCTAssertNil(session.finish(ids: ids))
        _ = session.begin(id: "c", ids: ids)
        session.preview(offset: 0, ids: ids)
        session.cancel()
        XCTAssertNil(session.finish(ids: ids))
    }

    func testUnavailableSourceTargetAndExternalOrderChangesInvalidateDrag() {
        for changedIDs in [["b", "c"], ["a", "b"], ["c", "b", "a"], ["a", "b", "c", "d"]] {
            let session = PanelLayoutEditingSession()
            _ = session.begin(id: "a", ids: ["a", "b", "c"])
            session.preview(offset: 3, ids: ["a", "b", "c"])
            XCTAssertNil(session.finish(ids: changedIDs))
            XCTAssertNil(session.token)
        }
    }

    func testNoOpDropsAndInvalidStartsAreIgnored() {
        let session = PanelLayoutEditingSession()
        XCTAssertNil(session.begin(id: "missing", ids: ["a", "b"]))
        XCTAssertNil(session.begin(id: "a", ids: ["a"]))
        for offset in [1, 2] {
            _ = session.begin(id: "b", ids: ["a", "b", "c"])
            session.preview(offset: offset, ids: ["a", "b", "c"])
            XCTAssertNil(session.finish(ids: ["a", "b", "c"]))
        }
    }

    func testMoveOffsetsSupportBothDirectionsAndBoundaries() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(PanelLayoutDestination.moving("a", toOffset: 2, in: ids), ["b", "a", "c"])
        XCTAssertEqual(PanelLayoutDestination.moving("c", toOffset: 1, in: ids), ["a", "c", "b"])
        XCTAssertEqual(PanelLayoutDestination.moving("c", toOffset: -5, in: ids), ["c", "a", "b"])
        XCTAssertEqual(PanelLayoutDestination.moving("a", toOffset: 10, in: ids), ["b", "c", "a"])
    }

    func testListDestinationIncludesFirstLastAndRowHalves() {
        XCTAssertEqual(PanelLayoutDestination.listOffset(at: CGPoint(x: 5, y: -10), count: 3), 0)
        XCTAssertEqual(PanelLayoutDestination.listOffset(at: CGPoint(x: 5, y: 10), count: 3), 0)
        XCTAssertEqual(PanelLayoutDestination.listOffset(at: CGPoint(x: 5, y: 35), count: 3), 1)
        XCTAssertEqual(PanelLayoutDestination.listOffset(at: CGPoint(x: 5, y: 70), count: 3), 1)
        XCTAssertEqual(PanelLayoutDestination.listOffset(at: CGPoint(x: 5, y: 90), count: 3), 2)
        XCTAssertEqual(PanelLayoutDestination.listOffset(at: CGPoint(x: 5, y: 500), count: 3), 3)
    }

    func testMixedSpanGridDestinationAndPreviewUseSequenceOrder() {
        let items = [item("a", .twoByTwo), item("b", .oneByOne), item("c", .fourByTwo), item("d", .oneByTwo)]
        let placements = ComponentGridPlacementEngine.placements(for: items)
        for (index, placement) in placements.enumerated() {
            let rect = PanelLayoutDestination.frame(placement)
            let before = CGPoint(x: rect.minX + 2, y: rect.midY)
            let after = CGPoint(x: rect.maxX - 2, y: rect.midY)
            XCTAssertEqual(PanelLayoutDestination.gridOffset(at: before, placements: placements, rightToLeft: false), index)
            XCTAssertEqual(PanelLayoutDestination.gridOffset(at: after, placements: placements, rightToLeft: false), index + 1)
            let mirrored = CGPoint(x: ComponentPanelLayout.gridWidth - before.x, y: before.y)
            XCTAssertEqual(PanelLayoutDestination.gridOffset(at: mirrored, placements: placements, rightToLeft: true), index)
        }
        XCTAssertEqual(PanelLayoutDestination.gridOffset(at: CGPoint(x: 10, y: -1), placements: placements, rightToLeft: false), 0)
        XCTAssertEqual(PanelLayoutDestination.gridOffset(at: CGPoint(x: 10, y: 5000), placements: placements, rightToLeft: false), 4)
        let session = PanelLayoutEditingSession()
        let ids = items.map(\.id)
        _ = session.begin(id: "d", ids: ids)
        session.preview(offset: 0, ids: ids)
        let reordered = session.previewIDs(currentIDs: ids).compactMap { id in items.first { $0.id == id } }
        let preview = ComponentGridPlacementEngine.placements(for: reordered)
        XCTAssertEqual(preview.first?.id, "d")
        XCTAssertEqual(preview, ComponentGridPlacementEngine.placements(for: reordered))
        for (index, placement) in preview.enumerated() {
            for other in preview.dropFirst(index + 1) {
                XCTAssertFalse(PanelLayoutDestination.frame(placement).intersects(PanelLayoutDestination.frame(other)))
            }
        }
    }

    func testEdgeScrollDirectionAndCenterDeadZone() {
        XCTAssertLessThan(PanelLayoutDestination.scrollDelta(pointerY: 5, viewportHeight: 200), 0)
        XCTAssertGreaterThan(PanelLayoutDestination.scrollDelta(pointerY: 195, viewportHeight: 200), 0)
        XCTAssertEqual(PanelLayoutDestination.scrollDelta(pointerY: 100, viewportHeight: 200), 0)
        XCTAssertEqual(PanelLayoutDestination.scrollDelta(pointerY: -1, viewportHeight: 200), 0)
    }

    func testDragTransferAcceptsRegisteredPayloadWithoutSuggestedName() {
        let provider = PanelLayoutDragTransfer.provider(token: "session-token")

        XCTAssertNil(provider.suggestedName)
        XCTAssertTrue(PanelLayoutDragTransfer.accepts(
            providers: [provider],
            hasActiveSession: true,
            sessionIsValid: true
        ))
    }

    func testDragTransferRejectsMissingPayloadOrInvalidSession() {
        let provider = PanelLayoutDragTransfer.provider(token: "session-token")

        XCTAssertFalse(PanelLayoutDragTransfer.accepts(
            providers: [NSItemProvider()],
            hasActiveSession: true,
            sessionIsValid: true
        ))
        XCTAssertFalse(PanelLayoutDragTransfer.accepts(
            providers: [provider],
            hasActiveSession: false,
            sessionIsValid: true
        ))
        XCTAssertFalse(PanelLayoutDragTransfer.accepts(
            providers: [provider],
            hasActiveSession: true,
            sessionIsValid: false
        ))
    }

    func testEditModeEligibilityDoneEscapeTabChangeAndDismissal() {
        let model = MenuBarUnifiedPanelModel(selectedTab: .components, contentHeight: 400,
                                             maximumFeatureListHeight: 400, isPanelVisible: true)
        model.beginLayoutEditing(visibleItemCount: 1)
        XCTAssertFalse(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        XCTAssertTrue(model.endLayoutEditing())
        XCTAssertFalse(model.endLayoutEditing(), "A second Escape should reach panel dismissal")
        model.beginLayoutEditing(visibleItemCount: 2)
        model.selectTab(.features)
        XCTAssertFalse(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        model.update(selectedTab: .components, contentHeight: 450, maximumFeatureListHeight: 400, isPanelVisible: true)
        XCTAssertTrue(model.isEditingLayout, "Height refresh should preserve editing")
        model.update(selectedTab: .features, contentHeight: 450, maximumFeatureListHeight: 400, isPanelVisible: true)
        XCTAssertFalse(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        model.update(selectedTab: .features, contentHeight: 450, maximumFeatureListHeight: 400, isPanelVisible: false)
        XCTAssertFalse(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        XCTAssertFalse(model.isEditingLayout)
    }

    private func item(_ id: String, _ span: PluginComponentSpan) -> PluginComponentItem {
        PluginComponentItem(id: id, title: id, iconName: "circle", iconTint: .blue, description: "",
                            helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true)
    }
}
