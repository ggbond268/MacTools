#!/usr/bin/env swift
// Read-only window-topology + notch-geometry probe.
// - CGWindowList census: pre-27 every NSStatusItem had its own window at the
//   status layer (25); on 26A5353q the whole menu bar is one WindowServer
//   "Menubar" window at the main-menu layer (24). MenuBarHidden's event
//   synthesis gate (Plugins/MenuBarHidden) keys off this topology.
// - Desktop-tier math backs HideNotchWallpaperRenderer.windowLevel
//   (min(desktopWindow + 1, desktopIconWindow - 1)).
// - Notch geometry backs HideNotchDisplayCatalog (auxiliary top areas +
//   safe-area insets).
// No screenshots, no event synthesis, no window mutation.

import AppKit
import CoreGraphics
import Foundation

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

func windowLayer(_ window: [String: Any]) -> Int? {
    (window[kCGWindowLayer as String] as? NSNumber)?.intValue
}

func windowOwner(_ window: [String: Any]) -> String {
    window[kCGWindowOwnerName as String] as? String ?? "?"
}

func windowWidth(_ window: [String: Any]) -> Int {
    guard
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
    else {
        return -1
    }
    return Int(bounds.width)
}

// 1. Status-item / menu-bar window census.
let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    report(.broken, "window-topology-census", "CGWindowListCopyWindowInfo returned nil — enumeration itself regressed")
    exit(0)
}

let statusItemWindows = windows.filter { windowLayer($0) == statusLayer }
let menuBandWindows = windows.filter { windowLayer($0) == mainMenuLayer }
let menuBandSummary = menuBandWindows
    .prefix(3)
    .map { "\(windowOwner($0)) w=\(windowWidth($0))" }
    .joined(separator: ", ")

let statusOwners = Set(statusItemWindows.map(windowOwner))
// Pre-27, every status item is its own layer-25 window, so a healthy host
// shows several of them from multiple owners (Control Center + each app).
// A lone third-party overlay at layer 25 (Bartender-style) on a rehosted
// host must not read back as pre-27 topology. The full-width "Window Server"
// menu band exists on both topologies, so it cannot discriminate by itself.
let perItemTopologyConfirmed = statusItemWindows.count >= 3 && statusOwners.count >= 2

if perItemTopologyConfirmed {
    report(
        .ok,
        "window-topology-census",
        "onscreen=\(windows.count); per-item status windows (layer \(statusLayer))=\(statusItemWindows.count) from \(statusOwners.count) owners — pre-27 topology; menu band (layer \(mainMenuLayer))=\(menuBandWindows.count) [\(menuBandSummary)]"
    )
} else if !statusItemWindows.isEmpty {
    report(
        .inconclusive,
        "window-topology-census",
        "onscreen=\(windows.count); layer \(statusLayer) windows=\(statusItemWindows.count) from owners [\(statusOwners.sorted().joined(separator: ", "))] — too few/too clustered to confirm per-item topology (third-party overlay on a rehosted host?); menu band (layer \(mainMenuLayer))=\(menuBandWindows.count) [\(menuBandSummary)]"
    )
} else if !menuBandWindows.isEmpty {
    report(
        .degraded,
        "window-topology-census",
        "onscreen=\(windows.count); per-item status windows (layer \(statusLayer))=0, single-window menu bar at layer \(mainMenuLayer): [\(menuBandSummary)] — 26A5353q rehosted topology, MenuBarHidden synthesis stays fail-closed"
    )
} else {
    report(
        .broken,
        "window-topology-census",
        "onscreen=\(windows.count); no windows at layers \(statusLayer)/\(mainMenuLayer) — menu bar not enumerable at all"
    )
}

// 2. Desktop-tier level math (HideNotch mask must sit between wallpaper and icons).
let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
let maskLevel = min(desktopLevel + 1, iconLevel - 1)
let screenSaverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

let observedWallpaperLayers = windows.compactMap(windowLayer).filter { $0 <= desktopLevel }
let observedIconWindows = windows.filter { windowLayer($0) == iconLevel }
let maxMenuLayer = max(statusLayer, mainMenuLayer)

let constantsHold = desktopLevel < maskLevel && maskLevel < iconLevel
let overlayHeadroomHolds = maxMenuLayer < screenSaverLevel
var tierDetails = "desktop=\(desktopLevel) mask=\(maskLevel) icons=\(iconLevel); "
tierDetails += "observed wallpaper-tier windows=\(observedWallpaperLayers.count), icon-tier windows=\(observedIconWindows.count); "
tierDetails += "menu band max layer \(maxMenuLayer) < screenSaver \(screenSaverLevel)=\(overlayHeadroomHolds)"

if constantsHold && overlayHeadroomHolds {
    report(.ok, "desktop-tier-math", tierDetails)
} else {
    report(.broken, "desktop-tier-math", tierDetails + " — HideNotch mask or full-screen overlay ordering no longer holds")
}

// 3. Notch geometry (HideNotchDisplayCatalog inputs).
func isBuiltin(_ screen: NSScreen) -> Bool {
    guard
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
        return false
    }
    return CGDisplayIsBuiltin(CGDirectDisplayID(truncating: screenNumber)) != 0
}

let builtinScreens = NSScreen.screens.filter(isBuiltin)

if builtinScreens.isEmpty {
    report(.skip, "notch-geometry", "no built-in display online (\(NSScreen.screens.count) screens total)")
} else {
    var notchDetails: [String] = []
    var sawNotch = false
    for screen in builtinScreens {
        let topLeft = screen.auxiliaryTopLeftArea
        let topRight = screen.auxiliaryTopRightArea
        let safeTop = screen.safeAreaInsets.top
        let menuBarApprox = screen.frame.maxY - screen.visibleFrame.maxY
        if topLeft != nil || topRight != nil || safeTop > 0 {
            sawNotch = true
        }
        let auxText = topLeft.map { "auxTopLeft=\(Int($0.width))x\(Int($0.height))" } ?? "auxTopLeft=nil"
        notchDetails.append("\(auxText) safeTop=\(safeTop) menuBar≈\(menuBarApprox)pt")
    }
    if sawNotch {
        report(.ok, "notch-geometry", notchDetails.joined(separator: "; "))
    } else {
        // Indistinguishable from non-notch hardware without a hardware table;
        // on a notched MacBook this would be a regression.
        report(
            .skip,
            "notch-geometry",
            notchDetails.joined(separator: "; ")
                + " — no notch reported; expected on non-notch hardware, regression if this Mac has a notch"
        )
    }
}
