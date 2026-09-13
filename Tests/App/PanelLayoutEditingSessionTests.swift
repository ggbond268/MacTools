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
        let provider = providerFromPasteboard(token: "session-token")

        XCTAssertNil(provider.suggestedName)
        XCTAssertTrue(PanelLayoutDragTransfer.accepts(
            providers: [provider],
            hasActiveSession: true,
            sessionIsValid: true
        ))
    }

    func testDragTransferRejectsMissingPayloadOrInvalidSession() {
        let provider = providerFromPasteboard(token: "session-token")

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

    func testNativeCompletionDoesNotCancelACommittedMoveOrANewerDrag() throws {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c"]
        let oldToken = try XCTUnwrap(session.begin(id: "a", ids: ids))
        session.preview(offset: 3, ids: ids)
        let move = try XCTUnwrap(session.finish(ids: ids))
        let after = PanelLayoutDestination.moving(move.id, toOffset: move.offset, in: ids)
        session.didSave(move, beforeIDs: ids, afterIDs: after)
        session.sourceEnded(token: oldToken)
        XCTAssertEqual(session.feedback, .saved)
        let newToken = try XCTUnwrap(session.begin(id: "b", ids: after))
        session.sourceEnded(token: oldToken)
        XCTAssertEqual(session.token, newToken)
        session.sourceEnded(token: newToken)
        XCTAssertNil(session.token)
        XCTAssertEqual(session.feedback, .cancelled)
    }

    func testUndoRestoresBothDirectionsAndBoundariesAndCannotOverwriteAnExternalMove() throws {
        for (id, offset) in [("a", 3), ("c", 0), ("b", 0), ("b", 3)] {
            let session = PanelLayoutEditingSession()
            let before = ["a", "b", "c"]
            let after = PanelLayoutDestination.moving(id, toOffset: offset, in: before)
            session.didSave(.init(id: id, offset: offset), beforeIDs: before, afterIDs: after)
            XCTAssertTrue(session.canUndo(ids: after))
            let undo = try XCTUnwrap(session.takeUndo(ids: after))
            XCTAssertEqual(PanelLayoutDestination.moving(undo.id, toOffset: undo.offset, in: after), before)
            XCTAssertNil(session.takeUndo(ids: after), "Undo is consumed exactly once")
            session.didSave(.init(id: id, offset: offset), beforeIDs: before, afterIDs: after)
            session.reconcile(ids: ["c", "b"])
            XCTAssertNil(session.takeUndo(ids: after), "A changed item list must invalidate history")
        }
    }

    func testInvalidationAndNoOpDropHaveDifferentFeedback() throws {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b"]
        _ = session.begin(id: "a", ids: ids)
        session.preview(offset: 1, ids: ids)
        XCTAssertNil(session.finish(ids: ids))
        XCTAssertEqual(session.feedback, .unchanged)
        _ = session.begin(id: "a", ids: ids)
        session.preview(offset: 2, ids: ids)
        session.reconcile(ids: ["b"])
        XCTAssertNil(session.token)
        XCTAssertEqual(session.feedback, .invalidated)
    }

    func testGridInsertionMarkerUsesTheSameStableBoundaryInBothDirections() throws {
        let placements = ComponentGridPlacementEngine.placements(for: [
            item("a", PluginComponentSpan(width: 2, height: 12)!),
            item("b", PluginComponentSpan(width: 1, height: 24)!),
            item("c", PluginComponentSpan(width: 4, height: 12)!)
        ])
        for offset in 0...placements.count {
            let marker = try XCTUnwrap(PanelLayoutDestination.gridInsertionFrame(
                offset: offset, placements: placements, rightToLeft: false))
            let mirrored = try XCTUnwrap(PanelLayoutDestination.gridInsertionFrame(
                offset: offset, placements: placements, rightToLeft: true))
            XCTAssertEqual(marker.minX, ComponentPanelLayout.gridWidth - mirrored.maxX)
            XCTAssertEqual(marker.minY, mirrored.minY)
            let point = CGPoint(x: marker.midX, y: marker.midY)
            XCTAssertEqual(PanelLayoutDestination.gridOffset(at: point, placements: placements, rightToLeft: false), offset)
        }
    }

    func testEditorSizingKeepsShortCardsVisibleAndBoundsLongLayouts() {
        let short = PanelLayoutDestination.editorContentHeight(itemHeight: 96, maximumHeight: 600)
        let viewport = short - MenuBarPanelLayout.contentVerticalPadding
            - PanelLayoutDestination.footerHeight - PanelLayoutDestination.footerSpacing
        XCTAssertGreaterThanOrEqual(viewport, 96 + PanelLayoutDestination.dropTailHeight)
        XCTAssertEqual(PanelLayoutDestination.editorContentHeight(itemHeight: 2000, maximumHeight: 600), 600)
    }

    private func providerFromPasteboard(token: String) -> NSItemProvider {
        let item = PanelLayoutDragTransfer.pasteboardItem(token: token)
        XCTAssertEqual(item.string(forType: PanelLayoutDragTransfer.pasteboardType), token)
        return NSItemProvider(item: item.data(forType: PanelLayoutDragTransfer.pasteboardType)! as NSData,
                              typeIdentifier: PanelLayoutDragTransfer.type.identifier)
    }

    private func item(_ id: String, _ span: PluginComponentSpan) -> PluginComponentItem {
        PluginComponentItem(id: id, title: id, iconName: "circle", iconTint: .blue, description: "",
                            helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true)
    }
}
