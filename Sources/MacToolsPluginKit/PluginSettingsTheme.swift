import AppKit
import SwiftUI

public enum PluginSettingsTheme {
    public enum Typography {
        public static var pageTitle: Font {
            .title2.weight(.semibold)
        }

        public static var pageDescription: Font {
            .subheadline
        }

        public static var sectionTitle: Font {
            .body.weight(.semibold)
        }

        public static var rowTitle: Font {
            .body.weight(.medium)
        }

        public static var emphasizedRowTitle: Font {
            .body.weight(.semibold)
        }

        public static var rowDescription: Font {
            .subheadline
        }

        public static var secondaryLabel: Font {
            .subheadline.weight(.medium)
        }

        public static var statusBadge: Font {
            .caption2.weight(.medium)
        }

        public static var rowIcon: Font {
            .caption.weight(.semibold)
        }

        public static var controlLabel: Font {
            .callout
        }

        public static var monospacedValue: Font {
            .system(size: 12, design: .monospaced)
        }
    }

    public enum Spacing {
        public static let pagePadding: CGFloat = 24
        public static let section: CGFloat = 18
        public static let sectionHeaderContent: CGFloat = 10
        public static let cardContent: CGFloat = 16
        public static let rowHorizontal: CGFloat = 16
        public static let rowVertical: CGFloat = 10
        public static let interactiveRowVertical: CGFloat = 12
        public static let rowTitleDescription: CGFloat = 3
        public static let rowContentControl: CGFloat = 12
        public static let controlCluster: CGFloat = 8
    }

    public enum Radius {
        public static let card: CGFloat = 10
        public static let hostCard: CGFloat = 12
        public static let control: CGFloat = 8
        public static let field: CGFloat = 6
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let standard: CGFloat = 1
    }

    public enum Size {
        public static let pageIcon: CGFloat = 42
        public static let rowIcon: CGFloat = 18
        public static let controlHeight: CGFloat = 30
        public static let shortcutRecorderWidth: CGFloat = 126
        public static let metricIcon: CGFloat = 36
        public static let emptyStateIcon: CGFloat = 28
    }

    public enum Palette {
        public static var recessedControlBackground: Color {
            Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }

        public static var fieldBackground: Color {
            Color(nsColor: .textBackgroundColor)
        }

        public static var keycapBackground: Color {
            Color(nsColor: .controlBackgroundColor)
        }

        public static var separator: Color {
            Color(nsColor: .separatorColor)
        }

        public static var cardBorder: Color {
            Color(nsColor: .separatorColor)
        }

        public static var sidebarHoverBackground: Color {
            Color.primary.opacity(0.05)
        }

        public static var sidebarSelectionBackground: Color {
            Color.accentColor.opacity(0.12)
        }

        public static var activeControlBackground: Color {
            Color.accentColor.opacity(0.12)
        }

        public static var recordingBackground: Color {
            Color.accentColor.opacity(0.08)
        }

    }

    public enum Surface {
        /// A raised control inside a recessed surface, such as the selected
        /// segment in a custom tab strip. Outer settings cards must use
        /// `pluginSettingsCardBackground(_:)` so their material and clipping
        /// stay consistent across appearances.
        public static var raisedControl: AnyShapeStyle {
            AnyShapeStyle(.background)
        }

        fileprivate static var standardCard: AnyShapeStyle {
            // Match the subtle adaptive separation of macOS grouped Form
            // cards without introducing fixed light/dark color branches.
            AnyShapeStyle(.ultraThinMaterial)
        }
    }
}

public enum PluginSettingsCardBackgroundStyle {
    case standard
    case recessed
}

public enum PluginSettingsListDividerStyle {
    case horizontal
    case vertical
}

public struct PluginSettingsCardBackground: ViewModifier {
    private let style: PluginSettingsCardBackgroundStyle

    public init(_ style: PluginSettingsCardBackgroundStyle = .standard) {
        self.style = style
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background(
                shape.fill(backgroundStyle)
            )
            // A card owns its visible surface. Clipping prevents native list
            // or editor backgrounds from punching square corners through it.
            .clipShape(shape)
    }

    private var radius: CGFloat {
        switch style {
        case .standard:
            return PluginSettingsTheme.Radius.hostCard
        case .recessed:
            return PluginSettingsTheme.Radius.card
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch style {
        case .standard:
            return PluginSettingsTheme.Surface.standardCard
        case .recessed:
            return AnyShapeStyle(PluginSettingsTheme.Palette.recessedControlBackground)
        }
    }

}

public struct PluginSettingsListDivider: View {
    private let style: PluginSettingsListDividerStyle
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat

    public init(
        _ style: PluginSettingsListDividerStyle = .horizontal,
        leadingInset: CGFloat = PluginSettingsTheme.Spacing.rowHorizontal,
        trailingInset: CGFloat = PluginSettingsTheme.Spacing.rowHorizontal
    ) {
        self.style = style
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
    }

