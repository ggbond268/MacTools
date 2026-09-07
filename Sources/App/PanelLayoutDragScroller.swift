import AppKit
import SwiftUI

/// Scrolls while the pointer rests near an edge, including between drag-update events.
@MainActor
final class PanelLayoutDragScroller: ObservableObject {
    weak var anchor: NSView?
    private var timer: Timer?
    private var onScroll: ((CGPoint) -> Void)?

    func start(onScroll: @escaping (CGPoint) -> Void) {
        self.onScroll = onScroll
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onScroll = nil
    }

    private func tick() {
        // Physical button state is not the native drag lifetime (for example with
        // trackpad drag lock). Only the source's completion callback ends a drag.
        scroll(at: NSEvent.mouseLocation)
    }

    func scroll(at screenPoint: CGPoint) {
        guard let anchor, let window = anchor.window, let scrollView = anchor.enclosingScrollView,
              let document = scrollView.documentView else { stop(); return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let clip = scrollView.contentView
        let clipPoint = clip.convert(windowPoint, from: nil)
        guard clip.bounds.contains(clipPoint) else { return }
        let localY = clipPoint.y - clip.bounds.minY
        let pointerY = clip.isFlipped ? localY : clip.bounds.height - localY
        let delta = PanelLayoutDestination.scrollDelta(pointerY: pointerY, viewportHeight: clip.bounds.height)
        guard abs(delta) > 0.1 else { return }
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? delta : -delta
        origin.y = min(max(origin.y, 0), max(0, document.bounds.height - clip.bounds.height))
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        onScroll?(anchor.convert(windowPoint, from: nil))
    }
}

struct PanelLayoutScrollAnchor: NSViewRepresentable {
    let scroller: PanelLayoutDragScroller

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        scroller.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scroller.anchor = nsView
    }

    private final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
