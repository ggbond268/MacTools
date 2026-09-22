import MacToolsPluginKit
import SwiftUI

struct ClipboardHistoryRowStyle: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PluginPaletteMetrics.rowHorizontalPadding)
            .padding(.vertical, PluginPaletteMetrics.rowVerticalPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: PluginPaletteMetrics.rowCornerRadius,
                    style: .continuous
                )
                .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: PluginPaletteMetrics.rowCornerRadius)
                    .strokeBorder(
                        isSelected && contrast == .increased ? Color.primary : .clear,
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var background: Color {
        if isSelected {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }
}
