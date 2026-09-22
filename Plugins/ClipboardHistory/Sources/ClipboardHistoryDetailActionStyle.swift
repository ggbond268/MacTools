import MacToolsPluginKit
import SwiftUI

/// One hit target and visual treatment for the preview's primary and secondary actions.
struct ClipboardHistoryDetailActionStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, isPrimary: isPrimary, isEnabled: isEnabled)
    }

    private struct ActionBody: View {
        let configuration: ButtonStyleConfiguration
        let isPrimary: Bool
        let isEnabled: Bool
        @State private var isHovered = false
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .padding(.horizontal, 10)
                .frame(minWidth: 36)
                .frame(height: 36)
                .foregroundStyle(!isEnabled ? Color.secondary : isPrimary
                    ? PluginPaletteColors.selectedText : Color.primary)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            contrast == .increased || (isPrimary && (isHovered || configuration.isPressed))
                                ? (isPrimary && isEnabled
                                ? PluginPaletteColors.selectedText : Color.primary)
                                : PluginSettingsTheme.Palette.cardBorder,
                            lineWidth: configuration.isPressed ? 2 : 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.1), value: isHovered)
        }

        private var background: Color {
            if isPrimary && isEnabled {
                return Color(nsColor: .selectedContentBackgroundColor)
            }
            return isHovered || configuration.isPressed
                ? PluginSettingsTheme.Palette.activeControlBackground
                : PluginSettingsTheme.Palette.fieldBackground
        }
    }
}
