import Foundation
import OSLog
import SwiftUI

@MainActor
final class KeepAwakePlugin: FeaturePlugin {
    private enum Timing {
        static let secondsPerMinute: TimeInterval = 60
    }

    private enum ControlID {
        static let duration = "duration"
    }

    private enum DurationPreset: String {
        case forever
        case thirtyMinutes
        case oneHour
        case twoHours
        case fiveHours

        var timeInterval: TimeInterval? {
            switch self {
            case .forever:
                return nil
            case .thirtyMinutes:
                return 30 * 60
            case .oneHour:
                return 60 * 60
            case .twoHours:
                return 2 * 60 * 60
            case .fiveHours:
                return 5 * 60 * 60
            }
        }
    }

    private enum DurationOptionID {
        static let forever = DurationPreset.forever.rawValue
        static let thirtyMinutes = DurationPreset.thirtyMinutes.rawValue
        static let oneHour = DurationPreset.oneHour.rawValue
        static let twoHours = DurationPreset.twoHours.rawValue
        static let fiveHours = DurationPreset.fiveHours.rawValue
    }

    let manifest = PluginManifest(
        id: "keep-awake",
        title: "阻止休眠",
        iconName: "powersleep",
        iconTint: Color(nsColor: .systemOrange),
        controlStyle: .switch,
        menuActionBehavior: .keepPresented,
        order: 50,
        defaultDescription: "阻止系统空闲休眠，允许显示器息屏"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = AppLog.keepAwakePlugin
    private var lastErrorMessage: String?
    private var session: KeepAwakeSession?
    private var selectedDurationPreset: DurationPreset = .forever
    private var scheduledEndDate: Date?
    private var subtitleRefreshTimer: Timer?

    var panelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: session != nil,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: panelDetail,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }

    var settingsSections: [PluginSettingsSection] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        scheduleSubtitleRefreshIfNeeded()
    }

    func handlePanelAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            setKeepAwakeEnabled(isEnabled)
        case .setDisclosureExpanded, .setNavigationSelection:
            return
        case let .setSelection(controlID, optionID):
            guard controlID == ControlID.duration else {
                return
            }

            updateDurationPreset(using: optionID)
        case .setDate:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}

    func handleSettingsAction(id: String) {}

    func handleShortcutAction(id: String) {}

    private var panelSubtitle: String {
        guard session != nil else {
            return manifest.defaultDescription
        }

        guard let scheduledEndDate else {
            return "已启用"
        }

        return remainingTimeDescription(until: scheduledEndDate, referenceDate: Date())
    }

    private var panelDetail: PluginPanelDetail? {
        guard session != nil else {
            return nil
        }

        return PluginPanelDetail(
            primaryControls: [
                PluginPanelControl(
                    id: ControlID.duration,
                    kind: .segmented,
                    options: [
                        PluginPanelControlOption(id: DurationOptionID.forever, title: "永不"),
                        PluginPanelControlOption(id: DurationOptionID.thirtyMinutes, title: "30min"),
                        PluginPanelControlOption(id: DurationOptionID.oneHour, title: "1h"),
                        PluginPanelControlOption(id: DurationOptionID.twoHours, title: "2h"),
                        PluginPanelControlOption(id: DurationOptionID.fiveHours, title: "5h")
                    ],
                    selectedOptionID: selectedDurationPreset.rawValue,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    isEnabled: true
                )
            ],
            secondaryPanel: nil
        )
    }

    private func setKeepAwakeEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            lastErrorMessage = nil
            session?.requestStop(reason: .userRequested)

            if session == nil {
                resetSelectionToDefaults()
                notifyChange()
            }

            return
        }

        selectedDurationPreset = .forever
        applyKeepAwakeConfiguration()
    }

    private func updateDurationPreset(using optionID: String) {
        guard let preset = DurationPreset(rawValue: optionID) else {
            return
        }

        selectedDurationPreset = preset
        lastErrorMessage = nil

        guard session != nil else {
            notifyChange()
            return
        }

        applyKeepAwakeConfiguration()
    }

    private func applyKeepAwakeConfiguration() {
        let session = session ?? KeepAwakeSession { [weak self] reason in
            self?.handleSessionEnd(reason)
        }
        let endDate = resolvedScheduledEndDate(referenceDate: Date())

        do {
            try session.start(until: endDate)
            self.session = session
            scheduledEndDate = endDate
            scheduleSubtitleRefreshIfNeeded()
            lastErrorMessage = nil
            notifyChange()
        } catch {
            logger.error("keep-awake session update failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private func resolvedScheduledEndDate(referenceDate: Date) -> Date? {
        selectedDurationPreset.timeInterval.map(referenceDate.addingTimeInterval)
    }

    private func remainingTimeDescription(
        until endDate: Date,
        referenceDate: Date
    ) -> String {
        let remainingDuration = max(endDate.timeIntervalSince(referenceDate), 0)
        let remainingMinutes = max(
            Int(ceil(remainingDuration / Timing.secondsPerMinute)),
            1
        )

        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60

        if hours == 0 {
            return "\(remainingMinutes) 分钟后自动停止"
        }

        if minutes == 0 {
            return "\(hours) 小时后自动停止"
        }

        return "\(hours) 小时 \(minutes) 分钟后自动停止"
    }

    private func scheduleSubtitleRefreshIfNeeded() {
        invalidateSubtitleRefreshTimer()

        guard session != nil, let scheduledEndDate else {
            return
        }

        let remainingDuration = scheduledEndDate.timeIntervalSinceNow

        guard remainingDuration > 0 else {
            return
        }

        let remainder = remainingDuration.truncatingRemainder(dividingBy: Timing.secondsPerMinute)
        let nextRefreshInterval = remainder > 0 ? remainder : Timing.secondsPerMinute

        let timer = Timer(
            timeInterval: nextRefreshInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSubtitleRefreshTimerFired()
            }
        }
        timer.tolerance = min(1, nextRefreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        subtitleRefreshTimer = timer
    }

    private func handleSubtitleRefreshTimerFired() {
        guard session != nil, scheduledEndDate != nil else {
            invalidateSubtitleRefreshTimer()
            return
        }

        notifyChange()
        scheduleSubtitleRefreshIfNeeded()
    }

    private func invalidateSubtitleRefreshTimer() {
        subtitleRefreshTimer?.invalidate()
        subtitleRefreshTimer = nil
    }

    private func handleSessionEnd(_ reason: KeepAwakeSession.EndReason) {
        session = nil
        resetSelectionToDefaults()

        switch reason {
        case .userRequested, .completed:
            lastErrorMessage = nil
        }

        notifyChange()
    }

    private func resetSelectionToDefaults() {
        selectedDurationPreset = .forever
        scheduledEndDate = nil
        invalidateSubtitleRefreshTimer()
    }

    private func notifyChange() {
        onStateChange?()
    }
}
