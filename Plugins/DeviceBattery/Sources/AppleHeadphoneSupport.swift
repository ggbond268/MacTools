import Foundation

struct DeviceBatteryAppleHeadphoneAdvertisementReading: Equatable, Sendable {
    let component: DeviceBatteryBluetoothPowerLogComponent
    let level: Int
    let chargeState: DeviceBatteryChargeState
}

struct DeviceBatteryAppleHeadphoneAdvertisement: Equatable, Sendable {
    let productID: Int
    let readings: [DeviceBatteryAppleHeadphoneAdvertisementReading]
}

enum DeviceBatteryAppleHeadphoneAdvertisementParser {
    private static let appleCompanyIdentifier: [UInt8] = [0x4C, 0x00]
    private static let proximityPairingMessage: UInt8 = 0x07
    private static let proximityPairingLength: UInt8 = 0x19
    private static let pairedDevicePrefix: UInt8 = 0x01
    private static let expectedByteCount = 29
    private static let rightEarFirstMask: UInt8 = 0x20
    private static let lowNibbleBatteryChargingMask: UInt8 = 0x01
    private static let highNibbleBatteryChargingMask: UInt8 = 0x02
    private static let caseChargingMask: UInt8 = 0x04

    static func readings(from manufacturerData: Data) -> [DeviceBatteryAppleHeadphoneAdvertisementReading] {
        advertisement(from: manufacturerData)?.readings ?? []
    }

    static func advertisement(from manufacturerData: Data) -> DeviceBatteryAppleHeadphoneAdvertisement? {
        let bytes = Array(manufacturerData)
        guard bytes.count == expectedByteCount,
              bytes.starts(with: appleCompanyIdentifier),
              bytes[2] == proximityPairingMessage,
              bytes[3] == proximityPairingLength,
              bytes[4] == pairedDevicePrefix
        else {
            return nil
        }

        let productID = Int(bytes[6]) << 8 | Int(bytes[5])
        let rightEarIsStoredFirst = bytes[7] & rightEarFirstMask != 0
        let firstStoredLevel = bytes[8] >> 4
        let secondStoredLevel = bytes[8] & 0x0F
        let caseLevel = bytes[9] & 0x0F
        let chargingFlags = bytes[9] >> 4

        let leftLevel = rightEarIsStoredFirst ? secondStoredLevel : firstStoredLevel
        let rightLevel = rightEarIsStoredFirst ? firstStoredLevel : secondStoredLevel
        let leftChargingMask = rightEarIsStoredFirst
            ? lowNibbleBatteryChargingMask
            : highNibbleBatteryChargingMask
        let rightChargingMask = rightEarIsStoredFirst
            ? highNibbleBatteryChargingMask
            : lowNibbleBatteryChargingMask

        let readings = [
            decode(
                caseLevel,
                component: .chargingCase,
                isCharging: chargingFlags & caseChargingMask != 0
            ),
            decode(
                leftLevel,
                component: .left,
                isCharging: chargingFlags & leftChargingMask != 0
            ),
            decode(
                rightLevel,
                component: .right,
                isCharging: chargingFlags & rightChargingMask != 0
            )
        ].compactMap { $0 }

        guard !readings.isEmpty else {
            return nil
        }
        return DeviceBatteryAppleHeadphoneAdvertisement(
            productID: productID,
            readings: readings
        )
    }

    private static func decode(
        _ encodedLevel: UInt8,
        component: DeviceBatteryBluetoothPowerLogComponent,
        isCharging: Bool
    ) -> DeviceBatteryAppleHeadphoneAdvertisementReading? {
        guard encodedLevel <= 10 else {
            return nil
        }

        let percentage = Int(encodedLevel) * 10

        return DeviceBatteryAppleHeadphoneAdvertisementReading(
            component: component,
            level: percentage,
            chargeState: isCharging ? .charging : .normal
        )
    }
}

enum AppleBluetoothBatteryTopology: Equatable, Sendable {
    case single
    case split
}

enum AppleBluetoothProductCatalog {
    private struct SystemTypeDeclaration {
        let identifier: String?
        let description: String?
        let conformingTypeIdentifiers: [String]
        let productIDs: [Int]
    }

