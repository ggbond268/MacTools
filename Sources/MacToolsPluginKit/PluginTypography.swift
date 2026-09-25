import AppKit
import SwiftUI

/// Information roles shared by native settings, panels, widgets, and windows.
/// Compact layouts reduce spacing and secondary content, not the minimum text size.
public enum PluginTypography: Sendable {
    case pageTitle
    case sectionTitle
    case body
    case detail
    case caption
    case control
    case value
    case metric
    case prominentMetric
    case code

    public var font: Font {
        switch self {
        case .pageTitle: .title2.weight(.semibold)
        case .sectionTitle: .body.weight(.semibold)
        case .body: .body
        case .detail: .subheadline
        case .caption: .caption
        case .control: .callout
        case .value: .callout.monospacedDigit()
        case .metric: .title2.weight(.semibold).monospacedDigit()
        case .prominentMetric: .largeTitle.weight(.semibold).monospacedDigit()
        case .code: .system(.callout, design: .monospaced)
        }
    }

    /// Use the same metrics for AppKit drawing, text measurement, and controls.
    public var nsFont: NSFont {
        let size = NSFont.preferredFont(forTextStyle: nativeTextStyle).pointSize
        switch self {
        case .value, .metric, .prominentMetric:
            return .monospacedDigitSystemFont(ofSize: size, weight: nativeWeight)
        case .code:
            return .monospacedSystemFont(ofSize: size, weight: nativeWeight)
        default:
            return .systemFont(ofSize: size, weight: nativeWeight)
        }
    }

    private var nativeTextStyle: NSFont.TextStyle {
        switch self {
        case .pageTitle, .metric: .title2
        case .sectionTitle, .body: .body
        case .detail: .subheadline
        case .caption: .caption1
        case .control, .value, .code: .callout
        case .prominentMetric: .largeTitle
        }
    }

    private var nativeWeight: NSFont.Weight {
        switch self {
        case .pageTitle, .sectionTitle, .metric, .prominentMetric: .semibold
        default: .regular
        }
    }
}
