import AppKit
import SwiftUI

/// Semantic colors shared by component-panel plugins.
///
/// The theme owns neutral UI scaffolding and a categorical data palette.
/// Brand colors, calendar event colors, and feature-specific thresholds remain
/// plugin concerns so a theme never changes their meaning.
public struct PluginComponentTheme: Sendable {
    public struct SurfacePalette: Sendable {
        public let panel: Color
        public let card: Color
        public let nested: Color
        public let nestedMuted: Color
        public let chip: Color
        public let control: Color
        public let controlHover: Color
        public let track: Color
        public let backplate: Color

        public init(
            panel: Color,
            card: Color,
            nested: Color,
            nestedMuted: Color,
            chip: Color,
            control: Color,
            controlHover: Color,
            track: Color,
            backplate: Color
        ) {
            self.panel = panel
            self.card = card
            self.nested = nested
            self.nestedMuted = nestedMuted
            self.chip = chip
            self.control = control
            self.controlHover = controlHover
            self.track = track
            self.backplate = backplate
        }
    }

    public struct TextPalette: Sendable {
        public let primary: Color
        public let secondary: Color
        public let tertiary: Color
        public let disabled: Color

        public init(
            primary: Color,
            secondary: Color,
            tertiary: Color,
            disabled: Color
        ) {
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.disabled = disabled
        }
    }

    public struct StatusPalette: Sendable {
        public let success: Color
        public let warning: Color
        public let critical: Color
        public let informational: Color

        public init(
            success: Color,
            warning: Color,
            critical: Color,
            informational: Color
        ) {
            self.success = success
            self.warning = warning
            self.critical = critical
            self.informational = informational
        }
    }

    public struct DataSeriesPalette: Sendable {
        public let primary: Color
        public let secondary: Color
        public let tertiary: Color
        public let quaternary: Color
        public let quinary: Color
        public let senary: Color

        public init(
            primary: Color,
            secondary: Color,
            tertiary: Color,
            quaternary: Color,
            quinary: Color,
            senary: Color
        ) {
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.quaternary = quaternary
            self.quinary = quinary
            self.senary = senary
        }
    }

    public struct InteractionPalette: Sendable {
        public let selectionOpacity: Double
        public let emphasisOpacity: Double
        public let subtleTintOpacity: Double

        public init(
            selectionOpacity: Double,
            emphasisOpacity: Double,
            subtleTintOpacity: Double
        ) {
            self.selectionOpacity = selectionOpacity
            self.emphasisOpacity = emphasisOpacity
            self.subtleTintOpacity = subtleTintOpacity
        }

        public func selection(_ accent: Color) -> Color {
            accent.opacity(selectionOpacity)
        }

        public func emphasis(_ accent: Color) -> Color {
            accent.opacity(emphasisOpacity)
        }

        public func subtleTint(_ accent: Color) -> Color {
            accent.opacity(subtleTintOpacity)
        }
    }

    public let surfaces: SurfacePalette
    public let text: TextPalette
    public let status: StatusPalette
    public let dataSeries: DataSeriesPalette
    public let interaction: InteractionPalette

    public init(
        surfaces: SurfacePalette,
        text: TextPalette,
        status: StatusPalette,
        dataSeries: DataSeriesPalette,
        interaction: InteractionPalette
    ) {
        self.surfaces = surfaces
        self.text = text
        self.status = status
        self.dataSeries = dataSeries
        self.interaction = interaction
    }

    public enum Opacity {
        public static let lightCardTint = 0.05
        public static let darkCardTint = 0.07
        public static let increasedContrastLightCardTint = 0.08
        public static let increasedContrastDarkCardTint = 0.12

        public static let lightNestedTint = 0.58
        public static let darkNestedTint = 0.06
        public static let increasedContrastLightNestedTint = 0.72
        public static let increasedContrastDarkNestedTint = 0.10

        public static let lightMutedNestedTint = 0.26
        public static let darkMutedNestedTint = 0.03
        public static let increasedContrastLightMutedNestedTint = 0.40
        public static let increasedContrastDarkMutedNestedTint = 0.05

        public static let lightChipTint = 0.055
        public static let darkChipTint = 0.08
        public static let increasedContrastLightChipTint = 0.09
        public static let increasedContrastDarkChipTint = 0.12

        public static let lightControlTint = 0.055
        public static let darkControlTint = 0.08
        public static let increasedContrastLightControlTint = 0.09
        public static let increasedContrastDarkControlTint = 0.12

        public static let lightControlHoverTint = 0.10
        public static let darkControlHoverTint = 0.14
        public static let increasedContrastLightControlHoverTint = 0.14
        public static let increasedContrastDarkControlHoverTint = 0.20

        public static let lightTrackTint = 0.10
        public static let darkTrackTint = 0.12
        public static let increasedContrastLightTrackTint = 0.14
        public static let increasedContrastDarkTrackTint = 0.18

