import SwiftUI

/// Preserve native button behavior while aligning labels and adding neutral hover feedback.
struct ClipboardHistoryDetailActionStyle: PrimitiveButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, isActive: isActive)
    }

    private struct ActionBody: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let isActive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var isHovered = false

        var body: some View {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
                    .frame(minWidth: 18)
                    .frame(height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.subheadline)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEnabled && (isHovered || isActive)
                        ? Color.primary.opacity(contrast == .increased ? 0.12 : 0.06)
                        : .clear)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
        }
    }
}
