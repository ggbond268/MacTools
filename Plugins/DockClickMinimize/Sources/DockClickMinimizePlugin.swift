import AppKit
import ApplicationServices
@preconcurrency import IOKit.hid
import MacToolsPluginKit
import SwiftUI

enum DockClickMinimizeInputMonitoringStatus: Equatable {
    case granted
    case denied
    case unknown
}

enum DockClickDecision {
    static func shouldScheduleHide(
        target: DockApplicationTarget?,
        frontmostApplication: DockFrontmostApplication?,
        hasVisibleWindow: Bool
    ) -> Bool {
        guard let target,
              let frontmostApplication,
              target.bundleIdentifier == frontmostApplication.bundleIdentifier,
              hasVisibleWindow
        else {
            return false
        }
        return true
    }
}

public final class DockClickMinimizePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DockClickMinimizePluginProvider(context: context)
    }
}

@MainActor
private struct DockClickMinimizePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            DockClickMinimizePlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            )
        ]
    }
}

@MainActor
final class DockClickMinimizePlugin: MacToolsPlugin, PluginPrimaryPanel, AccessibilityPermissionRefreshing {
    private enum PermissionID {
        static let accessibility = "accessibility"
        static let inputMonitoring = "input-monitoring"
    }

    private enum StorageKey {
        static let isEnabled = "dock-click-minimize.enabled"
    }

    private enum SettingsID {
        static let section = "dock-click-minimize.settings"
        static let isEnabled = "dock-click-minimize.settings.enabled"
    }

    private static let postDockClickDelay: Duration = .milliseconds(120)

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let storage: any PluginStorage
    private let monitor: any DockClickMonitoring
    private let applicationHider: any DockApplicationHiding
    private let frontmostApplicationProvider: any DockFrontmostApplicationProviding
    private let localization: PluginLocalization
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let inputMonitoringStatus: @MainActor () -> DockClickMinimizeInputMonitoringStatus
    private let openURL: @MainActor (URL) -> Void
    private let scheduleDelayedAction: (@escaping @MainActor () -> Void) -> Void
    private let notificationCenter: NotificationCenter

