import Foundation

enum CloudPreferencesSyncStatus: Equatable, Sendable {
    case offline(reason: OfflineReason)
    case syncing
    case synced(lastSyncedAt: Date?)
    case error(message: String)

    enum OfflineReason: Equatable, Sendable {
        case disabled
        case folderNotConfigured
        case folderNotFound
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var isSynced: Bool {
        if case .synced = self { return true }
        return false
    }

    var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    var lastSyncedDate: Date? {
        if case let .synced(date) = self { return date }
        return nil
    }

    var errorMessage: String? {
        if case let .error(message) = self { return message }
        return nil
    }
}
