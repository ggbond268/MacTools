import Foundation
import OSLog
import SwiftUI

@MainActor
final class KeepAwakePlugin: FeaturePlugin {
    private enum Timing {
        static let defaultCustomLeadTime: TimeInterval = 60
        static let minimumCustomLeadTime: TimeInterval = 1
    }

    private enum ControlID {
        static let duration = "duration"
        static let customEndDate = "customEndDate"
    }

    private enum DurationPreset: String {
        case forever
        case thirtyMinutes
        case custom
    }

    private enum DurationOptionID {
        static let forever = DurationPreset.forever.rawValue
        static let thirtyMinutes = DurationPreset.thirtyMinutes.rawValue
        static let custom = DurationPreset.custom.rawValue
    }

    let manifest = PluginManifest(
        id: "keep-awake",
        title: "阻止休眠",
        iconName: "powersleep",
        iconTint: Color(nsColor: .systemOrange),
        controlStyle: .switch,
        menuActionBehavior: .keepPresented,
        order: 50,
        defaultDescription: "允许息屏，阻止系统因空闲进入休眠"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = AppLog.keepAwakePlugin
    private var lastErrorMessage: String?
    private var session: KeepAwakeSession?
    private var selectedDurationPreset: DurationPreset = .forever
    private var customEndDate: Date?

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

    func refresh() {}

    func handlePanelAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            setKeepAwakeEnabled(isEnabled)
        case .setDisclosureExpanded:
            return
        case let .setSelection(controlID, optionID):
            guard controlID == ControlID.duration else {
                return
            }

            updateDurationPreset(using: optionID)
        case let .setDate(controlID, value):
            guard controlID == ControlID.customEndDate else {
                return
            }

            updateCustomEndDate(value)
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

        switch selectedDurationPreset {
        case .forever:
            return "已启用"
        case .thirtyMinutes:
            return "30 分钟后自动停止"
        case .custom:
            return "至 \(formattedEndDate(referenceDate: Date())) 自动停止"
        }
    }

    private var panelDetail: PluginPanelDetail? {
        guard session != nil else {
            return nil
        }

        let now = Date()
        var controls = [
            PluginPanelControl(
                id: ControlID.duration,
                kind: .segmented,
                options: [
                    PluginPanelControlOption(id: DurationOptionID.forever, title: "永不"),
                    PluginPanelControlOption(id: DurationOptionID.thirtyMinutes, title: "30min"),
                    PluginPanelControlOption(id: DurationOptionID.custom, title: "自定义")
                ],
                selectedOptionID: selectedDurationPreset.rawValue,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                isEnabled: true
            )
        ]

        if selectedDurationPreset == .custom {
            controls.append(
                PluginPanelControl(
                    id: ControlID.customEndDate,
                    kind: .datePicker,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: resolvedCustomEndDate(referenceDate: now),
                    minimumDate: minimumCustomEndDate(referenceDate: now),
                    displayedComponents: [.date, .hourAndMinute],
                    datePickerStyle: .dateTimeCard,
                    sectionTitle: nil,
                    isEnabled: true
                )
            )
        }

        return PluginPanelDetail(controls: controls)
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
        customEndDate = nil
        applyKeepAwakeConfiguration()
    }

    private func updateDurationPreset(using optionID: String) {
        guard let preset = DurationPreset(rawValue: optionID) else {
            return
        }

        selectedDurationPreset = preset
        lastErrorMessage = nil

        if preset == .custom {
            customEndDate = resolvedCustomEndDate(referenceDate: Date())
        }

        guard session != nil else {
            notifyChange()
            return
        }

        applyKeepAwakeConfiguration()
    }

    private func updateCustomEndDate(_ date: Date) {
        customEndDate = sanitizedCustomEndDate(date, referenceDate: Date())
        selectedDurationPreset = .custom
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

        do {
            try session.start(until: scheduledEndDate(referenceDate: Date()))
            self.session = session
            lastErrorMessage = nil
            notifyChange()
        } catch {
            logger.error("keep-awake session update failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private func scheduledEndDate(referenceDate: Date) -> Date? {
        switch selectedDurationPreset {
        case .forever:
            return nil
        case .thirtyMinutes:
            return referenceDate.addingTimeInterval(30 * 60)
        case .custom:
            return resolvedCustomEndDate(referenceDate: referenceDate)
        }
    }

    private func resolvedCustomEndDate(referenceDate: Date) -> Date {
        if let customEndDate {
            return sanitizedCustomEndDate(customEndDate, referenceDate: referenceDate)
        }

        return defaultCustomEndDate(referenceDate: referenceDate)
    }

    private func defaultCustomEndDate(referenceDate: Date) -> Date {
        referenceDate.addingTimeInterval(Timing.defaultCustomLeadTime)
    }

    private func sanitizedCustomEndDate(
        _ date: Date,
        referenceDate: Date
    ) -> Date {
        let minimumDate = minimumCustomEndDate(referenceDate: referenceDate)
        return max(date, minimumDate)
    }

    private func minimumCustomEndDate(referenceDate: Date) -> Date {
        referenceDate.addingTimeInterval(Timing.minimumCustomLeadTime)
    }

    private func formattedEndDate(referenceDate: Date) -> String {
        let endDate = resolvedCustomEndDate(referenceDate: referenceDate)

        if Calendar.current.isDateInToday(endDate) {
            return endDate.formatted(date: .omitted, time: .shortened)
        }

        return endDate.formatted(.dateTime.month().day().hour().minute())
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
        customEndDate = nil
    }

    private func notifyChange() {
        onStateChange?()
    }
}
