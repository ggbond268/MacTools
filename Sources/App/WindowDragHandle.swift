import AppKit
import SwiftUI

final class WindowDragHandleNSView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDragBegan?()
        window.performDrag(with: event)
        onDragEnded?()
    }
}

struct WindowDragHandleView: NSViewRepresentable {
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> WindowDragHandleNSView {
        let view = WindowDragHandleNSView()
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: WindowDragHandleNSView, context: Context) {
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
    }
}

struct WindowDragHandleBar: View {
    let coordinator: WindowSnapCoordinator?

    var body: some View {
        if let coordinator {
            ZStack {
                WindowDragHandleView(
                    onDragBegan: { [weak coordinator] in
                        coordinator?.startDragging()
                    },
                    onDragEnded: { [weak coordinator] in
                        coordinator?.finishDragging()
                    }
                )
                .frame(height: 14)

                Capsule(style: .continuous)
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.4))
                    .frame(width: 36, height: 4)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("mactools.command-palette.drag-handle")
        }
    }
}
