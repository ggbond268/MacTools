import AppKit
import CoreGraphics
import Darwin
import Foundation

private enum ManagedDisplaySpacesBridge {
    typealias DefaultConnectionForThreadFn = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    static let defaultConnectionForThread: DefaultConnectionForThreadFn? = load(
        name: "SLSDefaultConnectionForThread",
        as: DefaultConnectionForThreadFn.self
    )

    static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = load(
        name: "SLSCopyManagedDisplaySpaces",
        as: CopyManagedDisplaySpacesFn.self
    )

    private static func load<T>(name: String, as _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(symbol, to: T.self)
    }
}

enum HideNotchManagedDisplaySpaceResolver {
    static func spaces(from item: [String: Any]) -> [HideNotchDisplaySpace] {
        let currentSpace = item["Current Space"] as? [String: Any]
        let currentIdentifier = resolvedIdentifier(
            from: currentSpace,
            isCurrentSpace: true
        )

        var rawSpaces: [HideNotchDisplaySpace] = []

        if let currentIdentifier {
            rawSpaces.append(
                HideNotchDisplaySpace(
                    identifier: currentIdentifier,
                    isCurrent: true
                )
            )
        }

        if let spaces = item["Spaces"] as? [[String: Any]] {
            for space in spaces {
                guard let identifier = resolvedIdentifier(from: space, isCurrentSpace: false) else {
                    continue
                }

                rawSpaces.append(
                    HideNotchDisplaySpace(
                        identifier: identifier,
                        isCurrent: identifier == currentIdentifier
                    )
                )
            }
        }

        var seenIdentifiers: Set<String> = []
        let spaces = rawSpaces.filter { seenIdentifiers.insert($0.identifier).inserted }
        return spaces.isEmpty ? [.currentPlaceholder] : spaces
    }

    private static func resolvedIdentifier(
        from space: [String: Any]?,
        isCurrentSpace: Bool
    ) -> String? {
        guard let space else {
            return isCurrentSpace ? HideNotchDisplaySpace.currentPlaceholderIdentifier : nil
        }

        let spaceType = (space["type"] as? NSNumber)?.intValue ?? 0
        guard spaceType == 0 else {
            return nil
        }

        if let identifier = (space["uuid"] as? String), !identifier.isEmpty {
            return identifier
        }

        return isCurrentSpace ? HideNotchDisplaySpace.currentPlaceholderIdentifier : nil
    }
}

@MainActor
struct SystemHideNotchDisplayCatalog: HideNotchDisplayCatalogProviding {
    func listDisplayRecords() -> [HideNotchDisplayRecord] {
        let spacesByDisplay = displaySpacesByDisplayIdentifier()

        return NSScreen.screens.compactMap { screen in
            guard let context = Self.displayContext(for: screen) else {
                return nil
            }

            let spaces = spacesByDisplay[context.displayIdentifier] ?? [.currentPlaceholder]
            return HideNotchDisplayRecord(
                context: context,
                spaces: spaces
            )
        }
    }

    private func displaySpacesByDisplayIdentifier() -> [String: [HideNotchDisplaySpace]] {
        guard
            let defaultConnectionForThread = ManagedDisplaySpacesBridge.defaultConnectionForThread,
            let copyManagedDisplaySpaces = ManagedDisplaySpacesBridge.copyManagedDisplaySpaces,
            let managedDisplaySpaces = copyManagedDisplaySpaces(defaultConnectionForThread())?.takeRetainedValue()
                as? [[String: Any]]
        else {
            return [:]
        }

        return managedDisplaySpaces.reduce(into: [String: [HideNotchDisplaySpace]]()) { result, item in
            guard let displayIdentifier = (item["Display Identifier"] as? String)?.uppercased() else {
                return
            }

            result[displayIdentifier] = HideNotchManagedDisplaySpaceResolver.spaces(from: item)
        }
    }

    /// The mask must be pinned to the physical notch height (auxiliary top
    /// areas / safe area). The menu bar can be taller than the notch (observed
    /// on macOS 27 beta with an external main display), so taking the max of
    /// both would overflow the mask below the camera housing. Menu bar height
    /// is only an estimate used when no auxiliary-area data exists; in that
    /// case `hasUnobscuredTopArea` is false, so `isSupported` stays false and
    /// the fallback only affects the recorded context value, never masking.
    nonisolated static func notchHeight(
        auxLeftHeight: CGFloat,
        auxRightHeight: CGFloat,
        menuBarHeight: CGFloat
    ) -> CGFloat {
        // Sanitize each side before max(): Swift's max() propagates a NaN
        // first argument, which would discard a valid height on the other
        // side instead of falling back to it.
        let leftHeight = auxLeftHeight.isFinite ? max(auxLeftHeight, 0) : 0
        let rightHeight = auxRightHeight.isFinite ? max(auxRightHeight, 0) : 0
        let auxHeight = max(leftHeight, rightHeight)
        if auxHeight > 0 {
            return auxHeight
        }

        guard menuBarHeight.isFinite, menuBarHeight > 0 else {
            return 0
        }

        return menuBarHeight
    }

    private static func displayContext(for screen: NSScreen) -> HideNotchDisplayContext? {
        guard
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }

        let displayID = screenNumber.uint32Value

        if CGDisplayIsInMirrorSet(displayID) != 0, CGDisplayIsMain(displayID) == 0 {
            return nil
        }

        let topLeftArea = screen.auxiliaryTopLeftArea ?? .zero
        let topRightArea = screen.auxiliaryTopRightArea ?? .zero
        let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        let hasUnobscuredTopArea = !topLeftArea.isEmpty || !topRightArea.isEmpty
        let notchHeight = Self.notchHeight(
            auxLeftHeight: topLeftArea.height,
            auxRightHeight: topRightArea.height,
            menuBarHeight: NSApplication.shared.mainMenu?.menuBarHeight ?? 0
        )
        let isSupported = isBuiltin && hasUnobscuredTopArea && notchHeight > 0

        return HideNotchDisplayContext(
            displayID: displayID,
            displayIdentifier: HideNotchDisplayIdentity.stableIdentifier(for: displayID) ?? String(displayID),
            name: screen.localizedName,
            frame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor,
            notchHeightPoints: notchHeight,
            isBuiltin: isBuiltin,
            isSupported: isSupported
        )
    }
}