    public var body: some View {
        switch style {
        case .horizontal:
            Rectangle()
                .fill(PluginSettingsTheme.Palette.separator)
                .frame(height: PluginSettingsTheme.Stroke.standard)
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
        case .vertical:
            Rectangle()
                .fill(PluginSettingsTheme.Palette.separator)
                .frame(width: PluginSettingsTheme.Stroke.standard)
        }
    }
}

/// Keeps a shortcut's icon/title and recorder in one compact line. The first
/// child is the only compressible label; recorder fields and trailing actions
/// retain their intrinsic sizes as the settings window narrows.
public struct PluginSettingsShortcutControlLayout: Layout {
    private let spacing: CGFloat
    private let maximumLabelWidth: CGFloat

    public init(
        spacing: CGFloat = PluginSettingsTheme.Spacing.controlCluster,
        maximumLabelWidth: CGFloat = 160
    ) {
        self.spacing = max(spacing, 0)
        self.maximumLabelWidth = max(maximumLabelWidth, 0)
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let label = subviews.first else {
            return .zero
        }

        let trailingSizes = subviews.dropFirst().map {
            $0.sizeThatFits(.unspecified)
        }
        let totalSpacing = spacing * CGFloat(max(subviews.count - 1, 0))
        let trailingWidth = trailingSizes.reduce(0) { $0 + $1.width }
        let proposedLabelWidth = proposal.width.map {
            max($0 - trailingWidth - totalSpacing, 0)
        } ?? maximumLabelWidth
        let labelWidth = min(
            label.sizeThatFits(.unspecified).width,
            maximumLabelWidth,
            proposedLabelWidth
        )
        let labelSize = label.sizeThatFits(
            ProposedViewSize(width: labelWidth, height: proposal.height)
        )
        let measuredLabelWidth = min(labelSize.width, labelWidth)
        let height = ([labelSize] + trailingSizes).map(\.height).max() ?? 0

        return CGSize(
            width: measuredLabelWidth + trailingWidth + totalSpacing,
            height: height
        )
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let label = subviews.first else {
            return
        }

        let trailingSizes = subviews.dropFirst().map {
            $0.sizeThatFits(.unspecified)
        }
        let totalSpacing = spacing * CGFloat(max(subviews.count - 1, 0))
        let trailingWidth = trailingSizes.reduce(0) { $0 + $1.width }
        let availableLabelWidth = max(bounds.width - trailingWidth - totalSpacing, 0)
        let labelWidth = min(
            label.sizeThatFits(.unspecified).width,
            maximumLabelWidth,
            availableLabelWidth
        )
        let labelProposal = ProposedViewSize(width: labelWidth, height: bounds.height)
        let labelSize = label.sizeThatFits(labelProposal)
        var x = bounds.minX

        label.place(
            at: CGPoint(x: x, y: bounds.midY),
            anchor: .leading,
            proposal: labelProposal
        )
        x += min(labelSize.width, labelWidth)

        for (subview, size) in zip(subviews.dropFirst(), trailingSizes) {
            x += spacing
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
        }
    }
}

/// A stepped settings slider without macOS's dense tick-mark presentation.
/// Values are snapped relative to the lower bound before being written back,
/// so declarative and custom plugin settings share the same interaction model.
public struct PluginSettingsSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let onEditingChanged: (Bool) -> Void

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        Slider(
            value: Binding(
                get: { value },
                set: {
                    value = Self.snappedValue($0, in: range, step: step)
                }
            ),
            in: range,
            onEditingChanged: onEditingChanged
        )
    }

    public static func snappedValue(
        _ value: Double,
        in range: ClosedRange<Double>,
        step: Double?
    ) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard let step, step.isFinite, step > 0 else {
            return clamped
        }

        let offset = ((clamped - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + offset * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

public extension View {
    func pluginSettingsCardBackground(
        _ style: PluginSettingsCardBackgroundStyle = .standard
    ) -> some View {
        modifier(PluginSettingsCardBackground(style))
    }

    func pluginSettingsRowIconStyle(visualScale: CGFloat = 1) -> some View {
        pluginSettingsRowIconStyle(
            HierarchicalShapeStyle.secondary,
            visualScale: visualScale
        )
    }

    func pluginSettingsRowIconStyle<S: ShapeStyle>(
        _ foregroundStyle: S,
        visualScale: CGFloat = 1
    ) -> some View {
        self
            .font(PluginSettingsTheme.Typography.rowIcon)
            .foregroundStyle(foregroundStyle)
            .symbolRenderingMode(.monochrome)
            .scaleEffect(visualScale)
            .frame(
                width: PluginSettingsTheme.Size.rowIcon,
                height: PluginSettingsTheme.Size.rowIcon
            )
    }

    func pluginSettingsListRowPadding(interactive: Bool = false) -> some View {
        self
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(
                .vertical,
                interactive
                    ? PluginSettingsTheme.Spacing.interactiveRowVertical
                    : PluginSettingsTheme.Spacing.rowVertical
            )
    }
}
