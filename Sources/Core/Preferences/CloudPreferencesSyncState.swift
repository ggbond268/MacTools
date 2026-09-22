import Foundation

enum CloudPreferencesConflictChoice {
    case local
    case shared
}

struct CloudPreferencesConflict: Codable, Sendable {
    var local: PreferencesBackup
    let shared: CloudPreferencesSnapshot
}

/// Stored per folder. Local preferences are durable independently of the shared file.
/// The two baselines can differ because imports preserve device-local dependencies.
struct CloudPreferencesSyncState: Codable {
    var shared: CloudPreferencesSnapshot?
    var localBaseline: PreferencesBackup?
    var pending: PreferencesBackup?
    var conflict: CloudPreferencesConflict?
    var lastResolvedConflict: CloudPreferencesConflict?
    var needsPublication = false
}

enum CloudPreferencesSyncError: LocalizedError, Equatable {
    case snapshotMissing
    case sharedFileChanged

    var errorDescription: String? {
        switch self {
        case .snapshotMissing:
            AppL10n.preferencesBackup(
                "preferencesBackup.cloudSync.status.snapshotMissing",
                defaultValue: "共享文件暂不可用。请检查云盘后重试；本机设置已保留。"
            )
        case .sharedFileChanged:
            AppL10n.preferencesBackup(
                "preferencesBackup.cloudSync.error.sharedFileChanged",
                defaultValue: "共享设置仍在更改。请稍后重试；本机设置已保留。"
            )
        }
    }
}

/// Invalidate queued disk work when changing folders, disabling sync, or quitting.
final class CloudPreferencesSyncSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
