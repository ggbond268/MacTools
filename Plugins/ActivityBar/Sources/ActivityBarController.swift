import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class ActivityBarController: ObservableObject {
    static let pluginID = ActivityBarConstants.pluginID
    static let defaultSocketPath = ActivityBarConstants.defaultSocketPath

    enum HookInstallState: Equatable {
        case notInstalled
        case installed(timestamp: String)
        case failed
    }

    private enum StorageKey {
        static let isTrackingEnabled = "activity-bar.tracking.enabled"
        static let hooksInstalledAt = "activity-bar.hooks.installed-at"
    }

    @Published private(set) var isTrackingEnabled: Bool
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var hookInstallState: HookInstallState = .notInstalled

    let localization: PluginLocalization
    let inputStats: ActivityBarStatsStore
    let codingStats: ActivityBarCodingSessionStore

    var onStateChange: (() -> Void)?

    private let storage: PluginStorage
    private let inputMonitor: any ActivityBarInputMonitoring
    private let socketServer: any ActivityBarSocketServing
    private let inputEventNotificationDelay: Duration
    private let namespace: ActivityBarNamespace
    private var hookInstallerPaths: ActivityBarHookInstallerPaths
    private var inputEventNotificationTask: Task<Void, Never>?

    init(
        context: PluginRuntimeContext,
        inputMonitor: (any ActivityBarInputMonitoring)? = nil,
        socketServer: (any ActivityBarSocketServing)? = nil,
        inputStats: ActivityBarStatsStore? = nil,
        codingStats: ActivityBarCodingSessionStore? = nil,
        hookInstallerPaths: ActivityBarHookInstallerPaths? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        inputEventNotificationDelay: Duration = .milliseconds(750),
        namespace: ActivityBarNamespace = .init()
    ) {
        let resolvedInputStats = inputStats ?? ActivityBarStatsStore(storage: context.storage)
        let resolvedCodingStats = codingStats ?? ActivityBarCodingSessionStore(storage: context.storage)
        let resolvedInputMonitor = inputMonitor ?? ActivityBarInputMonitor()
        let resolvedHookInstallerPaths = hookInstallerPaths
            ?? ActivityBarHookInstallerPaths.defaults(
                supportDirectory: context.supportDirectory,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                namespace: namespace
            )
        let resolvedSocketServer = socketServer ?? ActivityBarHookSocketServer(socketPath: namespace.socketPath) { event in
            resolvedCodingStats.handleEvent(event)
        }

        storage = context.storage
        self.localization = localization
        self.inputStats = resolvedInputStats
        self.codingStats = resolvedCodingStats
        self.inputMonitor = resolvedInputMonitor
        self.hookInstallerPaths = resolvedHookInstallerPaths
        self.socketServer = resolvedSocketServer
        self.inputEventNotificationDelay = inputEventNotificationDelay
        self.namespace = namespace
        isTrackingEnabled = context.storage.bool(forKey: StorageKey.isTrackingEnabled)

        self.inputMonitor.onEvent = { [weak self] event in
            guard let self else {
                return
            }
            self.inputStats.record(event)
            self.scheduleInputEventNotification()
        }

        if let installedAt = context.storage.string(forKey: StorageKey.hooksInstalledAt) {
            hookInstallState = .installed(timestamp: installedAt)
        }

    }

    @MainActor deinit {
        inputEventNotificationTask?.cancel()
    }

    var hookStatusMessage: String? {
        switch hookInstallState {
        case .notInstalled:
            return nil
        case .installed(let timestamp):
            return localization.format("hook.status.installedWithDate", defaultValue: "已安装：%@", timestamp)
        case .failed:
            return localization.string("hook.status.installFailed", defaultValue: "安装失败")
        }
    }

    var isHookListenerRunning: Bool {
        socketServer.isRunning
    }

    var areHooksInstalled: Bool {
        if case .installed = hookInstallState {
            return true
        }

        return false
    }

    var monitorStatus: ActivityBarInputMonitorStatus {
        inputMonitor.status
    }

    var todayInputStats: ActivityBarDailyStats {
        inputStats.today
    }

    var todayCodingStats: ActivityBarCodingDailyStats {
        codingStats.today
    }

    var panelSubtitle: String {
        if let lastErrorMessage {
            return lastErrorMessage
        }

        if isTrackingEnabled {
            return localization.format(
                "panel.subtitle.todayInputs",
                defaultValue: "今日 %@ 次输入",
                ActivityBarFormatting.count(todayInputStats.totalInputs)
            )
        }

        if isHookListenerRunning {
            return localization.string("panel.subtitle.aiListening", defaultValue: "AI 活动监听中")
        }

        return localization.string("panel.subtitle.default", defaultValue: "统计输入与 AI 编程活动")
    }

    var componentSubtitle: String {
        if isTrackingEnabled {
            return localization.format(
                "component.subtitle.inputs",
                defaultValue: "%@ 次输入",
                ActivityBarFormatting.count(todayInputStats.totalInputs)
            )
        }
        if isHookListenerRunning {
            return localization.string("component.subtitle.aiListening", defaultValue: "AI 监听中")
        }
        return localization.string("component.subtitle.disabled", defaultValue: "未开启")
    }

    var inputMonitoringFootnote: String? {
        switch inputMonitor.status {
        case .inputMonitoringDenied:
            return localization.string(
                "settings.inputMonitoring.footnote",
                defaultValue: "键盘、鼠标和滚动统计需要在系统设置中允许 MacTools 进行输入监控。前台应用使用时长仍可记录。"
            )
        case .idle, .running:
            return nil
        }
    }

    var hookInstallFootnote: String {
        localization.string(
            "settings.aiHooks.footnote",
            defaultValue: "点击后会写入 Claude Code、Cursor 和 Codex 的 hook 配置；AI 活动监听不需要输入监控权限。"
        )
    }

    var hookUninstallFootnote: String {
        localization.string(
            "settings.aiHooks.uninstallFootnote",
            defaultValue: "只移除 MacTools 写入的 Hook 条目和脚本，不会清空其他工具配置。"
        )
    }

    var hookActionFootnote: String {
        areHooksInstalled ? hookUninstallFootnote : hookInstallFootnote
    }

    func activate(context: PluginRuntimeContext) {
        hookInstallerPaths = ActivityBarHookInstallerPaths.defaults(
            supportDirectory: context.supportDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            namespace: namespace
        )

        startHookListenerIfNeeded()
        if isTrackingEnabled {
            startInputTracking()
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopRuntime()
        inputEventNotificationTask?.cancel()
        inputEventNotificationTask = nil
    }

    func refresh() {
        inputStats.flushPendingChanges()
        codingStats.flushActiveDurations()
        notifyChange()
    }

    @discardableResult
    func setTrackingEnabled(_ enabled: Bool) -> ActivityBarPersistenceMutationResult {
        let previousRawValue = storage.object(forKey: StorageKey.isTrackingEnabled)
        guard previousRawValue == nil || previousRawValue is Bool else {
            return .recoveryRequired
        }
        if let previous = previousRawValue as? Bool, previous == enabled {
            return .committed
        }

        storage.set(enabled, forKey: StorageKey.isTrackingEnabled)
        guard storage.object(forKey: StorageKey.isTrackingEnabled) as? Bool == enabled else {
            let rollbackSucceeded = restoreActivityBarStorageValue(
                previousRawValue,
                forKey: StorageKey.isTrackingEnabled,
                storage: storage
            )
            if !rollbackSucceeded {
                reconcileTrackingWithStorage()
            }
            return .rejected(rollbackSucceeded: rollbackSucceeded)
        }

        applyTrackingState(enabled)
        notifyChange()
        return .committed
    }

    private func applyTrackingState(_ enabled: Bool) {
        isTrackingEnabled = enabled

        if enabled {
            startInputTracking()
            startHookListenerIfNeeded()
        } else {
            stopInputTracking()
            if !shouldRunHookListener {
                lastErrorMessage = nil
            }
        }
    }

    private func reconcileTrackingWithStorage() {
        let durableState = storage.object(forKey: StorageKey.isTrackingEnabled) as? Bool ?? false
        applyTrackingState(durableState)
        notifyChange()
    }

    @discardableResult
    func resetToday() -> ActivityBarPersistenceMutationResult {
        guard
            let inputReset = inputStats.prepareTodayReset(),
            let codingReset = codingStats.prepareTodayReset()
        else {
            return .recoveryRequired
        }

        let inputResult = inputStats.commitTodayReset(inputReset)
        guard inputResult == .committed else { return inputResult }

        let codingResult = codingStats.commitTodayReset(codingReset)
        guard codingResult == .committed else {
            let inputRollbackSucceeded = inputStats.rollbackTodayReset(inputReset)
            switch codingResult {
            case let .rejected(codingRollbackSucceeded):
                return .rejected(
                    rollbackSucceeded: codingRollbackSucceeded && inputRollbackSucceeded
                )
            case .recoveryRequired:
                return inputRollbackSucceeded ? .recoveryRequired : .rejected(rollbackSucceeded: false)
            case .committed:
                break
            }
            return .rejected(rollbackSucceeded: inputRollbackSucceeded)
        }

        notifyChange()
        return .committed
    }

    func installHooks() {
        let installer = ActivityBarHookInstaller(paths: hookInstallerPaths, namespace: namespace)

        do {
            let summary = try installer.install()
            let timestamp = Self.installTimestamp()
            storage.set(timestamp, forKey: StorageKey.hooksInstalledAt)
            hookInstallState = .installed(timestamp: timestamp)
            lastErrorMessage = nil
            startHookListenerIfNeeded()
            ActivityBarLog.hooks.info(
                "Activity bar hooks installed in \(summary.scriptDirectory.path, privacy: .public)"
            )
        } catch {
            lastErrorMessage = localization.format(
                "error.hook.installFailed",
                defaultValue: "Hook 安装失败：%@",
                localizedDescription(for: error)
            )
            hookInstallState = .failed
            ActivityBarLog.hooks.error("Activity bar hook installation failed: \(error.localizedDescription, privacy: .public)")
        }

        notifyChange()
    }

    func uninstallHooks() {
        let installer = ActivityBarHookInstaller(paths: hookInstallerPaths, namespace: namespace)

        do {
            let summary = try installer.uninstall()
            storage.removeObject(forKey: StorageKey.hooksInstalledAt)
            hookInstallState = .notInstalled
            lastErrorMessage = nil
            socketServer.stop()
            codingStats.flushActiveDurations()
            ActivityBarLog.hooks.info(
                "Activity bar hooks uninstalled from \(summary.scriptDirectory.path, privacy: .public)"
            )
        } catch {
            lastErrorMessage = localization.format(
                "error.hook.uninstallFailed",
                defaultValue: "Hook 卸载失败：%@",
                localizedDescription(for: error)
            )
            hookInstallState = .failed
            ActivityBarLog.hooks.error("Activity bar hook uninstallation failed: \(error.localizedDescription, privacy: .public)")
        }

        notifyChange()
    }

    func openInputMonitoringSettings() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    private var shouldRunHookListener: Bool {
        if case .installed = hookInstallState {
            return true
        }

        return false
    }

    private func startInputTracking() {
        inputMonitor.start()
    }

    private func startHookListenerIfNeeded() {
        guard shouldRunHookListener else {
            return
        }

        do {
            try socketServer.start()
        } catch {
            lastErrorMessage = localization.format(
                "error.socket.startFailed",
                defaultValue: "AI 活动监听启动失败：%@",
                localizedDescription(for: error)
            )
            ActivityBarLog.socket.error("Activity bar socket start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopRuntime() {
        stopInputTracking()
        socketServer.stop()
        codingStats.flushActiveDurations()
    }

    private func stopInputTracking() {
        inputMonitor.stop()
        inputStats.flushPendingChanges()
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func notifyChange() {
        inputEventNotificationTask?.cancel()
        inputEventNotificationTask = nil
        objectWillChange.send()
        onStateChange?()
    }

    private func scheduleInputEventNotification() {
        guard inputEventNotificationTask == nil else {
            return
        }

        inputEventNotificationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: inputEventNotificationDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            inputEventNotificationTask = nil
            objectWillChange.send()
            onStateChange?()
        }
    }

    private func localizedDescription(for error: Error) -> String {
        if let hookError = error as? ActivityBarHookInstallerError {
            return hookError.localizedDescription(localization: localization)
        }
        if let socketError = error as? ActivityBarSocketError {
            return socketError.localizedDescription(localization: localization)
        }
        return error.localizedDescription
    }

    private static func installTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
