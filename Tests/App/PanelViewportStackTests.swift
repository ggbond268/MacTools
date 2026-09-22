import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PanelViewportStackTests: XCTestCase {
    func testShrinkingDocumentKeepsTheNewBottomMountedBeforeNativeScrollClamping() {
        let viewport = CGRect(x: 0, y: 10_000, width: 304, height: 320)
        let frame = PanelItemFrame(id: "last", frame: CGRect(x: 0, y: 400, width: 304, height: 100))
        let clamped = PanelViewportState.clampedViewport(viewport, contentHeight: 500)
        XCTAssertEqual(clamped.minY, 180)
        XCTAssertEqual(PanelViewportState.visibleIDs(in: clamped, frames: [frame]), ["last"])
    }

    func testViewportIncludesOverscanAndKeepsIndependentIdentities() {
        let frames = (0..<120).map { index in
            PanelItemFrame(id: "copy-\(index)", frame: CGRect(
                x: index.isMultiple(of: 2) ? 0 : 156,
                y: CGFloat(index / 2) * 106, width: 148, height: 100))
        }
        let ids = PanelViewportState.visibleIDs(in: CGRect(x: 0, y: 1000, width: 304, height: 320), frames: frames)
        XCTAssertEqual(ids, Set(frames.filter { $0.frame.maxY > 840 && $0.frame.minY < 1480 }.map(\.id)))
        XCTAssertTrue(ids.contains("copy-18"))
        XCTAssertTrue(ids.contains("copy-19"))
        XCTAssertFalse(ids.contains("copy-0"))
    }

    func testLargePanelMountsOnlyNearbyViewsAndScrollsToLastCopy() async throws {
        let frames = (0..<1000).map { index in
            PanelItemFrame(id: "copy-\(index)", frame: CGRect(
                x: index.isMultiple(of: 2) ? 0 : 156,
                y: CGFloat(index / 2) * 106, width: 148, height: 100))
        }
        let height = try XCTUnwrap(frames.last).frame.maxY
        let probe = MountProbe()
        let root = NSHostingView(rootView: ScrollView(.vertical) {
            PanelViewportStack(frames: frames, width: 304, height: height,
                               retainedIDs: ["copy-0"]) { id in
                MountedWidget(id: id, probe: probe)
            }
        }.frame(width: 304, height: 320))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 304, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(probe.mounted.contains("copy-0"))
        XCTAssertLessThan(probe.mounted.count, 80, "Offscreen copies must not instantiate plugin views")
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(document.bounds.height, height, accuracy: 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(probe.mounted.contains("copy-999"))
        XCTAssertLessThan(probe.mounted.count, 160)
        XCTAssertEqual(probe.active["copy-0"], 1, "An active detail or drag anchor must survive scrolling")
        XCTAssertNil(probe.active["copy-1"], "Ordinary offscreen copies should leave the view hierarchy")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class MountProbe {
    var mounted: Set<String> = []
    var active: [String: Int] = [:]
}

private struct MountedWidget: NSViewRepresentable {
    let id: String
    let probe: MountProbe

    func makeCoordinator() -> Coordinator { Coordinator(id: id, probe: probe) }

    func makeNSView(context: Context) -> NSView {
        probe.mounted.insert(id)
        probe.active[id, default: 0] += 1
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.probe.active.removeValue(forKey: coordinator.id)
    }
    final class Coordinator {
        let id: String
        let probe: MountProbe
        init(id: String, probe: MountProbe) { self.id = id; self.probe = probe }
    }
}
