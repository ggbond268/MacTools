import AppKit
import SwiftUI

private enum ShortcutSettingsLayout {
    static let controlColumnWidth: CGFloat = 128
    static let controlHeight: CGFloat = 48
}

@MainActor
final class ShortcutCaptureController: ObservableObject {
    @Published private(set) var recordingShortcutID: String?

    private var localMonitor: Any?
    private var onCapture: ((ShortcutBinding) -> Void)?

    func toggleRecording(for shortcutID: String, onCapture: @escaping (ShortcutBinding) -> Void) {
        if recordingShortcutID == shortcutID {
            stopRecording()
            return
        }

        startRecording(for: shortcutID, onCapture: onCapture)
    }

    func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        localMonitor = nil
        onCapture = nil
        recordingShortcutID = nil
    }

    private func startRecording(for shortcutID: String, onCapture: @escaping (ShortcutBinding) -> Void) {
        stopRecording()
        recordingShortcutID = shortcutID
        self.onCapture = onCapture

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard recordingShortcutID != nil else {
            return event
        }

        let modifiers = ShortcutModifiers.from(event.modifierFlags)

        if event.keyCode == ShortcutKeyCode.escape, modifiers.isEmpty {
            stopRecording()
            return nil
        }

        if let binding = event.shortcutBindingCandidate {
            onCapture?(binding)
        }

        stopRecording()
        return nil
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @StateObject private var captureController = ShortcutCaptureController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("键盘快捷键", systemImage: "command")
                        .font(.title2.weight(.semibold))

                    Text("为常用动作配置全局快捷键。编辑后立即生效，必要项不可删除。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pluginHost.shortcutItems.enumerated()), id: \.element.id) { index, item in
                        ShortcutSettingsRow(
                            item: item,
                            isRecording: captureController.recordingShortcutID == item.id,
                            onConfigure: {
                                pluginHost.clearShortcutError(for: item.id)
                                captureController.toggleRecording(for: item.id) { binding in
                                    pluginHost.setShortcutBinding(binding, for: item.id)
                                }
                            },
                            onClear: {
                                captureController.stopRecording()
                                pluginHost.clearShortcutError(for: item.id)
                                pluginHost.clearShortcut(for: item.id)
                            },
                            onReset: {
                                captureController.stopRecording()
                                pluginHost.clearShortcutError(for: item.id)
                                pluginHost.resetShortcut(for: item.id)
                            }
                        )

                        if index < pluginHost.shortcutItems.count - 1 {
                            ShortcutSettingsDivider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                Label("点击编辑图标后，按下包含至少一个修饰键（⌘、⌥、CTRL、⇧）的组合键来设置快捷键。按 ESC 可取消本次录制。", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            captureController.stopRecording()
        }
    }
}

private struct ShortcutSettingsRow: View {
    let item: ShortcutSettingsItem
    let isRecording: Bool
    let onConfigure: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    private var supportingText: String {
        item.errorMessage ?? item.description
    }

    private var supportingColor: Color {
        item.errorMessage == nil ? .secondary : .red
    }

    private var rowHelpText: String {
        [item.title, supportingText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.title)

                    if item.isRequired {
                        ShortcutStatusBadge(text: "必填")
                    }
                }

                Text(supportingText)
                    .font(.footnote)
                    .foregroundStyle(supportingColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(supportingText)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(rowHelpText)

            HStack(alignment: .center, spacing: 10) {
                ShortcutBindingBadge(
                    text: isRecording ? "请按下快捷键" : item.bindingText,
                    isRecording: isRecording
                )
                .frame(width: ShortcutSettingsLayout.controlColumnWidth)

                ShortcutActionGroup(
                    isRecording: isRecording,
                    canClear: item.canClear,
                    canReset: !item.usesDefaultValue,
                    onConfigure: onConfigure,
                    onReset: onReset,
                    onClear: onClear,
                    clearHelp: item.canClear
                        ? "清除快捷键"
                        : (item.isRequired ? "该快捷键不能为空" : "当前没有可清除的快捷键")
                )
                .frame(width: ShortcutSettingsLayout.controlColumnWidth)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 18)
    }
}

private struct ShortcutStatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
    }
}

private struct ShortcutActionGroup: View {
    let isRecording: Bool
    let canClear: Bool
    let canReset: Bool
    let onConfigure: () -> Void
    let onReset: () -> Void
    let onClear: () -> Void
    let clearHelp: String

