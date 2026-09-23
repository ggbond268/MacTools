import CoreGraphics
import Foundation
import OSLog

@MainActor
final class UserDefaultsDisplayDisableStateStore: DisplayDisableStateStoring {
    private enum Constants {
        static let key = "DisplayBrightness.DisplayDisableRecords"
        static let legacySnapshotKey = "DisplayBrightness.DisplayDisableRecoverySnapshot"
    }

    /// The single built-in snapshot written before any display could be switched off.
    private struct LegacyRecoverySnapshot: Decodable {
        let createdAt: Date
        let builtInDisplayID: CGDirectDisplayID
        let vendorNumber: UInt32?
        let modelNumber: UInt32?
        let serialNumber: UInt32?
        let survivorDisplayIDs: [CGDirectDisplayID]
        let survivorIdentities: [DisplaySurvivorIdentity]?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DisplayDisableStateStore"
    )
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        migrateLegacySnapshotIfNeeded()
    }

    var records: [DisplayDisableRecord] {
        get {
            guard let data = userDefaults.data(forKey: Constants.key) else {
                return []
            }

            do {
                return try JSONDecoder().decode([DisplayDisableRecord].self, from: data)
            } catch {
                logger.error("failed to decode display disable records: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
        set {
            guard !newValue.isEmpty else {
                userDefaults.removeObject(forKey: Constants.key)
                return
            }

            do {
                let data = try JSONEncoder().encode(newValue)
                userDefaults.set(data, forKey: Constants.key)
            } catch {
                logger.error("failed to encode display disable records: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func migrateLegacySnapshotIfNeeded() {
        guard let data = userDefaults.data(forKey: Constants.legacySnapshotKey) else {
            return
        }
        userDefaults.removeObject(forKey: Constants.legacySnapshotKey)

        guard userDefaults.data(forKey: Constants.key) == nil,
              let legacy = try? JSONDecoder().decode(LegacyRecoverySnapshot.self, from: data)
        else {
            return
        }

        let survivors = legacy.survivorIdentities ?? legacy.survivorDisplayIDs.map {
            DisplaySurvivorIdentity(id: $0, vendorNumber: nil, modelNumber: nil, serialNumber: nil)
        }
        records = [
            DisplayDisableRecord(
                createdAt: legacy.createdAt,
                displayID: legacy.builtInDisplayID,
                name: DisplayBrightnessLocalization.string(
                    "displayDisable.builtInName",
                    defaultValue: "内建显示屏"
                ),
                isBuiltin: true,
                vendorNumber: legacy.vendorNumber,
                modelNumber: legacy.modelNumber,
                serialNumber: legacy.serialNumber,
                survivorIdentities: survivors
            )
        ]
    }
}
