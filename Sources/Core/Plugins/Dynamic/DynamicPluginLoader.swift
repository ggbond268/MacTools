import Foundation
import MacToolsPluginKit

struct DynamicPluginLoadResult {
    let record: PluginPackageRecord
    let plugins: [any MacToolsPlugin]
    let errorMessage: String?
}

@MainActor
protocol DynamicPluginLoading {
    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult]
}

@MainActor
final class DynamicPluginLoader: DynamicPluginLoading {
    private let packageStore: PluginPackageStore
    private let trustValidator: PluginTrustValidating
    private let quarantineInspector: PluginQuarantineInspecting

    init(
        packageStore: PluginPackageStore,
        trustValidator: PluginTrustValidating = SameTeamPluginTrustValidator(),
        quarantineInspector: PluginQuarantineInspecting = PluginQuarantineInspector()
    ) {
        self.packageStore = packageStore
        self.trustValidator = trustValidator
        self.quarantineInspector = quarantineInspector
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        records.map { record in
            guard case .enabled = record.state else {
                return DynamicPluginLoadResult(record: record, plugins: [], errorMessage: nil)
            }

            do {
                let provider = try PluginInvocationGuard
                    .value(operation: "load provider for \(record.id)") {
                        try loadProvider(for: record)
                    }
                    .get()
                let context = packageStore.runtimeContext(for: record)
                let plugins = try PluginInvocationGuard
                    .value(operation: "make plugins for \(record.id)") {
                        provider.makePlugins()
                    }
                    .get()
                try Self.validateLoadedPlugins(plugins, for: record)

                for plugin in plugins {
                    try PluginInvocationGuard
                        .run(operation: "activate plugin \(plugin.metadata.id)") {
                            plugin.activate(context: context)
                        }
                        .get()
                }

                return DynamicPluginLoadResult(record: record, plugins: plugins, errorMessage: nil)
            } catch {
                return DynamicPluginLoadResult(
                    record: record,
                    plugins: [],
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func loadProvider(for record: PluginPackageRecord) throws -> any PluginProvider {
        try trustValidator.validatePluginBundle(at: record.bundleURL)
        stripLingeringQuarantine(from: record)

        guard let bundle = Bundle(url: record.bundleURL) else {
            throw DynamicPluginLoaderError.unreadableBundle(record.bundleURL)
        }

        guard bundle.load() else {
            throw DynamicPluginLoaderError.loadFailed(record.bundleURL)
        }

        let context = packageStore.runtimeContext(for: record)

        if let className = record.manifest.factoryClass,
           let factoryClass = NSClassFromString(className) as? MacToolsPluginBundleFactory.Type {
            return try factoryClass.makeProvider(context: context)
        }

        guard let factoryClass = bundle.principalClass as? MacToolsPluginBundleFactory.Type else {
            throw DynamicPluginLoaderError.missingFactory(record.manifest.displayName)
        }

        return try factoryClass.makeProvider(context: context)
    }

    // Packages installed before install-time quarantine stripping existed may still carry
    // the attribute, and dlopen of such a bundle fails with an opaque AMFI/Gatekeeper error
    // in a hardened host. Stripping is gated on the trust validation in loadProvider having
    // succeeded right before this call; a failed validation never reaches this point.
    //
    // Best-effort by design: an inspector failure here must not block the load — a
    // non-hardened (Debug) host dlopens quarantined bundles just fine, and on a hardened
    // host dlopen fails exactly as it did before this strip existed, with the warning
    // below explaining why. The strict, user-facing quarantine error belongs to the
    // install path in PluginPackageStore.
    private func stripLingeringQuarantine(from record: PluginPackageRecord) {
        do {
            let quarantinedItems = try quarantineInspector.quarantinedItemURLs(in: record.packageURL)
            guard !quarantinedItems.isEmpty else {
                return
            }

            try quarantineInspector.stripQuarantine(at: record.packageURL)
            AppLog.dynamicPlugins.info(
                "Stripped lingering quarantine from \(quarantinedItems.count, privacy: .public) item(s) in installed package \(record.id, privacy: .public)"
            )
        } catch {
            AppLog.dynamicPlugins.warning(
                "Could not strip lingering quarantine from installed package \(record.id, privacy: .public); a hardened host may refuse to load it: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func validateLoadedPlugins(
        _ plugins: [any MacToolsPlugin],
        for record: PluginPackageRecord
    ) throws {
        guard plugins.count == 1 else {
            throw DynamicPluginLoaderError.invalidPluginCount(
                expected: record.manifest.id,
                actual: plugins.count
            )
        }

        guard let plugin = plugins.first else {
            return
        }

        guard plugin.metadata.id == record.manifest.id else {
            throw DynamicPluginLoaderError.pluginIdentifierMismatch(
                expected: record.manifest.id,
                actual: plugin.metadata.id
            )
        }
    }
}

enum DynamicPluginLoaderError: LocalizedError, Equatable {
    case unreadableBundle(URL)
    case loadFailed(URL)
    case missingFactory(String)
    case invalidPluginCount(expected: String, actual: Int)
    case pluginIdentifierMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableBundle(url):
            return AppL10n.pluginsFormat("plugin.error.loader.unreadableBundleFormat", defaultValue: "无法读取插件 bundle：%@", url.path)
        case let .loadFailed(url):
            return AppL10n.pluginsFormat("plugin.error.loader.loadFailedFormat", defaultValue: "插件代码加载失败：%@", url.path)
        case let .missingFactory(name):
            return AppL10n.pluginsFormat("plugin.error.loader.missingFactoryFormat", defaultValue: "插件缺少入口工厂：%@", name)
        case let .invalidPluginCount(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.loader.invalidPluginCountFormat",
                defaultValue: "插件包 %@ 必须返回 1 个插件，实际返回 %d 个。",
                expected,
                actual
            )
        case let .pluginIdentifierMismatch(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.loader.identifierMismatchFormat",
                defaultValue: "插件 ID 不匹配，manifest 为 %@，运行时代码为 %@。",
                expected,
                actual
            )
        }
    }
}
