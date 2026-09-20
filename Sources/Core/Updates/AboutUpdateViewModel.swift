import Combine
import SwiftUI

@MainActor
protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var availableUpdateVersion: String? { get }
    func installationEligibility() -> UpdateInstallationEligibility
    func checkForUpdateInformation() async -> AppUpdateProbeResult
    func checkForUpdates()
}

struct UpdateInstallationEligibility: Equatable {
    let isAllowed: Bool
    let reason: String?

    static let allowed = UpdateInstallationEligibility(isAllowed: true, reason: nil)

    static func blocked(_ reason: String) -> UpdateInstallationEligibility {
        UpdateInstallationEligibility(isAllowed: false, reason: reason)
    }
}

enum AppUpdateProbeResult: Equatable {
    case upToDate
    case updateAvailable(version: String)
    case error(message: String)
}

enum AboutUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case blocked(reason: String)
    case error(message: String)
}

@MainActor
final class AboutUpdateViewModel: ObservableObject {
    @Published private(set) var state: AboutUpdateState = .idle

    private let updater: any AppUpdating
    private var lastAvailableVersion: String?

    init(updater: any AppUpdating) {
        self.updater = updater
    }

    var primaryButtonTitle: String {
        shouldOfferInstallAction
            ? AppL10n.settings("about.update.installNow", defaultValue: "立即更新")
            : AppL10n.settings("about.update.check", defaultValue: "检查更新")
    }

    var isPrimaryButtonDisabled: Bool {
        state == .checking
    }

    var statusHeadline: String {
        switch state {
        case .idle:
            return AppL10n.settings("about.update.headline.idle", defaultValue: "检查最新版本")
        case .checking:
            return AppL10n.settings("about.update.headline.checking", defaultValue: "正在检查更新…")
        case .upToDate:
            return AppL10n.settings("about.update.headline.upToDate", defaultValue: "当前已是最新版本")
        case let .updateAvailable(version):
            return AppL10n.settingsFormat("about.update.headline.availableFormat", defaultValue: "检测到新版本 %@", version)
        case .blocked:
            if let version = lastAvailableVersion {
                return AppL10n.settingsFormat("about.update.headline.availableFormat", defaultValue: "检测到新版本 %@", version)
            }

            return AppL10n.settings("about.update.headline.blocked", defaultValue: "暂时无法启动更新")
        case .error:
            return AppL10n.settings("about.update.headline.failed", defaultValue: "检查更新失败")
        }
    }

    var statusDetail: String? {
        switch state {
        case .idle:
            return nil
        case .checking:
            return AppL10n.settings("about.update.detail.checking", defaultValue: "正在获取最新 Release 信息，请稍候。")
        case .upToDate:
            return AppL10n.settings("about.update.detail.upToDate", defaultValue: "当前已是最新版本。")
        case .updateAvailable:
            return AppL10n.settings(
                "about.update.detail.available",
                defaultValue: "已发现更高版本，点击“立即更新”后会进入系统标准安装流程。"
            )
        case let .blocked(reason):
            return reason
        case let .error(message):
            return message
        }
    }

    var statusSystemImage: String {
        switch state {
        case .idle:
            return "arrow.triangle.2.circlepath"
        case .checking:
            return "clock.arrow.circlepath"
        case .upToDate:
            return "checkmark.seal.fill"
        case .updateAvailable:
            return "sparkles"
        case .blocked:
            return "externaldrive.badge.exclamationmark"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch state {
        case .idle, .checking:
            return .accentColor
        case .upToDate:
            return .green
        case .updateAvailable:
            return .orange
        case .blocked, .error:
            return .red
        }
    }

    func performPrimaryAction() async {
        if shouldOfferInstallAction {
            startInteractiveUpdate()
        } else {
            await probeForUpdates()
        }
    }

    func performRequestedUpdateAction(version: String?) async {
        guard let version else {
            await probeForUpdates()
            return
        }
        lastAvailableVersion = version
        state = .updateAvailable(version: version)
        startInteractiveUpdate()
    }

    private var shouldOfferInstallAction: Bool {
        switch state {
        case .updateAvailable:
            return true
        case .blocked:
            return lastAvailableVersion != nil
        case .idle, .checking, .upToDate, .error:
            return false
        }
    }

    private func probeForUpdates() async {
        guard state != .checking else {
            return
        }

        if let version = updater.availableUpdateVersion {
            lastAvailableVersion = version
            state = .updateAvailable(version: version)
            return
        }

        guard updater.canCheckForUpdates else {
            state = .error(message: AppL10n.settings("about.update.error.servicePreparing", defaultValue: "更新服务正在准备中，请稍后再试。"))
            return
        }

        state = .checking
        lastAvailableVersion = nil

        switch await updater.checkForUpdateInformation() {
        case .upToDate:
            state = .upToDate
        case let .updateAvailable(version):
            lastAvailableVersion = version
            state = .updateAvailable(version: version)
        case let .error(message):
            state = .error(message: message)
        }
    }

    private func startInteractiveUpdate() {
        let eligibility = updater.installationEligibility()
        guard eligibility.isAllowed else {
            state = .blocked(
                reason: eligibility.reason
                    ?? AppL10n.settings("about.update.error.moveToApplications", defaultValue: "请先将应用移到 Applications 再更新。")
            )
            return
        }

        guard updater.canCheckForUpdates else {
            state = .error(message: AppL10n.settings("about.update.error.servicePreparing", defaultValue: "更新服务正在准备中，请稍后再试。"))
            return
        }

        updater.checkForUpdates()
    }
}
