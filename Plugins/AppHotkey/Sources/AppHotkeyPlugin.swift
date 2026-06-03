import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class AppHotkeyPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppHotkeyPluginProvider(context: context)
    }
}

@MainActor
private struct AppHotkeyPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [AppHotkeyPlugin(context: context)]
    }
}

// MARK: - Plugin

@MainActor
final class AppHotkeyPlugin: MacToolsPlugin, PluginPrimaryPanel {

    // MARK: Metadata

    let metadata = PluginMetadata(
        id: "app-hotkey",
        title: "应用快捷键",
        iconName: "keyboard",
        iconTint: Color(nsColor: .systemYellow),
        order: 65,
        defaultDescription: "为常用应用绑定全局快捷键"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: Private

    private let store: AppHotkeyStore
    private let hotkeyManager: AppHotkeyManager
    private let storage: PluginStorage
    private var isEnabled: Bool
    private var registrationErrorMessage: String?

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "app-hotkey"),
        hotkeyManager: AppHotkeyManager = AppHotkeyManager()
    ) {
        self.storage = context.storage
        self.store = AppHotkeyStore(storage: context.storage)
        self.hotkeyManager = hotkeyManager
        // 默认启用；仅当用户明确关闭后才存储 false
        self.isEnabled = context.storage.object(forKey: "isEnabled") == nil
            ? true
            : context.storage.bool(forKey: "isEnabled")

        hotkeyManager.onTrigger = { [weak self] id in
            self?.launch(entryID: id)
        }
    }

    // MARK: MacToolsPlugin

    func activate(context: PluginRuntimeContext) {
        syncHotkeys()
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup {
            hotkeyManager.unregisterAll()
        }
    }

    func refresh() {}

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    // 热键由插件自己管理，不使用宿主快捷键系统
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [self] _ in
            AppHotkeyManagerView(
                store: self.store,
                onUpdate: { [weak self] in
                    self?.syncHotkeys()
                    self?.onStateChange?()
                },
                onBeginRecording: { [weak self] id in
                    self?.hotkeyManager.temporarilyDisable(id: id)
                },
                onEndRecording: { [weak self] _ in
                    self?.syncHotkeys()
                }
            )
        }
    }

    // MARK: PluginPrimaryPanel

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: isEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: registrationErrorMessage
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(value):
            isEnabled = value
            storage.set(value, forKey: "isEnabled")
            syncHotkeys()
            onStateChange?()
        default:
            break
        }
    }

    // MARK: Private

    private var panelSubtitle: String {
        let count = store.entries.filter { $0.shortcut != nil }.count
        guard count > 0 else { return "暂无绑定，前往设置配置" }
        return isEnabled ? "\(count) 个快捷键已启用" : "快捷键已暂停"
    }

    private func syncHotkeys() {
        hotkeyManager.sync(entries: isEnabled ? store.entries : [])
        updateRegistrationError()
    }

    /// Surface hot-keys that the OS refused to register (most often because the
    /// combo is already claimed by another app) so the user isn't left wondering
    /// why a shortcut silently does nothing.
    private func updateRegistrationError() {
        let failedIDs = hotkeyManager.failedEntryIDs
        guard !failedIDs.isEmpty else {
            registrationErrorMessage = nil
            return
        }

        let names = store.entries
            .filter { failedIDs.contains($0.id) }
            .map(\.displayName)
        let joined = names.isEmpty ? "" : "：\(names.joined(separator: "、"))"
        registrationErrorMessage = "\(failedIDs.count) 个快捷键注册失败\(joined)，可能已被其它应用占用"
    }

    /// 按下快捷键时：若目标应用在前台则隐藏，否则打开/激活。
    private func launch(entryID: UUID) {
        guard let entry = store.entries.first(where: { $0.id == entryID }),
              let bundleURL = entry.bundleURL
        else { return }

        let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier

        if let bundleIdentifier,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier == bundleIdentifier {
            frontmost.hide()
        } else {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
        }
    }
}
