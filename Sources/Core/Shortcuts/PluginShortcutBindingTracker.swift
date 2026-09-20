import MacToolsPluginKit

/// Tracks notifications, not registration health or action availability.
/// Weak identity distinguishes replacement instances without retaining a plugin.
@MainActor
final class PluginShortcutBindingTracker {
    private struct Delivery {
        weak var plugin: (any MacToolsPlugin)?
        let binding: ShortcutBinding?
    }

    private var deliveries: [String: Delivery] = [:]

    func shouldDeliver(
        to plugin: any MacToolsPlugin,
        shortcutID: String,
        binding: ShortcutBinding?,
        force: Bool = false
    ) -> Bool {
        if !force, let previous = deliveries[shortcutID],
           previous.plugin === plugin, previous.binding == binding {
            return false
        }
        // Record before entering plugin code, which can notify the host again.
        // A stored nil is different from never having delivered this shortcut.
        deliveries[shortcutID] = Delivery(plugin: plugin, binding: binding)
        return true
    }

    func retain(shortcutIDs: Set<String>) {
        deliveries = deliveries.filter { shortcutIDs.contains($0.key) && $0.value.plugin != nil }
    }
}
