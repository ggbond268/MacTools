import CoreGraphics
import Foundation

struct DisplayDisableDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isActive: Bool
    let isInMirrorSet: Bool
    let isVisibleToAppKit: Bool
    let isVirtual: Bool
    let vendorNumber: UInt32?
    let modelNumber: UInt32?
    let serialNumber: UInt32?

    init(
        id: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        isActive: Bool,
        isInMirrorSet: Bool,
        isVisibleToAppKit: Bool,
        isVirtual: Bool = false,
        vendorNumber: UInt32? = nil,
        modelNumber: UInt32? = nil,
        serialNumber: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isInMirrorSet = isInMirrorSet
        self.isVisibleToAppKit = isVisibleToAppKit
        self.isVirtual = isVirtual
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }

    /// A physical display that currently shows a picture a person can use. Virtual devices
    /// (software dummies, headless adapters exposed as virtual) never count, so they cannot be
    /// the only thing left on after another display is switched off.
    var isDrawable: Bool {
        !isVirtual && (isActive || isVisibleToAppKit)
    }
}

extension DisplayDisableDisplay {
    func withActive(_ value: Bool) -> DisplayDisableDisplay {
        DisplayDisableDisplay(
            id: id,
            name: name,
            isBuiltin: isBuiltin,
            isActive: value,
            isInMirrorSet: isInMirrorSet,
            isVisibleToAppKit: isVisibleToAppKit,
            isVirtual: isVirtual,
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        )
    }

    func withVisibleToAppKit(_ value: Bool) -> DisplayDisableDisplay {
        DisplayDisableDisplay(
            id: id,
            name: name,
            isBuiltin: isBuiltin,
            isActive: isActive,
            isInMirrorSet: isInMirrorSet,
            isVisibleToAppKit: value,
            isVirtual: isVirtual,
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        )
    }
}

/// One switchable display as presented to the panel and actions.
struct DisplayDisableEntry: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    /// True while this display is switched off by MacTools and can be restored.
    let isDisabled: Bool
    let isDisableAllowed: Bool
    /// Why the display cannot be switched off right now, when `isDisableAllowed` is false.
    let unavailableReason: String?
}

struct DisplayDisableSnapshot: Equatable {
    let isSupported: Bool
    let entries: [DisplayDisableEntry]
    /// The failure or pending notice left by the most recent operation.
    let message: String?

    var builtIn: DisplayDisableEntry? {
        entries.first(where: \.isBuiltin)
    }

    func entry(for displayID: CGDirectDisplayID) -> DisplayDisableEntry? {
        entries.first { $0.id == displayID }
    }
}

struct DisplaySurvivorIdentity: Codable, Equatable {
    let id: CGDirectDisplayID
    let vendorNumber: UInt32?
    let modelNumber: UInt32?
    let serialNumber: UInt32?
}

/// A display MacTools switched off, persisted so the next start can restore it if the process
/// ended without doing so, and so a disconnect of the displays left on can bring it back.
struct DisplayDisableRecord: Codable, Equatable {
    let createdAt: Date
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let vendorNumber: UInt32?
    let modelNumber: UInt32?
    let serialNumber: UInt32?
    // Stable EDID identity for each display that stayed on. CGDirectDisplayID can change after
    // sleep/wake, so restore decisions prefer identity matching and fall back to IDs.
    let survivorIdentities: [DisplaySurvivorIdentity]
    /// Set when a restore was asked for but could not run yet, such as the built-in display
    /// while the lid is closed. The next reconcile restores it as soon as it can.
    var restoreRequested: Bool

    init(
        createdAt: Date,
        displayID: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        vendorNumber: UInt32?,
        modelNumber: UInt32?,
        serialNumber: UInt32?,
        survivorIdentities: [DisplaySurvivorIdentity],
        restoreRequested: Bool = false
    ) {
        self.createdAt = createdAt
        self.displayID = displayID
        self.name = name
        self.isBuiltin = isBuiltin
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.survivorIdentities = survivorIdentities
        self.restoreRequested = restoreRequested
    }

    /// Whether `display` is the monitor this record switched off. The built-in panel is unique;
    /// an external monitor matches by ID, or by full EDID identity only when it carries a serial
    /// number, so two identical monitors without serials are never confused with each other.
    func matchesTarget(_ display: DisplayDisableDisplay) -> Bool {
        if display.id == displayID {
            return true
        }
        if isBuiltin {
            return display.isBuiltin
        }
        guard !display.isBuiltin, let serialNumber, display.serialNumber == serialNumber else {
            return false
        }
        return display.vendorNumber == vendorNumber && display.modelNumber == modelNumber
    }
}