    private var applicationActivationObserver: NSObjectProtocol?
    private var isEnabled: Bool
    private var isAccessibilityGranted: Bool
    private var isInputMonitoringGranted: Bool
    private var lastErrorMessage: String?
    private var actionGeneration = 0

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "dock-click-minimize"),
        monitor: (any DockClickMonitoring)? = nil,
        applicationHider: (any DockApplicationHiding)? = nil,
        frontmostApplicationProvider: any DockFrontmostApplicationProviding = WorkspaceDockFrontmostApplicationProvider(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = { prompt in
            guard prompt else { return AXIsProcessTrusted() }
            return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        inputMonitoringStatus: @escaping @MainActor () -> DockClickMinimizeInputMonitoringStatus = {
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .unknown
            }
        },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        scheduleDelayedAction: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            Task { @MainActor in
                try? await Task.sleep(for: DockClickMinimizePlugin.postDockClickDelay)
                guard !Task.isCancelled else { return }
                action()
            }
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.storage = context.storage
        self.monitor = monitor ?? DockClickMonitor()
        self.applicationHider = applicationHider ?? DockApplicationHider()
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.localization = localization
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.inputMonitoringStatus = inputMonitoringStatus
        self.openURL = openURL
        self.scheduleDelayedAction = scheduleDelayedAction
        self.notificationCenter = notificationCenter
        self.isEnabled = context.storage.object(forKey: StorageKey.isEnabled) == nil
            ? true
            : context.storage.bool(forKey: StorageKey.isEnabled)
        self.isAccessibilityGranted = accessibilityTrusted()
        self.isInputMonitoringGranted = inputMonitoringStatus() == .granted
        self.metadata = PluginMetadata(
            id: "dock-click-minimize",
            title: localization.string("metadata.title", defaultValue: "点击程序坞隐藏活跃 App"),
            iconName: "dock.rectangle",
            iconTint: Color(nsColor: .systemIndigo),
            order: 47,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "点击活跃 App 的程序坞图标即可将其隐藏（如 Windows）。"
            )
        )

        self.monitor.onApplicationClick = { [weak self] target, frontmostApplication in
            MainActor.assumeIsolated {
                self?.handleDockApplicationClick(target, frontmostApplication: frontmostApplication)
            }
        }
    }

    func activate(context: PluginRuntimeContext) {
        observeApplicationActivation()
        refreshPermissionState()
        applyMonitoringState(promptForAccessibilityPermission: false)
    }

    func deactivate(reason: PluginDeactivationReason) {
        invalidatePendingActions()
        removeApplicationActivationObserver()
        monitor.stop()
    }

    func refresh() {
        refreshPermissionState()
        applyMonitoringState(promptForAccessibilityPermission: false)
        onStateChange?()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: isEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于识别程序坞中的应用，并隐藏当前活跃的应用。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string("permission.inputMonitoring.title", defaultValue: "输入监控"),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于在不阻止原生程序坞点击的情况下监听鼠标左键。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: SettingsID.section,
                    title: localization.string("settings.section.title", defaultValue: "设置"),
                    systemImage: "dock.rectangle",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.isEnabled,
                            title: metadata.title,
                            description: metadata.defaultDescription,
                            systemImage: "power",
                            error: lastErrorMessage,
                            control: .toggle(isOn: isEnabled)
                        ),
                    ]
                ),
            ]
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }
        self.isEnabled = isEnabled
        storage.set(isEnabled, forKey: StorageKey.isEnabled)
        if !isEnabled {
            invalidatePendingActions()
        }
        applyMonitoringState(promptForAccessibilityPermission: isEnabled)
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.accessibility:
            PluginPermissionState(
                isGranted: isAccessibilityGranted,
                footnote: isAccessibilityGranted ? nil : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "Allow MacTools in System Settings > Privacy & Security > Accessibility."
                )
            )
        case PermissionID.inputMonitoring:
            PluginPermissionState(
                isGranted: isInputMonitoringGranted,
                footnote: isInputMonitoringGranted ? nil : localization.string(
                    "permission.inputMonitoring.footnote",
                    defaultValue: "Allow MacTools in System Settings > Privacy & Security > Input Monitoring."
                )
            )
        default:
            PluginPermissionState(isGranted: false, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.accessibility:
            _ = requestAccessibilityTrust(true)
        case PermissionID.inputMonitoring:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                openURL(url)
            }
        default:
            return
        }
        refreshPermissionState()
        applyMonitoringState(promptForAccessibilityPermission: false)
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setBoolean(controlID, value) = action,
              controlID == SettingsID.isEnabled
        else {
            return
        }
        handleAction(.setSwitch(value))
    }
    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        let previouslyGranted = isAccessibilityGranted
        refreshPermissionState()
        if previouslyGranted && !isAccessibilityGranted {
            invalidatePendingActions()
        }
        applyMonitoringState(promptForAccessibilityPermission: false)
        onStateChange?()
    }

    func handleDockApplicationClick(
        _ target: DockApplicationTarget,
        frontmostApplication: DockFrontmostApplication
    ) {
        guard isEnabled,
              isAccessibilityGranted,
              isInputMonitoringGranted,
              target.bundleIdentifier == frontmostApplication.bundleIdentifier,
              applicationHider.hasVisibleWindow(for: frontmostApplication.processIdentifier),
              DockClickDecision.shouldScheduleHide(
                  target: target,
                  frontmostApplication: frontmostApplication,
                  hasVisibleWindow: true
              )
        else {
            return
        }

        let expectedGeneration = actionGeneration
        scheduleDelayedAction { [weak self] in
            self?.hideAfterDockClick(
                target: target,
                expectedFrontmostApplication: frontmostApplication,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private var panelSubtitle: String {
        guard isEnabled else {
            return localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
        }
        guard isAccessibilityGranted else {
            return localization.string("panel.subtitle.needsAccessibility", defaultValue: "需要辅助功能授权")
        }
        guard isInputMonitoringGranted else {
            return localization.string("panel.subtitle.needsInputMonitoring", defaultValue: "需要输入监控授权")
        }
        return localization.string("panel.subtitle.enabled", defaultValue: "已开启")
    }

    private func hideAfterDockClick(
        target: DockApplicationTarget,
        expectedFrontmostApplication: DockFrontmostApplication,
        expectedGeneration: Int
    ) {
        guard expectedGeneration == actionGeneration,
              isEnabled,
              isAccessibilityGranted,
              isInputMonitoringGranted,
              target.bundleIdentifier == expectedFrontmostApplication.bundleIdentifier,
              frontmostApplicationProvider.frontmostApplication() == expectedFrontmostApplication
        else {
            return
        }
        _ = applicationHider.hideApplication(
            bundleIdentifier: expectedFrontmostApplication.bundleIdentifier,
            processIdentifier: expectedFrontmostApplication.processIdentifier
        )
    }

    private func refreshPermissionState() {
        isAccessibilityGranted = accessibilityTrusted()
        isInputMonitoringGranted = inputMonitoringStatus() == .granted
    }

    private func applyMonitoringState(promptForAccessibilityPermission: Bool) {
        guard isEnabled else {
            monitor.stop()
            lastErrorMessage = nil
            return
        }

        refreshPermissionState()
        if !isAccessibilityGranted, promptForAccessibilityPermission {
            _ = requestAccessibilityTrust(true)
            refreshPermissionState()
        }
        guard isAccessibilityGranted else {
            monitor.stop()
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "Hide Active App on Dock Click needs Accessibility permission."
            )
            requestPermissionGuidance?(PermissionID.accessibility)
            return
        }
        guard isInputMonitoringGranted else {
            monitor.stop()
            lastErrorMessage = localization.string(
                "error.inputMonitoringRequired",
                defaultValue: "Hide Active App on Dock Click needs Input Monitoring permission."
            )
            requestPermissionGuidance?(PermissionID.inputMonitoring)
            return
        }
        guard monitor.start() else {
            lastErrorMessage = localization.string(
                "error.startFailed",
                defaultValue: "Hide Active App on Dock Click could not start. Check its permissions."
            )
            return
        }
        lastErrorMessage = nil
    }

    private func invalidatePendingActions() {
        actionGeneration &+= 1
    }

    private func observeApplicationActivation() {
        guard applicationActivationObserver == nil else {
            return
        }
        applicationActivationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissionState()
                self.applyMonitoringState(promptForAccessibilityPermission: false)
                self.onStateChange?()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else {
            return
        }
        notificationCenter.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }
}
