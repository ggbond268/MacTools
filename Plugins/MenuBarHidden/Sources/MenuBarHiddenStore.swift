// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import Foundation
import MacToolsPluginKit

enum MenuBarHiddenPersistenceMutationResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
    case recoveryRequired
}

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
        set { _ = setEnabled(newValue) }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> MenuBarHiddenPersistenceMutationResult {
        let previousRawValue = storage.object(forKey: Key.isEnabled)
        guard previousRawValue == nil || previousRawValue is Bool else {
            return .recoveryRequired
        }
        if let previous = previousRawValue as? Bool, previous == enabled {
            return .committed
        }

        storage.set(enabled, forKey: Key.isEnabled)
        guard storage.object(forKey: Key.isEnabled) as? Bool == enabled else {
            let rollbackSucceeded = restore(previousRawValue, forKey: Key.isEnabled)
            return .rejected(rollbackSucceeded: rollbackSucceeded)
        }
        return .committed
    }

    var isAlwaysHiddenEnabled: Bool {
        get { storage.object(forKey: Key.isAlwaysHiddenEnabled) as? Bool ?? false }
        set { storage.set(newValue, forKey: Key.isAlwaysHiddenEnabled) }
    }

    var showsHiddenIconsInPanel: Bool {
        get { storage.object(forKey: Key.showsHiddenIconsInPanel) as? Bool ?? false }
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

    private func restore(_ value: Any?, forKey key: String) -> Bool {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
        return valuesMatch(storage.object(forKey: key), value)
    }

    private func valuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}
