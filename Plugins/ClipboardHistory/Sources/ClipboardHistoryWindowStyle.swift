import MacToolsPluginKit
import SwiftUI

enum ClipboardHistoryWindowContent {
    @MainActor
    static func makeHostingView<Content: View>(rootView: Content) -> ClipboardHistoryHostingContainer<Content> {
        ClipboardHistoryHostingContainer(rootView: rootView)
    }
}

/// A plain AppKit content view keeps SwiftUI's top-level window sizing behavior
/// out of the panel. The hosting view follows the user's frame, never vice versa.
@MainActor
final class ClipboardHistoryHostingContainer<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        // The custom surface already owns its padding and drag handle. Keep native
        // resizing, but do not reserve an invisible title-bar strip in SwiftUI.
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }
}

/// A nearly opaque native backdrop keeps busy desktop content from competing with text.
struct ClipboardHistoryWindowSurface: View {
    enum Role {
        case history
        case actions
        case queue
    }

    let role: Role
    let reducesTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: PluginPaletteMetrics.surfaceCornerRadius,
            style: .continuous
        )
        Group {
            if reducesTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay { shape.strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5) }
            } else {
                ClipboardHistoryWindowMaterial()
                    .overlay { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.88)) }
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5) }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ClipboardHistoryWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
