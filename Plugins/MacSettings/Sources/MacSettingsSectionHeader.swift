import SwiftUI
import MacToolsPluginKit

struct MacSettingsSectionHeader<Trailing: View>: View {
    let title: String
    let description: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(PluginSettingsTheme.Typography.pageTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(18)
    }
}
