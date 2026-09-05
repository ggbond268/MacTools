import AppKit
import MacToolsPluginKit
import SwiftUI

struct ClipboardColorValue: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(hex text: String) {
        let literal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard literal.first == "#" else { return nil }
        let digits = Array(literal.dropFirst().utf8)
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let expanded = digits.count <= 4 ? digits.flatMap { [$0, $0] } : digits
        let components = stride(from: 0, to: expanded.count, by: 2).map { offset in
            Double(UInt8(String(decoding: expanded[offset...offset + 1], as: UTF8.self), radix: 16)!) / 255
        }
        red = components[0]
        green = components[1]
        blue = components[2]
        alpha = components.count == 4 ? components[3] : 1
    }

    init?(nativeColor: NSColor) {
        guard let rgb = nativeColor.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        red = min(max(Double(components[0]), 0), 1)
        green = min(max(Double(components[1]), 0), 1)
        blue = min(max(Double(components[2]), 0), 1)
        alpha = min(max(Double(components[3]), 0), 1)
    }

    static func literal(for item: ClipboardHistoryItem) -> Self? {
        guard item.kind == .plainText || item.kind == .richText else { return nil }
        return Self(hex: item.text)
    }

    static func decodeNative(_ data: Data) -> Self? {
        guard data.count <= 1_024 * 1_024,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
        return Self(nativeColor: color)
    }

    var hex: String {
        let components = [red, green, blue] + (alpha < 1 ? [alpha] : [])
        return "#" + components.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

enum ClipboardColorPreviewPalette {
    // Fixed display colors are intentional: the surrounding canvas and transparency
    // tiles must not change with the app's light/dark theme.
    static let canvas = Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5)
    static let tileLight = Color(.sRGB, red: 0.92, green: 0.92, blue: 0.92)
    static let tileDark = Color(.sRGB, red: 0.76, green: 0.76, blue: 0.76)
}

struct ClipboardColorSwatchView: View {
    let value: ClipboardColorValue
    let localization: PluginLocalization

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ClipboardColorPreviewPalette.tileLight))
                    let tile: CGFloat = 12
                    for row in 0...Int(size.height / tile) {
                        for column in 0...Int(size.width / tile) where (row + column).isMultiple(of: 2) {
                            context.fill(
                                Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                                with: .color(ClipboardColorPreviewPalette.tileDark)
                            )
                        }
                    }
                }
                value.color
            }
            .frame(width: 200, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.3), lineWidth: 1)
            }
            .accessibilityLabel(localization.string("content.kind.color", defaultValue: "颜色") + " " + value.hex)

            Text(value.hex)
                .font(PluginSettingsTheme.Typography.rowTitle.monospaced())
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(ClipboardColorPreviewPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .help(localization.string(
            "panel.color.preview.help",
            defaultValue: "固定中性背景；透明颜色显示棋盘格。预览不会更改复制的颜色。"
        ))
    }
}

enum ClipboardNativeColorPreviewResult: Sendable {
    case value(ClipboardColorValue)
    case unsupported
    case failed
}

enum ClipboardNativeColorPreviewLoader {
    static func load(item: ClipboardHistoryItem) async -> ClipboardNativeColorPreviewResult {
        let worker = Task.detached(priority: .utility) {
            defer { item.discardCachedPayloadIfReloadable() }
            guard !Task.isCancelled else { return ClipboardNativeColorPreviewResult.failed }
            guard item.payloadByteCount <= 1_024 * 1_024 else { return .unsupported }
            guard let payload = try? item.loadPayload(), !Task.isCancelled else { return .failed }
            guard let data = payload.representations.first(where: {
                $0.typeIdentifier == ClipboardRepresentationType.color
            })?.data else { return .unsupported }
            guard let value = ClipboardColorValue.decodeNative(data), !Task.isCancelled else { return .failed }
            return .value(value)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }
}

struct ClipboardNativeColorPreviewView: View {
    let item: ClipboardHistoryItem
    let localization: PluginLocalization
    var resetID: UInt = 0
    var isActive = true
    @State private var result: ClipboardNativeColorPreviewResult?
    @State private var retryID: UInt = 0

    var body: some View {
        Group {
            switch result {
            case let .value(value):
                ClipboardColorSwatchView(value: value, localization: localization)
            case .unsupported:
                ClipboardPreviewUnavailableView(localization: localization, isUnsupported: true)
            case .failed:
                ClipboardPreviewUnavailableView(localization: localization, retry: { retryID &+= 1 })
            case nil:
                ProgressView(localization.string("panel.preview.loading", defaultValue: "正在载入预览…"))
                    .controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: ClipboardPreviewRequestID(key: ClipboardEmbeddedPreviewKey(item), retry: retryID,
                                            presentation: resetID, isActive: isActive)) {
            result = nil
            guard isActive else { return }
            let loaded = await ClipboardNativeColorPreviewLoader.load(item: item)
            guard !Task.isCancelled else { return }
            result = loaded
        }
    }
}
