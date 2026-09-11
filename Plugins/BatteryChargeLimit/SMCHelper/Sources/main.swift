import Foundation
import IOKit

// MARK: - SMC Types

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    var dataSize: UInt32
    var dataType: UInt32
    var bytes: [UInt8]
}

private let kernelIndexSMC: UInt32 = 2
private let smcCmdReadBytes: UInt8 = 5
private let smcCmdWriteBytes: UInt8 = 6
private let smcCmdReadKeyInfo: UInt8 = 9

private let typeUI8 = fourCC("ui8 ")
private let typeHEX_ = fourCC("hex_")
private let typeFlag = fourCC("flag")

// MARK: - Errors

private enum SMCHelperError: LocalizedError {
    case serviceNotFound
    case openFailed(kern_return_t)
    case keyInfoFailed(String, kern_return_t)
    case invalidKeyInfo(String)
    case readFailed(String, kern_return_t)
    case writeFailed(String, kern_return_t)
    case writeVerificationFailed(String, expected: [UInt8], actual: [UInt8])
    case noWritableInhibitKey
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found"
        case .openFailed(let code):
            return "Failed to open SMC connection: \(String(format: "%08x", code))"
        case .keyInfoFailed(let key, let code):
            return "Failed to read key info for \(key): \(String(format: "%08x", code))"
        case .invalidKeyInfo(let key):
            return "Invalid key info for \(key)"
        case .readFailed(let key, let code):
            return "Failed to read \(key): \(String(format: "%08x", code))"
        case .writeFailed(let key, let code):
            return "Failed to write \(key): \(String(format: "%08x", code))"
        case .writeVerificationFailed(let key, let expected, let actual):
            return "Failed to verify \(key): expected \(hexString(expected)), read \(hexString(actual))"
        case .noWritableInhibitKey:
            return "No supported charge-inhibit SMC key is writable on this Mac"
        case .invalidArguments:
            return "Invalid arguments"
        }
    }
}

// MARK: - SMC Connection

private final class SMCConnection {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCHelperError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SMCHelperError.openFailed(result)
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    func readValue(key: String) throws -> SMCValue {
        let keyCode = fourCC(key)
        let info = try keyInfo(for: key, keyCode: keyCode)

        var input = SMCParam()
        input.key = keyCode
        input.keyInfo.dataSize = info.dataSize
        input.data8 = smcCmdReadBytes

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCHelperError.readFailed(key, result)
        }

        return SMCValue(
            dataSize: info.dataSize,
            dataType: info.dataType,
            bytes: byteArray(output.bytes)
        )
    }

    func writeValue(key: String, value: SMCValue) throws {
        var bytes = value.bytes
        if bytes.count < 32 {
            bytes.append(contentsOf: Array(repeating: 0, count: 32 - bytes.count))
        }

        var input = SMCParam()
        input.key = fourCC(key)
        input.keyInfo.dataSize = value.dataSize
        input.data8 = smcCmdWriteBytes
        input.bytes = bytesTuple(bytes)

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCHelperError.writeFailed(key, result)
        }
    }

    func hasKey(_ key: String) -> Bool {
        let keyCode = fourCC(key)
        if keyInfoCache[keyCode] != nil { return true }

        var input = SMCParam()
        input.key = keyCode
        input.data8 = smcCmdReadKeyInfo

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        return result == kIOReturnSuccess && output.result == 0 && output.keyInfo.dataSize > 0
    }

    private func keyInfo(for key: String, keyCode: UInt32) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[keyCode] {
            return cached
        }

        var input = SMCParam()
        input.key = keyCode
        input.data8 = smcCmdReadKeyInfo

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCHelperError.keyInfoFailed(key, result)
        }
        guard output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else {
            throw SMCHelperError.invalidKeyInfo(key)
        }

        keyInfoCache[keyCode] = output.keyInfo
        return output.keyInfo
    }
}

// MARK: - Charge Inhibit Logic

