import AppKit
import CoreGraphics
import Foundation

struct HideNotchSnapshot: Equatable, Sendable {
    let hasSupportedDisplay: Bool
    let supportedDisplayCount: Int
    let managedDisplayCount: Int
    let unsupportedVisibleDisplayCount: Int
    let pendingRestoreCount: Int
    let isEnabled: Bool
    let isProcessing: Bool
    let isAwaitingDisplay: Bool
    let errorMessage: String?
}

struct HideNotchDisplayContext: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let displayIdentifier: String
    let name: String
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let notchHeightPoints: CGFloat
    let isBuiltin: Bool
    let isSupported: Bool
}

struct HideNotchDisplaySpace: Equatable, Sendable {
    static let currentPlaceholderIdentifier = "__current__"
    static let currentPlaceholder = HideNotchDisplaySpace(
        identifier: currentPlaceholderIdentifier,
        isCurrent: true
    )

    let identifier: String
    let isCurrent: Bool
}

struct HideNotchDisplayRecord: Equatable, Sendable {
    let context: HideNotchDisplayContext
    let spaces: [HideNotchDisplaySpace]

    var currentSpaceIdentifier: String {
        spaces.first(where: \.isCurrent)?.identifier
            ?? spaces.first?.identifier
            ?? HideNotchDisplaySpace.currentPlaceholderIdentifier
    }

    var allSpaces: [HideNotchDisplaySpace] {
        spaces.isEmpty ? [.currentPlaceholder] : spaces
    }
}

enum HideNotchDisplayIdentity {
    static func stableIdentifier(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }

        return (CFUUIDCreateString(nil, uuid) as String).uppercased()
    }
}

@MainActor
protocol HideNotchDesktopMaskWindowing: AnyObject {
    func setFrame(_ frame: CGRect)
    func show()
    func close()
}

@MainActor
protocol HideNotchDesktopMaskWindowBuilding {
    func makeWindow(frame: CGRect) throws -> HideNotchDesktopMaskWindowing
}

@MainActor
protocol HideNotchDisplayCatalogProviding {
    func listDisplayRecords() -> [HideNotchDisplayRecord]
}

@MainActor
protocol HideNotchDesktopMaskManaging: AnyObject {
    var managedDisplayIdentifiers: Set<String> { get }

    func synchronizeMasks(for displays: [HideNotchDisplayContext]) throws
    func hideAllMasks()
}

@MainActor
protocol HideNotchStateStoring: AnyObject {
    var desiredEnabled: Bool { get set }
}

@MainActor
protocol HideNotchWallpaperControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }

    func snapshot() -> HideNotchSnapshot
    func refresh()
    func setEnabled(_ isEnabled: Bool)
}
