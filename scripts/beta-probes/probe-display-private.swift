#!/usr/bin/env swift
// Read-only probe for the private display stack the repo links via dlsym:
// - DisplayServices/SkyLight/CGS/CoreDisplay symbol presence (mirrors
//   DisplayServicesBrightnessBridge + PrivateDDCBridge + HideNotch's
//   ManagedDisplaySpacesBridge + MenuBarHidden's SkyLight/CGS symbol set).
// - SLSCopyManagedDisplaySpaces payload schema (HideNotch space tracking).
// - CoreDisplay_DisplayCreateInfoDictionary keys (DDC display matching).
// Nothing is written; no connection state is mutated.

import AppKit
import CoreGraphics
import Foundation

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
let coreDisplayPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
// Mirrors PrivateDDCBridge.privateFrameworkPaths + RTLD_DEFAULT fallback.
let ddcSearchPaths = [coreDisplayPath, skyLightPath, displayServicesPath]

func symbolPointer(_ name: String, paths: [String]) -> UnsafeMutableRawPointer? {
    for path in paths {
        if let handle = dlopen(path, RTLD_LAZY), let pointer = dlsym(handle, name) {
            return pointer
        }
    }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
}

// 1. Symbol presence census.
let symbolTable: [(name: String, paths: [String])] = [
    ("DisplayServicesGetBrightness", [displayServicesPath]),
    ("DisplayServicesSetBrightness", [displayServicesPath]),
    ("SLSDefaultConnectionForThread", [skyLightPath]),
    ("SLSCopyManagedDisplaySpaces", [skyLightPath]),
    // Presence check only — backs MenuBarHidden's icon snapshots
    // (MenuBarHiddenIconCache), but no image is ever created here.
    ("SLWindowListCreateImageFromArray", [skyLightPath]),
    // MenuBarHidden's @_silgen_name CGS surface (MenuBarHiddenItemEnumerator
    // + MenuBarHiddenIconCache); resolved like dyld via RTLD_DEFAULT fallback.
    ("CGSCopyActiveMenuBarDisplayIdentifier", [skyLightPath]),
    ("CGSGetProcessMenuBarWindowList", [skyLightPath]),
    ("CGSGetScreenRectForWindow", [skyLightPath]),
    ("CGSServiceForDisplayNumber", ddcSearchPaths),
    ("CoreDisplay_DisplayCreateInfoDictionary", ddcSearchPaths),
    ("IOAVServiceCreateWithService", ddcSearchPaths),
    ("IOAVServiceReadI2C", ddcSearchPaths),
    ("IOAVServiceWriteI2C", ddcSearchPaths)
]

let missingSymbols = symbolTable.filter { symbolPointer($0.name, paths: $0.paths) == nil }.map(\.name)
if missingSymbols.isEmpty {
    report(
        .ok,
        "display-private-symbols",
        "all \(symbolTable.count) DisplayServices/SkyLight/CGS/CoreDisplay symbols present"
    )
} else {
    report(
        .broken,
        "display-private-symbols",
        "missing: \(missingSymbols.joined(separator: ", ")) — DisplayBrightness/HideNotch/MenuBarHidden private link surface changed"
    )
}

// 2. SLSCopyManagedDisplaySpaces schema (keys HideNotch resolves).
func probeManagedDisplaySpacesSchema() {
    let name = "sls-managed-display-spaces-schema"
    typealias DefaultConnectionForThreadFunction = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?

    guard
        let connectionPointer = symbolPointer("SLSDefaultConnectionForThread", paths: [skyLightPath]),
        let copySpacesPointer = symbolPointer("SLSCopyManagedDisplaySpaces", paths: [skyLightPath])
    else {
        report(.broken, name, "SLS symbols unavailable (see display-private-symbols)")
        return
    }

    let defaultConnection = unsafeBitCast(connectionPointer, to: DefaultConnectionForThreadFunction.self)
    let copySpaces = unsafeBitCast(copySpacesPointer, to: CopyManagedDisplaySpacesFunction.self)

    let connection = defaultConnection()
    guard connection != 0 else {
        report(.broken, name, "SLSDefaultConnectionForThread returned 0 — no SkyLight connection")
        return
    }

    guard let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else {
        report(.broken, name, "SLSCopyManagedDisplaySpaces returned nil/empty for connection \(connection)")
        return
    }

    var missingKeys: Set<String> = []
    var spaceTypes: Set<Int> = []

    func checkSpace(_ space: [String: Any], label: String) {
        if (space["uuid"] as? String) == nil { missingKeys.insert("\(label).uuid") }
        if let type = (space["type"] as? NSNumber)?.intValue {
            spaceTypes.insert(type)
        } else {
            missingKeys.insert("\(label).type")
        }
    }

    for display in displays {
        if (display["Display Identifier"] as? String) == nil { missingKeys.insert("Display Identifier") }
        if let currentSpace = display["Current Space"] as? [String: Any] {
            checkSpace(currentSpace, label: "Current Space")
        } else {
            missingKeys.insert("Current Space")
        }
        if let spaces = display["Spaces"] as? [[String: Any]] {
            for space in spaces { checkSpace(space, label: "Spaces[]") }
        } else {
            missingKeys.insert("Spaces")
        }
    }

    if missingKeys.isEmpty {
        report(
            .ok,
            name,
            "connection=\(connection); \(displays.count) displays; Display Identifier/Current Space/Spaces/uuid/type all intact; space types seen=\(spaceTypes.sorted())"
        )
    } else {
        report(
            .broken,
            name,
            "\(displays.count) displays but schema keys missing: \(missingKeys.sorted().joined(separator: ", ")) — HideNotch space resolution would degrade"
        )
    }
}

probeManagedDisplaySpacesSchema()

// 3. CoreDisplay_DisplayCreateInfoDictionary keys (DDC location matching).
func probeCoreDisplayInfoDictionary() {
    let name = "coredisplay-info-dictionary"
    typealias CreateInfoDictionaryFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    guard let pointer = symbolPointer("CoreDisplay_DisplayCreateInfoDictionary", paths: ddcSearchPaths) else {
        report(.broken, name, "symbol unavailable (see display-private-symbols)")
        return
    }
    let createInfoDictionary = unsafeBitCast(pointer, to: CreateInfoDictionaryFunction.self)

    let mainDisplay = CGMainDisplayID()
    guard let info = createInfoDictionary(mainDisplay)?.takeRetainedValue() as? [String: Any] else {
        report(.broken, name, "returned nil for main display \(mainDisplay)")
        return
    }

    // "IODisplayLocation" (kIODisplayLocationKey) is what DisplayBrightnessDDC
    // uses to match DCPAVServiceProxy candidates to CGDirectDisplayIDs.
    if let location = info["IODisplayLocation"] as? String {
        report(.ok, name, "main display \(mainDisplay): \(info.count) keys, IODisplayLocation=\(location)")
    } else {
        report(
            .broken,
            name,
            "main display \(mainDisplay): \(info.count) keys but IODisplayLocation missing — DDC display matching loses its primary key"
        )
    }
}

probeCoreDisplayInfoDictionary()
