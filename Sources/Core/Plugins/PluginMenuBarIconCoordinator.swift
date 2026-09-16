import AppKit
import Foundation
import MacToolsPluginKit

/// Owns the exclusive primary-icon slot, not any NSStatusItem or plugin business data.
@MainActor
final class PluginMenuBarIconCoordinator {
    struct Reference: Codable, Equatable {
        let pluginID: String
        let iconID: String
    }

    private struct Registration {
        weak var plugin: (any MacToolsPlugin)?
        let token: UUID
        let iconIDs: Set<String>
    }

    private struct CachedSnapshot {
        let reference: Reference
        let token: UUID
        let context: PluginMenuBarIconRenderContext
        let snapshot: PluginMenuBarIconSnapshot
    }

    static let preferenceKey = "menuBar.primaryIconOwner.v1"
    private let userDefaults: UserDefaults
    private let updateDelay: Duration
    private var registrations: [String: Registration] = [:]
    private var selected: Reference?
    private var cache: CachedSnapshot?
    private var updateTask: Task<Void, Never>?
    private var isChangingPlacement = false
    private var renderContext = PluginMenuBarIconRenderContext(
        pointSize: CGSize(width: 24, height: 24), displayScale: 2, appearance: .light
    )

    /// The App renderer subscribes here; icon ticks never rebuild PluginHost's derived state.
    var onPrimaryIconChange: (() -> Void)?

    init(userDefaults: UserDefaults, updateDelay: Duration = .milliseconds(150)) {
        self.userDefaults = userDefaults
        self.updateDelay = updateDelay
        if let data = userDefaults.data(forKey: Self.preferenceKey) {
            selected = try? JSONDecoder().decode(Reference.self, from: data)
        }
    }

    isolated deinit { updateTask?.cancel() }

    var primaryIconOwner: PluginMenuBarIconOwner? {
        selected.map { reference in
            PluginMenuBarIconOwner(
                pluginID: reference.pluginID,
                iconID: reference.iconID,
                pluginTitle: registrations[reference.pluginID]?.plugin?.metadata.title ?? reference.pluginID
            )
        }
    }

    var primaryIconGeneration: UUID? {
        selected.flatMap { registrations[$0.pluginID]?.token }
    }

    /// A nil pending set means initial dynamic discovery has not finished yet.
    func synchronize(with plugins: [any MacToolsPlugin], pendingPluginIDs: Set<String>?) {
        let instances = Set(plugins.map(ObjectIdentifier.init))
        for (id, registration) in registrations {
            if registration.plugin.map({ !instances.contains(ObjectIdentifier($0)) }) ?? true {
                unregister(pluginID: id, reason: plugins.contains { $0.metadata.id == id } ? .updating : .disabled)
            }
        }
        for plugin in plugins { register(plugin) }
        if let selected, let pendingPluginIDs,
           registrations[selected.pluginID]?.iconIDs.contains(selected.iconID) != true,
           !pendingPluginIDs.contains(selected.pluginID) {
            setSelection(nil)
        }
    }

    func unregister(pluginID: String, reason: PluginDeactivationReason) {
        let removed = registrations.removeValue(forKey: pluginID)
        (removed?.plugin as? any PluginMenuBarIconProviding)?.onMenuBarIconChange = nil
        // Revoke capabilities before calling plugin teardown, including a retained old context.
        defer {
            _ = PluginInvocationGuard.run(operation: "revoke menu-bar icon context") {
                (removed?.plugin as? any PluginMenuBarIconHostContextConsuming)?.menuBarIconHostContext = nil
            }
        }
        guard selected?.pluginID == pluginID else { return }
        switch reason {
        case .updating, .hostShutdown:
            invalidatePrimaryIcon()
            notifyPlacements()
        case .disabled, .uninstalling:
            setSelection(nil)
        }
    }

    func deactivateAll(reason: PluginDeactivationReason) {
        for id in Array(registrations.keys) { unregister(pluginID: id, reason: reason) }
        if reason != .hostShutdown, reason != .updating { setSelection(nil) }
    }

    func snapshot(context: PluginMenuBarIconRenderContext) -> PluginMenuBarIconSnapshot? {
        renderContext = context
        guard let selected, let registration = registrations[selected.pluginID] else { return nil }
        return snapshot(for: selected, registration: registration, context: context)
    }

