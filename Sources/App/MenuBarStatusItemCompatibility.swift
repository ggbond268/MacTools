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
