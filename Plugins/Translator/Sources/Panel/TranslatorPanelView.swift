import SwiftUI

struct TranslatorPanelView: View {
    let snapshot: TranslatorPanelSnapshot
    let onAction: (TranslatorPanelAction) -> Void

    var body: some View {
        VStack(spacing: 14) {
            sourceCard
            languageRow
            resultCard
        }
        .padding(16)
        .frame(width: 520, height: 520)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("原文")
                    .font(.headline)
                Spacer()
                iconButton("speaker.wave.2", help: "朗读原文", action: .speakSource)
                    .disabled(sourceTextForDisplay.isEmpty)
                iconButton("doc.on.doc", help: "复制原文", action: .copySource)
                    .disabled(sourceTextForDisplay.isEmpty)
                iconButton("xmark", help: "关闭", action: .close)
            }

            ScrollView {
                Text(sourceTextForDisplay.isEmpty ? sourcePlaceholder : sourceTextForDisplay)
                    .font(.body)
                    .foregroundStyle(sourceTextForDisplay.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            languagePill(
                flag: snapshot.languageSelection?.source?.flag ?? "🌐",
                title: snapshot.languageSelection?.source?.displayName ?? "自动检测"
            )

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            languagePill(
                flag: snapshot.languageSelection?.target.flag ?? "🇨🇳",
                title: snapshot.languageSelection?.target.displayName ?? "简体中文"
            )
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(snapshot.translation?.providerTitle ?? "翻译结果")
                    .font(.headline)
                if case .translating = snapshot.phase {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                iconButton("speaker.wave.2", help: "朗读译文", action: .speakTranslation)
                    .disabled(resultTextForDisplay.isEmpty)
                iconButton("doc.on.doc", help: "复制译文", action: .copyTranslation)
                    .disabled(resultTextForDisplay.isEmpty)
                iconButton("arrow.clockwise", help: "重试", action: .retry)
                iconButton("gearshape", help: "设置", action: .openSettings)
            }

            ScrollView {
                Text(resultBodyText)
                    .font(.body)
                    .foregroundStyle(resultTextColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 202, maxHeight: 202, alignment: .topLeading)
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func languagePill(flag: String, title: String) -> some View {
        HStack(spacing: 8) {
            Text(flag)
                .font(.title3)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        action: TranslatorPanelAction
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var sourceTextForDisplay: String {
        snapshot.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var resultTextForDisplay: String {
        snapshot.translation?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var sourcePlaceholder: String {
        switch snapshot.phase {
        case .capturing:
            return "正在读取选中文本..."
        case .error(.missingSelection):
            return "未找到选中文本"
        case .error(.permissionRequired):
            return "需要辅助功能授权"
        default:
            return "等待选中文本"
        }
    }

    private var resultBodyText: String {
        if !resultTextForDisplay.isEmpty {
            return resultTextForDisplay
        }

        switch snapshot.phase {
        case .translating:
            return "正在翻译..."
        case .error:
            return snapshot.errorMessage ?? "请求失败，请稍后重试"
        default:
            return "等待翻译"
        }
    }

    private var resultTextColor: Color {
        if case .error = snapshot.phase {
            return .red
        }

        return resultTextForDisplay.isEmpty ? .secondary : .primary
    }
}
