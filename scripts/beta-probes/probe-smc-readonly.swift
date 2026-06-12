#!/usr/bin/env swift
// Strictly read-only SMC probe: AppleSMC selector-2 keyInfo (command 9) for
// the keys BatteryChargeLimit / FanControl / SystemStatus depend on. The
// struct layout mirrors SystemStatusSMCReader. This probe NEVER issues an SMC
// write and never even reads key bytes — keyInfo metadata only.

import Foundation
import IOKit

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

// Mirrors SystemStatusSMCReader.KeyData (Plugins/SystemStatus).
struct SMCKeyData {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuLimit: UInt32 = 0
        var gpuLimit: UInt32 = 0
        var memoryLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var limitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

func fourCharCode(_ value: String) -> UInt32 {
    value.utf8.reduce(UInt32(0)) { result, character in
        result << 8 | UInt32(character)
    }
}

func typeString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii)?
        .trimmingCharacters(in: .whitespaces) ?? "?"
}

let probeName = "smc-keyinfo-readonly"
let smcService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard smcService != 0 else {
    report(.broken, probeName, "AppleSMC service not found in IORegistry")
    exit(0)
}

var connection: io_connect_t = 0
let openResult = IOServiceOpen(smcService, mach_task_self_, 0, &connection)
IOObjectRelease(smcService)
guard openResult == kIOReturnSuccess, connection != 0 else {
    report(.broken, probeName, "IOServiceOpen(AppleSMC) failed: 0x" + String(UInt32(bitPattern: openResult), radix: 16))
    exit(0)
}
defer { IOServiceClose(connection) }

// Primary keys the plugins read (CHIE is Apple-silicon-only; the fan keys
// exist on both architectures) + Intel charge-limit keys (BatteryChargeLimit's
// Intel path). This probe runs on both architectures; the key set foreign to
// the local machine is reported informationally, not as a regression.
let watchedKeys = ["CHIE", "F0Ac", "FNum", "F0Mn", "F0Mx"]
let intelOnlyKeys = ["CH0B", "CH0C", "BCLM", "CH0I"]

var presentCount = 0
var mechanismFailures = 0
var keyDetails: [String] = []

for key in watchedKeys + intelOnlyKeys {
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = fourCharCode(key)
    input.data8 = 9 // kSMCGetKeyInfo — metadata read only

    let inputSize = MemoryLayout<SMCKeyData>.stride
    var outputSize = MemoryLayout<SMCKeyData>.stride
    let callResult = IOConnectCallStructMethod(connection, 2, &input, inputSize, &output, &outputSize)

    if callResult != kIOReturnSuccess {
        mechanismFailures += 1
        keyDetails.append("\(key)=kr0x" + String(UInt32(bitPattern: callResult), radix: 16))
    } else if output.result == 0 {
        presentCount += 1
        keyDetails.append("\(key)=\(typeString(output.keyInfo.dataType))/\(output.keyInfo.dataSize)")
    } else {
        keyDetails.append("\(key)=r0x" + String(output.result, radix: 16))
    }
}

let detail = keyDetails.joined(separator: " ")
if mechanismFailures == watchedKeys.count + intelOnlyKeys.count {
    report(.broken, probeName, detail + " — IOConnectCallStructMethod failed for every key; SMC user client path dead")
} else if presentCount == 0 {
    report(.broken, probeName, detail + " — keyInfo mechanism responds but no watched key resolves")
} else {
    #if arch(arm64)
    let architectureNote = "Intel charge keys absent on Apple silicon is expected"
    #else
    let architectureNote = "CHIE absent on Intel is expected"
    #endif
    report(
        .ok,
        probeName,
        detail + " (keyInfo only, nothing read or written; \(architectureNote))"
    )
}
