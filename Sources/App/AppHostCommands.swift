import Foundation
import MacToolsPluginKit

struct MacToolsCommandConfirmation: Hashable {
    let title: String
    let message: String
    let confirmButtonTitle: String

    init(title: String, message: String, confirmButtonTitle: String) {
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
    }

    init(_ confirmation: PluginCommandDefinition.Confirmation) {
        self.init(
            title: confirmation.title,
            message: confirmation.message,
            confirmButtonTitle: confirmation.confirmButtonTitle
        )
    }

    init(_ confirmation: ActionConfirmation) {
        self.init(
            title: confirmation.title,
            message: confirmation.message,
            confirmButtonTitle: confirmation.confirmButtonTitle
        )
    }
}

struct AppHostCommandDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let keywords: [String]
    let systemImage: String
    let confirmation: MacToolsCommandConfirmation?
    let action: AppHostCommandAction
}

enum AppHostCommandAction: Hashable {
    case appShortcut(AppShortcutAction)
    case setAppearance(AppAppearancePreference)
    case setLaunchAtLogin(Bool)
    case resetCommandPalettePosition
}

@MainActor
struct AppHostCommandContext {
    let pluginHost: PluginHost
    let launchAtLoginController: LaunchAtLoginController
    let appearanceUserDefaults: UserDefaults
    var resetCommandPalettePosition: (() -> Void)? = nil
}

enum AppHostCommandContinuation: Equatable {
    case dismissPalette
    case refreshIndex
}

enum AppHostCommandExecutionResult: Equatable {
    case performed(AppHostCommandContinuation)
    case unavailable
    case failed
}

@MainActor
enum AppHostCommandCatalog {
    static let sharedAppShortcutActions: [AppShortcutAction] = [
        .toggleDashboard,
        .toggleFeaturePanel,
    ]

    static func applicableDefinitions(
        in context: AppHostCommandContext
    ) -> [AppHostCommandDefinition] {
        let currentAppearance = AppAppearancePreference.stored(
            in: context.appearanceUserDefaults
        )
        return fixedDefinitions().filter { definition in
            switch definition.action {
            case .appShortcut:
                return true
            case let .setAppearance(preference):
                return preference != currentAppearance
            case let .setLaunchAtLogin(isEnabled):
                return isEnabled != context.launchAtLoginController.isEnabled
            case .resetCommandPalettePosition:
                return true
            }
        }
    }

    private static func fixedDefinitions() -> [AppHostCommandDefinition] {
        sharedAppShortcutActions.map(appShortcutDefinition)
            + AppAppearancePreference.allCases.map(appearanceDefinition)
            + [launchAtLoginDefinition(isEnabled: true), launchAtLoginDefinition(isEnabled: false)]
            + [resetCommandPalettePositionDefinition()]
    }

    private static func resetCommandPalettePositionDefinition() -> AppHostCommandDefinition {
        AppHostCommandDefinition(
            id: "app-command.command-palette.reset-position",
            title: AppL10n.search(
                "search.command.resetCommandPalettePosition.title",
                defaultValue: "重置命令面板位置"
            ),
            description: AppL10n.search(
                "search.command.resetCommandPalettePosition.description",
                defaultValue: "将命令面板恢复到当前屏幕的默认位置。"
            ),
            keywords: [
                "reset",
                "command palette",
                "position",
                "snap",
                "anchor",
                "center",
                "重置",
                "位置",
                "命令面板",
                "居中",
            ],
            systemImage: "arrow.counterclockwise",
            confirmation: nil,
            action: .resetCommandPalettePosition
        )
    }

    private static func appShortcutDefinition(
        _ action: AppShortcutAction
    ) -> AppHostCommandDefinition {
        let keywords: [String]
        switch action {
        case .toggleDashboard:
            keywords = ["dashboard", "show dashboard", "仪表盘", "显示仪表盘"]
        case .toggleFeaturePanel:
            keywords = ["feature panel", "show feature panel", "功能面板", "显示功能面板"]
        case .openSettings, .openCommandPalette:
            // Only the two actions in `sharedAppShortcutActions` reach this path.
            keywords = []
        }

        return AppHostCommandDefinition(
            id: "app-command.\(action.rawValue.replacingOccurrences(of: "app.", with: ""))",
            title: action.title,
            description: action.description,
            keywords: keywords,
            systemImage: action.systemImage,
            confirmation: nil,
            action: .appShortcut(action)
        )
    }

