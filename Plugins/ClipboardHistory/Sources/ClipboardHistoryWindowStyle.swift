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

/// Companion windows share their surface; only the Actions window emphasizes focus.
struct ClipboardHistoryWindowSurface: View {
    enum Role {
        case history
        case actions
    }

    let role: Role
    let reducesTransparency: Bool

    var body: some View {
        PluginPaletteSurface(reducesTransparency: reducesTransparency)
            .overlay {
                RoundedRectangle(
                    cornerRadius: PluginPaletteMetrics.surfaceCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    role == .actions ? Color.accentColor.opacity(0.55) : PluginSettingsTheme.Palette.cardBorder,
                    lineWidth: 1
                )
            }
            .allowsHitTesting(false)
    }
}
