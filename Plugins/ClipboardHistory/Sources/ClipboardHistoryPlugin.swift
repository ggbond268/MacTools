import AppKit
import Foundation
import ImageIO
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
    PluginShortcutSettingsGroupPresentationProviding,
    PluginShortcutBindingValidating,
    PluginInlineShortcutSettingsContextConsuming,
    PluginWindowLayoutTargetProviding,
    AccessibilityPermissionRefreshing
{
    static let pluginID = "clipboard"
    static let pluginOrder = 125

    enum ActionID {
        static let openHistory = "open-history"
        static let previousSequentialQueueItem = "previous-sequential-queue-item"
        static let skipSequentialQueueItem = "skip-sequential-queue-item"
        static let restartSequentialQueue = "restart-sequential-queue"
        static let cancelSequentialQueue = "cancel-sequential-queue"
        static let pauseCollection = "pause-collection"
        static let resumeCollection = "resume-collection"
        static let toggleCollection = "toggle-collection"
        static let clearAllHistory = "clear-all-history"

        static let all: Set<String> = [
            openHistory,
            previousSequentialQueueItem,
            skipSequentialQueueItem,
            restartSequentialQueue,
            cancelSequentialQueue,
            pauseCollection,
            resumeCollection,
            toggleCollection,
            clearAllHistory,
        ]
    }

    enum ShortcutID {
        static let privateCopy = "private-copy"
        static let ignoreNextCopy = "ignore-next-copy"
        static let pastePlainText = "paste-clipboard-as-plain-text"
        static let pasteSequentially = "paste-sequentially"
        static let panelActions = "panel-actions"
        static let panelExport = "panel-export"
        static let panelEditSnippet = "panel-edit-snippet"
        static let panelShare = "panel-share"
        static let panelSave = "panel-save"
        static let panelDelete = "panel-delete"
        static let panelMultiSelect = "panel-multi-select"
        static let panelToggleSelection = "panel-toggle-selection"
        static let panelSelectAll = "panel-select-all"
        static let panelCopyCombined = "panel-copy-combined"
        static let panelPasteCombined = "panel-paste-combined"
        // Keep the stored binding ID stable while cycling filter families instead of scope values.
        static let panelCycleScope = "panel-cycle-scope"
        static let primaryGroup = "primary-shortcuts"
        static let panelGroup = "clipboard-window-shortcuts"
        static let queueGroup = "sequential-paste-shortcuts"
        static let privacyGroup = "privacy-copy-shortcuts"
        static let collectionGroup = "collection-shortcuts"
    }

    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum SettingsSectionID {
        static let essentials = "clipboard-essential-settings"
        static let queue = "clipboard-queue-settings"
        static let snippets = "clipboard-snippet-settings"
        static let additionalShortcuts = "clipboard-additional-shortcuts"
        static let retention = "clipboard-retention-settings"
        static let exclusions = "clipboard-exclusion-settings"
        static let data = "clipboard-data-settings"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    let controller: ClipboardHistoryController
    let savedLibraryController: ClipboardSavedLibraryController

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var inlineShortcutSettingsContextProvider: (() -> PluginSettingsContext)?
    var focusedWindowLayoutTarget: NSWindow? {
        panelController.focusedWindowLayoutTarget
    }

    func shortcutValidationMessage(
        definitionID: String,
        binding: ShortcutBinding
    ) -> String? {
        if definitionID == ShortcutID.panelCycleScope,
           binding.modifiers.contains(.shift) {
            return localization.string(
                "panel.shortcuts.cycleScope.shiftReserved",
                defaultValue: "Shift is reserved for cycling backward. Record the forward shortcut without Shift."
            )
        }

        if let reverseConflictOwner = reverseCycleShortcutConflictOwner(
            definitionID: definitionID,
            binding: binding
        ) {
            return localization.format(
                "panel.shortcuts.reverseCycleConflict",
                defaultValue: "This key is reserved for cycling filters backward by %@.",
                reverseConflictOwner
            )
        }

        guard Self.panelShortcutDefinitionIDs.contains(definitionID),
              let owner = fixedClipboardCommandOwner(for: binding)
        else { return nil }
        return localization.format(
            "panel.shortcuts.fixedConflict",
            defaultValue: "This key is used by the Clipboard window for %@.",
            owner
        )
    }

    private func fixedClipboardCommandOwner(for binding: ShortcutBinding) -> String? {
        switch binding {
        case ClipboardHistoryFixedShortcut.close:
            return localization.string("common.close", defaultValue: "Close")
        case ClipboardHistoryFixedShortcut.paste:
            return localization.string("common.paste", defaultValue: "Paste")
        case ClipboardHistoryFixedShortcut.pastePlainText:
            return localization.string("panel.pastePlain", defaultValue: "Paste as Plain Text")
        case ClipboardHistoryFixedShortcut.copy:
            return localization.string("common.copy", defaultValue: "Copy")
        case ClipboardHistoryFixedShortcut.previous,
             ClipboardHistoryFixedShortcut.next,
             ClipboardHistoryFixedShortcut.previousAlternate,
             ClipboardHistoryFixedShortcut.nextAlternate:
            return localization.string("panel.footer.navigate", defaultValue: "Navigate")
        case ClipboardHistoryFixedShortcut.extendPrevious,
             ClipboardHistoryFixedShortcut.extendNext:
            return localization.string("panel.selection.extend", defaultValue: "Extend Selection")
        default:
            if ClipboardHistoryFixedShortcut.numberKeyCodes.contains(binding.keyCode),
               binding.modifiers == .command {
                return localization.string("panel.shortcuts.quickPaste", defaultValue: "Quick Paste")
            }
            if ClipboardHistoryFixedShortcut.numberKeyCodes.contains(binding.keyCode),
               binding.modifiers == .control {
                return localization.string("panel.shortcuts.chooseFilter", defaultValue: "Choose Filter")
            }
            return nil
        }
    }

    private func reverseCycleShortcutConflictOwner(
        definitionID: String,
        binding: ShortcutBinding
    ) -> String? {
        guard let shortcutBindingResolver else { return nil }

        if definitionID == ShortcutID.panelCycleScope {
            let reverseBinding = ShortcutBinding(
                keyCode: binding.keyCode,
                modifiers: binding.modifiers.union(.shift)
            )
            guard let conflictingDefinitionID = Self.panelShortcutDefinitionIDs.first(where: {
                $0 != ShortcutID.panelCycleScope
                    && shortcutBindingResolver($0) == reverseBinding
            }) else { return nil }
            return shortcutDefinitionTitle(conflictingDefinitionID)
        }

        guard let forwardBinding = shortcutBindingResolver(ShortcutID.panelCycleScope) else {
            return nil
        }
        let reverseBinding = ShortcutBinding(
            keyCode: forwardBinding.keyCode,
            modifiers: forwardBinding.modifiers.union(.shift)
        )
        guard binding == reverseBinding else { return nil }
        return shortcutDefinitionTitle(ShortcutID.panelCycleScope)
    }

    private func shortcutDefinitionTitle(_ definitionID: String) -> String {
        shortcutDefinitions.first(where: { $0.id == definitionID })?.title ?? definitionID
    }

    static let panelShortcutDefinitionIDs: Set<String> = [
        ShortcutID.panelActions,
        ShortcutID.panelCycleScope,
        ShortcutID.panelExport,
        ShortcutID.panelEditSnippet,
        ShortcutID.panelShare,
        ShortcutID.panelSave,
        ShortcutID.panelDelete,
        ShortcutID.panelMultiSelect,
        ShortcutID.panelToggleSelection,
        ShortcutID.panelSelectAll,
        ShortcutID.panelCopyCombined,
        ShortcutID.panelPasteCombined,
    ]

    private let settingsStore: ClipboardHistorySettingsStore
    private let privateCopyLeaseStore: PluginStorageClipboardPrivateCopyLeaseStore
    private let pasteboard: any ClipboardPasteboardAccess
    private let localization: PluginLocalization
    private let copyCommandSender: any ClipboardCopyCommandSending
    private let pasteCommandSender: any ClipboardPasteCommandSending
    private let accessibilityTrusted: () -> Bool
    private let accessibilityRequester: (Bool) -> Bool
    private let frontmostProcessIdentifier: () -> pid_t?
    private let sequentialPasteStabilizationDelay: Duration
    private let snippetPasteboardReader: ClipboardPasteboardReaderProcess
    private lazy var keywordExpander = ClipboardSnippetKeywordExpander(
        savedLibraryController: savedLibraryController,
        pasteboard: pasteboard,
        pasteboardReader: snippetPasteboardReader,
        onPasteboardWrite: { [weak self] in self?.controller.markCurrentPasteboardChangeAsInternal() }
    )
    private let privacyHUDPresenter: any ClipboardPrivacyHUDPresenting
    private let sequentialPasteCoordinator: ClipboardSequentialPasteCoordinator
    private var pendingSequentialPasteTargets: [pid_t?] = []
    private var isSequentialPasteInFlight = false
    private var sequentialPasteWorkerTask: Task<Void, Never>?
    private var sequentialPasteWorkerGeneration = 0
    private var sequentialHUDPreviewTask: Task<Void, Never>?
    private var privateCopyTask: Task<Void, Never>?
    private var privateCopyGeneration: UInt64 = 0
    private(set) var keywordExpansionStartAttemptCountForTesting = 0
    var hasPendingSequentialPasteForTesting: Bool {
        sequentialPasteWorkerTask != nil || isSequentialPasteInFlight || !pendingSequentialPasteTargets.isEmpty
    }
    var hasPrivateCopyOperationForTesting: Bool { privateCopyTask != nil }
    var isKeywordExpansionRunningForTesting: Bool { keywordExpander.isRunning }
    var hasConfiguredKeywordExpansionForTesting: Bool { keywordExpander.hasConfiguredKeywords }
    var snippetPasteboardReaderForTesting: ClipboardPasteboardReaderProcess { snippetPasteboardReader }
    var historyPasteboardReaderForTesting: ClipboardPasteboardReaderProcess? {
        (pasteboard as? GeneralClipboardPasteboard)?.payloadReaderForTesting
    }
    private lazy var sequentialPasteHUD: ClipboardSequentialPasteHUDController = {
        let hud = ClipboardSequentialPasteHUDController(localization: localization)
        hud.onPasteNext = { [weak self] in
            guard let self else { return }
            self.enqueueSequentialPaste(
                targetProcessIdentifier: self.frontmostProcessIdentifier()
            )
        }
        hud.onPrevious = { [weak self] in
            guard let self, !self.isSequentialQueueMutationLocked else { return }
            self.sequentialPasteCoordinator.moveToPrevious()
            self.sequentialQueueDidChange()
        }
        hud.onSkip = { [weak self] in
            guard let self, !self.isSequentialQueueMutationLocked else { return }
            self.sequentialPasteCoordinator.skip()
            self.sequentialQueueDidChange()
        }
        hud.onRestart = { [weak self] in
            guard let self, !self.isSequentialQueueMutationLocked else { return }
            self.sequentialPasteCoordinator.restart()
            self.sequentialQueueDidChange()
        }
        hud.onCancel = { [weak self] in
            self?.cancelPendingSequentialPastes()
            self?.sequentialHUDPreviewTask?.cancel()
            self?.sequentialHUDPreviewTask = nil
            self?.sequentialPasteCoordinator.cancel()
            self?.synchronizeSequentialPasteProtection()
            self?.sequentialPasteHUD.dismiss()
        }
        hud.onClose = { [weak self] in
            self?.sequentialHUDPreviewTask?.cancel()
            self?.sequentialHUDPreviewTask = nil
        }
        return hud
    }()
    private lazy var panelController = ClipboardHistoryPanelController(
        historyController: controller,
        savedLibraryController: savedLibraryController,
        previewPasteboard: pasteboard,
        localization: localization,
        onIgnoreNextCopy: { [weak self] in
            self?.armIgnoreNextCopy()
        },
        onManualClipboardWrite: { [weak self] in
            self?.resetImplicitQueueForManualClipboardWrite()
        },
        onStartSequentialQueue: { [weak self] itemIDs in
            self?.startSequentialQueue(itemIDs: itemIDs) == true
        },
        hudPresenter: privacyHUDPresenter,
        pasteCommandSender: pasteCommandSender,
        shortcutBindingProvider: { [weak self] shortcutID in
            guard let self else { return nil }
            if let shortcutBindingResolver = self.shortcutBindingResolver {
                return shortcutBindingResolver(shortcutID)
            }
            return Self.defaultPanelShortcutBinding(shortcutID)
        },
        shortcutSettingsContextProvider: { [weak self] in
            self?.inlineShortcutSettingsContextProvider?()
        }
    )

    init(
        context: PluginRuntimeContext,
        pasteboard: (any ClipboardPasteboardAccess)? = nil,
        sourceContext: (any ClipboardSourceContextProviding)? = nil,
        persistence: (any ClipboardHistoryPersisting)? = nil,
        savedPersistence: (any ClipboardSavedLibraryPersisting)? = nil,
        copyCommandSender: (any ClipboardCopyCommandSending)? = nil,
        pasteCommandSender: (any ClipboardPasteCommandSending)? = nil,
        privacyHUDPresenter: (any ClipboardPrivacyHUDPresenting)? = nil,
        imageTextRecognizer: (any ClipboardImageTextRecognizing)? = nil,
        accessibilityTrusted: @escaping () -> Bool = ClipboardHistoryAccessibilityCheck.isTrusted,
        accessibilityRequester: @escaping (Bool) -> Bool = ClipboardHistoryAccessibilityCheck.requestTrust(prompt:),
        frontmostProcessIdentifier: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        sequentialPasteStabilizationDelay: Duration = .milliseconds(120),
        snippetPasteboardReader: ClipboardPasteboardReaderProcess? = nil
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let settingsStore = ClipboardHistorySettingsStore(storage: context.storage)
        let privateCopyLeaseStore = PluginStorageClipboardPrivateCopyLeaseStore(storage: context.storage)
        let sequentialPasteCoordinator = ClipboardSequentialPasteCoordinator(
            store: PluginStorageClipboardSequentialPasteStore(storage: context.storage)
        )
        let snippetPasteboardReaderHelperURL = context.resourceBundle.url(
            forResource: "mactools-clipboard-pasteboard-reader-helper",
            withExtension: nil,
            subdirectory: "PasteboardReaderHelper"
        )
        let resolvedSnippetPasteboardReader = snippetPasteboardReader ?? ClipboardPasteboardReaderProcess {
            snippetPasteboardReaderHelperURL
        }
        let resolvedPasteboard = pasteboard ?? GeneralClipboardPasteboard(
            resourceBundle: context.resourceBundle
        )
        let resolvedSavedLibraryPasteboard: any ClipboardPasteboardAccess = pasteboard ?? GeneralClipboardPasteboard(
            resourceBundle: context.resourceBundle,
            payloadReader: resolvedSnippetPasteboardReader
        )
        let databaseURL = context.supportDirectory?.appendingPathComponent(
            "clipboard.sqlite3",
            isDirectory: false
        )
        let keyStore = ClipboardHistoryKeychainStore(
            service: PluginPrivateDataKeychainIdentity.service(pluginID: Self.pluginID)
        )
        let databaseAccess = ClipboardDatabaseAccessCoordinator()
        let resolvedPersistence: any ClipboardHistoryPersisting
        if let persistence {
            resolvedPersistence = persistence
        } else if let databaseURL {
            resolvedPersistence = IncrementalEncryptedClipboardHistoryStore(
                databaseURL: databaseURL,
                keyStore: keyStore,
                databaseAccess: databaseAccess
            )
        } else {
            resolvedPersistence = UnavailableClipboardHistoryStore()
        }
        let resolvedSavedPersistence: any ClipboardSavedLibraryPersisting
        if let savedPersistence {
            resolvedSavedPersistence = savedPersistence
        } else if let databaseURL {
            resolvedSavedPersistence = IncrementalEncryptedClipboardSavedLibraryStore(
                databaseURL: databaseURL,
                keyStore: keyStore,
                databaseAccess: databaseAccess
            )
        } else {
            resolvedSavedPersistence = UnavailableClipboardSavedLibraryStore()
        }

        self.localization = localization
        self.settingsStore = settingsStore
        self.privateCopyLeaseStore = privateCopyLeaseStore
        self.pasteboard = resolvedPasteboard
        self.copyCommandSender = copyCommandSender ?? SystemClipboardCopyCommandSender()
        self.pasteCommandSender = pasteCommandSender ?? SystemClipboardPasteCommandSender()
        self.privacyHUDPresenter = privacyHUDPresenter ?? ClipboardPrivacyHUDController(localization: localization)
        self.sequentialPasteCoordinator = sequentialPasteCoordinator
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityRequester = accessibilityRequester
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.sequentialPasteStabilizationDelay = sequentialPasteStabilizationDelay
        self.snippetPasteboardReader = resolvedSnippetPasteboardReader
        self.controller = ClipboardHistoryController(
            settings: settingsStore,
            pasteboard: resolvedPasteboard,
            sourceContext: sourceContext ?? WorkspaceClipboardSourceContextProvider(),
            persistence: resolvedPersistence,
            imageTextRecognizer: imageTextRecognizer ?? VisionClipboardImageTextRecognizer(),
            errorMessageProvider: { error in
                Self.localizedErrorMessage(error, localization: localization)
            }
        )
        self.savedLibraryController = ClipboardSavedLibraryController(
            pasteboard: resolvedSavedLibraryPasteboard,
            persistence: resolvedSavedPersistence,
            errorMessageProvider: { error in
                Self.localizedErrorMessage(error, localization: localization)
            }
        )
        self.savedLibraryController.maximumExpandedTextByteCount = { [weak settingsStore] in
            ClipboardHistorySettingsStore.validExpandedTextByteCount(settingsStore?.maximumExpandedTextByteCount ?? 0)
        }
        self.metadata = PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "剪贴板"),
            iconName: "clipboard",
            iconTint: .accentColor,
            order: Self.pluginOrder,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "搜索历史记录并管理可重复使用的片段和已存项目"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: {
                localization.string("panel.button.open", defaultValue: "打开")
            }
        )

        settingsStore.onChange = { [weak self] in
            self?.controller.settingsDidChange()
            self?.synchronizeKeywordExpansion()
        }
        controller.onChange = { [weak self] in
            self?.onStateChange?()
        }
        savedLibraryController.onChange = { [weak self] in
            self?.synchronizeKeywordExpansion()
            self?.onStateChange?()
        }
        savedLibraryController.onPasteboardWrite = { [weak self] in
            self?.controller.markCurrentPasteboardChangeAsInternal()
            self?.resetImplicitQueueForManualClipboardWrite()
        }
        controller.onCaptureSuppressionEvent = { [weak privacyHUDPresenter = self.privacyHUDPresenter] event in
            privacyHUDPresenter?.handleSuppressionEvent(event)
        }
        controller.onPrivateCopyLeaseChange = { [weak privateCopyLeaseStore] lease in
            if let lease {
                privateCopyLeaseStore?.save(
                    baselineChangeCount: lease.baselineChangeCount,
                    expiresAt: lease.expiresAt
                )
            } else {
                privateCopyLeaseStore?.clear()
            }
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
            case .historyCapacityFull:
                privacyHUDPresenter?.showFailure(localization.string(
                    "hud.capture.capacityFull",
                    defaultValue: "Not saved: History capacity is full"
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
        controller.onExternalPasteboardChange = { [weak self] in
            guard let self else { return }
            self.resetImplicitQueueForManualClipboardWrite()
        }
        controller.updateSequentialPasteProtectedItemIDs(
            sequentialPasteCoordinator.protectedItemIDs()
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: localization.string(
                "metadata.description",
                defaultValue: "Search encrypted local History and manage reusable Saved items"
            ),
            sections: [
                PluginSettingsSection(
                    id: SettingsSectionID.essentials,
                    presentation: .edgeToEdge
                ) { [weak self] context in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            savedLibraryController: self.savedLibraryController,
                            localization: self.localization,
                            settingsContext: context,
                            contentSections: [.essentials]
                        )
                    } else {
                        EmptyView()
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.queue,
                    presentation: .edgeToEdge,
                    embeddedShortcutGroupIDs: [ShortcutID.queueGroup]
                ) { [weak self] context in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            savedLibraryController: self.savedLibraryController,
                            localization: self.localization,
                            settingsContext: context,
                            contentSections: [.queue]
                        )
                    } else {
                        EmptyView()
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.snippets,
                    presentation: .edgeToEdge
                ) { [weak self] _ in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            savedLibraryController: self.savedLibraryController,
                            localization: self.localization,
                            contentSections: [.snippets],
                            onManageSnippets: { [weak self] in self?.panelController.showSnippets() }
                        )
                    } else {
                        EmptyView()
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.additionalShortcuts,
                    presentation: .edgeToEdge,
                    embeddedShortcutGroupIDs: [ShortcutID.panelGroup, ShortcutID.collectionGroup]
                ) { [weak self] context in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            savedLibraryController: self.savedLibraryController,
                            localization: self.localization,
                            settingsContext: context,
                            contentSections: [.additionalShortcuts]
                        )
                    } else {
                        EmptyView()
                    }
                }.headerAccessory { [weak self] _ in
                    if let self {
                        ClipboardSettingsAdvancedDivider(
                            title: self.localization.string("settings.advanced.title", defaultValue: "高级")
                        )
                    }
                },
                PluginSettingsSection(
                    id: SettingsSectionID.retention,
                    presentation: .edgeToEdge
                ) { [weak self] _ in
                    if let self {
                        ClipboardHistorySettingsView(
                            controller: self.controller,
                            savedLibraryController: self.savedLibraryController,
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
                            savedLibraryController: self.savedLibraryController,
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
                            savedLibraryController: self.savedLibraryController,
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
        } else if controller.isIgnoringNextCopy {
            subtitle = localization.string("panel.status.ignoreNext", defaultValue: "下次复制不会保存")
        } else {
            subtitle = localization.format(
                "panel.status.count",
                defaultValue: "%d history items · %d saved",
                controller.historyItems.count,
                controller.savedItems.count + savedLibraryController.items.count
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
            PluginShortcutDefinition(
                id: ShortcutID.pasteSequentially,
                title: localization.string(
                    "shortcut.pasteSequentially.title",
                    defaultValue: "Paste Sequentially"
                ),
                description: localization.string(
                    "shortcut.pasteSequentially.description",
                    defaultValue: "Paste the next queued item, or start with a snapshot of recent history."
                ),
                actionID: ShortcutID.pasteSequentially,
                scope: .global,
                defaultBinding: ShortcutBinding(
                    keyCode: 9,
                    modifiers: [.option, .shift]
                ),
                isRequired: false,
                settingsGroupID: ShortcutID.queueGroup,
                settingsGroupTitle: localization.string(
                    "settings.queue.shortcuts.title",
                    defaultValue: "Sequential Paste"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.pasteSequentially.groupDescription",
                    defaultValue: "Paste recent entries one at a time; advanced queue controls are optional."
                ),
                settingsControlTitle: localization.string(
                    "shortcut.pasteSequentially.controlTitle",
                    defaultValue: "Paste Next Queue Item"
                ),
                settingsControlSystemImage: "list.number"
            ),
            panelShortcut(
                id: ShortcutID.panelCycleScope,
                title: localization.string(
                    "panel.shortcuts.cycleScope",
                    defaultValue: "Cycle Filter Group"
                ),
                description: localization.string(
                    "panel.shortcuts.cycleScope.description",
                    defaultValue: "Switch between available filter groups; add Shift to go backward. Control-1 through Control-9 chooses an option in the active group."
                ),
                keyCode: 48,
                modifiers: [.control],
                systemImage: "rectangle.3.group"
            ),
            panelShortcut(
                id: ShortcutID.panelActions,
                title: localization.string("panel.shortcuts.actions", defaultValue: "Toggle Actions"),
                description: localization.string("panel.shortcuts.actions.description", defaultValue: "Open Actions or close it and return to the history search."),
                keyCode: 40,
                modifiers: [.command],
                systemImage: "command"
            ),
            panelShortcut(
                id: ShortcutID.panelEditSnippet,
                title: localization.string("saved.edit", defaultValue: "Edit Snippet"),
                description: localization.string("panel.shortcuts.editSnippet.description", defaultValue: "Edit the selected snippet while Clipboard History is focused."),
                keyCode: 14,
                modifiers: [.command, .option],
                systemImage: "pencil"
            ),
            panelShortcut(
                id: ShortcutID.panelExport,
                title: localization.string("panel.shortcuts.export", defaultValue: "Export"),
                description: localization.string("panel.shortcuts.export.description", defaultValue: "Open export formats for the focused clipboard item."),
                keyCode: 14,
                modifiers: [.command],
                systemImage: "square.and.arrow.down"
            ),
            panelShortcut(
                id: ShortcutID.panelShare,
                title: localization.string("panel.shortcuts.share", defaultValue: "Share"),
                description: localization.string("panel.shortcuts.share.description", defaultValue: "Open the macOS share sheet for the current item or selection."),
                keyCode: 14,
                modifiers: [.command, .shift],
                systemImage: "square.and.arrow.up"
            ),
            panelShortcut(
                id: ShortcutID.panelSave,
                title: localization.string("panel.shortcuts.save", defaultValue: "Save or Unsave Clip"),
                description: localization.string("panel.shortcuts.save.description", defaultValue: "Toggle whether the focused captured item is kept in Saved."),
                keyCode: 35,
                modifiers: [.command],
                systemImage: "bookmark"
            ),
            panelShortcut(
                id: ShortcutID.panelDelete,
                title: localization.string("panel.shortcuts.delete", defaultValue: "Delete Item"),
                description: localization.string("panel.shortcuts.delete.description", defaultValue: "Delete the focused clipboard item without conflicting with text editing."),
                keyCode: 51,
                modifiers: [.command, .shift],
                systemImage: "trash"
            ),
            panelShortcut(
                id: ShortcutID.panelMultiSelect,
                title: localization.string("panel.shortcuts.multiSelect", defaultValue: "Select Multiple Items"),
                description: localization.string("panel.shortcuts.multiSelect.description", defaultValue: "Enter or leave multiple-selection mode."),
                keyCode: 37,
                modifiers: [.command],
                systemImage: "checklist"
            ),
            panelShortcut(
                id: ShortcutID.panelToggleSelection,
                title: localization.string("panel.selection.toggleFocused", defaultValue: "Mark or Unmark Item"),
                description: localization.string("panel.shortcuts.toggleSelection.description", defaultValue: "In multi-select mode, select or unselect the highlighted item, even while the search field is focused."),
                keyCode: 36,
                modifiers: [.command],
                systemImage: "checkmark.square"
            ),
            panelShortcut(
                id: ShortcutID.panelSelectAll,
                title: localization.string("panel.selection.selectAll", defaultValue: "Select All Visible"),
                description: localization.string(
                    "panel.shortcuts.selectAll.description",
                    defaultValue: "In multi-select mode, select every item currently shown without taking focus from search."
                ),
                keyCode: 0,
                modifiers: [.command, .option],
                systemImage: "checkmark.square.fill"
            ),
            panelShortcut(
                id: ShortcutID.panelCopyCombined,
                title: localization.string("panel.shortcuts.copyCombined", defaultValue: "Copy Combined Selection"),
                description: localization.string("panel.shortcuts.copyCombined.description", defaultValue: "Copy selected entries together in their selected order."),
                keyCode: 8,
                modifiers: [.command, .shift],
                systemImage: "doc.on.doc"
            ),
            panelShortcut(
                id: ShortcutID.panelPasteCombined,
                title: localization.string("panel.shortcuts.pasteCombined", defaultValue: "Paste Combined Selection"),
                description: localization.string("panel.shortcuts.pasteCombined.description", defaultValue: "Paste selected entries together in their selected order."),
                keyCode: 36,
                modifiers: [.command, .shift],
                systemImage: "arrow.right.doc.on.clipboard"
            ),
        ]
    }

    private func panelShortcut(
        id: String,
        title: String,
        description: String,
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        systemImage: String
    ) -> PluginShortcutDefinition {
        PluginShortcutDefinition(
            id: id,
            title: title,
            description: description,
            actionID: id,
            scope: .whilePluginActive,
            defaultBinding: ShortcutBinding(keyCode: keyCode, modifiers: modifiers),
            isRequired: false,
            settingsGroupID: ShortcutID.panelGroup,
            settingsGroupTitle: localization.string(
                "panel.shortcuts.group",
                defaultValue: "Clipboard Window Shortcuts"
            ),
            settingsGroupDescription: localization.string(
                "panel.shortcuts.group.description",
                defaultValue: "These shortcuts work only while Clipboard History is focused."
            ),
            settingsControlTitle: title,
            settingsControlSystemImage: systemImage
        )
    }

    static func defaultPanelShortcutBinding(_ id: String) -> ShortcutBinding? {
        switch id {
        case ShortcutID.panelCycleScope:
            ShortcutBinding(keyCode: 48, modifiers: [.control])
        case ShortcutID.panelActions:
            ShortcutBinding(keyCode: 40, modifiers: [.command])
        case ShortcutID.panelExport:
            ShortcutBinding(keyCode: 14, modifiers: [.command])
        case ShortcutID.panelEditSnippet:
            ShortcutBinding(keyCode: 14, modifiers: [.command, .option])
        case ShortcutID.panelShare:
            ShortcutBinding(keyCode: 14, modifiers: [.command, .shift])
        case ShortcutID.panelSave:
            ShortcutBinding(keyCode: 35, modifiers: [.command])
        case ShortcutID.panelDelete:
            ShortcutBinding(keyCode: 51, modifiers: [.command, .shift])
        case ShortcutID.panelMultiSelect:
            ShortcutBinding(keyCode: 37, modifiers: [.command])
        case ShortcutID.panelToggleSelection:
            ShortcutBinding(keyCode: 36, modifiers: [.command])
        case ShortcutID.panelSelectAll:
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        case ShortcutID.panelCopyCombined:
            ShortcutBinding(keyCode: 8, modifiers: [.command, .shift])
        case ShortcutID.panelPasteCombined:
            ShortcutBinding(keyCode: 36, modifiers: [.command, .shift])
        default:
            nil
        }
    }

    static let queueControlActionIDs = [
        ActionID.previousSequentialQueueItem,
        ActionID.skipSequentialQueueItem,
        ActionID.restartSequentialQueue,
        ActionID.cancelSequentialQueue,
    ]

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
                id: ShortcutID.queueGroup,
                title: localization.string(
                    "settings.queue.shortcuts.title",
                    defaultValue: "Sequential Paste Queue"
                ),
                description: localization.string(
                    "settings.queue.shortcuts.description",
                    defaultValue: "Assign Paste Next first. Advanced queue controls are optional and can be added later."
                ),
                systemImage: "list.number",
                actionIDs: Set(Self.queueControlActionIDs),
                shortcutDefinitionIDs: [ShortcutID.pasteSequentially],
                placementAfterSectionID: SettingsSectionID.queue
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.panelGroup,
                title: localization.string("panel.shortcuts.group", defaultValue: "Clipboard Window Shortcuts"),
                description: localization.string("panel.shortcuts.group.description", defaultValue: "These shortcuts work only while Clipboard History is focused."),
                systemImage: "rectangle.and.hand.point.up.left",
                shortcutDefinitionIDs: [
                    ShortcutID.panelCycleScope,
                    ShortcutID.panelActions,
                    ShortcutID.panelEditSnippet,
                    ShortcutID.panelExport,
                    ShortcutID.panelShare,
                    ShortcutID.panelSave,
                    ShortcutID.panelDelete,
                    ShortcutID.panelMultiSelect,
                    ShortcutID.panelToggleSelection,
                    ShortcutID.panelSelectAll,
                    ShortcutID.panelCopyCombined,
                    ShortcutID.panelPasteCombined,
                ],
                placementAfterSectionID: SettingsSectionID.additionalShortcuts
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.privacyGroup,
                title: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                systemImage: "eye.slash",
                shortcutDefinitionIDs: [ShortcutID.privateCopy, ShortcutID.ignoreNextCopy],
                placementAfterSectionID: SettingsSectionID.snippets
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.collectionGroup,
                title: localization.string(
                    "settings.shortcuts.collection.title",
                    defaultValue: "高级控制"
                ),
                description: localization.string(
                    "settings.shortcuts.collection.description",
                    defaultValue: "可选：控制收集状态或清除历史记录。"
                ),
                systemImage: "playpause",
                actionIDs: Set(Self.collectionControlActionIDs),
                placementAfterSectionID: SettingsSectionID.additionalShortcuts
            ),
        ]
    }

    var shortcutDefinitionFirstSettingsGroupIDs: Set<String> {
        [ShortcutID.queueGroup]
    }

    static let collectionControlActionIDs = [
        ActionID.pauseCollection,
        ActionID.resumeCollection,
        ActionID.toggleCollection,
        ActionID.clearAllHistory,
    ]

    var collapsibleShortcutSettingsGroupIDs: Set<String> {
        [ShortcutID.panelGroup, ShortcutID.collectionGroup]
    }

    var collapsibleActionSettingsGroupIDs: Set<String> {
        [ShortcutID.queueGroup]
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
                id: ActionID.previousSequentialQueueItem,
                title: localization.string("hud.queue.previous", defaultValue: "Previous Queue Item"),
                description: localization.string(
                    "action.queue.previous.description",
                    defaultValue: "Move the sequential paste queue to the previous item."
                ),
                systemImage: "chevron.left"
            ),
            action(
                id: ActionID.skipSequentialQueueItem,
                title: localization.string("hud.queue.skip", defaultValue: "Skip Queue Item"),
                description: localization.string(
                    "action.queue.skip.description",
                    defaultValue: "Skip the next item without pasting it."
                ),
                systemImage: "forward.end"
            ),
            action(
                id: ActionID.restartSequentialQueue,
                title: localization.string("hud.queue.restart", defaultValue: "Restart Queue"),
                description: localization.string(
                    "action.queue.restart.description",
                    defaultValue: "Start the active paste queue again from its first item."
                ),
                systemImage: "backward.end"
            ),
            action(
                id: ActionID.cancelSequentialQueue,
                title: localization.string("hud.queue.cancel", defaultValue: "Cancel Queue"),
                description: localization.string(
                    "action.queue.cancel.description",
                    defaultValue: "Cancel the active sequential paste queue."
                ),
                systemImage: "xmark.circle"
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
                id: ActionID.clearAllHistory,
                title: localization.string("action.clearAll.title", defaultValue: "清除全部剪贴板历史"),
                description: localization.string(
                    "action.clearAll.description",
                    defaultValue: "Permanently delete all History items without removing Saved items."
                ),
                systemImage: "trash.slash",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？"),
                    message: localization.string(
                        "clear.all.actionMessage",
                        defaultValue: "All History items will be permanently deleted. Saved items are not affected. This cannot be undone."
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
        case ActionID.restartSequentialQueue,
             ActionID.previousSequentialQueueItem,
             ActionID.skipSequentialQueueItem:
            if isSequentialQueueMutationLocked {
                return .unavailable(localization.string(
                    "availability.sequentialPaste.inProgress",
                    defaultValue: "Wait for the current sequential paste to finish."
                ))
            }
            // Queue-control shortcuts remain configurable even while a queue is inactive.
            // Invoking an inapplicable control is intentionally a no-op.
            return .available
        case ActionID.cancelSequentialQueue:
            return .available
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
        case ActionID.previousSequentialQueueItem:
            guard !isSequentialQueueMutationLocked else { break }
            sequentialPasteCoordinator.moveToPrevious()
            sequentialQueueDidChange()
        case ActionID.skipSequentialQueueItem:
            guard !isSequentialQueueMutationLocked else { break }
            sequentialPasteCoordinator.skip()
            sequentialQueueDidChange()
        case ActionID.restartSequentialQueue:
            guard !isSequentialQueueMutationLocked else { break }
            sequentialPasteCoordinator.restart()
            sequentialQueueDidChange()
        case ActionID.cancelSequentialQueue:
            cancelPendingSequentialPastes()
            sequentialHUDPreviewTask?.cancel()
            sequentialHUDPreviewTask = nil
            sequentialPasteCoordinator.cancel()
            synchronizeSequentialPasteProtection()
            sequentialPasteHUD.dismiss()
        case ActionID.pauseCollection:
            settingsStore.setPaused(true)
        case ActionID.resumeCollection:
            settingsStore.setPaused(false)
        case ActionID.toggleCollection:
            settingsStore.setPaused(!settingsStore.isPaused)
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
            guard privateCopyTask == nil, !controller.isIgnoringNextCopy else { return }
            let targetProcessIdentifier = frontmostProcessIdentifier()
            privateCopyGeneration &+= 1
            let generation = privateCopyGeneration
            privateCopyTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performPrivateCopy(targetProcessIdentifier: targetProcessIdentifier)
                guard !Task.isCancelled, self.privateCopyGeneration == generation else { return }
                self.privateCopyTask = nil
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
        case ShortcutID.pasteSequentially:
            enqueueSequentialPaste(
                targetProcessIdentifier: frontmostProcessIdentifier()
            )
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
        synchronizeKeywordExpansion()
        onStateChange?()
    }

    func refreshAccessibilityPermission() {
        synchronizeKeywordExpansion()
        onStateChange?()
    }

    func activate(context: PluginRuntimeContext) {
        if let lease = privateCopyLeaseStore.load() {
            _ = controller.restorePrivateCopySuppression(lease)
        }
        controller.start()
        savedLibraryController.start()
        synchronizeKeywordExpansion()
    }

    func deactivate(reason: PluginDeactivationReason) {
        privateCopyGeneration &+= 1
        privateCopyTask?.cancel()
        privateCopyTask = nil
        cancelPendingSequentialPastes()
        sequentialPasteCoordinator.resetImplicitQueueForExternalCopy()
        synchronizeSequentialPasteProtection()
        panelController.close(restorePreviousApplication: false)
        privacyHUDPresenter.dismiss()
        sequentialHUDPreviewTask?.cancel()
        sequentialHUDPreviewTask = nil
        sequentialPasteHUD.dismiss()
        keywordExpander.stop()
        snippetPasteboardReader.stopImmediately()
        controller.stop()
        if reason == .uninstalling {
            privateCopyLeaseStore.clear()
        }
        savedLibraryController.stop(invalidatePersistence: reason == .uninstalling)
    }

    func refresh() {
        controller.settingsDidChange()
        controller.start()
        savedLibraryController.start()
        synchronizeKeywordExpansion()
    }

    private func synchronizeKeywordExpansion() {
        keywordExpander.onDiagnostic = { [weak settingsStore] diagnostic in
            settingsStore?.keywordExpansionDiagnostic = diagnostic
        }
        guard settingsStore.isKeywordExpansionEnabled else {
            settingsStore.keywordExpansionDiagnostic = nil
            keywordExpander.stop()
            settingsStore.setKeywordExpansionStatus(.off)
            return
        }
        keywordExpander.updateItems()
        guard keywordExpander.hasConfiguredKeywords else {
            keywordExpander.stop()
            settingsStore.setKeywordExpansionStatus(.noKeywords)
            return
        }
        guard accessibilityTrusted() else {
            keywordExpander.stop()
            settingsStore.setKeywordExpansionStatus(.accessibilityRequired)
            return
        }
        keywordExpansionStartAttemptCountForTesting += 1
        settingsStore.setKeywordExpansionStatus(keywordExpander.start() ? .ready : .unavailable)
    }

    func setKeywordExpansionEnabledForTesting(_ enabled: Bool) {
        settingsStore.isKeywordExpansionEnabled = enabled
    }

    func startSequentialQueueForTesting(itemIDs: [UUID]) -> Bool {
        startSequentialQueue(itemIDs: itemIDs)
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
            // There is no trustworthy completion acknowledgement after posting Command-C. Keep
            // suppression fail-closed until the pasteboard transition is consumed or the original
            // timeout expires; cancelling it after a short observation window can persist a slow
            // application's sensitive copy.
            return controller?.ignoreNextCopy(expiringAfter: 15, mode: .privateCopy) == true
        }
        guard !Task.isCancelled else {
            if privateCopyLeaseStore.load() == nil {
                controller.cancelNextCaptureSuppression()
            }
            return
        }
        guard sent else {
            let hadPendingSuppression = controller.isIgnoringNextCopy
            let mayHaveDispatchedCopy = privateCopyLeaseStore.load() != nil
            if !mayHaveDispatchedCopy {
                controller.cancelNextCaptureSuppression()
            }
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
            return
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
        switch await controller.rewriteCurrentClipboardAsPlainText() {
        case .succeeded:
            resetImplicitQueueForManualClipboardWrite()
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
        let preparedClipboardVersion = controller.currentPasteboardVersion
        guard await pasteCommandSender.sendPasteCommand(
            to: targetProcessIdentifier,
            expectedPasteboardVersion: preparedClipboardVersion,
            currentPasteboardVersion: { self.controller.currentPasteboardVersion }
        ) else {
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

    private func enqueueSequentialPaste(targetProcessIdentifier: pid_t?) {
        let remainingCount = sequentialPasteCoordinator.availablePasteRequestCount(
            recentHistoryItemIDs: controller.recentItemIDsForSequentialPaste
        )
        let reservedRequestCount = pendingSequentialPasteTargets.count
            + (isSequentialPasteInFlight ? 1 : 0)
        guard reservedRequestCount < remainingCount else {
            showSequentialPasteHUD()
            return
        }
        pendingSequentialPasteTargets.append(targetProcessIdentifier)
        startSequentialPasteWorkerIfNeeded()
    }

    private func startSequentialPasteWorkerIfNeeded() {
        guard sequentialPasteWorkerTask == nil,
              !pendingSequentialPasteTargets.isEmpty else { return }
        sequentialPasteWorkerGeneration &+= 1
        let generation = sequentialPasteWorkerGeneration
        sequentialPasteWorkerTask = Task { @MainActor [weak self] in
            await self?.drainSequentialPasteRequests(generation: generation)
        }
    }

    private func drainSequentialPasteRequests(generation: Int) async {
        var pastedAtLeastOneItem = false
        defer {
            if sequentialPasteWorkerGeneration == generation {
                if pastedAtLeastOneItem {
                    showSequentialPasteHUD()
                }
                sequentialPasteWorkerTask = nil
                startSequentialPasteWorkerIfNeeded()
            }
        }

        while sequentialPasteWorkerGeneration == generation,
              !Task.isCancelled,
              !pendingSequentialPasteTargets.isEmpty {
            let targetProcessIdentifier = pendingSequentialPasteTargets.removeFirst()
            isSequentialPasteInFlight = true
            let didPaste = await performSequentialPaste(
                targetProcessIdentifier: targetProcessIdentifier,
                workerGeneration: generation
            )
            // An old worker must not clear a newly started worker's reservations.
            guard isCurrentSequentialPasteWorker(generation: generation) else { return }
            isSequentialPasteInFlight = false
            guard didPaste else {
                pendingSequentialPasteTargets.removeAll()
                return
            }
            pastedAtLeastOneItem = true
        }
    }

    private func cancelPendingSequentialPastes() {
        sequentialPasteWorkerGeneration &+= 1
        pendingSequentialPasteTargets.removeAll()
        isSequentialPasteInFlight = false
        sequentialPasteWorkerTask?.cancel()
        sequentialPasteWorkerTask = nil
    }

    private func performSequentialPaste(
        targetProcessIdentifier: pid_t?,
        workerGeneration: Int
    ) async -> Bool {
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.sequentialPaste.accessibilityRequired",
                defaultValue: "Sequential paste requires Accessibility permission"
            ))
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return false
        }
        guard let targetProcessIdentifier,
              frontmostProcessIdentifier() == targetProcessIdentifier else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.sequentialPaste.failed",
                defaultValue: "Couldn’t paste the next clipboard item"
            ))
            return false
        }
        guard let operation = sequentialPasteCoordinator.nextOperation(
            recentHistoryItemIDs: controller.recentItemIDsForSequentialPaste
        ) else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.sequentialPaste.empty",
                defaultValue: "No clipboard items are available to paste"
            ))
            return false
        }
        let itemID = operation.itemID
        let implicitClipboardVersion = sequentialPasteCoordinator.session?.source == .recentHistory
            ? pasteboard.changeCount : nil
        synchronizeSequentialPasteProtection()

        let preparedClipboardVersion: Int?
        if controller.items.contains(where: { $0.id == itemID }) {
            let didPreparePayload = await controller.preparePayloadForUse(id: itemID)
            guard isCurrentSequentialPasteWorker(generation: workerGeneration),
                  sequentialPasteCoordinator.session?.matches(operation) == true,
                  revalidateImplicitClipboardVersion(implicitClipboardVersion),
                  didPreparePayload else {
                return markSequentialItemUnavailable(operation)
            }
            preparedClipboardVersion = await controller.copyItemForPaste(id: itemID) { [weak self] in
                guard let self else { return false }
                return self.isCurrentSequentialPasteWorker(generation: workerGeneration)
                    && self.sequentialPasteCoordinator.session?.matches(operation) == true
                    && self.revalidateImplicitClipboardVersion(implicitClipboardVersion)
            }
        } else if savedLibraryController.items.contains(where: { $0.id == itemID }) {
            // Resolve snippet variables at paste time so every queue step sees current values.
            preparedClipboardVersion = await savedLibraryController.copyForPaste(id: itemID)?.pasteboardVersion
        } else {
            return markSequentialItemUnavailable(operation)
        }
        guard isCurrentSequentialPasteWorker(generation: workerGeneration),
              sequentialPasteCoordinator.session?.matches(operation) == true else {
            return false
        }
        guard let preparedClipboardVersion else {
            return markSequentialItemUnavailable(operation)
        }
        let didSendPaste = await pasteCommandSender.sendPasteCommand(to: targetProcessIdentifier) { [weak self] in
            guard let self,
                  self.isCurrentSequentialPasteWorker(generation: workerGeneration),
                  self.sequentialPasteCoordinator.session?.matches(operation) == true else { return false }
            guard self.pasteboard.changeCount == preparedClipboardVersion else {
                self.resetImplicitQueueForManualClipboardWrite()
                return false
            }
            return true
        }
        guard isCurrentSequentialPasteWorker(generation: workerGeneration) else {
            return false
        }
        guard didSendPaste else {
            synchronizeSequentialPasteProtection()
            privacyHUDPresenter.showFailure(localization.string(
                "hud.sequentialPaste.failed",
                defaultValue: "Couldn’t paste the next clipboard item"
            ))
            return false
        }
        // Commit the exact item that was actually sent before yielding for pacing. Session-bound
        // operations prevent a late completion from advancing a replaced or cancelled queue.
        _ = sequentialPasteCoordinator.recordSuccessfulPaste(operation: operation)
        synchronizeSequentialPasteProtection()
        isSequentialPasteInFlight = false

        // Shortcut presses are buffered immediately, while clipboard replacement is paced so the
        // destination gets a reliable chance to consume the current payload first.
        try? await Task.sleep(for: sequentialPasteStabilizationDelay)
        return true
    }

    private var isSequentialQueueMutationLocked: Bool {
        isSequentialPasteInFlight || !pendingSequentialPasteTargets.isEmpty
    }

    private func markSequentialItemUnavailable(
        _ operation: ClipboardSequentialPasteOperation
    ) -> Bool {
        _ = sequentialPasteCoordinator.markCurrentUnavailable(operation: operation)
        synchronizeSequentialPasteProtection()
        privacyHUDPresenter.showFailure(localization.string(
            "hud.sequentialPaste.unavailable",
            defaultValue: "This queued item is no longer available"
        ))
        return false
    }

    private func isCurrentSequentialPasteWorker(generation: Int) -> Bool {
        sequentialPasteWorkerGeneration == generation && !Task.isCancelled
    }

    private func synchronizeSequentialPasteProtection() {
        controller.updateSequentialPasteProtectedItemIDs(
            sequentialPasteCoordinator.protectedItemIDs()
        )
    }

    private func resetImplicitQueueForManualClipboardWrite() {
        // A request can be buffered before its first implicit session is created.
        guard sequentialPasteCoordinator.session?.source != .explicitQueue else { return }
        cancelPendingSequentialPastes()
        sequentialPasteCoordinator.resetImplicitQueueForExternalCopy()
        synchronizeSequentialPasteProtection()
    }

    private func revalidateImplicitClipboardVersion(_ expectedVersion: Int?) -> Bool {
        guard let expectedVersion else { return true }
        guard pasteboard.changeCount == expectedVersion else {
            // A copy may precede the polling callback while a payload is loading.
            resetImplicitQueueForManualClipboardWrite()
            return false
        }
        return true
    }

    @discardableResult
    private func startSequentialQueue(itemIDs: [UUID]) -> Bool {
        let availableItemIDs = Set(controller.items.map(\.id))
            .union(savedLibraryController.items.map(\.id))
        guard !itemIDs.isEmpty, itemIDs.allSatisfy(availableItemIDs.contains) else {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.sequentialPaste.unavailable",
                defaultValue: "This queued item is no longer available"
            ))
            return false
        }
        do {
            try sequentialPasteCoordinator.startExplicitQueue(itemIDs: itemIDs)
            cancelPendingSequentialPastes()
            synchronizeSequentialPasteProtection()
            privacyHUDPresenter.showSuccess(localization.format(
                "hud.queue.created",
                defaultValue: "Queue ready · %lld items",
                sequentialPasteCoordinator.session?.totalCount ?? 0
            ))
            showSequentialPasteHUD()
            return true
        } catch ClipboardSequentialQueueError.activeQueueExists {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.queue.active",
                defaultValue: "Finish or cancel the current queue before creating another one"
            ))
        } catch ClipboardSequentialQueueError.exceedsMaximumItemCount {
            privacyHUDPresenter.showFailure(localization.format(
                "hud.queue.tooMany",
                defaultValue: "A queue can contain up to %lld items",
                ClipboardSequentialPasteSession.maximumItemCount
            ))
        } catch {
            privacyHUDPresenter.showFailure(localization.string(
                "hud.queue.empty",
                defaultValue: "Select at least one item for the queue"
            ))
        }
        return false
    }

    private func sequentialQueueDidChange() {
        synchronizeSequentialPasteProtection()
        showSequentialPasteHUD()
    }

    private func showSequentialPasteHUD() {
        sequentialHUDPreviewTask?.cancel()
        sequentialHUDPreviewTask = nil
        guard let session = sequentialPasteCoordinator.session else {
            sequentialPasteHUD.dismiss()
            return
        }
        guard !session.isComplete else {
            sequentialPasteHUD.showCompletion(
                source: session.source,
                dismissAfter: settingsStore.sequentialHUDDismissal.interval
            )
            return
        }
        let justPastedID = session.cursor > 0 ? session.itemIDs[session.cursor - 1] : nil
        let nextID = session.nextItemID
        let content = makeSequentialHUDContent(
            session: session,
            justPastedID: justPastedID,
            nextID: nextID,
            justPastedPreviewImageData: nil,
            nextPreviewImageData: nil
        )
        sequentialPasteHUD.show(
            content,
            dismissAfter: settingsStore.sequentialHUDDismissal.interval
        )

        guard !settingsStore.hidesSequentialHUDPreview else { return }
        let expectedCursor = session.cursor
        sequentialHUDPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let justPastedPreview = self.loadItemPreviewImageData(id: justPastedID)
            async let nextPreview = self.loadItemPreviewImageData(id: nextID)
            let loadedPreviews = await (justPastedPreview, nextPreview)
            guard !Task.isCancelled,
                  let currentSession = self.sequentialPasteCoordinator.session,
                  currentSession.cursor == expectedCursor,
                  currentSession.itemIDs == session.itemIDs else { return }
            let updatedContent = self.makeSequentialHUDContent(
                session: currentSession,
                justPastedID: justPastedID,
                nextID: nextID,
                justPastedPreviewImageData: loadedPreviews.0,
                nextPreviewImageData: loadedPreviews.1
            )
            self.sequentialPasteHUD.updateContentIfVisible(updatedContent)
        }
    }

    private func makeSequentialHUDContent(
        session: ClipboardSequentialPasteSession,
        justPastedID: UUID?,
        nextID: UUID?,
        justPastedPreviewImageData: Data?,
        nextPreviewImageData: Data?
    ) -> ClipboardSequentialPasteHUDContent {
        ClipboardSequentialPasteHUDContent(
            source: session.source,
            justPastedTitle: itemTitle(id: justPastedID),
            nextTitle: itemTitle(id: nextID),
            justPastedPreviewImageData: justPastedPreviewImageData,
            nextPreviewImageData: nextPreviewImageData,
            position: max(1, session.currentPosition ?? session.totalCount),
            totalCount: session.totalCount,
            hidesPreview: settingsStore.hidesSequentialHUDPreview,
            isComplete: false
        )
    }

    private func itemTitle(id: UUID?) -> String? {
        guard let id else { return nil }
        if let savedItem = savedLibraryController.items.first(where: { $0.id == id }) {
            return String(savedItem.title.prefix(100))
        }
        guard let item = controller.items.first(where: { $0.id == id }) else { return nil }
        let rawTitle = item.text.isEmpty
            ? Self.localizedContentKindTitle(item.kind, localization: localization)
            : item.text
        let title = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(100))
    }

    private static func localizedContentKindTitle(
        _ kind: ClipboardHistoryContentKind,
        localization: PluginLocalization
    ) -> String {
        switch kind {
        case .plainText:
            localization.string("content.kind.text", defaultValue: "Text")
        case .richText:
            localization.string("content.kind.richText", defaultValue: "Rich Text")
        case .image:
            localization.string("content.kind.image", defaultValue: "Image")
        case .pdf:
            localization.string("content.kind.pdf", defaultValue: "PDF")
        case .files:
            localization.string("content.kind.files", defaultValue: "Files")
        case .link:
            localization.string("content.kind.link", defaultValue: "Link")
        case .color:
            localization.string("content.kind.color", defaultValue: "Color")
        case .media:
            localization.string("content.kind.media", defaultValue: "Media")
        }
    }

    private func loadItemPreviewImageData(id: UUID?) async -> Data? {
        guard let id else { return nil }
        let payload: ClipboardHistoryPayload
        let discardPayload: () -> Void
        if let item = controller.items.first(where: { $0.id == id }),
           item.filterContentKinds.contains(.image),
           let loaded = try? await item.loadPayloadAsync() {
            payload = loaded
            discardPayload = { item.discardCachedPayloadIfReloadable() }
        } else if let item = savedLibraryController.items.first(where: { $0.id == id }),
                  item.contentKind == .image,
                  let loaded = try? await item.loadPayloadAsync() {
            payload = loaded
            discardPayload = { item.discardCachedPayloadIfReloadable() }
        } else {
            return nil
        }
        let worker = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled,
                  let data = payload.representations.first(where: {
                      ClipboardRepresentationType.isImage($0.typeIdentifier)
                  })?.data else { return nil }
            return Self.makeHUDThumbnailData(from: data)
        }
        let imageData = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        discardPayload()
        return imageData
    }

    nonisolated static func makeHUDThumbnailData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              ClipboardEmbeddedPreviewPolicy.allowsImageSourceDimensions(
                  width: width.intValue,
                  height: height.intValue
              ),
              !Task.isCancelled,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 160,
                  ] as CFDictionary
              ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        return bitmap.representation(using: .png, properties: [:])
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
        if let templateError = error as? ClipboardSnippetTemplateError {
            return templateError.localizedMessage(localization)
        }
        if let savedError = error as? ClipboardSavedLibraryError {
            switch savedError {
            case let .duplicateKeyword(keyword):
                return localization.format(
                    "saved.error.duplicateKeyword",
                    defaultValue: "The keyword %@ is already assigned to another snippet.",
                    keyword
                )
            case .invalidKeyword:
                return localization.string(
                    "saved.error.invalidKeyword",
                    defaultValue: "A keyword cannot contain spaces or line breaks."
                )
            case let .snippetTooLarge(maximumByteCount):
                return localization.format(
                    "saved.error.snippetTooLarge",
                    defaultValue: "A snippet cannot exceed %@.",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(maximumByteCount),
                        countStyle: .file
                    )
                )
            case let .keywordExpansionCacheFull(maximumByteCount):
                return localization.format(
                    "saved.error.keywordCacheFull",
                    defaultValue: "Keyword-enabled snippets cannot exceed %@ in total.",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(maximumByteCount),
                        countStyle: .file
                    )
                )
            case .plainTextUnavailable:
                return localization.string(
                    "saved.error.plainTextUnavailable",
                    defaultValue: "This saved item doesn’t contain pasteable text."
                )
            }
        }
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
