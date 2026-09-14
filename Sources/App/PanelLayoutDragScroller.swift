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
    let hover: PanelLayoutHoverState
    var bottomRequest: UUID? = nil

    func makeCoordinator() -> PanelLayoutBottomFollower { PanelLayoutBottomFollower() }

    func makeNSView(context: Context) -> NSView {
        let view = PanelLayoutHoverTrackingView()
        view.identifier = NSUserInterfaceItemIdentifier("panel.layout.canvas")
        view.hover = hover
        hover.trackingView = view
        scroller.anchor = view
        view.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.attach(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scroller.anchor = nsView
        context.coordinator.update(request: bottomRequest, anchor: nsView)
    }

    static func dismantleNSView(_ view: NSView, coordinator: PanelLayoutBottomFollower) {
        (view as? PanelLayoutHoverTrackingView)?.onLayout = nil
        coordinator.detach()
    }
}

/// Follow document and viewport resizing after an insertion, until the user scrolls away.
/// The request survives the SwiftUI update that precedes AppKit's document layout.
@MainActor
final class PanelLayoutBottomFollower: NSObject {
    private weak var scrollView: NSScrollView?
    private var lastRequest: UUID?
    private var followsBottom = false
    private var isScrolling = false
    private var documentSize = CGSize.zero
    private var viewportSize = CGSize.zero

    func update(request: UUID?, anchor: NSView) {
        if request != lastRequest {
            lastRequest = request
            followsBottom = request != nil
        }
        attach(to: anchor)
        scrollToBottom()
    }

    func attach(to anchor: NSView) {
        guard let scroll = anchor.enclosingScrollView else { return }
        if scroll !== scrollView {
            detach()
            scrollView = scroll
            scroll.documentView?.postsFrameChangedNotifications = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)),
                name: NSView.frameDidChangeNotification, object: scroll.documentView)
            NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        scrollToBottom()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
    }

    @objc private func geometryChanged(_ notification: Notification) {
        guard !isScrolling, let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let resized = documentSize != document.bounds.size || viewportSize != clip.bounds.size
        // Native user scrolling changes the origin without changing either size.
        if !resized, notification.object as? NSClipView === clip,
           abs(clip.bounds.minY - bottomOrigin(document: document, clip: clip)) > 1 {
            followsBottom = false
        }
        scrollToBottom()
    }

    private func bottomOrigin(document: NSView, clip: NSClipView) -> CGFloat {
        document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
    }

    private func scrollToBottom() {
        guard !isScrolling, let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        documentSize = document.bounds.size
        viewportSize = clip.bounds.size
        guard followsBottom else { return }
        let origin = CGPoint(x: clip.bounds.minX, y: bottomOrigin(document: document, clip: clip))
        guard origin != clip.bounds.origin else { return }
        isScrolling = true
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        isScrolling = false
    }
}