    private func register(_ plugin: any MacToolsPlugin) {
        let id = plugin.metadata.id
        guard registrations[id]?.plugin !== plugin,
              let provider = plugin as? any PluginMenuBarIconProviding,
              let consumer = plugin as? any PluginMenuBarIconHostContextConsuming else { return }
        let descriptors = (try? PluginInvocationGuard.value(operation: "read menu-bar icon descriptors") {
            provider.menuBarIconDescriptors
        }.get()) ?? []
        let ids = Set(descriptors.map(\.id))
        guard !ids.isEmpty, ids.count == descriptors.count,
              ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil })
        else { return }
        let token = UUID()
        registrations[id] = Registration(plugin: plugin, token: token, iconIDs: ids)
        provider.onMenuBarIconChange = { [weak self] iconID in
            self?.iconDidChange(pluginID: id, iconID: iconID, token: token)
        }
        let context = PluginMenuBarIconHostContext(
            placement: { [weak self] iconID in
                guard let self, self.registrations[id]?.token == token else { return .standalone }
                return self.selected == Reference(pluginID: id, iconID: iconID) ? .primary : .standalone
            },
            primaryIconOwner: { [weak self] in
                guard let self, self.registrations[id]?.token == token else { return nil }
                return self.primaryIconOwner
            },
            requestPlacement: { [weak self] placement, iconID in
                self?.requestPlacement(placement, pluginID: id, iconID: iconID, token: token)
                    ?? .failure(.unavailable)
            }
        )
        if case .failure = PluginInvocationGuard.run(operation: "install menu-bar icon context", {
            consumer.menuBarIconHostContext = context
        }) {
            unregister(pluginID: id, reason: .disabled)
            return
        }
        if selected?.pluginID == id { invalidatePrimaryIcon() }
    }

    private func requestPlacement(
        _ placement: PluginMenuBarIconPlacement,
        pluginID: String,
        iconID: String,
        token: UUID
    ) -> Result<Void, PluginMenuBarIconPlacementError> {
        guard !isChangingPlacement else { return .failure(.unavailable) }
        isChangingPlacement = true
        defer { isChangingPlacement = false }
        guard let registration = registrations[pluginID], registration.token == token,
              registration.iconIDs.contains(iconID) else { return .failure(.unavailable) }
        let reference = Reference(pluginID: pluginID, iconID: iconID)
        if placement == .standalone {
            if selected == reference { setSelection(nil) }
            return .success(())
        }
        if selected == reference { return .success(()) }
        if let owner = primaryIconOwner { return .failure(.occupied(owner: owner)) }
        guard snapshot(for: reference, registration: registration, context: renderContext) != nil else {
            return .failure(.invalidIcon)
        }
        // Commit the claim atomically on MainActor; no suspension between checking and claiming.
        setSelection(reference)
        return .success(())
    }

    private func setSelection(_ reference: Reference?) {
        guard selected != reference else { return }
        selected = reference
        if let reference, let data = try? JSONEncoder().encode(reference) {
            userDefaults.set(data, forKey: Self.preferenceKey)
        } else {
            userDefaults.removeObject(forKey: Self.preferenceKey)
        }
        // Render the primary/fallback frame before a provider removes its standalone item.
        invalidatePrimaryIcon()
        notifyPlacements()
    }

    private func notifyPlacements() {
        let consumers = registrations.values.compactMap {
            $0.plugin as? any PluginMenuBarIconHostContextConsuming
        }
        for consumer in consumers {
            _ = PluginInvocationGuard.run(operation: "notify menu-bar icon placement") {
                consumer.menuBarIconPlacementDidChange()
            }
        }
    }

    private func invalidatePrimaryIcon() {
        updateTask?.cancel()
        updateTask = nil
        cache = nil
        onPrimaryIconChange?()
    }

    private func iconDidChange(pluginID: String, iconID: String, token: UUID) {
        guard registrations[pluginID]?.token == token,
              selected == Reference(pluginID: pluginID, iconID: iconID) else { return }
        cache = nil
        guard updateTask == nil else { return }
        let delay = updateDelay
        updateTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.registrations[pluginID]?.token == token else { return }
            self.updateTask = nil
            self.onPrimaryIconChange?()
        }
    }

    private func snapshot(
        for reference: Reference,
        registration: Registration,
        context: PluginMenuBarIconRenderContext
    ) -> PluginMenuBarIconSnapshot? {
        if let cache, cache.reference == reference, cache.token == registration.token, cache.context == context {
            return cache.snapshot
        }
        guard registration.iconIDs.contains(reference.iconID),
              let provider = registration.plugin as? any PluginMenuBarIconProviding else { return nil }
        let result = PluginInvocationGuard.value(operation: "render menu-bar icon") {
            provider.menuBarIcon(for: reference.iconID, context: context)
        }
        guard case let .success(snapshot?) = result,
              Self.isValid(snapshot.image) else { return nil }
        cache = CachedSnapshot(reference: reference, token: registration.token, context: context, snapshot: snapshot)
        return snapshot
    }

    private static func isValid(_ image: NSImage) -> Bool {
        image.size.width.isFinite && image.size.height.isFinite
            && image.size.width > 0 && image.size.height > 0
            && image.size.width <= 128 && image.size.height <= 128
            && image.isValid
    }
}
