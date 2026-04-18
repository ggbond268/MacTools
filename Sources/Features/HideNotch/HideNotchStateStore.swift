import Foundation

@MainActor
final class HideNotchStateStore: HideNotchStateStoring {
    private enum DefaultsKey {
        static let desiredEnabled = "hide-notch.enabled"
    }

    private let userDefaults: UserDefaults
    private let obsoleteKeys = [
        "feature.hideNotchManagedWallpapers",
        "feature.hideNotchEnabled",
        "hide-notch.original-wallpaper-states",
        "hide-notch.managed-space-states"
    ]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        removeObsoleteStateIfNeeded()
    }

    var desiredEnabled: Bool {
        get { userDefaults.bool(forKey: DefaultsKey.desiredEnabled) }
        set { userDefaults.set(newValue, forKey: DefaultsKey.desiredEnabled) }
    }

    private func removeObsoleteStateIfNeeded() {
        for key in obsoleteKeys where userDefaults.object(forKey: key) != nil {
            userDefaults.removeObject(forKey: key)
        }
    }
}
