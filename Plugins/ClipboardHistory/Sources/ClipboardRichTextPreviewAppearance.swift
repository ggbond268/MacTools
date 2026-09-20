import AppKit
import SwiftUI

enum ClipboardRichTextCanvas: Sendable {
    case light
    case dark

    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var opposite: Self { self == .dark ? .light : .dark }

    var backgroundColor: NSColor { resolve(.textBackgroundColor) }

    func resolve(_ color: NSColor) -> NSColor {
        var resolved = color
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }
}

struct ClipboardRichTextCanvasSelection: Equatable {
    private(set) var override: ClipboardRichTextCanvas?

    func resolved(for appCanvas: ClipboardRichTextCanvas) -> ClipboardRichTextCanvas {
        override ?? appCanvas
    }

    mutating func toggle(appCanvas: ClipboardRichTextCanvas) {
        let next = resolved(for: appCanvas).opposite
        override = next == appCanvas ? nil : next
    }
}

struct ClipboardRichTextPreviewDocument: Sendable {
    let light: AttributedString
    let dark: AttributedString

    init(_ source: AttributedString) {
        light = ClipboardRichTextPreviewColors.adapt(source, to: .light)
        dark = ClipboardRichTextPreviewColors.adapt(source, to: .dark)
    }

    func text(for canvas: ClipboardRichTextCanvas) -> AttributedString {
        canvas == .dark ? dark : light
    }
}

enum ClipboardRichTextPreviewColors {
    static let minimumContrast: CGFloat = 4.5

    private struct ColorPair: Hashable {
        let foreground: NSColor
        let background: NSColor
    }

    static func adapt(_ source: AttributedString, to canvas: ClipboardRichTextCanvas) -> AttributedString {
        var result = source
        let background = canvas.backgroundColor
        var resolvedColors: [NSColor: NSColor] = [:]
        var readableColors: [ColorPair: NSColor] = [:]
        func resolved(_ color: NSColor) -> NSColor {
            if let cached = resolvedColors[color] { return cached }
            let resolved = canvas.resolve(color)
            resolvedColors[color] = resolved
            return resolved
        }
        func adapted(_ color: NSColor, on background: NSColor) -> NSColor {
            let pair = ColorPair(foreground: resolved(color), background: background)
            if let cached = readableColors[pair] { return cached }
            let adapted = readable(pair.foreground, on: background)
            readableColors[pair] = adapted
            return adapted
        }
        for run in source.runs {
            let runBackground = run.appKit.backgroundColor.map(resolved)
            let effectiveBackground = runBackground.map { composite($0, over: background) } ?? background
            let defaultForeground = run.link == nil ? NSColor.textColor : NSColor.linkColor
            result[run.range].appKit.foregroundColor = adapted(run.appKit.foregroundColor ?? defaultForeground, on: effectiveBackground)
            if let runBackground { result[run.range].appKit.backgroundColor = runBackground }
            if let underline = run.appKit.underlineColor {
                result[run.range].appKit.underlineColor = adapted(underline, on: effectiveBackground)
            }
            if let strikethrough = run.appKit.strikethroughColor {
                result[run.range].appKit.strikethroughColor = adapted(strikethrough, on: effectiveBackground)
            }
        }
        return result
    }

    static func readable(_ foreground: NSColor, on background: NSColor) -> NSColor {
        let visible = composite(foreground, over: background)
        guard contrast(visible, background) < minimumContrast else { return foreground }
        let target = contrast(.white, background) >= contrast(.black, background) ? NSColor.white : .black
        guard let rgb = visible.usingColorSpace(.sRGB) else { return target }
        // Neutral text should read like native text. Preserve the hue of colored text by
        // moving it only as far toward black or white as needed for a readable preview.
        if max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
            - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) < 0.08 {
            return target
        }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let fraction = (lower + upper) / 2
            let candidate = mix(rgb, target, fraction: fraction)
            if contrast(candidate, background) >= minimumContrast { upper = fraction }
            else { lower = fraction }
        }
        return mix(rgb, target, fraction: upper)
    }

    static func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let first = luminance(composite(foreground, over: background))
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        guard let foreground = foreground.usingColorSpace(.sRGB) else { return background }
        return mix(background, foreground, fraction: foreground.alphaComponent)
    }

    private static func mix(_ first: NSColor, _ second: NSColor, fraction: CGFloat) -> NSColor {
        guard let first = first.usingColorSpace(.sRGB), let second = second.usingColorSpace(.sRGB) else { return second }
        return NSColor(srgbRed: first.redComponent * (1 - fraction) + second.redComponent * fraction,
                       green: first.greenComponent * (1 - fraction) + second.greenComponent * fraction,
                       blue: first.blueComponent * (1 - fraction) + second.blueComponent * fraction, alpha: 1)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}
