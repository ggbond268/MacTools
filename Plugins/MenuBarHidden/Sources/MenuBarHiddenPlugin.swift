import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import MacToolsPluginKit

public final class MenuBarHiddenPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        MenuBarHiddenPluginProvider(context: context)
    }
}

@MainActor
private struct MenuBarHiddenPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            MenuBarHiddenPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class MenuBarHiddenPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel, MenuBarHostStatusItemRecovering {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var descriptor: PluginComponentDescriptor {
        let items = controller.snapshot.hiddenItems + controller.snapshot.alwaysHiddenItems
        let height = MenuBarHiddenComponentIconLayout.spanHeight(
            forItems: items,
            iconCache: controller.manager.iconCache
        )
        return PluginComponentDescriptor(
            span: PluginComponentSpan(width: 4, height: height)!
        )
    }

    private let context: PluginRuntimeContext
    private let localization: PluginLocalization
    private let controller: MenuBarHiddenController
    private var launchObserver: NSObjectProtocol?

    var hostStatusItemFrameProvider: (() -> NSRect?)? {
        get { controller.manager.hostStatusItemFrameProvider }
        set {
            controller.manager.hostStatusItemFrameProvider = newValue
            activateAfterHostStatusItem()
        }
    }

    var resetHostStatusItemPosition: (() -> Void)? {
        get { controller.manager.resetHostStatusItemPosition }
        set { controller.manager.resetHostStatusItemPosition = newValue }
    }

    var onStateChange: (() -> Void)? {
        didSet {
            controller.onStateChange = onStateChange
            controller.manager.iconCache.onLayoutMetricsChange = onStateChange
        }
    }

    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: MenuBarHiddenConstants.pluginID),
        controller: MenuBarHiddenController? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.context = context
        self.localization = localization
        self.metadata = PluginMetadata(
            id: MenuBarHiddenConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "隐藏菜单栏图标"),
            iconName: "menubar.arrow.up.rectangle",
            iconTint: Color(nsColor: .systemBlue),
            order: 12,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "隐藏菜单栏图标并支持拖拽布局与点击转发"
            )
        )
        let ctrl = controller ?? MenuBarHiddenController(context: context, localization: localization)
        self.controller = ctrl

        if controller != nil {
            ctrl.activate()
        }
    }

    // MARK: - Lifecycle

    func activate(context _: PluginRuntimeContext) {
        activateAfterHostStatusItem()
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else { return }
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        controller.deactivate()
    }

    private func activateAfterHostStatusItem() {
        // The host app's NSStatusItem is created inside applicationDidFinishLaunching.
        // NSStatusBar inserts later items to the LEFT of earlier ones, so we must
        // install the divider AFTER the host icon exists. Otherwise expanding the
        // divider would push our own icon off-screen.
        if hostStatusItemFrameProvider?() != nil {
            DispatchQueue.main.async { [weak self] in
                self?.controller.activate()
            }
        } else if launchObserver == nil {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.activateAfterHostStatusItem() }
            }
        }
    }

    // MARK: - Panel state

    var primaryPanelState: PluginPanelState {
        guard controller.isHostSupported else {
            // Fail-closed unsupported host (macOS 27 beta single-window menu
            // bar): keep the row visible so users see why, disable the switch.
            return PluginPanelState(
                subtitle: localization.string(
                    "compat.unsupported.subtitle",
                    defaultValue: "暂不兼容"
                ),
                isOn: false,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: localization.string(
                    "compat.unsupported.message",
                    defaultValue: "当前 macOS 版本暂不兼容菜单栏隐藏"
                )
            )
        }
        return PluginPanelState(
            subtitle: controller.panelSubtitle,
            isOn: controller.isEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var componentPanelState: PluginComponentState {
        let shouldShowHiddenIconsCard = controller.isHostSupported
            && controller.currentPermissions().canManageItems
            && controller.showsHiddenIconsInPanel
        return PluginComponentState(
            subtitle: shouldShowHiddenIconsCard ? controller.componentSubtitle : "",
            isActive: controller.isEnabled,
            isEnabled: shouldShowHiddenIconsCard,
            isVisible: shouldShowHiddenIconsCard,
            errorMessage: nil
        )
    }

    // MARK: - Permissions
    //
    // The toggle works without permissions; only drag-reorder and click
    // forwarding need them. The host UI uses these to display permission
    // status cards.

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "accessibility",
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于合成鼠标事件以拖拽菜单栏图标并转发点击"
                )
            ),
            PluginPermissionRequirement(
                id: "screen-recording",
                kind: .screenRecording,
                title: localization.string("permission.screenRecording.title", defaultValue: "屏幕录制"),
                description: localization.string(
                    "permission.screenRecording.description",
                    defaultValue: "用于捕获菜单栏图标的真实外观，仅授权后才能在面板中查看与点击"
                )
            ),
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        let permissions = controller.currentPermissions()
        switch permissionID {
        case "accessibility":
            let granted = permissions.hasAccessibility
            return PluginPermissionState(
                isGranted: granted,
                footnote: granted ? nil : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "未授权时仍可使用隐藏开关，但无法拖拽或转发点击"
                )
            )
        case "screen-recording":
            let granted = permissions.hasScreenRecording
            return PluginPermissionState(
                isGranted: granted,
                footnote: granted ? nil : localization.string(
                    "permission.screenRecording.footnote",
                    defaultValue: "未授权时仍可使用隐藏开关，但布局栏与弹窗不可用"
                )
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id permissionID: String) {
        controller.refreshPermissions()
        switch permissionID {
        case "accessibility":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        case "screen-recording":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        default:
            break
        }
    }

    // MARK: - Configuration

    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription, prefersFullHeight: false) { [controller] _ in
            MenuBarHiddenSettingsView(controller: controller)
        }
    }

    // MARK: - Actions

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enabled) = action else { return }
        controller.isEnabled = enabled
    }

    // MARK: - Component panel

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(
            MenuBarHiddenComponentView(
                controller: controller,
                context: context
            )
        )
    }
}
