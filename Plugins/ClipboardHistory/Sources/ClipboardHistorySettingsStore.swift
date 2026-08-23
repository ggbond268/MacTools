import Foundation
import MacToolsPluginKit

@MainActor
final class ClipboardHistorySettingsStore: ObservableObject {
    private enum Key {
        static let isPaused = "collection-paused"
        static let maximumItemCount = "maximum-item-count"
        static let expirationDays = "expiration-days"
        static let maximumItemByteCount = "maximum-item-byte-count"
        static let maximumTotalPayloadByteCount = "maximum-total-payload-byte-count"
        static let excludedApplications = "excluded-applications"
        static let didCompleteInitialSetup = "did-complete-initial-setup"
        static let didPresentInitialSetup = "did-present-initial-setup"
    }

    static let allowedItemCounts = [
        100,
        250,
        500,
        1_000,
        2_500,
        5_000,
        ClipboardHistorySettings.maximumSupportedItemCount,
    ]
    static let allowedItemByteCounts = [
        1 * 1_024 * 1_024,
        5 * 1_024 * 1_024,
        20 * 1_024 * 1_024,
        50 * 1_024 * 1_024,
    ]
    static let allowedTotalPayloadByteCounts = [
        64 * 1_024 * 1_024,
        256 * 1_024 * 1_024,
        1 * 1_024 * 1_024 * 1_024,
        ClipboardHistorySettings.maximumSupportedTotalPayloadByteCount,
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

    @Published var maximumTotalPayloadByteCount: Int {
        didSet {
            storage.set(
                Self.validTotalPayloadByteCount(maximumTotalPayloadByteCount),
                forKey: Key.maximumTotalPayloadByteCount
            )
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
    private(set) var hasPresentedInitialSetup: Bool

    var onChange: (() -> Void)?

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
        let defaults = ClipboardHistorySettings.defaults
        let completedInitialSetup = storage.bool(forKey: Key.didCompleteInitialSetup)
        // Collection is privacy-sensitive on a new installation. Existing installations retain
        // their persisted pause value, while a completed setup without that legacy key remains on.
        isPaused = storage.object(forKey: Key.isPaused) == nil
            ? !completedInitialSetup
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

        let storedTotalPayloadByteCount = storage.integer(forKey: Key.maximumTotalPayloadByteCount)
        maximumTotalPayloadByteCount = Self.validTotalPayloadByteCount(
            storedTotalPayloadByteCount == 0
                ? defaults.maximumTotalPayloadByteCount
                : storedTotalPayloadByteCount
        )

        if let data = storage.data(forKey: Key.excludedApplications),
           let decoded = try? JSONDecoder().decode([ClipboardExcludedApplication].self, from: data) {
            excludedApplications = Self.normalizedApplications(decoded)
        } else {
            excludedApplications = defaults.excludedApplications
        }
        hasCompletedInitialSetup = completedInitialSetup
        hasPresentedInitialSetup = storage.bool(forKey: Key.didPresentInitialSetup)
    }

    var snapshot: ClipboardHistorySettings {
        ClipboardHistorySettings(
            isPaused: isPaused,
            maximumItemCount: maximumItemCount,
            expiration: expiration,
            maximumItemByteCount: maximumItemByteCount,
            maximumTotalPayloadByteCount: maximumTotalPayloadByteCount,
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

    func shouldAutomaticallyPresentInitialSetup() -> Bool {
        guard !hasCompletedInitialSetup, !hasPresentedInitialSetup else {
            return false
        }
        hasPresentedInitialSetup = true
        storage.set(true, forKey: Key.didPresentInitialSetup)
        return true
    }

    private static func validItemCount(_ value: Int) -> Int {
        if value == ClipboardHistorySettings.noItemCountLimit {
            return ClipboardHistorySettings.maximumSupportedItemCount
        }
        return allowedItemCounts.contains(value)
            ? value
            : ClipboardHistorySettings.defaultMaximumItemCount
    }

    private static func validItemByteCount(_ value: Int) -> Int {
        allowedItemByteCounts.contains(value) ? value : ClipboardHistorySettings.defaultMaximumItemByteCount
    }

    private static func validTotalPayloadByteCount(_ value: Int) -> Int {
        allowedTotalPayloadByteCounts.contains(value)
            ? value
            : ClipboardHistorySettings.defaultMaximumTotalPayloadByteCount
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