/// Charge-inhibit keys that are written as a paired set on Apple Silicon.
/// Both must flip together; community-standard pattern from AlDente / batt.
private let appleSiliconInhibitKeys = ["CH0B", "CH0C"]
/// Newer charging-control key seen on macOS 26 ("Tahoe") firmware.
private let tahoeChargingKey = "CHTE"
/// Newer adapter-control key seen on macOS 26 ("Tahoe") firmware.
private let tahoeAdapterKey = BatteryForceDischargePolicy.tahoeAdapterKey
/// Intel-only persistent charge ceiling key.
private let intelCeilingKey = "BCLM"
/// Force-discharge key (drains battery even while plugged in).
private let forceDischargeKey = BatteryForceDischargePolicy.legacyAdapterKey
/// Secondary adapter-control key found on legacy force-discharge firmware.
private let secondaryForceDischargeKey = BatteryForceDischargePolicy.secondaryAdapterKey
/// MagSafe LED color hint (optional cosmetic).
private let magSafeLEDKey = "ACLC"
private let writeMaxAttempts = 3
private let writeInitialBackoff: TimeInterval = 0.05
private let writeVerifyReads = 6
private let writeVerifyInterval: TimeInterval = 0.2

private struct Capabilities {
    var hasCHTE: Bool
    var hasCH0BC: Bool
    var hasBCLM: Bool
    var hasCH0I: Bool
    var hasCHIE: Bool
    var hasCH0J: Bool

    var canInhibit: Bool { hasCHTE || hasCH0BC || hasBCLM }
    var canForceDischarge: Bool { hasCHIE || hasCH0J || hasCH0I }
}

private func probeCapabilities(connection: SMCConnection) -> Capabilities {
    Capabilities(
        hasCHTE: connection.hasKey(tahoeChargingKey),
        hasCH0BC: appleSiliconInhibitKeys.allSatisfy { connection.hasKey($0) },
        hasBCLM: connection.hasKey(intelCeilingKey),
        hasCH0I: connection.hasKey(forceDischargeKey),
        hasCHIE: connection.hasKey(tahoeAdapterKey),
        hasCH0J: connection.hasKey(secondaryForceDischargeKey)
    )
}

/// Write bytes to an SMC key and verify the firmware applied the value.
/// Some Macs report the old value for a short window after a successful write.
private func writeBytes(_ bytes: [UInt8], key: String, connection: SMCConnection) throws {
    let original = try connection.readValue(key: key)
    let dataSize = max(1, Int(original.dataSize))
    guard bytes.count <= dataSize else {
        throw SMCHelperError.invalidKeyInfo(key)
    }

    let payload = bytes + Array(repeating: UInt8(0), count: dataSize - bytes.count)
    if Array(original.bytes.prefix(dataSize)) == payload {
        return
    }

    var writeValue = original
    writeValue.bytes = payload + Array(repeating: UInt8(0), count: max(0, 32 - payload.count))
    writeValue.dataSize = UInt32(dataSize)
    var actual: [UInt8] = []
    var lastError: Error?
    var retryBackoff = writeInitialBackoff

    for writeAttempt in 1...writeMaxAttempts {
        do {
            try connection.writeValue(key: key, value: writeValue)

            for verifyAttempt in 1...writeVerifyReads {
                let readBack = try connection.readValue(key: key)
                actual = Array(readBack.bytes.prefix(dataSize))
                if actual == payload {
                    return
                }
                if verifyAttempt < writeVerifyReads {
                    Thread.sleep(forTimeInterval: writeVerifyInterval)
                }
            }

            lastError = SMCHelperError.writeVerificationFailed(key, expected: payload, actual: actual)
        } catch {
            lastError = error
        }

        if writeAttempt < writeMaxAttempts, retryBackoff > 0 {
            Thread.sleep(forTimeInterval: retryBackoff)
            retryBackoff *= 2
        }
    }

    throw lastError ?? SMCHelperError.writeVerificationFailed(key, expected: payload, actual: actual)
}

/// Write a single byte to a 1-byte SMC key.
private func writeByte(_ byte: UInt8, key: String, connection: SMCConnection) throws {
    try writeBytes([byte], key: key, connection: connection)
}

/// Older helper builds incorrectly used CHIE as a charging-control key. CHIE is
/// adapter control on Tahoe firmware, so clear it whenever we touch charging
/// state to avoid carrying forward a stale adapter setting after upgrade.
@discardableResult
private func clearStaleAdapterControl(connection: SMCConnection) -> Bool {
    guard connection.hasKey(tahoeAdapterKey) else { return false }
    return (try? writeByte(0x00, key: tahoeAdapterKey, connection: connection)) != nil
}

private func availableForceDischargeKeys(connection: SMCConnection) -> [BatteryForceDischargePolicy.Candidate] {
    BatteryForceDischargePolicy.availableCandidates { connection.hasKey($0) }
}

