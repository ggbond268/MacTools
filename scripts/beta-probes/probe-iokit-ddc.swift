#!/usr/bin/env swift
// Read-only IOKit DDC probe (Apple silicon registry path used by
// Plugins/DisplayBrightness/Sources/DisplayBrightnessDDC.swift):
// - registry census: AppleCLCD2 / IOMobileFramebufferShim / DCPAVServiceProxy
//   service counts (on 26A5353q AppleCLCD2 disappeared; the shim is the only
//   matching fallback left).
// - with an external display online: IOAVServiceCreateWithService + a VCP 0x10
//   *read* (the DDC get-VCP request is written to the I2C bus, but brightness
//   is only read — never set).

import CoreGraphics
import Foundation
import IOKit

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

#if arch(arm64)

func serviceCount(name: String) -> Int {
    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceNameMatching(name),
        &iterator
    ) == KERN_SUCCESS else {
        return -1
    }
    defer { IOObjectRelease(iterator) }

    var count = 0
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
        count += 1
    }
    return count
}

// Private symbols, loaded exactly like PrivateDDCBridge.loadSymbol.
let privateFrameworkPaths = [
    "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
]

func loadSymbol(_ symbol: String) -> UnsafeMutableRawPointer? {
    for path in privateFrameworkPaths {
        if let handle = dlopen(path, RTLD_LAZY), let pointer = dlsym(handle, symbol) {
            return pointer
        }
    }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) // RTLD_DEFAULT
}

typealias CGSServiceFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<io_service_t>) -> Void
typealias CreateWithServiceFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias I2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> kern_return_t

// 1. Registry census.
let clcdCount = serviceCount(name: "AppleCLCD2")
let shimCount = serviceCount(name: "IOMobileFramebufferShim")
let proxyCount = serviceCount(name: "DCPAVServiceProxy")

var cgsServiceDetail = "CGSServiceForDisplayNumber(main)=unavailable"
if let cgsPointer = loadSymbol("CGSServiceForDisplayNumber") {
    let cgsServiceForDisplay = unsafeBitCast(cgsPointer, to: CGSServiceFunction.self)
    var mainService = io_service_t()
    cgsServiceForDisplay(CGMainDisplayID(), &mainService)
    cgsServiceDetail = "CGSServiceForDisplayNumber(main)=\(mainService)"
    if mainService != 0 {
        IOObjectRelease(mainService)
    }
}

let censusDetail = "AppleCLCD2=\(clcdCount) IOMobileFramebufferShim=\(shimCount) DCPAVServiceProxy=\(proxyCount); \(cgsServiceDetail)"
if clcdCount > 0 {
    report(.ok, "ddc-registry-census", censusDetail)
} else if shimCount > 0 {
    report(
        .degraded,
        "ddc-registry-census",
        censusDetail + " — AppleCLCD2 gone (26A5353q state), matching is single-pointed on IOMobileFramebufferShim"
    )
} else {
    report(.broken, "ddc-registry-census", censusDetail + " — no display registry service name matches; DDC matching dead")
}

// 2. End-to-end read-only VCP 0x10 (external display required).
func externalDisplayCount() -> Int {
    var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var onlineCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineIDs, &onlineCount) == .success else {
        return 0
    }
    return onlineIDs.prefix(Int(onlineCount)).filter { CGDisplayIsBuiltin($0) == 0 }.count
}

func searchedProperty(key: String, service: io_service_t) -> AnyObject? {
    IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key as CFString,
        kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    )
}