    var body: some View {
        HStack(spacing: 0) {
            ShortcutActionButton(
                systemName: isRecording ? "xmark" : "pencil",
                helpText: isRecording ? "取消录制快捷键" : "编辑快捷键",
                tint: isRecording ? .accentColor : .primary,
                isActive: isRecording,
                action: onConfigure
            )

            ShortcutActionDivider()

            ShortcutActionButton(
                systemName: "arrow.counterclockwise",
                helpText: canReset ? "重置为默认快捷键" : "已是默认快捷键",
                tint: .secondary,
                isDisabled: !canReset,
                action: onReset
            )

            ShortcutActionDivider()

            ShortcutActionButton(
                systemName: "trash",
                helpText: clearHelp,
                tint: .red,
                isDisabled: !canClear,
                action: onClear
            )
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: ShortcutSettingsLayout.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ShortcutActionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 18)
            .padding(.vertical, 5)
    }
}

private struct ShortcutActionButton: View {
    let systemName: String
    let helpText: String
    let tint: Color
    var isDisabled: Bool = false
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? tint.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? Color.secondary.opacity(0.35) : tint)
        .disabled(isDisabled)
        .help(helpText)
    }
}

private struct ShortcutBindingBadge: View {
    let text: String
    let isRecording: Bool

    private var displayText: String {
        text == "None" ? "未设置" : text
    }

    private var tokens: [String] {
        guard !isRecording, displayText != "未设置" else {
            return []
        }

        return Self.keycapTokens(from: displayText)
    }

    var body: some View {
        badgeContent
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: ShortcutSettingsLayout.controlHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isRecording ? Color.accentColor.opacity(0.06) : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isRecording ? 1.5 : 1
                )
        )
    }

    @ViewBuilder
    private var badgeContent: some View {
        if isRecording {
            Label("请按下快捷键", systemImage: "record.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else if displayText == "未设置" {
            Text(displayText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                ShortcutKeycapRow(tokens: tokens, metrics: .regular)
                ShortcutKeycapRow(tokens: tokens, metrics: .compact)
                ShortcutKeycapRow(tokens: tokens, metrics: .compressed)
            }
        }
    }

    private static func keycapTokens(from text: String) -> [String] {
        let separator = " + "
        if text.contains(separator) {
            let components = text
                .components(separatedBy: separator)
                .filter { !$0.isEmpty }
            if !components.isEmpty {
                return components
            }
        }

        let modifierSymbols: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]
        var tokens: [String] = []
        var keyToken = ""

        for character in text {
            if modifierSymbols.contains(character), keyToken.isEmpty {
                tokens.append(String(character))
            } else {
                keyToken.append(character)
            }
        }

        if !keyToken.isEmpty {
            tokens.append(keyToken)
        }

        return tokens.isEmpty ? [text] : tokens
    }
}

private struct ShortcutKeycapRow: View {
    let tokens: [String]
    let metrics: ShortcutKeycapMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                ShortcutKeycap(text: token, metrics: metrics)
            }
        }
    }
}

private struct ShortcutKeycapMetrics {
    let singleCharacterFontSize: CGFloat
    let multiCharacterFontSize: CGFloat
    let horizontalPadding: CGFloat
    let multiCharacterHorizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let spacing: CGFloat

    static let regular = ShortcutKeycapMetrics(
        singleCharacterFontSize: 13,
        multiCharacterFontSize: 12,
        horizontalPadding: 8,
        multiCharacterHorizontalPadding: 9,
        verticalPadding: 5,
        cornerRadius: 8,
        spacing: 6
    )

    static let compact = ShortcutKeycapMetrics(
        singleCharacterFontSize: 12,
        multiCharacterFontSize: 11,
        horizontalPadding: 7,
        multiCharacterHorizontalPadding: 7,
        verticalPadding: 4,
        cornerRadius: 7,
        spacing: 5
    )

    static let compressed = ShortcutKeycapMetrics(
        singleCharacterFontSize: 11,
        multiCharacterFontSize: 10,
        horizontalPadding: 6,
        multiCharacterHorizontalPadding: 6,
        verticalPadding: 4,
        cornerRadius: 7,
        spacing: 4
    )
}

private struct ShortcutKeycap: View {
    let text: String
    let metrics: ShortcutKeycapMetrics

    var body: some View {
        Text(text)
            .font(
                .system(
                    size: text.count > 1 ? metrics.multiCharacterFontSize : metrics.singleCharacterFontSize,
                    weight: .semibold
                )
            )
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, text.count > 1 ? metrics.multiCharacterHorizontalPadding : metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
    }
}