        public static func cardTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightCardTint,
                dark: darkCardTint,
                increasedLight: increasedContrastLightCardTint,
                increasedDark: increasedContrastDarkCardTint
            )
        }

        public static func nestedTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightNestedTint,
                dark: darkNestedTint,
                increasedLight: increasedContrastLightNestedTint,
                increasedDark: increasedContrastDarkNestedTint
            )
        }

        public static func mutedNestedTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightMutedNestedTint,
                dark: darkMutedNestedTint,
                increasedLight: increasedContrastLightMutedNestedTint,
                increasedDark: increasedContrastDarkMutedNestedTint
            )
        }

        public static func chipTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightChipTint,
                dark: darkChipTint,
                increasedLight: increasedContrastLightChipTint,
                increasedDark: increasedContrastDarkChipTint
            )
        }

        public static func controlTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightControlTint,
                dark: darkControlTint,
                increasedLight: increasedContrastLightControlTint,
                increasedDark: increasedContrastDarkControlTint
            )
        }

        public static func controlHoverTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightControlHoverTint,
                dark: darkControlHoverTint,
                increasedLight: increasedContrastLightControlHoverTint,
                increasedDark: increasedContrastDarkControlHoverTint
            )
        }

        public static func trackTint(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast
        ) -> Double {
            resolve(
                colorScheme: colorScheme,
                contrast: contrast,
                light: lightTrackTint,
                dark: darkTrackTint,
                increasedLight: increasedContrastLightTrackTint,
                increasedDark: increasedContrastDarkTrackTint
            )
        }

        private static func resolve(
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast,
            light: Double,
            dark: Double,
            increasedLight: Double,
            increasedDark: Double
        ) -> Double {
            switch (colorScheme, contrast) {
            case (.light, .standard):
                light
            case (.dark, .standard):
                dark
            case (.light, .increased):
                increasedLight
            case (.dark, .increased):
                increasedDark
            @unknown default:
                colorScheme == .dark ? dark : light
            }
        }
    }

    public static func system(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> PluginComponentTheme {
        let adaptiveTint = colorScheme == .dark ? Color.white : Color.black

        return PluginComponentTheme(
            surfaces: SurfacePalette(
                panel: Color(nsColor: .windowBackgroundColor),
                card: adaptiveTint.opacity(
                    Opacity.cardTint(colorScheme: colorScheme, contrast: contrast)
                ),
                nested: Color.white.opacity(
                    Opacity.nestedTint(colorScheme: colorScheme, contrast: contrast)
                ),
                nestedMuted: Color.white.opacity(
                    Opacity.mutedNestedTint(colorScheme: colorScheme, contrast: contrast)
                ),
                chip: adaptiveTint.opacity(
                    Opacity.chipTint(colorScheme: colorScheme, contrast: contrast)
                ),
                control: adaptiveTint.opacity(
                    Opacity.controlTint(colorScheme: colorScheme, contrast: contrast)
                ),
                controlHover: adaptiveTint.opacity(
                    Opacity.controlHoverTint(colorScheme: colorScheme, contrast: contrast)
                ),
                track: adaptiveTint.opacity(
                    Opacity.trackTint(colorScheme: colorScheme, contrast: contrast)
                ),
                backplate: Color(nsColor: .controlBackgroundColor)
            ),
            text: TextPalette(
                primary: Color(nsColor: .labelColor),
                secondary: Color(nsColor: .secondaryLabelColor),
                tertiary: Color(nsColor: .tertiaryLabelColor),
                disabled: Color(nsColor: .disabledControlTextColor)
            ),
            status: StatusPalette(
                success: Color(nsColor: .systemGreen),
                warning: Color(nsColor: .systemOrange),
                critical: Color(nsColor: .systemRed),
                informational: Color(nsColor: .systemBlue)
            ),
            dataSeries: DataSeriesPalette(
                primary: Color(nsColor: .systemBlue),
                secondary: Color(nsColor: .systemOrange),
                tertiary: Color(nsColor: .systemGreen),
                quaternary: Color(nsColor: .systemPurple),
                quinary: Color(nsColor: .systemTeal),
                senary: Color(nsColor: .systemYellow)
            ),
            interaction: InteractionPalette(
                selectionOpacity: resolveInteractionOpacity(
                    colorScheme: colorScheme,
                    contrast: contrast,
                    light: 0.16,
                    dark: 0.18,
                    increasedLight: 0.22,
                    increasedDark: 0.24
                ),
                emphasisOpacity: resolveInteractionOpacity(
                    colorScheme: colorScheme,
                    contrast: contrast,
                    light: 0.08,
                    dark: 0.10,
                    increasedLight: 0.12,
                    increasedDark: 0.15
                ),
                subtleTintOpacity: resolveInteractionOpacity(
                    colorScheme: colorScheme,
                    contrast: contrast,
                    light: 0.08,
                    dark: 0.10,
                    increasedLight: 0.12,
                    increasedDark: 0.14
                )
            )
        )
    }

    private static func resolveInteractionOpacity(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast,
        light: Double,
        dark: Double,
        increasedLight: Double,
        increasedDark: Double
    ) -> Double {
        switch (colorScheme, contrast) {
        case (.light, .standard):
            light
        case (.dark, .standard):
            dark
        case (.light, .increased):
            increasedLight
        case (.dark, .increased):
            increasedDark
        @unknown default:
            colorScheme == .dark ? dark : light
        }
    }
}

private struct PluginComponentThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = PluginComponentTheme.system(
        colorScheme: .light,
        contrast: .standard
    )
}

public extension EnvironmentValues {
    var pluginComponentTheme: PluginComponentTheme {
        get { self[PluginComponentThemeEnvironmentKey.self] }
        set { self[PluginComponentThemeEnvironmentKey.self] = newValue }
    }
}

/// The shared adaptive surface for cards shown in the component panel.
/// The host supplies an opaque semantic window background. Component cards add
/// a subtle appearance-aware tonal fill, without borders or shadows.
public struct PluginComponentCardBackground: View {
    @Environment(\.pluginComponentTheme) private var theme

    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = PluginPanelWidgetLayoutMetrics.cardCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.surfaces.card)
    }
}
