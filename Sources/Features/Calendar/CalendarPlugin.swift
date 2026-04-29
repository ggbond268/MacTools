import AppKit
import SwiftUI

@MainActor
final class CalendarPlugin: ComponentPlugin {
    private enum PermissionID {
        static let calendarEvents = "calendar-events"
        static let calendarAutomation = "calendar-automation"
    }

    let metadata = PluginMetadata(
        id: "calendar",
        title: "日历",
        iconName: "calendar",
        iconTint: Color(nsColor: .systemIndigo),
        order: 15,
        defaultDescription: "查看日期、节假日和系统日程"
    )

    let componentDescriptor = PluginComponentDescriptor(
        span: PluginComponentSpan(width: 4, height: 3)!
    )

    private let eventService = CalendarEventService()

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var componentState: PluginComponentState {
        PluginComponentState(
            subtitle: metadata.defaultDescription,
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.calendarEvents,
                kind: .calendarFullAccess,
                title: "系统日历事件",
                description: "读取系统日历事件，用于在日历组件中显示当天日程。"
            ),
            PluginPermissionRequirement(
                id: PermissionID.calendarAutomation,
                kind: .automation,
                title: "定位系统日历",
                description: "点击日期时需要控制系统日历应用，打开并定位到对应日期。"
            )
        ]
    }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func makeComponentView(context: PluginComponentContext) -> AnyView {
        AnyView(CalendarComponentView(context: context))
    }

    func refresh() {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.calendarEvents:
            return calendarEventsPermissionState
        case PermissionID.calendarAutomation:
            return PluginPermissionState(
                isGranted: false,
                footnote: "首次定位系统日历时 macOS 会请求控制“日历”的权限；若曾拒绝，请在系统设置的自动化中允许。",
                statusText: "按需确认",
                statusSystemImage: "cursorarrow.click.2",
                statusTone: .neutral
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.calendarEvents:
            handleCalendarEventsPermissionAction()
        case PermissionID.calendarAutomation:
            openPrivacyPane(anchor: "Privacy_Automation")
        default:
            break
        }
    }
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private var calendarEventsPermissionState: PluginPermissionState {
        switch eventService.authorization {
        case .fullAccess:
            return PluginPermissionState(isGranted: true, footnote: nil)
        case .notDetermined:
            return PluginPermissionState(
                isGranted: false,
                footnote: "点击请求授权后，系统会询问是否允许读取日历事件。"
            )
        case let .denied(message):
            return PluginPermissionState(
                isGranted: false,
                footnote: "\(message)。可在系统设置的日历隐私项中重新允许。"
            )
        }
    }

    private func handleCalendarEventsPermissionAction() {
        switch eventService.authorization {
        case .fullAccess:
            onStateChange?()
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                _ = await eventService.requestAccess()
                onStateChange?()
            }
        case .denied:
            openPrivacyPane(anchor: "Privacy_Calendars")
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
