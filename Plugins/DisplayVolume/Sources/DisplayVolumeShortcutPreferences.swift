import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class DisplayVolumeShortcutPreferences: ObservableObject {
    enum TargetMode: String, CaseIterable, Identifiable {
        case followsMouse
        case allDisplays

        var id: String { rawValue }

        func title(localization: PluginLocalization) -> String {
            switch self {
            case .followsMouse:
                localization.string("settings.shortcutTarget.followsMouse", defaultValue: "跟随鼠标")
            case .allDisplays:
                localization.string("settings.shortcutTarget.allDisplays", defaultValue: "所有显示器")
            }
        }

        func description(localization: PluginLocalization) -> String {
            switch self {
            case .followsMouse:
                localization.string(
                    "settings.shortcutTarget.followsMouseDescription",
                    defaultValue: "只调整光标所在屏幕。"
                )
            case .allDisplays:
                localization.string(
                    "settings.shortcutTarget.allDisplaysDescription",
                    defaultValue: "同步调整所有可控显示器。"
                )
            }
        }
    }

    @Published var targetMode: TargetMode {
        didSet { storage.set(targetMode.rawValue, forKey: Keys.targetMode) }
    }

    private let storage: PluginStorage

    private enum Keys {
        static let targetMode = "shortcutTargetMode"
    }

    init(storage: PluginStorage) {
        self.storage = storage
        self.targetMode = TargetMode(rawValue: storage.string(forKey: Keys.targetMode) ?? "")
            ?? .followsMouse
    }
}
