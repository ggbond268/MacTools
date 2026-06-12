import CoreGraphics
import Foundation

// MARK: - MenuBarHiddenHostProbe
//
// Fail-closed host compatibility gate. On macOS 27 beta the menu bar is
// composited into a single WindowServer window and the CGS per-item
// enumeration comes back empty — the empty check catches that. A future seed
// could instead return *plausible-looking* data (e.g. the one composited
// "Menubar" window), which would re-enable dividers and event synthesis
// against coordinates that no longer mean anything. The shape verdict
// therefore also requires the enumerated windows to look like a healthy
// pre-27 per-item menu bar: small band-height windows sitting in some
// display's top band, never a single window spanning the whole bar.
//
// All geometry is in CG global coordinates (top-left origin, y grows down) —
// the shared space of CGDisplayBounds, CGS screen rects and kCGWindowBounds.

enum MenuBarHiddenHostProbe {
    /// Geometry of one enumerated menu bar item window, decoupled from
    /// CGS/CGWindow lookups so the plausibility rules stay pure and testable.
    struct WindowShape: Equatable {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    enum Verdict: Equatable {
        case plausible
        case empty
        case implausible(reason: String)
    }

    /// Live-probe result. `.indeterminate` means the environment offered
    /// nothing to validate against (no active displays, transient CGWindow
    /// lookup failure): callers must stay fail-closed but should not cache
    /// the verdict, unlike the positive `.unsupported` evidence.
    enum Outcome {
        case supported
        case unsupported
        case indeterminate
    }

    /// Healthy pre-27 menu bar items are 22–37 pt tall (24 pt on regular
    /// displays, taller on notched ones); padded for scale rounding.
    static let plausibleWindowHeightRange: ClosedRange<CGFloat> = 18...48
    /// Items sit at the very top of a display; the band is taller than any
    /// real menu bar so future bar-height tweaks don't reject healthy hosts.
    static let topBandHeight: CGFloat = 64
    /// "Automatically hide and show the menu bar" slides items just above the
    /// display's top edge, so the band extends slightly off-screen upward.
    static let topBandUpwardSlop: CGFloat = 40
    /// A real menu bar holds at most a few dozen item windows.
    static let maximumWindowCount = 200
    /// No real status item approaches the full bar width; one window at
    /// ~screen width is the macOS 27 composited-menu-bar fingerprint.
    static let maximumWindowWidthFraction: CGFloat = 0.9
    /// Menu bar hiders (this plugin, Ice, Hidden Bar) hide items behind an
    /// expanding spacer status item ~10000pt long — far wider than any
    /// physical display — whereas the macOS 27 composited menu bar window is
    /// at most one display wide. A band-height window wider than every
    /// display by this factor is the healthy spacer fingerprint.
    static let hiderSpacerWidthFactor: CGFloat = 1.2

    /// Pure shape check: `windows` and `displayBounds` are snapshots taken by
    /// the caller, so tests can drive this without real displays or CGS.
    static func verdict(for windows: [WindowShape], displayBounds: [CGRect]) -> Verdict {
        guard !windows.isEmpty else { return .empty }
        guard windows.count <= maximumWindowCount else {
            return .implausible(reason: "window count \(windows.count) exceeds \(maximumWindowCount)")
        }

        let displays = displayBounds.filter { bounds in
            !bounds.isNull && !bounds.isEmpty
                && bounds.minX.isFinite && bounds.minY.isFinite
                && bounds.width.isFinite && bounds.height.isFinite
        }
        guard !displays.isEmpty else {
            return .implausible(reason: "no valid display bounds to validate against")
        }

        for window in windows {
            if let reason = implausibilityReason(for: window, displays: displays) {
                return .implausible(reason: reason)
            }
        }
        return .plausible
    }

