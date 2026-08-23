import Foundation
import MacToolsPluginKit

@MainActor
final class ClipboardHistorySettingsStore: ObservableObject {
    private enum Key {
        static let isPaused = "collection-paused"
        static let maximumItemCount = "maximum-item-count"
        static let expirationDays = "expiration-days"
        static let maximumItemByteCount = "maximum-item-byte-count"
        static let excludedApplications = "excluded-applications"
        static let didCompleteInitialSetup = "did-complete-initial-setup"
    }

    static let allowedItemCounts = [
        100,
        250,
        500,
        1_000,
        ClipboardHistorySettings.noItemCountLimit,
    ]
    static let allowedItemByteCounts = [
        1 * 1_024 * 1_024,
        5 * 1_024 * 1_024,
        20 * 1_024 * 1_024,
        50 * 1_024 * 1_024,
    ]

    @Published var isPaused: Bool {
        didSet {
            storage.set(isPaused, forKey: Key.isPaused)
            onChange?()
        }
    }

    @Published var maximumItemCount: Int {
        didSet {
            storage.set(Self.validItemCount(maximumItemCount), forKey: Key.maximumItemCount)
            onChange?()
        }
    }

    @Published var expiration: ClipboardHistoryExpiration {
        didSet {
            storage.set(expiration.rawValue, forKey: Key.expirationDays)
            onChange?()
        }
    }

    @Published var maximumItemByteCount: Int {
        didSet {
            storage.set(Self.validItemByteCount(maximumItemByteCount), forKey: Key.maximumItemByteCount)
            onChange?()
        }
    }

    @Published var excludedApplications: [ClipboardExcludedApplication] {
        didSet {
            if let data = try? JSONEncoder().encode(
                Self.normalizedApplications(excludedApplications)
            ) {
                storage.set(data, forKey: Key.excludedApplications)
            }
            onChange?()
        }
    }

    @Published private(set) var hasCompletedInitialSetup: Bool

    var onChange: (() -> Void)?

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
        let defaults = ClipboardHistorySettings.defaults
        isPaused = storage.object(forKey: Key.isPaused) == nil
            ? defaults.isPaused
            : storage.bool(forKey: Key.isPaused)

        let storedItemCount = storage.integer(forKey: Key.maximumItemCount)
        maximumItemCount = Self.validItemCount(
            storedItemCount == 0 ? defaults.maximumItemCount : storedItemCount
        )

        let storedExpiration = storage.integer(forKey: Key.expirationDays)
        expiration = storage.object(forKey: Key.expirationDays) == nil
            ? defaults.expiration
            : ClipboardHistoryExpiration(rawValue: storedExpiration) ?? defaults.expiration

        let storedItemByteCount = storage.integer(forKey: Key.maximumItemByteCount)
        maximumItemByteCount = Self.validItemByteCount(
            storedItemByteCount == 0 ? defaults.maximumItemByteCount : storedItemByteCount
        )

        if let data = storage.data(forKey: Key.excludedApplications),
           let decoded = try? JSONDecoder().decode([ClipboardExcludedApplication].self, from: data) {
            excludedApplications = Self.normalizedApplications(decoded)
        } else {
            excludedApplications = defaults.excludedApplications
        }
        hasCompletedInitialSetup = storage.bool(forKey: Key.didCompleteInitialSetup)
    }

    var snapshot: ClipboardHistorySettings {
        ClipboardHistorySettings(
            isPaused: isPaused,
            maximumItemCount: maximumItemCount,
            expiration: expiration,
            maximumItemByteCount: maximumItemByteCount,
            excludedApplications: excludedApplications
        )
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
    }

    func addExcludedApplications(_ applications: [ClipboardExcludedApplication]) {
        excludedApplications = Self.normalizedApplications(excludedApplications + applications)
    }

    func removeExcludedApplication(bundleIdentifier: String) {
        excludedApplications.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    func completeInitialSetup() {
        guard !hasCompletedInitialSetup else { return }
        hasCompletedInitialSetup = true
        storage.set(true, forKey: Key.didCompleteInitialSetup)
        onChange?()
    }

    private static func validItemCount(_ value: Int) -> Int {
        allowedItemCounts.contains(value) ? value : ClipboardHistorySettings.defaultMaximumItemCount
    }

    private static func validItemByteCount(_ value: Int) -> Int {
        allowedItemByteCounts.contains(value) ? value : ClipboardHistorySettings.defaultMaximumItemByteCount
    }

    private static func normalizedApplications(
        _ applications: [ClipboardExcludedApplication]
    ) -> [ClipboardExcludedApplication] {
        var seen = Set<String>()
        return applications
            .filter { !$0.bundleIdentifier.isEmpty }
            .filter { seen.insert($0.bundleIdentifier.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
