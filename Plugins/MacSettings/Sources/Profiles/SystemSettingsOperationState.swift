import Foundation

enum SystemSettingsOperationState: Equatable {
    case idle
    case preparing
    case applying
    case restoring
}

enum SystemSettingOperationPhase: String, Equatable {
    case reading
    case applying
    case verifying
    case restoring

    var title: String {
        switch self {
        case .reading: MacSettingsStrings.text("Reading")
        case .applying: MacSettingsStrings.text("Applying")
        case .verifying: MacSettingsStrings.text("Verifying")
        case .restoring: MacSettingsStrings.text("Restoring")
        }
    }
}

enum SystemSettingsProgressEvent {
    case phase(SystemSettingID, SystemSettingOperationPhase)
    case finished(SystemSettingsProfileApplyResult)
}

struct SystemSettingsOperationProgress {
    let total: Int
    var results: [SystemSettingsProfileApplyResult] = []
    var activeSettingID: SystemSettingID?
    var phase: SystemSettingOperationPhase?
    var completed: Int { results.count }
}

struct SystemSettingRecovery: Codable, Equatable, Identifiable {
    let settingID: SystemSettingID
    let original: SystemSettingSnapshot
    var current: SystemSettingSnapshot?
    var message: String

    var id: SystemSettingID { settingID }

    /// Local-only details: custom paths and raw device preferences never enter portable backups.
    var differences: [String] {
        guard let current else { return [MacSettingsStrings.text("The current state could not be read. The original snapshot has been retained.")] }
        let before = original.recoveryFields
        let after = current.recoveryFields
        return Set(before.keys).union(after.keys).sorted().compactMap { key in
            guard before[key] != after[key] else { return nil }
            return MacSettingsStrings.format("%@: %@ (original: %@)", "\(key)", "\(after[key] ?? MacSettingsStrings.text("Unknown"))", "\(before[key] ?? MacSettingsStrings.text("Unknown"))")
        }
    }
}

private extension SystemSettingSnapshot {
    var recoveryFields: [String: String] {
        if let components {
            return components.reduce(into: [:]) { result, component in
                let name: String = switch component.key {
                case "persisted": MacSettingsStrings.text("Device Preferences")
                case "live": MacSettingsStrings.text("Live State")
                case "0": MacSettingsStrings.text("Built-in Trackpad")
                case "1": MacSettingsStrings.text("Bluetooth Trackpad")
                default: component.key
                }
                for (key, value) in component.value.recoveryFields {
                    result[key == MacSettingsStrings.text("Value") ? name : "\(name) · \(key)"] = value
                }
            }
        }
        if let restoration {
            return restoration.mapValues {
                switch $0 {
                case .missing: MacSettingsStrings.text("Not Set")
                case let .boolean(value): value ? MacSettingsStrings.text("On") : MacSettingsStrings.text("Off")
                case let .integer(value): String(value)
                case let .string(value): value
                }
            }
        }
        return [MacSettingsStrings.text("Value"): value.conciseDescription]
    }
}