private func writeForceDischarge(_ on: Bool, connection: SMCConnection) throws {
    let keys = availableForceDischargeKeys(connection: connection)
    do {
        if on {
            try BatteryForceDischargePolicy.enable(keys) { candidate in
                try writeByte(candidate.enabledValue, key: candidate.key, connection: connection)
            }
            return
        }

        try BatteryForceDischargePolicy.disable(
            keys,
            isActive: { candidate in
                let value = try connection.readValue(key: candidate.key)
                return BatteryForceDischargePolicy.activeState(
                    for: value.bytes.first,
                    enabledValue: candidate.enabledValue
                )
            },
            clear: { candidate in
                try writeByte(0x00, key: candidate.key, connection: connection)
            }
        )
    } catch let error as BatteryForceDischargePolicyError {
        switch error {
        case .noAvailableKey, .noKeyCleared:
            throw SMCHelperError.noWritableInhibitKey
        case let .activeKeyClearFailed(_, underlying),
             let .indeterminateKeyClearFailed(_, underlying):
            throw underlying
        }
    }
}

/// Inhibit charging across all supported key families on this Mac.
/// Prefer BCLM when a limit is supplied because it behaves like a soft ceiling
/// and avoids hard adapter renegotiation on USB-C display power chains.
/// If no BCLM ceiling is available, fall back to Apple Silicon hard-inhibit
/// keys or Intel's blocking BCLM value for older firmware.
private func inhibitCharging(limit: Int?, connection: SMCConnection) throws {
    clearStaleAdapterControl(connection: connection)

    let caps = probeCapabilities(connection: connection)
    guard caps.canInhibit else { throw SMCHelperError.noWritableInhibitKey }

    if let limit, caps.hasBCLM {
        let bclmValue = UInt8(clamping: max(0, min(100, limit)))
        if (try? writeByte(bclmValue, key: intelCeilingKey, connection: connection)) != nil {
            return
        }
    }

    var anyOK = false
    if caps.hasCHTE {
        if (try? writeBytes([0x01, 0x00, 0x00, 0x00], key: tahoeChargingKey, connection: connection)) != nil {
            anyOK = true
        }
    }
    if caps.hasCH0BC {
        var allPairOK = true
        for key in appleSiliconInhibitKeys {
            if (try? writeByte(0x02, key: key, connection: connection)) == nil {
                allPairOK = false
            }
        }
        if allPairOK { anyOK = true }
    }
    if caps.hasBCLM {
        let bclmValue = UInt8(clamping: max(0, min(100, limit ?? 0)))
        if (try? writeByte(bclmValue, key: intelCeilingKey, connection: connection)) != nil {
            anyOK = true
        }
    }
    if !anyOK {
        throw SMCHelperError.noWritableInhibitKey
    }
}

/// Resume charging — clear all charge-inhibit keys.
private func resumeCharging(connection: SMCConnection) throws {
    let caps = probeCapabilities(connection: connection)

    var anyOK = clearStaleAdapterControl(connection: connection)
    if caps.hasCHTE {
        if (try? writeBytes([0x00, 0x00, 0x00, 0x00], key: tahoeChargingKey, connection: connection)) != nil {
            anyOK = true
        }
    }
    if caps.hasCH0BC {
        var allPairOK = true
        for key in appleSiliconInhibitKeys {
            if (try? writeByte(0x00, key: key, connection: connection)) == nil {
                allPairOK = false
            }
        }
        if allPairOK { anyOK = true }
    }
    if caps.hasBCLM {
        if (try? writeByte(100, key: intelCeilingKey, connection: connection)) != nil {
            anyOK = true
        }
    }
    // Stop any force-discharge as part of resume. Do not report resume as
    // successful if an active or indeterminate adapter key could not clear.
    var forceDischargeError: Error?
    if caps.canForceDischarge {
        do {
            try writeForceDischarge(false, connection: connection)
        } catch {
            forceDischargeError = error
        }
    }
    if let forceDischargeError {
        throw forceDischargeError
    }
    if !anyOK {
        throw SMCHelperError.noWritableInhibitKey
    }
}

private func setForceDischarge(_ on: Bool, connection: SMCConnection) throws {
    let caps = probeCapabilities(connection: connection)
    guard caps.canForceDischarge else { throw SMCHelperError.noWritableInhibitKey }
    try writeForceDischarge(on, connection: connection)
}

