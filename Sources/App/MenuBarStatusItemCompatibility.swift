import AppKit

// MARK: - MenuBarStatusItemHostCompatibility
//
// macOS 27 beta (26A5353q) re-architected the menu bar: every status item is
// composited into a single WindowServer-owned "Menubar" window. A third-party
// NSStatusItem button is then backed by a stub window — verified on device:
// `windowNumber == 4294967296` (the 2^32 sentinel, beyond the 32-bit
// CGWindowID space of real windows), `frame == (0,0,51,0)` (zero height) —
// and CGWindowList shows no per-item window at all.
//
// In that hosting mode the system only delivers `.leftMouseUp` to the
// button's action (mouseDown never arrives, so a down-only sendAction mask
// makes the item completely dead; right mouse events are not routed to
// third-party items at all). Older systems must keep the historical
// down-mask byte-for-byte: registering both down and up there would
// double-trigger every click.

enum MenuBarStatusItemHostCompatibility {
    /// The stub backing window reports a window number outside the 32-bit
    /// CGWindowID space that every real window lives in.
    private static let maximumRealWindowNumber = Int(UInt32.max)

    /// Pure detection used by both the action-mask gate and diagnostics.
    static func isStubBackingWindow(windowNumber: Int, frameHeight: CGFloat) -> Bool {
        if frameHeight <= 0 { return true }
        if windowNumber <= 0 { return true }
        if windowNumber > maximumRealWindowNumber { return true }
        return false
    }

    /// A status item button without any backing window is treated as stub
    /// hosting as well — on every shipping macOS (14…26) the button is placed
    /// into a real status bar window synchronously at creation.
    static func isStubBackingWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return true }
        return isStubBackingWindow(
            windowNumber: window.windowNumber,
            frameHeight: window.frame.height
        )
    }

    /// Pure decision for whether a derived button screen rect must collapse to
    /// a nil anchor (so floating-window consumers fall back to a centered /
    /// default position). The stub backing window on the macOS 27 single-window
    /// menu bar host produces a degenerate, non-nil rect (e.g.
    /// `{{0,-11},{22,22}}`) that lands plugin windows off-screen; returning nil
    /// there is what makes the existing `anchor == nil → screen center` fallback
    /// reachable. On every shipping macOS (14…26) the button is backed by a real
    /// status bar window with a positive-height frame, so this stays false and
    /// the genuine rect is used unchanged.
    static func anchorRectDegeneratesToNil(
        screenRectHeight: CGFloat,
        windowIsStub: Bool
    ) -> Bool {
        if screenRectHeight <= 0 { return true }
        if windowIsStub { return true }
        return false
    }

    /// Pure mask decision, OS-gated by the caller. Up-mask only when the new
    /// single-window menu bar host was detected (runtime stub probe) or the
    /// OS is known to use it (macOS 27+); otherwise the legacy down-mask is
    /// preserved unchanged.
    static func sendActionMask(
        buttonWindowIsStub: Bool,
        isMacOS27OrLater: Bool
    ) -> NSEvent.EventTypeMask {
        if buttonWindowIsStub || isMacOS27OrLater {
            return [.leftMouseUp, .rightMouseUp]
        }
        return [.leftMouseDown, .rightMouseDown]
    }

    /// Runtime OS gate. `#available` is a pure runtime version comparison, so
    /// this compiles and behaves correctly with older SDKs too.
    static var isMacOS27OrLater: Bool {
        if #available(macOS 27.0, *) {
            return true
        }
        return false
    }
}

// MARK: - MenuBarStatusItemClickGeometry

/// Geometry-first click judgment for the status item button. Under the stub
/// host the historical `event.window === button.window` identity chain is
/// untrustworthy, while a screen-rect containment test keeps working wherever
/// a healthy rect is available and explicitly reports "cannot decide" where
/// it is not.
enum MenuBarStatusItemClickGeometry {
    /// Containment test in screen coordinates. Returns nil when no healthy
    /// button rect is available (the stub host collapses the rect to nil),
    /// telling the caller geometry cannot decide. The top edge counts as
    /// inside — clicks slammed against the screen top must still hit the
    /// item — while the trailing edge does not, because the neighboring
    /// status item starts there.
    static func isLocationInsideButton(
        _ screenLocation: NSPoint,
        buttonScreenRect: NSRect?
    ) -> Bool? {
        guard let rect = buttonScreenRect, rect.width > 0, rect.height > 0 else {
            return nil
        }
        guard screenLocation.x >= rect.minX, screenLocation.x < rect.maxX else {
            return false
        }
        return screenLocation.y >= rect.minY && screenLocation.y <= rect.maxY
    }

    /// Whether a click landed in the menu bar strip of the given screen. Used
    /// only to decide whether an outside-click dismissal *could* have been a
    /// click on our own geometry-less icon; the top edge is inclusive for the
    /// same slam-to-top reason as above.
    static func isLocationInMenuBarBand(
        _ screenLocation: NSPoint,
        screenFrame: NSRect,
        bandHeight: CGFloat
    ) -> Bool {
        guard bandHeight > 0 else { return false }
        guard
            screenLocation.x >= screenFrame.minX,
            screenLocation.x <= screenFrame.maxX
        else {
            return false
        }
        return screenLocation.y >= screenFrame.maxY - bandHeight
            && screenLocation.y <= screenFrame.maxY
    }

