import Foundation
import MacToolsPluginKit

@MainActor
final class MenuBarHiddenStore {
    private enum Key {
        static let isEnabled = "is-enabled"
        static let isAlwaysHiddenEnabled = "is-always-hidden-enabled"
        static let showsHiddenIconsInPanel = "shows-hidden-icons-in-panel"
        static let visibleItemStableKeys = "visible-item-stable-keys"
        static let hiddenItemStableKeys = "hidden-item-stable-keys"
        static let alwaysHiddenItemStableKeys = "always-hidden-item-stable-keys"
    }

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
    }

    var isEnabled: Bool {
        get { storage.object(forKey: Key.isEnabled) as? Bool ?? false }
        set { storage.set(newValue, forKey: Key.isEnabled) }
    }

    var isAlwaysHiddenEnabled: Bool {
        get { storage.object(forKey: Key.isAlwaysHiddenEnabled) as? Bool ?? false }
        set { storage.set(newValue, forKey: Key.isAlwaysHiddenEnabled) }
    }

    var showsHiddenIconsInPanel: Bool {
        get { storage.object(forKey: Key.showsHiddenIconsInPanel) as? Bool ?? true }
        set { storage.set(newValue, forKey: Key.showsHiddenIconsInPanel) }
    }

    var hasVisibleHiddenLayout: Bool {
        storage.object(forKey: Key.visibleItemStableKeys) != nil
            || storage.object(forKey: Key.hiddenItemStableKeys) != nil
    }

    var visibleItemStableKeys: [String] {
        get {
            normalizedStableKeys(storage.stringArray(forKey: Key.visibleItemStableKeys) ?? [])
        }
        set {
            storage.set(normalizedStableKeys(newValue), forKey: Key.visibleItemStableKeys)
        }
    }

    var hiddenItemStableKeys: [String] {
        get {
            normalizedStableKeys(storage.stringArray(forKey: Key.hiddenItemStableKeys) ?? [])
        }
        set {
            storage.set(normalizedStableKeys(newValue), forKey: Key.hiddenItemStableKeys)
        }
    }

    var alwaysHiddenItemStableKeys: Set<String> {
        get {
            Set(storage.stringArray(forKey: Key.alwaysHiddenItemStableKeys) ?? [])
        }
        set {
            let keys = newValue.sorted()
            if keys.isEmpty {
                storage.removeObject(forKey: Key.alwaysHiddenItemStableKeys)
            } else {
                storage.set(keys, forKey: Key.alwaysHiddenItemStableKeys)
            }
        }
    }

    func recordVisibleHiddenLayout(visibleKeys: [String], hiddenKeys: [String]) {
        let visible = normalizedStableKeys(visibleKeys)
        let hidden = normalizedStableKeys(hiddenKeys.filter { !visible.contains($0) })
        storage.set(visible, forKey: Key.visibleItemStableKeys)
        storage.set(hidden, forKey: Key.hiddenItemStableKeys)
    }

    func recordAlwaysHiddenItem(_ tag: MenuBarItemTag) {
        var keys = alwaysHiddenItemStableKeys
        guard keys.insert(tag.stableKey).inserted else { return }
        alwaysHiddenItemStableKeys = keys
    }

    func removeAlwaysHiddenItem(_ tag: MenuBarItemTag) {
        var keys = alwaysHiddenItemStableKeys
        guard keys.remove(tag.stableKey) != nil else { return }
        alwaysHiddenItemStableKeys = keys
    }

    private func normalizedStableKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys where !key.isEmpty {
            guard seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }
}