// MARK: - JSON Output Helpers

private func printProbe(connection: SMCConnection) {
    let caps = probeCapabilities(connection: connection)
    let lines = [
        "{",
        "  \"CHTE\": \(caps.hasCHTE),",
        "  \"CH0B_CH0C\": \(caps.hasCH0BC),",
        "  \"BCLM\": \(caps.hasBCLM),",
        "  \"CHIE\": \(caps.hasCHIE),",
        "  \"CH0J\": \(caps.hasCH0J),",
        "  \"CH0I\": \(caps.hasCH0I)",
        "}"
    ]
    print(lines.joined(separator: "\n"))
}

private func printRead(key: String, connection: SMCConnection) throws {
    let value = try connection.readValue(key: key)
    let hex = hexString(Array(value.bytes.prefix(Int(value.dataSize))))
    print("Key: \(key)")
    print("Type: \(fourCCString(value.dataType))")
    print("Size: \(value.dataSize)")
    print("Bytes: \(hex)")
    if value.dataSize >= 1 {
        print("Byte0: \(value.bytes[0])")
    }
}

// MARK: - Utilities

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func fourCC(_ value: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, byte) in value.utf8.prefix(4).enumerated() {
        result |= UInt32(byte) << (8 * (3 - index))
    }
    return result
}

private func fourCCString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
}

private func byteArray(_ bytes: SMCBytes) -> [UInt8] {
    [
        bytes.0, bytes.1, bytes.2, bytes.3,
        bytes.4, bytes.5, bytes.6, bytes.7,
        bytes.8, bytes.9, bytes.10, bytes.11,
        bytes.12, bytes.13, bytes.14, bytes.15,
        bytes.16, bytes.17, bytes.18, bytes.19,
        bytes.20, bytes.21, bytes.22, bytes.23,
        bytes.24, bytes.25, bytes.26, bytes.27,
        bytes.28, bytes.29, bytes.30, bytes.31
    ]
}

private func bytesTuple(_ bytes: [UInt8]) -> SMCBytes {
    (
        bytes[safe: 0], bytes[safe: 1], bytes[safe: 2], bytes[safe: 3],
        bytes[safe: 4], bytes[safe: 5], bytes[safe: 6], bytes[safe: 7],
        bytes[safe: 8], bytes[safe: 9], bytes[safe: 10], bytes[safe: 11],
        bytes[safe: 12], bytes[safe: 13], bytes[safe: 14], bytes[safe: 15],
        bytes[safe: 16], bytes[safe: 17], bytes[safe: 18], bytes[safe: 19],
        bytes[safe: 20], bytes[safe: 21], bytes[safe: 22], bytes[safe: 23],
        bytes[safe: 24], bytes[safe: 25], bytes[safe: 26], bytes[safe: 27],
        bytes[safe: 28], bytes[safe: 29], bytes[safe: 30], bytes[safe: 31]
    )
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8 {
        indices.contains(index) ? self[index] : 0
    }
}

// MARK: - Entry Point

private func usage() {
    let program = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "mactools-battery-smc-helper"
    print("MacTools Battery SMC Helper")
    print("Usage:")
    print("  \(program) probe")
    print("  \(program) inhibit [<percent>]")
    print("  \(program) resume")
    print("  \(program) discharge on|off")
    print("  \(program) read <KEY>")
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        usage()
        throw SMCHelperError.invalidArguments
    }

    let connection = try SMCConnection()

    switch arguments[1] {
    case "probe":
        printProbe(connection: connection)

    case "inhibit":
        let limit: Int? = arguments.count >= 3 ? Int(arguments[2]) : nil
        try inhibitCharging(limit: limit, connection: connection)

    case "resume":
        try resumeCharging(connection: connection)

    case "discharge":
        guard arguments.count >= 3 else { throw SMCHelperError.invalidArguments }
        switch arguments[2] {
        case "on": try setForceDischarge(true, connection: connection)
        case "off": try setForceDischarge(false, connection: connection)
        default: throw SMCHelperError.invalidArguments
        }

    case "read":
        guard arguments.count >= 3 else { throw SMCHelperError.invalidArguments }
        try printRead(key: arguments[2], connection: connection)

    default:
        usage()
        throw SMCHelperError.invalidArguments
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