    private static let bluetoothVendorProductTag = "public.bluetooth-vendor-product-id"
    private static let appleBluetoothVendor = 76
    private static let systemNamesByProductID = loadNamesByProductID()
    private static let splitBatteryProductIDs: Set<Int> = [
        0x2002,
        0x200B,
        0x200E,
        0x200F,
        0x2011,
        0x2012,
        0x2013,
        0x2014,
        0x2016,
        0x2019,
        0x201B,
        0x201C,
        0x201D,
        0x201E,
        0x2020,
        0x2024,
        0x2026,
        0x2027
    ]
    private static let verifiedSingleBatteryProductIDs: Set<Int> = [
        0x200A,
        0x201F,
        0x202D
    ]
    private static let verifiedSingleBatteryModelNames: Set<String> = Set([
        "AirPods Max",
        "AirPods Max (USB-C)",
        "AirPods Max 2"
    ].map(normalizedModelName))
    private static let maintainedNamesByProductID: [Int: String] = [
        0x2002: "AirPods",
        0x2003: "Powerbeats 3",
        0x2005: "BeatsX",
        0x2006: "Beats Solo 3",
        0x2009: "Beats Studio 3",
        0x200A: "AirPods Max",
        0x200B: "Powerbeats Pro",
        0x200C: "Beats Solo Pro",
        0x200D: "Powerbeats 4",
        0x200E: "AirPods Pro",
        0x200F: "AirPods 2",
        0x2010: "Beats Flex",
        0x2011: "Beats Studio Buds",
        0x2012: "Beats Fit Pro",
        0x2013: "AirPods 3",
        0x2014: "AirPods Pro 2",
        0x2016: "Beats Studio Buds+",
        0x2017: "Beats Studio Pro",
        0x2019: "AirPods 4",
        0x201A: "Beats Pill",
        0x201B: "AirPods 4",
        0x201C: "AirPods 4",
        0x201D: "Powerbeats Pro 2",
        0x201E: "AirPods 4",
        0x201F: "AirPods Max (USB-C)",
        0x2020: "AirPods 4",
        0x2024: "AirPods Pro 2 (USB-C)",
        0x2025: "Beats Solo 4",
        0x2026: "Beats Solo Buds",
        0x2027: "AirPods Pro 3",
        0x202D: "AirPods Max 2"
    ]

    static func modelName(forProductID productID: String) -> String? {
        numericProductIDCandidates(from: productID).lazy.compactMap { productID in
            maintainedNamesByProductID[productID] ?? systemNamesByProductID[productID]
        }
        .first
    }

    static func modelName(
        forProductID productID: String,
        namesByProductID: [Int: String]
    ) -> String? {
        numericProductIDCandidates(from: productID).lazy
            .compactMap { namesByProductID[$0] }
            .first
    }

    static func matches(productID: Int, encodedProductID: String) -> Bool {
        resolvedProductID(from: encodedProductID) == productID
    }

    static func isHeadphoneProduct(forProductID productID: String) -> Bool? {
        guard let numericProductID = resolvedProductID(from: productID),
              maintainedNamesByProductID[numericProductID] != nil
        else {
            return nil
        }

        // Beats Pill is the only maintained Apple Bluetooth audio product here
        // that is a speaker rather than a wearable headphone device.
        return numericProductID != 0x201A
    }

    static func supportsSplitBattery(forProductID productID: String) -> Bool? {
        batteryTopology(forProductID: productID).map { $0 == .split }
    }

    static func supportsSplitBattery(forProductID productID: Int) -> Bool? {
        batteryTopology(forProductID: productID).map { $0 == .split }
    }

    static func batteryTopology(forProductID productID: String) -> AppleBluetoothBatteryTopology? {
        guard let numericProductID = resolvedProductID(from: productID) else {
            return nil
        }
        return batteryTopology(forProductID: numericProductID)
    }

    static func batteryTopology(forProductID productID: Int) -> AppleBluetoothBatteryTopology? {
        if splitBatteryProductIDs.contains(productID) {
            return .split
        }
        if verifiedSingleBatteryProductIDs.contains(productID) {
            return .single
        }
        return nil
    }

    static func isVerifiedSingleBatteryModelName(_ name: String?) -> Bool {
        guard let name else {
            return false
        }
        return verifiedSingleBatteryModelNames.contains(normalizedModelName(name))
    }

