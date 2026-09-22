import Foundation

/// Parser for JBL Sense Lite (and compatible) earbuds battery levels
/// using the proprietary ExcelPoint BLE GATT service.
///
/// Protocol discovered via BLE reverse engineering:
/// - Service UUID: 65786365-6C70-6F69-6E74-2E636F6D0000 ("excelpoint.com")
/// - RX (notify): 65786365-6C70-6F69-6E74-2E636F6D0001
/// - TX (write):  65786365-6C70-6F69-6E74-2E636F6D0002
///
/// Notification packet structure (confirmed via multiple samples):
/// ┌─────────────────────────────────────────────────────────────┐
/// │ Header: 00 DD 03 00 01 00 [len] 00 00 00                   │
/// ├─────────────────────────────────────────────────────────────┤
/// │ Feature 0x0D: 0D 00 01 00 [left_battery]    (0~100%)       │
/// │ Feature 0x0E: 0E 00 01 00 [right_battery]   (0~100%)       │
/// │ Feature 0x1F: 03 1F 01 00 [case_battery]    (0~100%)       │
/// │ Feature 0x34: 34 00 01 00 [status]          (unknown)      │
/// ├─────────────────────────────────────────────────────────────┤
/// │ Footer: 01 1F 03 00 19 0A 0A                               │
/// └─────────────────────────────────────────────────────────────┘
enum JBLSenseLiteBLEBatteryParser {

    // MARK: - Service UUIDs

    /// ExcelPoint service UUID ("excelpoint.com")
    static let excelPointServiceUUID = "65786365-6C70-6F69-6E74-2E636F6D0000"

    /// RX characteristic (notifications from device)
    static let rxCharacteristicUUID = "65786365-6C70-6F69-6E74-2E636F6D0001"

    /// TX characteristic (commands to device)
    static let txCharacteristicUUID = "65786365-6C70-6F69-6E74-2E636F6D0002"

    // MARK: - Feature IDs

    private static let leftBatteryFeatureID: UInt8 = 0x0D
    private static let rightBatteryFeatureID: UInt8 = 0x0E
    private static let caseBatteryFeatureID: UInt8 = 0x03
    private static let statusFeatureID: UInt8 = 0x34

    // MARK: - Battery Reading

    struct BatteryReading: Equatable, Sendable {
        let leftBattery: Int?
        let rightBattery: Int?
        let caseBattery: Int?
        let isValid: Bool

        static let empty = BatteryReading(
            leftBattery: nil,
            rightBattery: nil,
            caseBattery: nil,
            isValid: false
        )
    }

    // MARK: - Parsing

    /// Parse a JBL ExcelPoint notification packet to extract battery levels.
    /// - Parameter data: Raw notification data from RX characteristic
    /// - Returns: Parsed battery reading, or nil if data is invalid
    static func parseBatteryNotification(_ data: Data) -> BatteryReading? {
        guard data.count >= 10 else { return nil }

        // Verify header: 00 DD 03 00 01 00
        let header: [UInt8] = [0x00, 0xDD, 0x03, 0x00, 0x01, 0x00]
        guard data.prefix(6).elementsEqual(header) else { return nil }

        let bytes = [UInt8](data)
        var leftBattery: Int?
        var rightBattery: Int?
        var caseBattery: Int?

        // Scan for feature patterns: [ID] 00 01 00 [level]
        var i = 6 // Skip header
        while i + 4 < bytes.count {
            // Left battery: 0D 00 01 00 [level]
            if bytes[i] == leftBatteryFeatureID,
               bytes[i + 1] == 0x00,
               bytes[i + 2] == 0x01,
               bytes[i + 3] == 0x00 {
                let level = Int(bytes[i + 4])
                if (0...100).contains(level) {
                    leftBattery = level
                }
                i += 5
                continue
            }

            // Right battery: 0E 00 01 00 [level]
            if bytes[i] == rightBatteryFeatureID,
               bytes[i + 1] == 0x00,
               bytes[i + 2] == 0x01,
               bytes[i + 3] == 0x00 {
                let level = Int(bytes[i + 4])
                if (0...100).contains(level) {
                    rightBattery = level
                }
                i += 5
                continue
            }

            // Case battery: 03 1F 01 00 [level]
            if bytes[i] == caseBatteryFeatureID,
               bytes[i + 1] == 0x1F,
               bytes[i + 2] == 0x01,
               bytes[i + 3] == 0x00 {
                let level = Int(bytes[i + 4])
                if (0...100).contains(level) {
                    caseBattery = level
                }
                i += 5
                continue
            }

            i += 1
        }

        // At least one battery level must be present and valid
        guard leftBattery != nil || rightBattery != nil || caseBattery != nil else {
            return nil
        }

        return BatteryReading(
            leftBattery: leftBattery,
            rightBattery: rightBattery,
            caseBattery: caseBattery,
            isValid: true
        )
    }

    /// Check if a device name matches JBL earbuds pattern.
    static func isJBLEarbuds(_ name: String) -> Bool {
        name.lowercased().hasPrefix("jbl")
    }
}
