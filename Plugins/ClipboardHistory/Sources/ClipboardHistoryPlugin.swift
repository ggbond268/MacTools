import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

public final class ClipboardHistoryPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ClipboardHistoryPluginProvider(context: context)
    }
}

@MainActor
private struct ClipboardHistoryPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [ClipboardHistoryPlugin(context: context)]
    }
}

@MainActor
final class ClipboardHistoryPlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginActionProviding,
    PluginGroupedShortcutSettingsProviding,
    PluginWindowLayoutTargetProviding,
    AccessibilityPermissionRefreshing
{
    static let pluginID = "clipboard-history"
    static let pluginOrder = 125

    enum ActionID {
        static let openHistory = "open-history"
        static let pauseCollection = "pause-collection"
        static let resumeCollection = "resume-collection"
        static let toggleCollection = "toggle-collection"
        static let clearUnpinnedHistory = "clear-unpinned-history"
        static let clearAllHistory = "clear-all-history"

        static let all: Set<String> = [
            openHistory,
            pauseCollection,
            resumeCollection,
            toggleCollection,
            clearUnpinnedHistory,
            clearAllHistory,
        ]
    }

    enum ShortcutID {
        static let privateCopy = "private-copy"
        static let ignoreNextCopy = "ignore-next-copy"
        static let pastePlainText = "paste-clipboard-as-plain-text"
        static let primaryGroup = "primary-shortcuts"
        static let privacyGroup = "privacy-copy-shortcuts"
        static let collectionGroup = "collection-shortcuts"
    }

    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum SettingsSectionID {
        static let essentials = "clipboard-essential-settings"
        static let retention = "clipboard-retention-settings"
        static let exclusions = "clipboard-exclusion-settings"
        static let data = "clipboard-data-settings"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    let controller: ClipboardHistoryController

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var focusedWindowLayoutTarget: NSWindow? {
        panelController.focusedWindowLayoutTarget
    }

    private let settingsStore: ClipboardHistorySettingsStore
    private let localization: PluginLocalization
    private let copyCommandSender: any ClipboardCopyCommandSending
    private let pasteCommandSender: any ClipboardPasteCommandSending
    private let accessibilityTrusted: () -> Bool
    private let accessibilityRequester: (Bool) -> Bool
    private let frontmostProcessIdentifier: () -> pid_t?
    private let privacyHUDPresenter: any ClipboardPrivacyHUDPresenting
    private lazy var panelController = ClipboardHistoryPanelController(
        historyController: controller,
        localization: localization,
        onIgnoreNextCopy: { [weak self] in
            self?.armIgnoreNextCopy()
        },
        pasteCommandSender: pasteCommandSender
    )

    init(
        context: PluginRuntimeContext,
        pasteboard: (any ClipboardPasteboardAccess)? = nil,
        sourceContext: (any ClipboardSourceContextProviding)? = nil,
        persistence: (any ClipboardHistoryPersisting)? = nil,
        copyCommandSender: (any ClipboardCopyCommandSending)? = nil,
        pasteCommandSender: (any ClipboardPasteCommandSending)? = nil,
        privacyHUDPresenter: (any ClipboardPrivacyHUDPresenting)? = nil,
        imageTextRecognizer: (any ClipboardImageTextRecognizing)? = nil,
        accessibilityTrusted: @escaping () -> Bool = ClipboardHistoryAccessibilityCheck.isTrusted,
        accessibilityRequester: @escaping (Bool) -> Bool = ClipboardHistoryAccessibilityCheck.requestTrust(prompt:),
        frontmostProcessIdentifier: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let settingsStore = ClipboardHistorySettingsStore(storage: context.storage)
        let resolvedPersistence: any ClipboardHistoryPersisting
        if let persistence {
            resolvedPersistence = persistence
        } else if let supportDirectory = context.supportDirectory {
            resolvedPersistence = IncrementalEncryptedClipboardHistoryStore(
                databaseURL: supportDirectory.appendingPathComponent("history.sqlite3", isDirectory: false),
                legacyFileURL: supportDirectory.appendingPathComponent("history.mth", isDirectory: false),
                keyStore: ClipboardHistoryKeychainStore(
                    service: PluginPrivateDataKeychainIdentity.service(pluginID: Self.pluginID)
                )
            )
        } else {
            resolvedPersistence = UnavailableClipboardHistoryStore()
        }

        self.localization = localization
        self.settingsStore = settingsStore
        self.copyCommandSender = copyCommandSender ?? SystemClipboardCopyCommandSender()
        self.pasteCommandSender = pasteCommandSender ?? SystemClipboardPasteCommandSender()
        self.privacyHUDPresenter = privacyHUDPresenter ?? ClipboardPrivacyHUDController(localization: localization)
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityRequester = accessibilityRequester
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.controller = ClipboardHistoryController(
            settings: settingsStore,
            pasteboard: pasteboard ?? GeneralClipboardPasteboard(),
            sourceContext: sourceContext ?? WorkspaceClipboardSourceContextProvider(),
            persistence: resolvedPersistence,
            imageTextRecognizer: imageTextRecognizer ?? VisionClipboardImageTextRecognizer(),
            errorMessageProvider: { error in
                Self.localizedErrorMessage(error, localization: localization)
            }
        )
        self.metadata = PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "剪贴板历史"),
            iconName: "clipboard",
            iconTint: .accentColor,
            order: Self.pluginOrder,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "搜索本机加密保存的剪贴板历史和固定项目"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: {
                localization.string("panel.button.open", defaultValue: "打开")
            }
        )

        settingsStore.onChange = { [weak controller] in
            controller?.settingsDidChange()
        }
        controller.onChange = { [weak self] in
            self?.onStateChange?()
        }
        controller.onCaptureSuppressionEvent = { [weak privacyHUDPresenter = self.privacyHUDPresenter] event in
            privacyHUDPresenter?.handleSuppressionEvent(event)
        }
        controller.onCaptureRejection = {
            [weak privacyHUDPresenter = self.privacyHUDPresenter, localization = self.localization]
            reason,
            limit in
            switch reason {
            case .oversized:
                privacyHUDPresenter?.showFailure(localization.format(
                    "hud.capture.oversized",
                    defaultValue: "未保存：内容超过 %d MB",
                    max(1, limit / (1_024 * 1_024))
                ))
            case .pinnedItemsFillCapacity:
                privacyHUDPresenter?.showFailure(localization.string(
                    "hud.capture.pinnedCapacity",
                    defaultValue: "未保存：固定项目已占满历史容量"
                ))
            case .tooManyObjects:
                privacyHUDPresenter?.showFailure(localization.format(
                    "hud.capture.tooManyObjects",
                    defaultValue: "未保存：剪贴板项目超过 %d 个",
                    limit
                ))
            default:
                break
            }
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: localization.string(
                "metadata.description",
                defaultValue: "搜索本机加密保存的剪贴板历史和固定项目"
            ),
            sections: [
                PluginSettingsSection(
                    id: SettingsSectionID.essentials,
                    presentation: .edgeToEdge
                ) { [weak self] context in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            localization: self.localization,
                            settingsContext: context,
                            contentSections: [.essentials]
                        )
                    } else {
                        EmptyView()
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.retention,
                    presentation: .edgeToEdge
                ) { [weak self] _ in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            localization: self.localization,
                            contentSections: [.retention]
                        )
                    } else {
                        EmptyView()
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.exclusions,
                    presentation: .edgeToEdge
                ) { [weak self] _ in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            localization: self.localization,
                            contentSections: [.exclusions]
                        )
                    } else {
                        EmptyView()
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.data,
                    presentation: .edgeToEdge
                ) { [weak self] _ in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            localization: self.localization,
                            contentSections: [.data]
                        )
                    } else {
                        EmptyView()
                    }
                },
            ]
        )
    }

    var primaryPanelState: PluginPanelState {
        let subtitle: String
        if let errorMessage = controller.errorMessage {
            subtitle = errorMessage
        } else if !controller.isLoaded {
            subtitle = localization.string("panel.status.loading", defaultValue: "正在读取加密历史…")
        } else if settingsStore.isPaused {
            subtitle = localization.string("panel.status.paused", defaultValue: "收集已暂停")
        } else if controller.isCaptureBlockedByPinnedItems {
            subtitle = localization.string(
                "panel.status.pinnedCapacity",
                defaultValue: "固定项目已占满历史容量"
            )
        } else if controller.isIgnoringNextCopy {
            subtitle = localization.string("panel.status.ignoreNext", defaultValue: "下次复制不会保存")
        } else {
            subtitle = localization.format(
                "panel.status.count",
                defaultValue: "%d 条记录 · %d 条固定",
                controller.items.count,
                controller.pinnedItems.count
            )
        }
        return PluginPanelState(
            subtitle: subtitle,
            isOn: !settingsStore.isPaused && controller.isCollectionOperational,
            isExpanded: false,
            isEnabled: controller.isLoaded,
            isVisible: true,
            detail: nil,
            errorMessage: controller.errorMessage
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
                    defaultValue: "用于发送私密复制和粘贴快捷键，也用于将历史记录粘贴到之前的应用。"
                )
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: ShortcutID.privateCopy,
                title: localization.string("shortcut.privateCopy.title", defaultValue: "私密复制"),
                description: localization.string(
                    "shortcut.privateCopy.description",
                    defaultValue: "复制当前选择，但不读取或保存这次剪贴板内容。"
                ),
                actionID: ShortcutID.privateCopy,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.privacyGroup,
                settingsGroupTitle: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "“立即私密复制”一步复制当前选择；“忽略下一次复制”会等待之后的右键菜单或 Command-C，15 秒后自动取消。"
                ),
                settingsControlTitle: localization.string(
                    "shortcut.privateCopy.controlTitle",
                    defaultValue: "立即私密复制"
                ),
                settingsControlSystemImage: "keyboard"
            ),
            PluginShortcutDefinition(
                id: ShortcutID.ignoreNextCopy,
                title: localization.string("shortcut.ignoreNext.title", defaultValue: "忽略下一次复制"),
                description: localization.string(
                    "shortcut.ignoreNext.description",
                    defaultValue: "接下来一次剪贴板变化不会被读取或保存，15 秒后自动取消。"
                ),
                actionID: ShortcutID.ignoreNextCopy,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.privacyGroup,
                settingsGroupTitle: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "“立即私密复制”一步复制当前选择；“忽略下一次复制”会等待之后的右键菜单或 Command-C，15 秒后自动取消。"
                ),
                settingsControlTitle: localization.string(
                    "shortcut.ignoreNext.controlTitle",
                    defaultValue: "忽略下一次复制"
                ),
                settingsControlSystemImage: "cursorarrow.click"
            ),
            PluginShortcutDefinition(
                id: ShortcutID.pastePlainText,
                title: localization.string(
                    "shortcut.pastePlain.title",
                    defaultValue: "以纯文本粘贴剪贴板"
                ),
                description: localization.string(
                    "shortcut.pastePlain.description",
                    defaultValue: "不打开历史记录，直接粘贴纯文本；当前剪贴板为图片时使用已识别的文字。"
                ),
                actionID: ShortcutID.pastePlainText,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.primaryGroup,
                settingsGroupTitle: localization.string(
                    "shortcut.pastePlain.groupTitle",
                    defaultValue: "纯文本粘贴快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.pastePlain.groupDescription",
                    defaultValue: "用一个快捷键直接粘贴无格式文本或当前图片中已识别的文字，无需打开剪贴板历史。"
                ),
                settingsControlTitle: localization.string(
                    "shortcut.pastePlain.controlTitle",
                    defaultValue: "粘贴当前剪贴板为纯文本"
                ),
                settingsControlSystemImage: "textformat"
            ),
        ]
    }

    var shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] {
        [
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.primaryGroup,
                title: localization.string(
                    "settings.shortcuts.primary.title",
                    defaultValue: "主要快捷键"
                ),
                systemImage: "keyboard",
                actionIDs: [ActionID.openHistory],
                shortcutDefinitionIDs: [ShortcutID.pastePlainText],
                placementAfterSectionID: SettingsSectionID.essentials
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.privacyGroup,
                title: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                systemImage: "eye.slash",
                shortcutDefinitionIDs: [ShortcutID.privateCopy, ShortcutID.ignoreNextCopy],
                placementAfterSectionID: SettingsSectionID.essentials
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.collectionGroup,
                title: localization.string(
                    "settings.shortcuts.collection.title",
                    defaultValue: "高级控制"
                ),
                description: localization.string(
                    "settings.shortcuts.collection.description",
                    defaultValue: "可选：控制收集状态，或清除未固定记录和全部历史。"
                ),
                systemImage: "playpause",
                actionIDs: [
                    ActionID.toggleCollection,
                    ActionID.pauseCollection,
                    ActionID.resumeCollection,
                    ActionID.clearUnpinnedHistory,
                    ActionID.clearAllHistory,
                ],
                placementAfterSectionID: SettingsSectionID.data
            ),
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            action(
                id: ActionID.openHistory,
                title: localization.string("action.open.title", defaultValue: "打开剪贴板历史"),
                description: localization.string(
                    "action.open.description",
                    defaultValue: "打开可搜索的本机剪贴板历史面板；再次按下全局快捷键可关闭。"
                ),
                systemImage: "clipboard"
            ),
            action(
                id: ActionID.pauseCollection,
                title: localization.string("action.pause.title", defaultValue: "暂停剪贴板历史"),
                description: localization.string("action.pause.description", defaultValue: "暂停保存之后复制的剪贴板项目。"),
                systemImage: "pause.circle",
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            action(
                id: ActionID.resumeCollection,
                title: localization.string("action.resume.title", defaultValue: "恢复剪贴板历史"),
                description: localization.string("action.resume.description", defaultValue: "恢复保存之后复制的剪贴板项目。"),
                systemImage: "play.circle",
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            action(
                id: ActionID.toggleCollection,
                title: localization.string("action.toggle.title", defaultValue: "切换剪贴板历史收集"),
                description: localization.string("action.toggle.description", defaultValue: "在暂停和恢复之间切换。"),
                systemImage: "playpause",
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            action(
                id: ActionID.clearUnpinnedHistory,
                title: localization.string("action.clearUnpinned.title", defaultValue: "清除未固定的剪贴板历史"),
                description: localization.string(
                    "action.clearUnpinned.description",
                    defaultValue: "永久删除所有未固定的剪贴板记录。"
                ),
                systemImage: "trash",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("clear.unpinned.actionTitle", defaultValue: "清除未固定的剪贴板历史？"),
                    message: localization.string("clear.unpinned.message", defaultValue: "固定片段会保留。此操作无法撤销。"),
                    confirmButtonTitle: localization.string("common.clear", defaultValue: "清除")
                )
            ),
            action(
                id: ActionID.clearAllHistory,
                title: localization.string("action.clearAll.title", defaultValue: "清除全部剪贴板历史"),
                description: localization.string(
                    "action.clearAll.description",
                    defaultValue: "永久删除所有剪贴板记录和固定片段。"
                ),
                systemImage: "trash.slash",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？"),
                    message: localization.string(
                        "clear.all.actionMessage",
                        defaultValue: "所有历史记录和固定片段都会被永久删除。此操作无法撤销。"
                    ),
                    confirmButtonTitle: localization.string("common.clearAll", defaultValue: "全部清除")
                )
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        switch reference.key.actionID {
        case ActionID.openHistory:
            return controller.isLoaded
                ? .available
                : .unavailable(localization.string("availability.loading", defaultValue: "剪贴板历史仍在载入。"))
        case ActionID.pauseCollection:
            if let message = collectionActionBlockingMessage() {
                return .unavailable(message)
            }
            return .available
        case ActionID.resumeCollection:
            if let message = collectionActionBlockingMessage() {
                return .unavailable(message)
            }
            return .available
        case ActionID.toggleCollection:
            if let message = collectionActionBlockingMessage() {
                return .unavailable(message)
            }
            return .available
        case ActionID.clearUnpinnedHistory:
            if controller.isClearingHistory {
                return .unavailable(localization.string(
                    "availability.clearInProgress",
                    defaultValue: "正在清除剪贴板历史。"
                ))
            }
            return controller.recentItems.isEmpty
                ? .unavailable(localization.string("availability.noUnpinned", defaultValue: "没有可清除的未固定记录。"))
                : .available
        case ActionID.clearAllHistory:
            if controller.isClearingHistory {
                return .unavailable(localization.string(
                    "availability.clearInProgress",
                    defaultValue: "正在清除剪贴板历史。"
                ))
            }
            if let errorMessage = controller.errorMessage {
                return .unavailable(errorMessage)
            }
            return controller.items.isEmpty
                ? .unavailable(localization.string("availability.noItems", defaultValue: "没有可清除的记录。"))
                : .available
        default:
            return .unavailable(PluginKitLocalization.actionInvalidParameters)
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if [ActionID.pauseCollection, ActionID.resumeCollection, ActionID.toggleCollection]
            .contains(invocation.reference.key.actionID),
           let message = collectionActionBlockingMessage() {
            return ActionExecutionHandle { .failed(message: message) }
        }
        switch invocation.reference.key.actionID {
        case ActionID.openHistory:
            if invocation.source == .globalShortcut {
                panelController.handleGlobalShortcut()
            } else {
                panelController.show()
            }
        case ActionID.pauseCollection:
            settingsStore.setPaused(true)
        case ActionID.resumeCollection:
            settingsStore.setPaused(false)
        case ActionID.toggleCollection:
            settingsStore.setPaused(!settingsStore.isPaused)
        case ActionID.clearUnpinnedHistory:
            let controller = controller
            let failureMessage = localization.string(
                "availability.clearInProgress",
                defaultValue: "正在清除剪贴板历史。"
            )
            return ActionExecutionHandle {
                let succeeded = await controller.clearUnpinnedHistory()
                return succeeded
                    ? .succeeded()
                    : .failed(message: controller.errorMessage ?? failureMessage)
            }
        case ActionID.clearAllHistory:
            let controller = controller
            let failureMessage = localization.string(
                "availability.clearInProgress",
                defaultValue: "正在清除剪贴板历史。"
            )
            return ActionExecutionHandle {
                let succeeded = await controller.clearAllHistory()
                return succeeded
                    ? .succeeded()
                    : .failed(message: controller.errorMessage ?? failureMessage)
            }
        default:
            return ActionExecutionHandle {
                .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
        }
        return ActionExecutionHandle { .succeeded() }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == "execute" else { return }
        panelController.show()
    }

    func handleShortcutAction(id: String) {
        switch id {
        case ShortcutID.privateCopy:
            let targetProcessIdentifier = frontmostProcessIdentifier()
            Task { @MainActor [weak self] in
                await self?.performPrivateCopy(targetProcessIdentifier: targetProcessIdentifier)
            }
        case ShortcutID.ignoreNextCopy:
            armIgnoreNextCopy()
        case ShortcutID.pastePlainText:
            let targetProcessIdentifier = frontmostProcessIdentifier()
            Task { @MainActor [weak self] in
                await self?.performPasteClipboardAsPlainText(
                    targetProcessIdentifier: targetProcessIdentifier
                )
            }
        default:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        let isGranted = accessibilityTrusted()
        return PluginPermissionState(
            isGranted: isGranted,
            footnote: isGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "普通收集、搜索和复制不需要此权限；私密复制和所有自动粘贴快捷键需要。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }
        _ = accessibilityRequester(true)
        onStateChange?()
    }

    func refreshAccessibilityPermission() {
        onStateChange?()
    }

    func activate(context: PluginRuntimeContext) {
        controller.start()
    }

    func deactivate(reason: PluginDeactivationReason) {
        panelController.close(restorePreviousApplication: false)
        privacyHUDPresenter.dismiss()
        controller.stop()
    }

    func refresh() {
        controller.settingsDidChange()
        controller.start()
    }

    private func performPrivateCopy(targetProcessIdentifier: pid_t?) async {
        guard controller.canSuppressNextCapture else {
            showClipboardUnavailableHUD()
            return
        }
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.privateCopy.accessibilityRequired",
                defaultValue: "私密复制需要辅助功能权限"
            ))
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return
        }
        guard let targetProcessIdentifier else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.privateCopy.failed",
                defaultValue: "私密复制失败"
            ))
            return
        }

        let sent = await copyCommandSender.sendCopyCommand(
            to: targetProcessIdentifier
        ) { [weak controller] in
            // A direct private copy should not leave a stale one-shot suppression behind when the
            // target application has no selection or refuses Command-C.
            controller?.ignoreNextCopy(expiringAfter: 15, mode: .privateCopy) == true
        }
        if !sent {
            let hadPendingSuppression = controller.isIgnoringNextCopy
            controller.cancelNextCaptureSuppression()
            if !controller.canSuppressNextCapture {
                showClipboardUnavailableHUD()
            } else if !hadPendingSuppression {
                privacyHUDPresenter.showFailure(localization.string(
                    "hud.privateCopy.failed",
                    defaultValue: "私密复制失败"
                ))
            }
            if !accessibilityTrusted() {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
        }
    }

    private func performPasteClipboardAsPlainText(targetProcessIdentifier: pid_t?) async {
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.pastePlain.accessibilityRequired",
                defaultValue: "纯文本粘贴需要辅助功能权限"
            ))
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return
        }
        guard let targetProcessIdentifier,
              frontmostProcessIdentifier() == targetProcessIdentifier else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.pastePlain.failed",
                defaultValue: "无法粘贴纯文本"
            ))
            return
        }
        switch controller.rewriteCurrentClipboardAsPlainText() {
        case .succeeded:
            break
        case .imageTextRecognitionPending:
            privacyHUDPresenter.showFailure(localization.string(
                "panel.imageText.pending",
                defaultValue: "正在识别文字…"
            ))
            return
        case .imageTextUnavailable:
            privacyHUDPresenter.showFailure(localization.string(
                "panel.imageText.unavailable",
                defaultValue: "未识别到文字"
            ))
            return
        case .unavailable:
            privacyHUDPresenter.showFailure(localization.string(
                "hud.pastePlain.unavailable",
                defaultValue: "剪贴板中没有可粘贴的文本"
            ))
            return
        }
        guard await pasteCommandSender.sendPasteCommand(to: targetProcessIdentifier) else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.pastePlain.failed",
                defaultValue: "无法粘贴纯文本"
            ))
            if !accessibilityTrusted() {
                requestPermissionGuidance?(PermissionID.accessibility)
                onStateChange?()
            }
            return
        }
    }

    private func armIgnoreNextCopy() {
        guard controller.ignoreNextCopy() else {
            showClipboardUnavailableHUD()
            return
        }
    }

    private func showClipboardUnavailableHUD() {
        privacyHUDPresenter.showFailure(localization.string(
            "hud.clipboardUnavailable",
            defaultValue: "剪贴板历史尚未准备好"
        ))
    }

    private func collectionActionBlockingMessage() -> String? {
        if let errorMessage = controller.errorMessage {
            return errorMessage
        }
        guard controller.isLoaded else {
            return localization.string(
                "availability.loading",
                defaultValue: "剪贴板历史仍在载入。"
            )
        }
        guard !controller.isClearingHistory else {
            return localization.string(
                "availability.clearInProgress",
                defaultValue: "正在清除剪贴板历史。"
            )
        }
        guard controller.isCollectionOperational else {
            return localization.string(
                "availability.collectionUnavailable",
                defaultValue: "剪贴板历史收集目前不可用。"
            )
        }
        return nil
    }

    private func action(
        id: String,
        title: String,
        description: String,
        systemImage: String,
        risk: ActionRisk = .safe,
        confirmation: ActionConfirmation? = nil,
        capabilities: ActionExecutionCapabilities = [.foregroundInteractive]
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: id),
            title: title,
            description: description,
            keywords: [
                localization.string("action.keyword.clipboard", defaultValue: "剪贴板"),
                "clipboard",
                "history",
                title,
            ],
            systemImage: systemImage,
            risk: risk,
            confirmation: confirmation,
            externalInvocationPolicy: .unavailable,
            capabilities: capabilities
        )
    }

    private static func localizedErrorMessage(
        _ error: Error,
        localization: PluginLocalization
    ) -> String {
        guard let storeError = error as? ClipboardHistoryStoreError else {
            return error.localizedDescription
        }
        switch storeError {
        case .missingEncryptionKey:
            return localization.string(
                "error.missingEncryptionKey",
                defaultValue: "找不到剪贴板历史的加密密钥。历史记录已停止收集。"
            )
        case .invalidEncryptionKey:
            return localization.string(
                "error.invalidEncryptionKey",
                defaultValue: "剪贴板历史的加密密钥无效。历史记录已停止收集。"
            )
        case .invalidEnvelope:
            return localization.string(
                "error.invalidEnvelope",
                defaultValue: "无法读取剪贴板历史。原始加密数据已保留。"
            )
        case .authenticationFailed:
            return localization.string(
                "error.authenticationFailed",
                defaultValue: "无法验证剪贴板历史。原始加密数据已保留。"
            )
        case .historyTooLarge:
            return localization.string(
                "error.historyTooLarge",
                defaultValue: "剪贴板历史超过安全存储上限。请清除现有历史记录。"
            )
        case .insufficientDiskSpace:
            return localization.string(
                "error.insufficientDiskSpace",
                defaultValue: "可用磁盘空间不足，无法保存新的剪贴板历史。"
            )
        case .unavailableStorage:
            return localization.string(
                "error.unavailableStorage",
                defaultValue: "无法使用剪贴板历史的专用存储空间。"
            )
        case .keychain:
            return localization.string(
                "error.keychain",
                defaultValue: "无法访问用于保护剪贴板历史的钥匙串密钥。"
            )
        }
    }
}
