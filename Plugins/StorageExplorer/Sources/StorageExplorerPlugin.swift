import Foundation
import MacToolsPluginKit
import SwiftUI

public final class StorageExplorerPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        StorageExplorerPluginProvider(context: context)
    }
}

@MainActor
private struct StorageExplorerPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = StorageExplorerController()
        return [
            StorageExplorerPlugin(
                controller: controller,
                localization: localization
            )
        ]
    }
}

@MainActor
public final class StorageExplorerPlugin: MacToolsPlugin, PluginSettingsPresenting {
    public let metadata: PluginMetadata
    public let controller: StorageExplorerController
    public let localization: PluginLocalization

    public var onStateChange: (() -> Void)?
    public var requestPermissionGuidance: ((String) -> Void)?
    public var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    public var requestSettingsPresentation: (() -> Void)?

    public init(
        controller: StorageExplorerController,
        localization: PluginLocalization
    ) {
        self.controller = controller
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "com.mactools.plugin.storage-explorer",
            title: localization.string("metadata.title", defaultValue: "存储空间分析"),
            iconName: "internaldrive",
            iconTint: .blue,
            order: 55,
            defaultDescription: localization.string("metadata.description", defaultValue: "以层级视图直观分析磁盘占用，找出大文件，在审阅确认后移至废纸篓")
        )
    }

    public var settingsPage: PluginSettingsPage? {
        .workspace(
            description: metadata.defaultDescription,
            scrolling: .selfManaged
        ) { [weak self] _ in
            if let self {
                StorageExplorerWorkspaceView(
                    controller: self.controller,
                    localization: self.localization
                )
            }
        }
    }
}
