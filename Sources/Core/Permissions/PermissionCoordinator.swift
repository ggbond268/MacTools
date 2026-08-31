import AppKit
import Combine
import Foundation
import MacToolsPluginKit
import PermissionFlow
import SystemSettingsKit

private final class PermissionNotificationObserver: @unchecked Sendable {
    let notificationCenter: NotificationCenter
    let token: NSObjectProtocol

    init(notificationCenter: NotificationCenter, token: NSObjectProtocol) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    deinit {
        notificationCenter.removeObserver(token)
    }
}

enum HostPermissionKind: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case calendarFullAccess
    case automation
    case systemAudioRecording
    case fullDiskAccess
    case finderExtension

    static func resolve(
        permissionID: String,
        pluginKind: PluginPermissionKind
    ) -> HostPermissionKind {
        switch permissionID {
        case "system-audio-recording":
            return .systemAudioRecording
        case "full-disk-access":
            return .fullDiskAccess
        default:
            break
        }

        return switch pluginKind {
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        case .calendarFullAccess: .calendarFullAccess
        case .automation: .automation
        case .screenRecording: .screenRecording
        case .finderExtension: .finderExtension
        }
    }

    var sortOrder: Int {
        switch self {
        case .accessibility: 0
        case .inputMonitoring: 1
        case .screenRecording: 2
        case .systemAudioRecording: 3
        case .calendarFullAccess: 4
        case .automation: 5
        case .fullDiskAccess: 6
        case .finderExtension: 7
        }
    }
}

enum PermissionCenterStatus: Int, Equatable, Sendable {
    case attention
    case onDemand
    case granted
}

struct PermissionCenterRequirement: Equatable, Sendable {
    let pluginID: String
    let pluginTitle: String
    let permissionID: String
    let kind: HostPermissionKind
    let description: String
    let isGranted: Bool
    let footnote: String?
    let statusText: String?
    let statusSystemImage: String?
    let statusTone: PluginStatusTone?
}

struct PermissionCenterAffectedFeature: Identifiable, Equatable, Sendable {
    let pluginID: String
    let pluginTitle: String
    let permissionID: String
    let description: String
    let isGranted: Bool
    let footnote: String?

    var id: String {
        "\(pluginID).permission.\(permissionID)"
    }
}

struct PermissionCenterItem: Identifiable, Equatable, Sendable {
    let kind: HostPermissionKind
    let status: PermissionCenterStatus
    let affectedFeatures: [PermissionCenterAffectedFeature]
    let statusText: String
    let statusSystemImage: String
    let statusTone: PluginStatusTone
    let footnote: String?

    var id: String { kind.rawValue }
    var actionTarget: PermissionCenterAffectedFeature? {
        affectedFeatures.first(where: { !$0.isGranted }) ?? affectedFeatures.first
    }
}

enum PermissionCenterAggregator {
    static func aggregate(
        _ requirements: [PermissionCenterRequirement]
    ) -> [PermissionCenterItem] {
        Dictionary(grouping: requirements, by: \.kind)
            .map { kind, requirements in
                let affectedFeatures = requirements
                    .map {
                        PermissionCenterAffectedFeature(
                            pluginID: $0.pluginID,
                            pluginTitle: $0.pluginTitle,
                            permissionID: $0.permissionID,
                            description: $0.description,
                            isGranted: $0.isGranted,
                            footnote: $0.footnote
                        )
                    }
                    .sorted {
                        if $0.pluginTitle.localizedStandardCompare($1.pluginTitle) == .orderedSame {
                            return $0.id < $1.id
                        }
                        return $0.pluginTitle.localizedStandardCompare($1.pluginTitle) == .orderedAscending
                    }

                let unresolved = requirements.filter { !$0.isGranted }
                let status: PermissionCenterStatus
                if unresolved.isEmpty {
                    status = .granted
                } else if unresolved.allSatisfy({ $0.statusTone == .neutral }) {
                    status = .onDemand
                } else {
                    status = .attention
                }

                let representative = unresolved.first ?? requirements.first
                let statusPresentation = statusPresentation(
                    status: status,
                    representative: representative
                )
                return PermissionCenterItem(
                    kind: kind,
                    status: status,
                    affectedFeatures: affectedFeatures,
                    statusText: statusPresentation.text,
                    statusSystemImage: statusPresentation.systemImage,
                    statusTone: statusPresentation.tone,
                    footnote: centerFootnote(for: kind, requirements: requirements)
                )
            }
            .sorted {
                if $0.status.rawValue != $1.status.rawValue {
                    return $0.status.rawValue < $1.status.rawValue
                }
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
    }

    private static func statusPresentation(
        status: PermissionCenterStatus,
        representative: PermissionCenterRequirement?
    ) -> (text: String, systemImage: String, tone: PluginStatusTone) {
        switch status {
        case .granted:
            return (
                AppL10n.plugins("plugin.permission.granted", defaultValue: "已授权"),
                "checkmark.shield.fill",
                .positive
            )
        case .onDemand:
            return (
                representative?.statusText
                    ?? AppL10n.settings("permissions.status.onDemand", defaultValue: "按需请求"),
                representative?.statusSystemImage ?? "cursorarrow.click.2",
                .neutral
            )
        case .attention:
            return (
                representative?.statusText
                    ?? AppL10n.plugins("plugin.permission.notGranted", defaultValue: "未授权"),
                representative?.statusSystemImage ?? "exclamationmark.triangle.fill",
                representative?.statusTone ?? .caution
            )
        }
    }

    private static func centerFootnote(
        for kind: HostPermissionKind,
        requirements: [PermissionCenterRequirement]
    ) -> String? {
        switch kind {
        case .fullDiskAccess:
            return AppL10n.settings(
                "permissions.fullDiskAccess.restartNote",
                defaultValue: "更改完全磁盘访问后，可能需要重新打开 MacTools 才能刷新完整访问范围。"
            )
        case .automation:
            return AppL10n.settings(
                "permissions.automation.onDemandNote",
                defaultValue: "自动化权限由 macOS 在功能首次控制目标 App 时按需请求。"
            )
        case .systemAudioRecording:
            return AppL10n.settings(
                "permissions.systemAudio.onDemandNote",
                defaultValue: "系统音频录制由相关功能首次捕获音频时按需请求。"
            )
        default:
            return requirements.lazy.compactMap(\.footnote).first
        }
    }
}

@MainActor
final class PermissionCoordinator: ObservableObject {
    typealias SpecializedActionHandler = (_ pluginID: String, _ permissionID: String) -> Void
    typealias RefreshHandler = () -> Void
    typealias GuidanceHandler = @MainActor (_ kind: HostPermissionKind, _ sourceFrame: CGRect?) -> Void

