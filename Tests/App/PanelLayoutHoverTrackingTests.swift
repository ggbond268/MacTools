import AppKit
import Combine
import XCTest
@testable import MacTools

@MainActor
final class PanelLayoutHoverTrackingTests: XCTestCase {
    func testStationaryPointerTracksRapidScrollingAndRemovedCards() async throws {
        let hover = PanelLayoutHoverState()
        let region = PanelLayoutHoverTrackingView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        region.hover = hover
        hover.trackingView = region
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        scroll.documentView = region
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }
        let cards = (0..<8).map { index in
            let card = NSView(frame: CGRect(x: 0, y: index * 100, width: 240, height: 100))
            region.addSubview(card)
            hover.register(card, id: "card-\(index)")
            return card
        }
        let point = scroll.contentView.convert(CGPoint(x: 80, y: 50), to: nil)
        region.pointerLocationInWindow = { _ in point }
        region.layoutSubtreeIfNeeded()
        region.refresh()
        XCTAssertEqual(hover.activeItemID, "card-0")
        var owners: [String?] = []
        let subscription = hover.$activeItemID.sink { owners.append($0) }
        defer { subscription.cancel() }
        // No mouse-enter/exit events are sent. Only the clip bounds change.
        for offset in stride(from: 100, through: 600, by: 100) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(hover.activeItemID, "card-6")
        XCTAssertEqual(owners, ["card-0", "card-6"], "Scroll notifications should resolve the latest geometry once")
        hover.unregister(cards[6])
        cards[6].removeFromSuperview()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(hover.activeItemID)
        scroll.contentView.scroll(to: .zero)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(hover.activeItemID, "card-0")
        region.pointerLocationInWindow = { _ in CGPoint(x: -100, y: -100) }
        region.refresh()
        XCTAssertNil(hover.activeItemID)
    }

    func testFocusAndDragShareOneOverlayOwner() {
        let hover = PanelLayoutHoverState()
        hover.focusChanged(id: "first", isFocused: true)
        XCTAssertEqual(hover.activeItemID, "first")
        hover.focusChanged(id: "second", isFocused: true)
        hover.focusChanged(id: "first", isFocused: false)
        XCTAssertEqual(hover.activeItemID, "second", "Late focus departure must not clear the new owner")
        hover.setDragging(true)
        XCTAssertNil(hover.activeItemID)
        hover.setDragging(false)
        XCTAssertEqual(hover.activeItemID, "second")
    }

    func testOwnerChangeOnlyNotifiesTheTwoAffectedCards() {
        let hover = PanelLayoutHoverState()
        let states = (0..<20).map { hover.state(for: "card-\($0)") }
        var updates = Array(repeating: 0, count: states.count)
        let subscriptions = states.enumerated().map { index, state in
            state.objectWillChange.sink { updates[index] += 1 }
        }
        defer { subscriptions.forEach { $0.cancel() } }

        hover.focusChanged(id: "card-0", isFocused: true)
        updates = Array(repeating: 0, count: states.count)
        hover.focusChanged(id: "card-1", isFocused: true)
        hover.focusChanged(id: "card-0", isFocused: false)
        hover.focusChanged(id: "card-1", isFocused: true)

        XCTAssertEqual(updates, [1, 1] + Array(repeating: 0, count: 18))
        XCTAssertFalse(states[0].isActive)
        XCTAssertTrue(states[1].isActive)
        XCTAssertTrue(states[1] === hover.state(for: "card-1"))
        hover.setDragging(true)
        XCTAssertFalse(states[1].isActive)
        hover.setDragging(false)
        XCTAssertTrue(states[1].isActive)
    }

    func testCenteredControlsFitWideRowsAndNarrowCards() {
        for size in [CGSize(width: 304, height: 47), CGSize(width: 70, height: 128), CGSize(width: 70, height: 64)] {
            let bounds = CGRect(origin: .zero, size: size)
            let frame = PanelLayoutItemControlsLayout.frame(in: bounds)
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertEqual(frame.midX, bounds.midX)
            XCTAssertEqual(frame.midY, bounds.midY)
        }
        XCTAssertTrue(PanelLayoutItemControlsLayout(size: CGSize(width: 70, height: 128)).isVertical)
        XCTAssertFalse(PanelLayoutItemControlsLayout(size: CGSize(width: 304, height: 47)).isVertical)
    }
}
