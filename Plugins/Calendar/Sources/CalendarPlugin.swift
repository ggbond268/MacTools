import AppKit
import SwiftUI
import MacToolsPluginKit

public final class CalendarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        CalendarPluginProvider(context: context)
    }
}

@MainActor
private struct CalendarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let resourceContext = PluginRuntimeContext(
            pluginID: context.pluginID,
            resourceBundle: context.resourceBundle,
            resourceSubdirectory: "CalendarPluginResources",
            storage: context.storage,
            supportDirectory: context.supportDirectory,
            cacheDirectory: context.cacheDirectory,
            temporaryDirectory: context.temporaryDirectory
        )
        return [CalendarPlugin(context: resourceContext, localization: localization)]
    }
}

@MainActor
final class CalendarPlugin: MacToolsPlugin, PluginComponentPanel, PluginPanelSurfaceLifecycleHandling {
    private enum PermissionID {
        static let calendarEvents = "calendar-events"
        static let calendarAutomation = "calendar-automation"
    }

    let metadata: PluginMetadata

    let descriptor = PluginComponentDescriptor(
        span: PluginComponentSpan(
            width: 4,
            height: PluginComponentPanelLayoutMetrics.default.heightSpan(closestToOriginalSpanHeight: 5)
        )!
    )

    private let context: PluginRuntimeContext
    private let eventService: CalendarEventServicing
    private let localization: PluginLocalization
    private let settingsStore: CalendarSettingsStore
    private let viewModel: CalendarComponentViewModel

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(
            pluginID: "calendar",
            resourceSubdirectory: "CalendarPluginResources"
        ),
        eventService: CalendarEventServicing? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.context = context
        self.localization = localization
        self.eventService = eventService ?? CalendarEventService(localization: localization)
        self.settingsStore = CalendarSettingsStore(storage: context.storage)
        self.viewModel = CalendarComponentViewModel(
            eventService: self.eventService,
            holidayProvider: .bundled(context: context),
            calendar: CalendarComponentCalendars.gregorian(
                firstWeekday: self.settingsStore.weekStartDay.calendarFirstWeekday
            ),
            localization: localization
        )
        self.metadata = PluginMetadata(
            id: "calendar",
            title: localization.string("metadata.title", defaultValue: "日历"),
            iconName: "calendar",
            iconTint: Color(nsColor: .systemIndigo),
            order: 15,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看日期、节假日和系统日程"
            )
        )
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var componentPanelState: PluginComponentState {
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
                title: localization.string("permission.events.title", defaultValue: "系统日历事件"),
                description: localization.string(
                    "permission.events.description",
                    defaultValue: "读取系统日历事件，用于在日历组件中显示当天日程。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.calendarAutomation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "定位系统日历"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "点击日期时需要控制系统日历应用，打开并定位到对应日期。"
                )
            )
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "calendar-display",
                    title: localization.string("settings.display.title", defaultValue: "日历显示"),
                    systemImage: "calendar",
                    rows: [
                        PluginSettingsRow(
                            id: "week-start-day",
                            title: localization.string("settings.weekStart.title", defaultValue: "每周起始日"),
                            description: localization.string(
                                "settings.weekStart.description",
                                defaultValue: "选择月历每周显示的第一天。"
                            ),
                            systemImage: "calendar.day.timeline.leading",
                            control: .picker(
                                selectionID: settingsStore.weekStartDay.rawValue,
                                options: CalendarWeekStartDay.allCases.map {
                                    PluginSettingsOption(id: $0.rawValue, title: $0.displayName())
                                },
                                style: .menu
                            )
                        )
                    ]
                )
            ]
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(
            CalendarComponentView(
                context: context,
                viewModel: viewModel,
                localization: localization
            )
        )
    }

    func refresh() {}

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        guard surface == .component else {
            return
        }

        viewModel.start()
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        guard surface == .component else {
            return
        }

        viewModel.stop()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.calendarEvents:
            return calendarEventsPermissionState
        case PermissionID.calendarAutomation:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.automation.footnote",
                    defaultValue: "首次定位系统日历时 macOS 会请求控制“日历”的权限；若曾拒绝，请在系统设置的自动化中允许。"
                ),
                statusText: localization.string("permission.automation.status", defaultValue: "按需确认"),
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
    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setSelection(controlID, optionID) = action,
              controlID == "week-start-day",
              let day = CalendarWeekStartDay(rawValue: optionID)
        else { return }
        setWeekStartDay(day)
    }
    func handleShortcutAction(id: String) {}

    private func setWeekStartDay(_ day: CalendarWeekStartDay) {
        settingsStore.setWeekStartDay(day)
        viewModel.setWeekStartDay(day)
        onStateChange?()
    }

    private var calendarEventsPermissionState: PluginPermissionState {
        switch eventService.authorization {
        case .fullAccess:
            return PluginPermissionState(isGranted: true, footnote: nil)
        case .notDetermined:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.events.notDetermined",
                    defaultValue: "点击请求授权后，系统会询问是否允许读取日历事件。"
                )
            )
        case let .denied(message):
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.format(
                    "permission.events.denied",
                    defaultValue: "%@。可在系统设置的日历隐私项中重新允许。",
                    message
                )
            )
        }
    }

    private func handleCalendarEventsPermissionAction() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let authorization = await eventService.requestAccess()
            if case .denied = authorization {
                openPrivacyPane(anchor: "Privacy_Calendars")
            }

            onStateChange?()
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
