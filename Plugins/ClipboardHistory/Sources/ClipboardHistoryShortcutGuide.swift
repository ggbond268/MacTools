import MacToolsPluginKit
import SwiftUI

struct ClipboardHistoryShortcutGuideHint: Hashable {
    let title: String
    let shortcut: String
}

struct ClipboardHistoryShortcutGuide: View {
    let title: String
    let navigation: [ClipboardHistoryShortcutGuideHint]
    let actions: [ClipboardHistoryShortcutGuideHint]
    let closing: [ClipboardHistoryShortcutGuideHint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    rows(navigation)
                    Divider()
                    rows(actions)
                    Divider()
                    rows(closing)
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 410)
    }

    private func rows(_ hints: [ClipboardHistoryShortcutGuideHint]) -> some View {
        ForEach(hints, id: \.self) { hint in
            ClipboardHistoryShortcutGuideRow(hint: hint)
        }
    }
}

/// Every help row uses the same trailing column, including navigation and close.
struct ClipboardHistoryShortcutGuideRow: View {
    let hint: ClipboardHistoryShortcutGuideHint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(hint.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(hint.shortcut)
                .monospaced()
                .fixedSize()
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .accessibilityElement(children: .combine)
    }
}
