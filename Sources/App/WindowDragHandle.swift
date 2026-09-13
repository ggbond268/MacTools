import AppKit
import SwiftUI

final class WindowDragHandleNSView: NSView {
    var onDragBegan: (() -> Void)?

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
    }
}

struct WindowDragHandleView: NSViewRepresentable {
    let onDragBegan: () -> Void

    func makeNSView(context: Context) -> WindowDragHandleNSView {
        let view = WindowDragHandleNSView()
        view.onDragBegan = onDragBegan
        return view
    }

    func updateNSView(_ nsView: WindowDragHandleNSView, context: Context) {
        nsView.onDragBegan = onDragBegan
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
                    }
                )
                .frame(width: 72, height: 15)

                Capsule(style: .continuous)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 28, height: 3)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .help(AppL10n.search(
                "search.dragHandle.help",
                defaultValue: "Drag to move and align"
            ))
            .accessibilityLabel(AppL10n.search(
                "search.dragHandle.help",
                defaultValue: "Drag to move and align"
            ))
            .accessibilityIdentifier("mactools.command-palette.drag-handle")
        }
    }
}