    private static func implausibilityReason(for window: WindowShape, displays: [CGRect]) -> String? {
        let bounds = window.bounds
        guard
            !bounds.isNull,
            bounds.minX.isFinite, bounds.minY.isFinite,
            bounds.width.isFinite, bounds.height.isFinite,
            bounds.width > 0
        else {
            return "window \(window.windowID) has degenerate bounds"
        }
        guard plausibleWindowHeightRange.contains(bounds.height) else {
            return "window \(window.windowID) height \(bounds.height) is outside the menu bar item range"
        }
        // Hidden items legitimately sit at far negative X (this plugin's own
        // expanding divider, or another hider app), so only the vertical
        // placement has to match a display's top band.
        let hostingDisplays = displays.filter { display in
            bounds.minY >= display.minY - topBandUpwardSlop
                && bounds.maxY <= display.minY + topBandHeight
        }
        guard !hostingDisplays.isEmpty else {
            return "window \(window.windowID) at y=\(bounds.minY) is outside every display's top band"
        }
        // A band-height window wider than every display can only be a hider
        // app's expanding spacer (a legitimate pre-27 pattern this plugin
        // itself uses); the composited macOS 27 bar never exceeds one display.
        if let widestWidth = displays.map(\.width).max(),
           bounds.width > widestWidth * hiderSpacerWidthFactor
        {
            return nil
        }
        // Compare against the narrowest hosting display: erring toward
        // rejection is the point of this gate, and real items never get close.
        if let narrowestWidth = hostingDisplays.map(\.width).min(),
           bounds.width >= narrowestWidth * maximumWindowWidthFraction
        {
            return "window \(window.windowID) width \(bounds.width) spans nearly a full menu bar"
        }
        return nil
    }
}

// MARK: - Live probe

extension MenuBarHiddenHostProbe {
    /// Default `hostSupportProbe` implementation. Fail closed: `.unsupported`
    /// when the CGS menu bar enumeration is empty *or* returns data that does
    /// not look like a per-item menu bar window list; `.indeterminate` when
    /// the environment cannot be validated at all (so a later re-probe may
    /// still succeed). Read-only: enumerates IDs, resolves bounds, never
    /// posts events or moves windows.
    static func hostMenuBarSupport() -> Outcome {
        let windowIDs = MenuBarHiddenWindowServer.menuBarWindowIDs(itemsOnly: true, activeSpaceOnly: true)
        guard !windowIDs.isEmpty else {
            // An empty list on a healthy system is impossible (the host's own
            // status item is always present), so empty == the macOS 27
            // single-window menu bar host or a CGS failure.
            MenuBarHiddenLog.plugin.error(
                "Menu bar window enumeration returned no items; treating menu bar host as unsupported"
            )
            return .unsupported
        }

        let shapes = windowShapes(for: windowIDs)
        guard !shapes.isEmpty else {
            // IDs exist but no CGWindow descriptions resolved — a transient
            // lookup failure, not evidence of the composited menu bar host.
            MenuBarHiddenLog.plugin.error(
                "Menu bar window enumeration returned \(windowIDs.count) IDs but none resolved to window bounds; menu bar host support is indeterminate"
            )
            return .indeterminate
        }

        let displayIDs = MenuBarHiddenWindowServer.activeDisplayIDs()
        guard !displayIDs.isEmpty else {
            // All displays asleep/disconnected (e.g. clamshell at login):
            // there is nothing to validate window shapes against.
            MenuBarHiddenLog.plugin.error(
                "No active displays to validate menu bar windows against; menu bar host support is indeterminate"
            )
            return .indeterminate
        }

        switch verdict(for: shapes, displayBounds: displayIDs.map(CGDisplayBounds)) {
        case .plausible:
            return .supported
        case .empty:
            // Unreachable (guarded above); keep the fail-closed default.
            return .unsupported
        case .implausible(let reason):
            MenuBarHiddenLog.plugin.error(
                "Menu bar window enumeration returned \(shapes.count) windows but their shape is implausible (\(reason, privacy: .public)); treating menu bar host as unsupported"
            )
            return .unsupported
        }
    }

    private static func windowShapes(for windowIDs: [CGWindowID]) -> [WindowShape] {
        let described = WindowInfo.createWindows(from: windowIDs)
        guard !described.isEmpty else { return [] }
        return described.map { window in
            WindowShape(windowID: window.windowID, bounds: preferredBounds(for: window))
        }
    }

    private static func preferredBounds(for window: WindowInfo) -> CGRect {
        guard
            let rect = MenuBarHiddenWindowServer.screenRect(for: window.windowID),
            !rect.isNull, !rect.isEmpty,
            rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite
        else {
            return window.bounds
        }
        return rect
    }
}