    /// Menu bar strip height for one screen. The visible-frame inset tracks
    /// the real height (including taller notched / beta bars); when the menu
    /// bar is auto-hidden that inset is 0, so the status bar thickness keeps
    /// a usable minimum. Overshooting is harmless: the band only gates
    /// *recording* a suppression candidate, never the suppression match.
    static func menuBarBandHeight(
        screenFrameMaxY: CGFloat,
        visibleFrameMaxY: CGFloat,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        max(screenFrameMaxY - visibleFrameMaxY, statusBarThickness)
    }
}

// MARK: - Toggle suppression (stub-host icon-click bounce)

/// Identity of one physical click, reduced to Sendable values so it can hop
/// from an event monitor to the main actor and later be compared against the
/// action's `NSApp.currentEvent`.
///
/// On the rehosted (stub) menu bar the event number CANNOT carry the
/// identity: the monitor sees the user's physical mouse-down with its real
/// window-server number, but the action receives a host-SYNTHESIZED up
/// whose number is unrelated (observed live on 26A5353q: armed
/// eventNumber=6845, the matching action arrived unsuppressed — while
/// fully synthetic clicks deliver 0 on both sides). `eventNumber` is kept
/// for diagnostics only; the identity is the location plus the time
/// window: a click's down and up land at the same point, while a click on
/// a different status item lands tens of points away.
struct MenuBarStatusItemClickIdentity: Equatable, Sendable {
    let eventNumber: Int
    let timestamp: TimeInterval
    let screenLocation: CGPoint
}

/// Stub host: a click on our own icon is first seen by the outside-click
/// monitors (no usable geometry, untrustworthy identity chain → judged
/// "outside" → panels dismissed), then the same click's leftMouseUp action
/// arrives and would toggle the panels straight back open — the icon could
/// never close them. Recording the dismissing click lets the controller treat
/// the matching action as the already-completed toggle-off. Nothing is ever
/// recorded on healthy hosts, so their behavior is unchanged.
struct MenuBarStatusItemToggleSuppressor {
    /// Staleness bound between the dismissing mouse-down and the action's
    /// mouse-up. Must absorb both a press-and-hold release and the rehosted
    /// menu bar's forwarding latency (observed up to ~1s on 26A5353q between
    /// the monitored physical down and the synthesized action up).
    static let maximumClickDuration: TimeInterval = 10

    /// Maximum distance between the dismissing down and the action's up for
    /// them to count as one click. A click's down/up share a point (small
    /// jitter aside); distinct status items sit tens of points apart. The
    /// location carries the whole identity on the stub host — see
    /// `MenuBarStatusItemClickIdentity` for why the event number cannot.
    static let maximumClickDrift: CGFloat = 8

    /// The activation-dismissal path has no NSEvent and stamps its record
    /// with "now", which can land AFTER the forwarded action's own event
    /// timestamp (observed live: the suppression was missed and the panel
    /// bounced because elapsed came out negative). Allow that much backward
    /// skew before treating the action as predating the record.
    static let maximumTimestampSkew: TimeInterval = 2

    private struct PendingDismissal {
        let click: MenuBarStatusItemClickIdentity
        let dismissedPanels: Set<MenuBarStatusItemInvocation>
    }

    private var pendingDismissal: PendingDismissal?

    mutating func recordOutsideDismissal(
        _ click: MenuBarStatusItemClickIdentity,
        dismissedPanels: Set<MenuBarStatusItemInvocation>
    ) {
        pendingDismissal = PendingDismissal(click: click, dismissedPanels: dismissedPanels)
    }

    /// True when `action` is the same physical click that already dismissed
    /// the panel it targets — its toggle-off is complete and reopening must
    /// be skipped. A click targeting a panel that was NOT among the dismissed
    /// ones is a panel switch (e.g. Option-click for the secondary panel
    /// while the primary was open) and must proceed. Every evaluation clears
    /// the record: a match may only suppress once, and a non-match means a
    /// newer click superseded it.
    mutating func shouldSuppressToggle(
        for action: MenuBarStatusItemClickIdentity,
        target: MenuBarStatusItemInvocation
    ) -> Bool {
        guard let pending = pendingDismissal else { return false }
        pendingDismissal = nil
        guard pending.dismissedPanels.contains(target) else { return false }
        let drift = hypot(
            action.screenLocation.x - pending.click.screenLocation.x,
            action.screenLocation.y - pending.click.screenLocation.y
        )
        guard drift <= Self.maximumClickDrift else { return false }
        let elapsed = action.timestamp - pending.click.timestamp
        return elapsed >= -Self.maximumTimestampSkew && elapsed <= Self.maximumClickDuration
    }
}
