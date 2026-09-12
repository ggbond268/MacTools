import AppKit
import SwiftUI
import MacToolsPluginKit

/// Native source completion owns cancellation; SwiftUI's destination owns commit.
struct PanelLayoutDragSource: NSViewRepresentable {
    let id: String
    let title: String
    let icon: String
    let begin: () -> String?
    let end: (String) -> Void
    @Environment(\.layoutDirection) private var layoutDirection

    func makeNSView(context: Context) -> PanelLayoutDragSourceView {
        let view = PanelLayoutDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PanelLayoutDragSourceView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("panel.layout.drag.\(id)")
        view.title = title
        view.icon = icon
        view.menuOnLeft = layoutDirection == .rightToLeft
        view.onBegin = begin
        view.onEnd = end
    }
}

@MainActor
final class PanelLayoutDragSourceView: NSView, NSDraggingSource {
    var title = ""
    var icon = ""
    var menuOnLeft = false
    var onBegin: (() -> String?)?
    var onEnd: ((String) -> Void)?
    private var mouseDownPoint: CGPoint?
    private var completion: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The menu has a 22-point label and six points of surrounding padding.
    var menuFrame: CGRect {
        CGRect(x: menuOnLeft ? 0 : max(0, bounds.width - 34),
               y: max(0, bounds.height - 40), width: min(34, bounds.width),
               height: min(40, bounds.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !menuFrame.contains(local) else { return nil }
        return self
    }

    override func resetCursorRects() {
        // Keep the menu's normal pointer while making the card affordance explicit.
        let body = CGRect(x: 0, y: 0, width: bounds.width, height: menuFrame.minY)
        let footer = CGRect(x: menuOnLeft ? menuFrame.maxX : 0, y: menuFrame.minY,
                            width: max(0, bounds.width - menuFrame.width), height: menuFrame.height)
        addCursorRect(body, cursor: .openHand)
        addCursorRect(footer, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard completion == nil, let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4,
              let token = onBegin?() else { return }
        mouseDownPoint = nil
        // Capture this gesture's callback. SwiftUI may update or remove the source
        // view after a commit, and a late source callback must not end a newer drag.
        let end = onEnd
        completion = { end?(token) }
        let item = NSDraggingItem(pasteboardWriter: PanelLayoutDragTransfer.pasteboardItem(token: token))
        let point = convert(event.locationInWindow, from: nil)
        let image = draggingImage()
        item.setDraggingFrame(CGRect(x: point.x - 18, y: point.y - 18,
                                     width: image.size.width, height: image.size.height), contents: image)
        let draggingSession = beginDraggingSession(with: [item], event: event, source: self)
        draggingSession.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let end = completion
        completion = nil
        mouseDownPoint = nil
        end?()
    }

    private func draggingImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 200, height: 36))
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: image.size), xRadius: 8, yRadius: 8).fill()
        NSImage(systemSymbolName: PluginSystemImage.resolvedName(icon), accessibilityDescription: nil)?
            .draw(in: CGRect(x: 10, y: 10, width: 16, height: 16))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: CGRect(x: 34, y: 9, width: 156, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        image.unlockFocus()
        return image
    }
}
