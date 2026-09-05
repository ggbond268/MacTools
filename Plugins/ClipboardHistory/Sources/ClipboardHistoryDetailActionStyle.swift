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

        var body: some View {
            configuration.label
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .padding(.horizontal, 10)
                .frame(minWidth: 36)
                .frame(height: 36)
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            isPrimary ? Color.clear : PluginSettingsTheme.Palette.cardBorder,
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.1), value: isHovered)
        }

        private var background: Color {
            if isPrimary {
                return Color.accentColor.opacity(configuration.isPressed ? 0.65 : isHovered ? 0.85 : 1)
            }
            return isHovered || configuration.isPressed
                ? PluginSettingsTheme.Palette.activeControlBackground
                : PluginSettingsTheme.Palette.fieldBackground
        }
    }
}
