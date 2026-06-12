#!/usr/bin/env swift
// Read-only gamma-table probe. Mirrors the gamma fallback in
// Plugins/DisplayBrightness/Sources/DisplayBrightnessBackends.swift:
// the app reads the table capacity via CGDisplayGammaTableCapacity and then
// reads the full transfer table; the historical "capacity = 0, nil buffers"
// size-query idiom regressed on macOS 27 beta 26A5353q (returns 1001).
// This probe never writes a gamma table.

import CoreGraphics
import Foundation

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

let maxDisplays: UInt32 = 16
var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
var onlineCount: UInt32 = 0
let listResult = CGGetOnlineDisplayList(maxDisplays, &onlineIDs, &onlineCount)

guard listResult == .success, onlineCount > 0 else {
    report(
        .inconclusive,
        "gamma-capacity-fixpath",
        "CGGetOnlineDisplayList result=\(listResult.rawValue) count=\(onlineCount); no display to probe"
    )
    exit(0)
}

let displays = Array(onlineIDs.prefix(Int(onlineCount)))

// 1. Current app path: capacity via CGDisplayGammaTableCapacity + full-table read.
var fixpathBroken = false
var fixpathDetails: [String] = []

for displayID in displays {
    let capacity = CGDisplayGammaTableCapacity(displayID)
    guard capacity > 0, capacity <= 65536 else {
        fixpathBroken = true
        fixpathDetails.append("display \(displayID): capacity=\(capacity) (unusable)")
        continue
    }

    var red = [CGGammaValue](repeating: 0, count: Int(capacity))
    var green = [CGGammaValue](repeating: 0, count: Int(capacity))
    var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
    var sampleCount: UInt32 = 0
    let readResult = CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &sampleCount)

    if readResult == .success, sampleCount > 0 {
        fixpathDetails.append("display \(displayID): capacity=\(capacity) read=\(sampleCount)")
    } else {
        fixpathBroken = true
        fixpathDetails.append(
            "display \(displayID): capacity=\(capacity) read error=\(readResult.rawValue) samples=\(sampleCount)"
        )
    }
}

report(
    fixpathBroken ? .broken : .ok,
    "gamma-capacity-fixpath",
    fixpathDetails.joined(separator: "; ")
        + (fixpathBroken ? " — GammaBrightnessBackend.canControl()/loadOriginalTransferTableIfNeeded would fail" : "")
)

// 2. Legacy size-query idiom (capacity = 0, nil buffers). The app no longer
// uses it; this tracks whether the 26A5353q regression (error 1001) heals.
var legacyRegressed = false
var legacyDetails: [String] = []

for displayID in displays {
    var sampleCount: UInt32 = 0
    let queryResult = CGGetDisplayTransferByTable(displayID, 0, nil, nil, nil, &sampleCount)
    if queryResult == .success {
        legacyDetails.append("display \(displayID): size-query ok count=\(sampleCount)")
    } else {
        legacyRegressed = true
        legacyDetails.append("display \(displayID): size-query error=\(queryResult.rawValue)")
    }
}

report(
    legacyRegressed ? .degraded : .ok,
    "gamma-legacy-size-query",
    legacyDetails.joined(separator: "; ")
        + (legacyRegressed
            ? " — known 26A5353q regression, app already migrated to CGDisplayGammaTableCapacity"
            : " — legacy idiom works again")
)
