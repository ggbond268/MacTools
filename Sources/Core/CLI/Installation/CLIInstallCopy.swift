import Foundation
import MacToolsPluginKit

enum CLIInstallCopy: String, CaseIterable {
    case details
    case manage
    case terminalSetup
    case allowConnection
    case build
    case automaticUpdates
    case rollbackHelp
    case update
    case rollback
    case remove
    case reveal
    case copyPath
    case installPrompt
    case retry
    case copyDiagnostics
    case pathHelp
    case copy
    case notInstalled
    case downloading
    case verifying
    case installing
    case installed
    case updateAvailable
    case failed
    case confirmTitle
    case paths
    case ownershipHelp
    case enableIntegration
    case integrationOn
    case integrationOff
    case cancel
    case install

    var text: String { AppL10n.settings("cli.install." + rawValue, defaultValue: source) }

    private var source: String {
        switch self {
        case .details: "详细信息"
        case .manage: "管理"
        case .terminalSetup: "终端设置"
        case .allowConnection: "允许 CLI 连接 MacTools"
        case .build: "构建版本 %@"
        case .automaticUpdates: "CLI 会随 MacTools 自动更新。"
        case .rollbackHelp: "已保留回退版本；下次 MacTools 更新时将自动更新 CLI。"
        case .update: "更新"
        case .rollback: "回退上一版本"
        case .remove: "移除"
        case .reveal: "在访达中显示"
        case .copyPath: "复制 CLI 路径"
        case .installPrompt: "安装 CLI…"
        case .retry: "重试"
        case .copyDiagnostics: "复制诊断信息"
        case .pathHelp: "若终端找不到命令，请将 ~/.local/bin 添加到 PATH。MacTools 不会修改 shell 配置。"
        case .copy: "复制"
        case .notInstalled: "CLI 未安装"
        case .downloading: "正在下载 CLI…"
        case .verifying: "正在验证 CLI…"
        case .installing: "正在安装 CLI…"
        case .installed: "CLI 已安装"
        case .updateAvailable: "CLI 有可用更新"
        case .failed: "CLI 操作未完成：%@"
        case .confirmTitle: "安装 CLI？"
        case .paths: "安装目录：\n%@\n\n命令路径：\n%@"
        case .ownershipHelp: "不会覆盖手动、Homebrew 或其他渠道安装。无需管理员密码。"
        case .enableIntegration: "启用命令行集成"
        case .integrationOn: "允许 CLI 连接此应用；macOS 可能要求批准后台运行。"
        case .integrationOff: "CLI 本机命令仍可使用；访问应用操作需要启用命令行集成。"
        case .cancel: "取消"
        case .install: "安装"
        }
    }

    func format(_ arguments: CVarArg...) -> String {
        String(format: text, locale: PluginRuntimeLocalization.locale, arguments: arguments)
    }

    static func status(_ phase: CLIInstallPhase, error: Error? = nil) -> String {
        switch phase {
        case .notInstalled: notInstalled.text
        case .downloading: downloading.text
        case .verifying: verifying.text
        case .installing: installing.text
        case .installed: installed.text
        case .updateAvailable: updateAvailable.text
        case let .failed(message): failed.format(error?.localizedDescription ?? message)
        }
    }
}