// Mirrors Arm64DDCTransport.readBrightness packet/parse logic (read request only).
func readBrightnessVCP(service: CFTypeRef, write: I2CFunction, read: I2CFunction) -> (current: UInt16, maximum: UInt16)? {
    let displayAddress7Bit: UInt32 = 0x37
    let hostAddress: UInt8 = 0x51

    var packet: [UInt8] = [0x82, 0x01, 0x10, 0]
    packet[packet.count - 1] = packet.dropLast().reduce(UInt8(0x37 << 1), ^)

    var didWrite = false
    for _ in 0..<2 {
        usleep(40_000)
        let result = packet.withUnsafeMutableBytes { buffer in
            write(service, displayAddress7Bit, UInt32(hostAddress), buffer.baseAddress, UInt32(buffer.count))
        }
        if result == KERN_SUCCESS {
            didWrite = true
        }
    }
    guard didWrite else { return nil }

    var reply = [UInt8](repeating: 0, count: 11)
    for _ in 0..<3 {
        usleep(50_000)
        let result = reply.withUnsafeMutableBytes { buffer in
            read(service, displayAddress7Bit, 0, buffer.baseAddress, UInt32(buffer.count))
        }
        if result == KERN_SUCCESS {
            let checksum = reply.dropLast().reduce(UInt8(0x50), ^)
            guard checksum == reply[10], reply[2] == 0x02, reply[3] == 0x00 else {
                return nil
            }
            return (
                current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])
            )
        }
        usleep(20_000)
    }
    return nil
}

func probeEndToEnd() {
    let name = "ddc-endtoend-readonly"
    guard externalDisplayCount() > 0 else {
        report(.skip, name, "no external display online — connect one to exercise the IOAVService VCP read")
        return
    }

    guard
        let createPointer = loadSymbol("IOAVServiceCreateWithService"),
        let writePointer = loadSymbol("IOAVServiceWriteI2C"),
        let readPointer = loadSymbol("IOAVServiceReadI2C")
    else {
        report(.broken, name, "IOAVService symbols unavailable")
        return
    }
    let createWithService = unsafeBitCast(createPointer, to: CreateWithServiceFunction.self)
    let writeI2C = unsafeBitCast(writePointer, to: I2CFunction.self)
    let readI2C = unsafeBitCast(readPointer, to: I2CFunction.self)

    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceNameMatching("DCPAVServiceProxy"),
        &iterator
    ) == KERN_SUCCESS else {
        report(.broken, name, "DCPAVServiceProxy enumeration failed")
        return
    }
    defer { IOObjectRelease(iterator) }

    var externalProxies = 0
    var createdServices = 0
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }

        let location = searchedProperty(key: "Location", service: service) as? String
        // Mirrors discoverCandidates(): missing Location is treated as external.
        guard location?.localizedCaseInsensitiveContains("external") ?? true else {
            continue
        }
        externalProxies += 1

        guard let avService = createWithService(kCFAllocatorDefault, service)?.takeRetainedValue() else {
            continue
        }
        createdServices += 1

        let displayAttributes = searchedProperty(key: "DisplayAttributes", service: service) as? [String: Any]
        let productName = (displayAttributes?["ProductAttributes"] as? [String: Any])?["ProductName"] as? String

        if let value = readBrightnessVCP(service: avService, write: writeI2C, read: readI2C) {
            report(
                .ok,
                name,
                "IOAVService OK on \(productName ?? location ?? "external"); VCP 0x10 current=\(value.current) max=\(value.maximum) (read only)"
            )
            return
        }
    }

    if externalProxies == 0 {
        report(.broken, name, "external display online but no external DCPAVServiceProxy found")
    } else if createdServices == 0 {
        report(.broken, name, "IOAVServiceCreateWithService failed for all \(externalProxies) external proxies")
    } else {
        report(
            .inconclusive,
            name,
            "IOAVService created (\(createdServices)/\(externalProxies)) but VCP 0x10 read failed — monitor may not support DDC"
        )
    }
}

probeEndToEnd()

#else

report(.skip, "ddc-registry-census", "Apple-silicon-only probe (AppleCLCD2/IOMobileFramebufferShim/DCPAVServiceProxy)")
report(.skip, "ddc-endtoend-readonly", "Apple-silicon-only probe")

#endif
