import Foundation

/// A narrow bridge for plugins that compose canonical actions owned by other plugins.
/// Execution still passes through the host action registry, availability checks, safety policy,
/// confirmation service, and the original provider's implementation.
public enum PluginActionHostExecutionResult: Equatable, Sendable {
    case succeeded(message: String?)
    case failed(message: String)
    case cancelled
    case unavailable(reason: String)
}

@MainActor
public struct PluginActionExecutionHostContext {
    private let itemHandler: (ActionReference) -> ActionSurfaceCatalogItem?
    private let executionHandler: (ActionReference, ActionExecutionSource) async -> PluginActionHostExecutionResult
    private let providerSettingsHandler: (String) -> Void

    public init(
        item: @escaping (ActionReference) -> ActionSurfaceCatalogItem?,
        execute: @escaping (
            ActionReference,
            ActionExecutionSource
        ) async -> PluginActionHostExecutionResult
    ) {
        self.init(item: item, execute: execute, openProviderSettings: { _ in })
    }

    public init(
        item: @escaping (ActionReference) -> ActionSurfaceCatalogItem?,
        execute: @escaping (ActionReference, ActionExecutionSource) async -> PluginActionHostExecutionResult,
        openProviderSettings: @escaping (String) -> Void
    ) {
        self.itemHandler = item
        self.executionHandler = execute
        self.providerSettingsHandler = openProviderSettings
    }

    public func item(for reference: ActionReference) -> ActionSurfaceCatalogItem? {
        itemHandler(reference)
    }

    /// Explicit user navigation to an installed provider or its installation/enablement surface.
    public func openProviderSettings(providerID: String) {
        providerSettingsHandler(providerID)
    }

    public func execute(
        _ reference: ActionReference,
        source: ActionExecutionSource = .manual
    ) async -> PluginActionHostExecutionResult {
        await executionHandler(reference, source)
    }
}

/// Optional companion contract for a plugin that deliberately composes actions from other
/// providers. Keeping the bridge separate preserves the MacToolsPlugin witness table.
@MainActor
public protocol PluginActionExecutionHostContextConsuming: AnyObject {
    var actionExecutionHostContext: PluginActionExecutionHostContext? { get set }
    func actionExecutionCatalogDidChange()
}

public extension PluginActionExecutionHostContextConsuming {
    func actionExecutionCatalogDidChange() {}
}