    @Published private(set) var items: [PermissionCenterItem] = []

    private let specializedActionHandler: SpecializedActionHandler
    private let refreshHandler: RefreshHandler
    private let guidanceHandler: GuidanceHandler
    private var activationObserver: PermissionNotificationObserver?

    init(
        notificationCenter: NotificationCenter = .default,
        specializedActionHandler: @escaping SpecializedActionHandler,
        refreshHandler: @escaping RefreshHandler,
        guidanceHandler: @escaping GuidanceHandler = PermissionFlowGuidancePresenter.shared.present
    ) {
        self.specializedActionHandler = specializedActionHandler
        self.refreshHandler = refreshHandler
        self.guidanceHandler = guidanceHandler
        let token = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshHandler()
            }
        }
        activationObserver = PermissionNotificationObserver(
            notificationCenter: notificationCenter,
            token: token
        )
    }

    func replaceRequirements(_ requirements: [PermissionCenterRequirement]) {
        items = PermissionCenterAggregator.aggregate(requirements)
    }

    @discardableResult
    func performAction(
        pluginID: String,
        permissionID: String,
        sourceFrame: CGRect? = nil
    ) -> Bool {
        guard let item = items.first(where: { item in
            item.affectedFeatures.contains {
                $0.pluginID == pluginID && $0.permissionID == permissionID
            }
        }) else {
            return false
        }
        performAction(for: item, sourceFrame: sourceFrame)
        return true
    }

    func performAction(
        for item: PermissionCenterItem,
        sourceFrame: CGRect? = nil
    ) {
        switch item.kind {
        case .accessibility, .inputMonitoring, .screenRecording, .fullDiskAccess:
            guidanceHandler(item.kind, sourceFrame)
        case .automation:
            guidanceHandler(.automation, sourceFrame)
        case .calendarFullAccess, .systemAudioRecording, .finderExtension:
            guard let target = item.actionTarget else { return }
            specializedActionHandler(target.pluginID, target.permissionID)
        }
    }

    func refresh() {
        refreshHandler()
    }
}

@MainActor
final class PermissionFlowGuidancePresenter {
    static let shared = PermissionFlowGuidancePresenter()

    private let controller = PermissionFlow.makeController(
        configuration: PermissionFlowConfiguration(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false,
            localeIdentifier: PluginRuntimeLocalization.locale.identifier
        )
    )

    func present(kind: HostPermissionKind, sourceFrame: CGRect?) {
        controller.setLocaleIdentifier(PluginRuntimeLocalization.locale.identifier)
        switch kind {
        case .accessibility:
            authorize(.accessibility, sourceFrame: sourceFrame)
        case .inputMonitoring:
            authorize(.inputMonitoring, sourceFrame: sourceFrame)
        case .screenRecording:
            authorize(.screenRecording, sourceFrame: sourceFrame)
        case .fullDiskAccess:
            authorize(.fullDiskAccess, sourceFrame: sourceFrame)
        case .automation:
            SystemSettings.open(.privacy(anchor: .privacyAutomation))
        case .calendarFullAccess:
            SystemSettings.open(.privacy(anchor: .privacyCalendars))
        case .systemAudioRecording:
            SystemSettings.open(.privacy(anchor: .privacyAudioCapture))
        case .finderExtension:
            break
        }
    }

    private func authorize(_ pane: PermissionFlowPane, sourceFrame: CGRect?) {
        controller.authorize(
            pane: pane,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: sourceFrame
        )
    }
}
