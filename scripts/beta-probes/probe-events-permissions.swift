#!/usr/bin/env swift
// Read-only permission-bit readout + Carbon hotkey registration round-trip.
// - Permission checks never prompt (AXIsProcessTrustedWithOptions with
//   prompt:false, IOHIDCheckAccess, CGPreflight* only).
// - The hotkey is registered with an unlikely chord (Ctrl+Opt+Cmd+Shift+F15)
//   and unregistered immediately; no run loop is entered, nothing stays
//   resident. Mirrors the registration chain in Sources/Core/Shortcuts.

import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import IOKit.hid

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

// 1. Permission status bits (environment readout; values themselves are not
// pass/fail — the probe verifies the APIs still answer without prompting).
func accessTypeName(_ type: IOHIDAccessType) -> String {
    switch type {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied: return "denied"
    default: return "unknown"
    }
}

let axTrusted = AXIsProcessTrusted()
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let axTrustedNoPrompt = AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary)
let hidListen = accessTypeName(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
let hidPost = accessTypeName(IOHIDCheckAccess(kIOHIDRequestTypePostEvent))
let preflightListen = CGPreflightListenEventAccess()
let preflightPost = CGPreflightPostEventAccess()
let preflightScreenCapture = CGPreflightScreenCaptureAccess()

report(
    .ok,
    "permission-status-bits",
    "AXIsProcessTrusted=\(axTrusted) noPromptVariant=\(axTrustedNoPrompt); IOHIDCheckAccess listen=\(hidListen) post=\(hidPost); CGPreflight listen=\(preflightListen) post=\(preflightPost) screenCapture=\(preflightScreenCapture) (no prompts shown)"
)

// 2. Carbon hotkey register + immediate unregister.
func probeCarbonHotkey() {
    let name = "carbon-hotkey-registration"
    guard let dispatcherTarget = GetEventDispatcherTarget() else {
        report(.broken, name, "GetEventDispatcherTarget returned nil")
        return
    }

    var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )
    var handlerRef: EventHandlerRef?
    let installStatus = InstallEventHandler(
        dispatcherTarget,
        { _, _, _ in noErr },
        1,
        &eventType,
        nil,
        &handlerRef
    )

    // 'MTBP' — probe-private signature, never collides with app hotkey IDs.
    let hotKeyID = EventHotKeyID(signature: OSType(0x4D54_4250), id: 1)
    let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    var hotKeyRef: EventHotKeyRef?
    let registerStatus = RegisterEventHotKey(
        UInt32(kVK_F15),
        modifiers,
        hotKeyID,
        dispatcherTarget,
        0,
        &hotKeyRef
    )

    var unregisterStatus: OSStatus = noErr
    if let hotKeyRef {
        unregisterStatus = UnregisterEventHotKey(hotKeyRef)
    }
    if let handlerRef {
        RemoveEventHandler(handlerRef)
    }

    let detail = "install=\(installStatus) register=\(registerStatus) ref=\(hotKeyRef != nil ? "non-nil" : "nil") unregister=\(unregisterStatus)"
    if installStatus == noErr, registerStatus == noErr, hotKeyRef != nil, unregisterStatus == noErr {
        report(
            .ok,
            name,
            detail + " — registration chain intact (callback dispatch on a real keypress still needs an on-machine check)"
        )
    } else {
        report(.broken, name, detail + " — GlobalShortcutManager registration chain regressed")
    }
}

probeCarbonHotkey()
