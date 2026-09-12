import Foundation
import CoreBluetooth

struct JBLHeadphoneAdvertisementReading: Equatable, Sendable {
    let component: DeviceBatteryBluetoothPowerLogComponent
    let level: Int
    let chargeState: DeviceBatteryChargeState
}

struct JBLHeadphoneAdvertisement: Equatable, Sendable {
    let readings: [JBLHeadphoneAdvertisementReading]
}

enum JBLHeadphoneAdvertisementParser {
    private static let jblCompanyIdentifier: [UInt8] = [0x01, 0x00] // JBL的公司ID
    
    static func readings(from manufacturerData: Data) -> [JBLHeadphoneAdvertisementReading] {
        advertisement(from: manufacturerData)?.readings ?? []
    }
    
    static func advertisement(from manufacturerData: Data) -> JBLHeadphoneAdvertisement? {
        let bytes = Array(manufacturerData)
        
        guard bytes.count >= 6,
              bytes.starts(with: jblCompanyIdentifier)
        else {
            return nil
        }
        
        var readings: [JBLHeadphoneAdvertisementReading] = []
        
        if bytes.count >= 10 {
            let leftLevel = Int(bytes[4])
            let rightLevel = Int(bytes[5])
            let caseLevel = Int(bytes[6])
            let chargingFlags = bytes[7]
            
            if leftLevel <= 100 {
                readings.append(JBLHeadphoneAdvertisementReading(
                    component: .left,
                    level: leftLevel,
                    chargeState: chargingFlags & 0x01 != 0 ? .charging : .normal
                ))
            }
            
            if rightLevel <= 100 {
                readings.append(JBLHeadphoneAdvertisementReading(
                    component: .right,
                    level: rightLevel,
                    chargeState: chargingFlags & 0x02 != 0 ? .charging : .normal
                ))
            }
            
            if caseLevel <= 100 {
                readings.append(JBLHeadphoneAdvertisementReading(
                    component: .chargingCase,
                    level: caseLevel,
                    chargeState: chargingFlags & 0x04 != 0 ? .charging : .normal
                ))
            }
        }
        
        guard !readings.isEmpty else {
            return nil
        }
        
        return JBLHeadphoneAdvertisement(readings: readings)
    }
}

enum JBLHeadphoneCatalog {
    static let jblVendorName = "JBL"
    
    static let knownJBLHeadphoneModels: Set<String> = [
        "JBL Tune 770NC",
        "JBL Tune 720BT",
        "JBL Tune 520BT",
        "JBL Tune 510BT",
        "JBL Tune 230NC",
        "JBL Tune 130NC",
        "JBL Tour Pro 2",
        "JBL Tour Pro 3",
        "JBL Live Pro 2",
        "JBL Live Pro+",
        "JBL Live 770NC",
        "JBL Live 670NC",
        "JBL Live 520BT",
        "JBL Quantum",
        "JBL Charge",
        "JBL Flip",
        "JBL Xtreme",
        "JBL Pulse",
        "JBL Clip",
        "JBL Go",
        "JBL Sense Lite"
    ]
    
    static func isJBLHeadphone(name: String?, manufacturer: String?) -> Bool {
        if let manufacturer, manufacturer.localizedCaseInsensitiveContains(jblVendorName) {
            return true
        }
        
        if let name {
            for model in knownJBLHeadphoneModels {
                if name.localizedCaseInsensitiveContains(model) {
                    return true
                }
            }
            if name.localizedCaseInsensitiveContains(jblVendorName) {
                return true
            }
        }
        
        return false
    }
    
    static func supportsSplitBattery(name: String?) -> Bool {
        guard let name else { return false }
        
        let lowercasedName = name.lowercased()
        return lowercasedName.contains("tune 770nc")
            || lowercasedName.contains("tour pro")
            || lowercasedName.contains("live pro")
            || lowercasedName.contains("live 770nc")
            || lowercasedName.contains("live 670nc")
            || lowercasedName.contains("quantum")
            || lowercasedName.contains("sense lite")
    }
}

enum JBLHeadphoneBatteryTopology: Equatable, Sendable {
    case single
    case split
}

enum JBLHeadphoneBatteryService {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevelCharacteristic = CBUUID(string: "2A19")
    
    static func isBatteryService(_ service: CBService) -> Bool {
        service.uuid == batteryService
    }
    
    static func isBatteryLevelCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.uuid == batteryLevelCharacteristic
    }
}

enum JBLHeadphoneSupport {
    static func batteryTopology(for name: String?) -> JBLHeadphoneBatteryTopology {
        if JBLHeadphoneCatalog.supportsSplitBattery(name: name) {
            return .split
        }
        return .single
    }
}
