import AppKit
import Combine
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditingSessionTests: XCTestCase {
    func testPointerPreviewDoesNotInvalidateTheEditorSession() throws {
        let session = PanelLayoutEditingSession()
        let ids = (0..<20).map(String.init)
        XCTAssertNotNil(session.begin(id: "0", ids: ids))
        var editorUpdates = 0
        var markerUpdates = 0
        let editorSubscription = session.objectWillChange.sink { editorUpdates += 1 }
        let markerSubscription = session.dragPreview.objectWillChange.sink { markerUpdates += 1 }
        defer { editorSubscription.cancel(); markerSubscription.cancel() }

        for offset in 0..<20 {
            for _ in 0..<10 { session.preview(offset: offset, ids: ids) }
        }
        XCTAssertEqual(markerUpdates, 20, "Repeated pointer events within one boundary should not redraw")
        XCTAssertEqual(editorUpdates, 0, "Moving the marker must not rebuild cards or the action bar")
        session.leave()
        XCTAssertEqual(markerUpdates, 21)
        XCTAssertEqual(editorUpdates, 0)
        XCTAssertNil(session.destination)
    }

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

    func testRepeatedPreviewAtSameDestinationDoesNotRepublishState() {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c"]
        _ = session.begin(id: "a", ids: ids)
        var updateCount = 0
        let cancellable = session.objectWillChange.sink { updateCount += 1 }

        session.preview(offset: 3, ids: ids)
        XCTAssertEqual(updateCount, 0)

        session.preview(offset: 3, ids: ids)
        XCTAssertEqual(updateCount, 0)
        withExtendedLifetime(cancellable) {}
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
        XCTAssertNotNil(session.begin(id: "a", ids: ["a"]), "A single item can move to another panel")
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

    func testMixedSpanGridDestinationAndPreviewUseSequenceOrder() {
        let items = [item("a", .twoByTwo), item("b", .oneByOne), item("c", .fourByTwo), item("d", .oneByTwo)]
        let placements = ComponentGridPlacementEngine.placements(for: items)
        let geometry = geometry(for: placements)
        for (index, placement) in placements.enumerated() {
            let rect = PanelLayoutDestination.frame(placement)
            let before = CGPoint(x: rect.minX + 2, y: rect.midY)
            let after = CGPoint(x: rect.maxX - 2, y: rect.midY)
            XCTAssertEqual(geometry.target(at: before, rightToLeft: false).offset, index)
            XCTAssertEqual(geometry.target(at: after, rightToLeft: false).offset, index + 1)
            let mirrored = CGPoint(x: ComponentPanelLayout.gridWidth - before.x, y: before.y)
            XCTAssertEqual(geometry.target(at: mirrored, rightToLeft: true).offset, index)
        }
        XCTAssertEqual(geometry.target(at: CGPoint(x: 10, y: -1), rightToLeft: false).offset, 0)
        XCTAssertEqual(geometry.target(at: CGPoint(x: 10, y: 5000), rightToLeft: false).offset, 4)
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
        model.beginLayoutEditing(visibleItemCount: 0)
        XCTAssertTrue(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        XCTAssertTrue(model.endLayoutEditing())
        XCTAssertFalse(model.endLayoutEditing(), "A second Escape should reach panel dismissal")
        model.beginLayoutEditing(visibleItemCount: 2)
        model.selectTab(.features)
        XCTAssertTrue(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        model.update(selectedTab: .components, contentHeight: 450, maximumFeatureListHeight: 400, isPanelVisible: true)
        XCTAssertTrue(model.isEditingLayout, "Height refresh should preserve editing")
        model.update(selectedTab: .features, contentHeight: 450, maximumFeatureListHeight: 400, isPanelVisible: true)
        XCTAssertTrue(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        model.update(selectedTab: .features, contentHeight: 450, maximumFeatureListHeight: 400, isPanelVisible: false)
        XCTAssertFalse(model.isEditingLayout)
        model.beginLayoutEditing(visibleItemCount: 2)
        XCTAssertFalse(model.isEditingLayout)
    }

    func testEditingChangeCallbackRunsWithoutAnExtraMainRunLoopTurn() {
        let model = MenuBarUnifiedPanelModel(selectedTab: .components, contentHeight: 400,
                                             maximumFeatureListHeight: 400, isPanelVisible: true)
        var changes: [Bool] = []
        model.onLayoutEditingChange = { changes.append($0) }

        model.beginLayoutEditing(visibleItemCount: 2)
        XCTAssertEqual(changes, [true])

        XCTAssertTrue(model.endLayoutEditing())
        XCTAssertEqual(changes, [true, false])
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
            item("a", PluginPanelWidgetSpan(width: 2, height: 12)!),
            item("b", PluginPanelWidgetSpan(width: 1, height: 24)!),
            item("c", PluginPanelWidgetSpan(width: 4, height: 12)!)
        ])
        let geometry = geometry(for: placements)
        for placement in placements {
            let frame = PanelLayoutDestination.frame(placement)
            let point = CGPoint(x: frame.minX + 1, y: frame.midY)
            let target = geometry.target(at: point, rightToLeft: false)
            let mirroredPoint = CGPoint(x: ComponentPanelLayout.gridWidth - point.x, y: point.y)
            let mirrored = geometry.target(at: mirroredPoint, rightToLeft: true)
            let marker = try XCTUnwrap(target.markerFrame)
            let mirroredMarker = try XCTUnwrap(mirrored.markerFrame)
            XCTAssertEqual(marker.minX, ComponentPanelLayout.gridWidth - mirroredMarker.maxX, accuracy: 0.001)
            XCTAssertEqual(marker.minY, mirroredMarker.minY)
            XCTAssertEqual(target.offset, mirrored.offset)
            XCTAssertEqual(geometry.target(at: CGPoint(x: marker.midX, y: marker.midY), rightToLeft: false).offset,
                           target.offset)
        }
    }

    func testEditorSizingKeepsShortCardsVisibleAndBoundsLongLayouts() {
        let short = PanelLayoutDestination.editorContentHeight(itemHeight: 96, maximumHeight: 600)
        let viewport = short - MenuBarPanelLayout.contentVerticalPadding
        XCTAssertGreaterThanOrEqual(viewport, 96 + PanelLayoutDestination.dropTailHeight)
        XCTAssertEqual(PanelLayoutDestination.editorContentHeight(itemHeight: 2000, maximumHeight: 600), 600)
        let empty = PanelLayoutDestination.editorContentHeight(itemHeight: 0, maximumHeight: 600)
        XCTAssertEqual(MenuBarPanelLayout.panelHeight(forContentHeight: empty, showsEditingActionBar: true),
                       MenuBarPanelLayout.minimumPanelHeight, "The footer must not add empty space to the minimum panel size")
    }

    private func geometry(for placements: [ComponentGridPlacement]) -> PanelLayoutDropGeometry {
        PanelLayoutDropGeometry(frames: placements.map {
            .init(entry: .init(placement: .init(item: .init(pluginID: $0.id, itemID: "widget")), kind: .widget),
                  frame: PanelLayoutDestination.frame($0))
        })
    }

    private func providerFromPasteboard(token: String) -> NSItemProvider {
        let item = PanelLayoutDragTransfer.pasteboardItem(token: token)
        XCTAssertEqual(item.string(forType: PanelLayoutDragTransfer.pasteboardType), token)
        return NSItemProvider(item: item.data(forType: PanelLayoutDragTransfer.pasteboardType)! as NSData,
                              typeIdentifier: PanelLayoutDragTransfer.type.identifier)
    }

    private func item(_ id: String, _ span: PluginPanelWidgetSpan) -> PluginPanelWidgetSnapshot {
        PluginPanelWidgetSnapshot(id: id, title: id, iconName: "circle", iconTint: .blue, description: "",
                            helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true)
    }
}
