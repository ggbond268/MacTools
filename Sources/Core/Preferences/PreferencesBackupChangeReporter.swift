import Foundation

enum PreferencesBackupChangeSource: Hashable, Sendable {
    case application
    case settingsSidebar
    case pluginDisplay
    case shortcuts
    case actionShortcutAssignments
    case actionInvocationPresets
    case automationDefinitions
    case plugin(String)
}

/// Receives only meaningful, successfully persisted changes that contribute
/// to a portable preferences backup. Runtime state, caches, history, and
/// failed or rolled-back writes must never report through this type.
@MainActor
final class PreferencesBackupChangeReporter {
    var onCommittedChange: ((PreferencesBackupChangeSource) -> Void)?

    func didPersist(_ source: PreferencesBackupChangeSource) {
        onCommittedChange?(source)
    }
}