    private static func appearanceDefinition(
        _ preference: AppAppearancePreference
    ) -> AppHostCommandDefinition {
        let keyComponent: String
        let title: String
        let description: String
        let targetKeywords: [String]
        switch preference {
        case .system:
            keyComponent = "system"
            title = AppL10n.search(
                "search.command.appearance.system.title",
                defaultValue: "使用系统外观"
            )
            description = AppL10n.search(
                "search.command.appearance.system.description",
                defaultValue: "让 MacTools 外观自动跟随系统。"
            )
            targetKeywords = ["system", "automatic", "follow system", "系统", "自动", "跟随系统"]
        case .dark:
            keyComponent = "dark"
            title = AppL10n.search(
                "search.command.appearance.dark.title",
                defaultValue: "使用深色外观"
            )
            description = AppL10n.search(
                "search.command.appearance.dark.description",
                defaultValue: "将 MacTools 外观固定为深色。"
            )
            targetKeywords = ["dark", "dark mode", "深色", "深色模式"]
        case .light:
            keyComponent = "light"
            title = AppL10n.search(
                "search.command.appearance.light.title",
                defaultValue: "使用浅色外观"
            )
            description = AppL10n.search(
                "search.command.appearance.light.description",
                defaultValue: "将 MacTools 外观固定为浅色。"
            )
            targetKeywords = ["light", "light mode", "浅色", "浅色模式"]
        }

        return AppHostCommandDefinition(
            id: "app-command.appearance.\(keyComponent)",
            title: title,
            description: description,
            keywords: ["appearance", "theme", "外观", "主题"] + targetKeywords,
            systemImage: "circle.lefthalf.filled",
            confirmation: nil,
            action: .setAppearance(preference)
        )
    }

    private static func launchAtLoginDefinition(
        isEnabled: Bool
    ) -> AppHostCommandDefinition {
        let title = isEnabled
            ? AppL10n.search(
                "search.command.launchAtLogin.enable.title",
                defaultValue: "开启登录时启动"
            )
            : AppL10n.search(
                "search.command.launchAtLogin.disable.title",
                defaultValue: "关闭登录时启动"
            )
        let description = isEnabled
            ? AppL10n.search(
                "search.command.launchAtLogin.enable.description",
                defaultValue: "登录系统时自动启动 MacTools。"
            )
            : AppL10n.search(
                "search.command.launchAtLogin.disable.description",
                defaultValue: "登录系统时不再自动启动 MacTools。"
            )
        let actionKeywords = isEnabled
            ? ["enable", "start", "开启", "启用"]
            : ["disable", "stop", "关闭", "停用"]

        return AppHostCommandDefinition(
            id: "app-command.launch-at-login.\(isEnabled ? "enable" : "disable")",
            title: title,
            description: description,
            keywords: [
                "launch at login",
                "login item",
                "startup",
                "开机启动",
                "登录项",
                "自启动",
            ] + actionKeywords,
            systemImage: "power",
            confirmation: nil,
            action: .setLaunchAtLogin(isEnabled)
        )
    }

}

@MainActor
enum AppHostCommandExecutor {
    static func perform(
        expectedDefinition: AppHostCommandDefinition,
        context: AppHostCommandContext
    ) -> AppHostCommandExecutionResult {
        context.launchAtLoginController.refreshStatus()
        guard AppHostCommandCatalog.applicableDefinitions(in: context).contains(expectedDefinition) else {
            return .unavailable
        }

        switch expectedDefinition.action {
        case let .appShortcut(action):
            guard context.pluginHost.performAppCommand(action) else {
                return .failed
            }
            return .performed(.dismissPalette)

        case let .setAppearance(preference):
            guard context.pluginHost.setApplicationAppearancePreference(
                rawValue: preference.rawValue
            ) else {
                return .failed
            }
            return .performed(.refreshIndex)

        case let .setLaunchAtLogin(isEnabled):
            context.launchAtLoginController.setEnabled(isEnabled)
            guard context.launchAtLoginController.isEnabled == isEnabled else {
                return .failed
            }
            return .performed(.refreshIndex)

        case .resetCommandPalettePosition:
            guard let resetAction = context.resetCommandPalettePosition else {
                return .failed
            }
            resetAction()
            return .performed(.refreshIndex)
        }
    }
}
