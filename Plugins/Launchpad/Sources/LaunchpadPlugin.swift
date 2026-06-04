import Combine
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class LaunchpadPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LaunchpadPluginProvider(context: context)
    }
}

private struct LaunchpadPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [LaunchpadPlugin(context: context)]
    }
}

@MainActor
final class LaunchpadPlugin: MacToolsPlugin, PluginPrimaryPanel {
    private enum ControlID {
        static let execute = "execute"
    }
    private enum ActionID {
        static let toggle = "toggleLaunchpad"
    }
    private enum ShortcutID {
        static let toggle = "launchpad.toggle"
    }

    let metadata = PluginMetadata(
        id: "launchpad",
        title: "启动台",
        iconName: "square.grid.3x3.fill",
        iconTint: Color(nsColor: .systemBlue),
        order: 12,
        defaultDescription: "唤出应用网格，搜索并启动"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling,
        buttonTitle: "打开"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadPlugin"
    )

    private let preferences: LaunchpadPreferences
    private let overlay: LaunchpadOverlayController
    private let hotCornerMonitor = LaunchpadHotCornerMonitor()
    private var cancellables = Set<AnyCancellable>()

    init(context: PluginRuntimeContext) {
        let preferences = LaunchpadPreferences(storage: context.storage)
        self.preferences = preferences
        self.overlay = LaunchpadOverlayController(preferences: preferences)

        // Hot corner *summons* (open-only), it does not toggle: re-entering the corner
        // while the launcher is already open must not close it (Codex P1). `open()` is a
        // no-op when already shown. Menu button / global hotkey keep toggle semantics.
        hotCornerMonitor.onTrigger = { [weak self] in self?.overlay.open() }
        // Apply the saved corner now and whenever the user changes it in settings.
        preferences.$hotCorner
            .sink { [weak hotCornerMonitor] corner in hotCornerMonitor?.update(corner: corner) }
            .store(in: &cancellables)
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [preferences] _ in
            LaunchpadSettingsView(preferences: preferences)
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: ShortcutID.toggle,
                title: "打开启动台",
                description: "全局快捷键唤出或收起应用网格。默认未设置，可在此自定义。",
                actionID: ActionID.toggle,
                scope: .global,
                defaultBinding: nil,        // v1 决定：不抢占系统/用户已有热键
                isRequired: false
            )
        ]
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == ControlID.execute else {
            return
        }
        openLaunchpad()
    }

    func handleShortcutAction(id: String) {
        guard id == ActionID.toggle else { return }
        openLaunchpad()
    }

    private func openLaunchpad() {
        overlay.toggle()
    }

    func activate(context: PluginRuntimeContext) {
        // Re-arm the hot corner after a pause/resume cycle. `deactivate` stops the poll;
        // without this, disable→enable would leave the corner "on" in settings but dead
        // (Codex P1). `update` restarts the poll when the saved corner isn't `.off`.
        hotCornerMonitor.update(corner: preferences.hotCorner)
    }

    func deactivate(reason: PluginDeactivationReason) {
        // Always release the internal poll task + overlay window — including `.updating`
        // (hot reload), so a replaced instance never leaves a stale 120ms poll or window
        // behind (Codex P1). These are process-internal resources, not system side effects.
        hotCornerMonitor.stop()
        overlay.close()
    }
}