    static func namesByProductID(in infoDictionaries: [[String: Any]]) -> [Int: String] {
        let declarations = infoDictionaries.flatMap(systemTypeDeclarations(in:))
        let declarationsByIdentifier = Dictionary(
            declarations.compactMap { declaration in
                declaration.identifier.map { ($0, declaration) }
            },
            uniquingKeysWith: { _, newer in newer }
        )
        var result: [Int: String] = [:]

        for declaration in declarations {
            guard let description = declaration.description else { continue }
            for productID in declaration.productIDs {
                result[productID] = description
            }
        }

        for declaration in declarations where declaration.description == nil {
            guard let description = inheritedDescription(
                for: declaration,
                declarationsByIdentifier: declarationsByIdentifier,
                visitedIdentifiers: []
            ) else {
                continue
            }
            for productID in declaration.productIDs where result[productID] == nil {
                result[productID] = description
            }
        }

        return result
    }

    private static func systemTypeDeclarations(in info: [String: Any]) -> [SystemTypeDeclaration] {
        guard let rawDeclarations = info["UTExportedTypeDeclarations"] as? [[String: Any]] else {
            return []
        }

        return rawDeclarations.map { declaration in
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            let bluetoothTags = tags?[bluetoothVendorProductTag] as? [String] ?? []
            let conformingTypeIdentifiers: [String]
            if let identifier = declaration["UTTypeConformsTo"] as? String {
                conformingTypeIdentifiers = [identifier]
            } else {
                conformingTypeIdentifiers = declaration["UTTypeConformsTo"] as? [String] ?? []
            }

            return SystemTypeDeclaration(
                identifier: declaration["UTTypeIdentifier"] as? String,
                description: declaration["UTTypeDescription"] as? String,
                conformingTypeIdentifiers: conformingTypeIdentifiers,
                productIDs: bluetoothTags.compactMap(numericProductID(fromBluetoothTag:))
            )
        }
    }

    private static func normalizedModelName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func inheritedDescription(
        for declaration: SystemTypeDeclaration,
        declarationsByIdentifier: [String: SystemTypeDeclaration],
        visitedIdentifiers: Set<String>
    ) -> String? {
        if let description = declaration.description {
            return description
        }

        for identifier in declaration.conformingTypeIdentifiers
            where !visitedIdentifiers.contains(identifier) {
            guard let parent = declarationsByIdentifier[identifier] else { continue }
            var visited = visitedIdentifiers
            visited.insert(identifier)
            if let description = inheritedDescription(
                for: parent,
                declarationsByIdentifier: declarationsByIdentifier,
                visitedIdentifiers: visited
            ) {
                return description
            }
        }

        return nil
    }

    private static func numericProductIDCandidates(from value: String) -> [Int] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        if trimmed.lowercased().hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16).map { [$0] } ?? []
        }

        let decimal = Int(trimmed, radix: 10)
        let hexadecimal = Int(trimmed, radix: 16)
        let looksLikeUnprefixedHex = decimal.map { $0 < 0x1000 } ?? true
        let ordered = looksLikeUnprefixedHex
            ? [hexadecimal, decimal]
            : [decimal, hexadecimal]
        return ordered.compactMap { $0 }.reduce(into: []) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }

    private static func resolvedProductID(from value: String) -> Int? {
        let candidates = numericProductIDCandidates(from: value)
        return candidates.first { candidate in
            maintainedNamesByProductID[candidate] != nil
                || systemNamesByProductID[candidate] != nil
        } ?? candidates.first
    }

    private static func numericProductID(fromBluetoothTag tag: String) -> Int? {
        let fields = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2,
              Int(fields[0]) == appleBluetoothVendor
        else {
            return nil
        }
        return Int(fields[1])
    }

    private static func loadNamesByProductID() -> [Int: String] {
        namesByProductID(in: systemTypeDictionaries())
    }

    private static func systemTypeDictionaries() -> [[String: Any]] {
        systemTypeInfoURLs().compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let propertyList = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  )
            else {
                return nil
            }
            return propertyList as? [String: Any]
        }
    }

    private static func systemTypeInfoURLs() -> [URL] {
        let fileManager = FileManager.default
        let libraryURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library",
            isDirectory: true
        )
        var urls = [
            URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Info.plist"),
            URL(fileURLWithPath: "/System/Library/CoreServices/MobileCoreTypes.bundle/Contents/Info.plist"),
            URL(fileURLWithPath: "/System/Library/CoreServices/MobileCoreTypes.bundle/Info.plist")
        ]

        if let children = try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where child.pathExtension == "bundle" {
                urls.append(child.appendingPathComponent("Contents/Info.plist"))
                urls.append(child.appendingPathComponent("Info.plist"))
            }
        }

        return urls.filter { fileManager.fileExists(atPath: $0.path) }
    }
}
