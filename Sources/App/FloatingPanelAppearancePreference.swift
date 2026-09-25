import MacToolsPluginKit

extension PluginFloatingPanelAppearance {
    var title: String {
        switch self {
        case .system:
            AppL10n.settings(
                "floatingPanelAppearance.system",
                defaultValue: "跟随 macOS"
            )
        case .solid:
            AppL10n.settings(
                "floatingPanelAppearance.solid",
                defaultValue: "实色"
            )
        }
    }
}
