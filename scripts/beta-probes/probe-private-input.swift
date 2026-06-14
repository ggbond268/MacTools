#!/usr/bin/env swift
// Read-only probe for the two private input/display-comfort frameworks:
// - CoreBrightness CBBlueLightClient (NightShift / DisplayTrueColor plugins):
//   dlopen + selector responses + a real getBlueLightStatus: read. Never calls
//   setEnabled:/setStrength:commit:.
// - MultitouchSupport (MiddleClick plugin): dlopen + the 9 symbols the plugin
//   links + MTDeviceCreateList count. Never calls MTDeviceStart / registers a
//   contact-frame callback.

import Foundation
import ObjectiveC

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

// 1. CoreBrightness / CBBlueLightClient.
func probeCoreBrightness() {
    let name = "corebrightness-cbbluelightclient"
    let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    guard dlopen(path, RTLD_LAZY) != nil else {
        report(.broken, name, "dlopen(\(path)) failed: \(String(cString: dlerror()))")
        return
    }

    guard let clientClass = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
        report(.broken, name, "CBBlueLightClient class missing after dlopen")
        return
    }

    let selectorNames = ["getBlueLightStatus:", "setEnabled:", "setStrength:commit:"]
    let missing = selectorNames.filter { !clientClass.instancesRespond(to: NSSelectorFromString($0)) }
    guard missing.isEmpty else {
        report(.broken, name, "selectors missing: \(missing.joined(separator: ", "))")
        return
    }

    // Live read-only call. Struct layout mirrors
    // Sources/Core/CoreBrightness/CoreBrightness.h (CBBlueLightStatus):
    // 0: active(BOOL) 1: enabled 2: sunSchedulePermitted 4: mode(int)
    // 8..24: schedule 24: disableFlags(u64) 32: available(BOOL).
    let client = clientClass.init()
    let getStatusSelector = NSSelectorFromString("getBlueLightStatus:")
    guard let implementation = class_getMethodImplementation(clientClass, getStatusSelector) else {
        report(.broken, name, "no IMP for getBlueLightStatus:")
        return
    }

    typealias GetStatusFunction = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> ObjCBool
    let getStatus = unsafeBitCast(implementation, to: GetStatusFunction.self)

    var statusBuffer = [UInt8](repeating: 0, count: 64)
    let callSucceeded = statusBuffer.withUnsafeMutableBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress else { return false }
        return getStatus(client, getStatusSelector, baseAddress).boolValue
    }

    guard callSucceeded else {
        report(.broken, name, "getBlueLightStatus: returned false — read path regressed")
        return
    }

    let enabled = statusBuffer[1]
    let mode = statusBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
    let available = statusBuffer[32]
    report(
        .ok,
        name,
        "class + 3 selectors present; live read: enabled=\(enabled) mode=\(mode) available=\(available) (write selectors untested by design)"
    )
}

// 2. MultitouchSupport symbols + device enumeration (no Start, no callbacks).
func probeMultitouchSupport() {
    let name = "multitouchsupport-symbols"
    let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    guard let handle = dlopen(path, RTLD_LAZY) else {
        report(.broken, name, "dlopen(\(path)) failed: \(String(cString: dlerror()))")
        return
    }

    let symbolNames = [
        "MTDeviceCreateList",
        "MTDeviceCreateDefault",
        "MTDeviceIsAlive",
        "MTDeviceIsRunning",
        "MTRegisterContactFrameCallback",
        "MTUnregisterContactFrameCallback",
        "MTDeviceStart",
        "MTDeviceStop",
        "MTDeviceRelease"
    ]
    let missing = symbolNames.filter { dlsym(handle, $0) == nil }
    guard missing.isEmpty else {
        report(.broken, name, "missing symbols: \(missing.joined(separator: ", ")) — MiddleClick private link surface changed")
        return
    }

    typealias CreateListFunction = @convention(c) () -> Unmanaged<CFArray>?
    guard let createListPointer = dlsym(handle, "MTDeviceCreateList") else {
        report(.broken, name, "MTDeviceCreateList vanished between checks")
        return
    }
    let createList = unsafeBitCast(createListPointer, to: CreateListFunction.self)
    let deviceCount = createList().map { CFArrayGetCount($0.takeUnretainedValue()) } ?? -1

    if deviceCount >= 0 {
        report(
            .ok,
            name,
            "all \(symbolNames.count) symbols present; MTDeviceCreateList count=\(deviceCount) (0 is normal without a trackpad; devices never started)"
        )
    } else {
        report(.broken, name, "all symbols present but MTDeviceCreateList returned nil")
    }
}

probeCoreBrightness()
probeMultitouchSupport()
