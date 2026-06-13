import AppKit
import CoreGraphics
import Foundation

// MARK: - MenuBarSecondaryClickHitTest

/// Pure, headless-testable hit geometry for the secondary-click event tap.
///
/// The tap is the macOS 27 reachability path for a right-click on our own
/// status item: the rehosted single-window menu bar host no longer routes
/// right mouse events into any high-level channel (action / menu / expanded
/// interface / gesture recognizers all stay silent — verified on 26A5353q),
/// but the physical events are still alive at the `.cgSessionEventTap` layer.
/// A listen-only tap observes them there and, only when one lands on our icon,
/// opens the panel. Deciding "on our icon" means comparing the CG-global event
/// location against the status item button's current AppKit-global frame, so
/// the two coordinate systems must be reconciled first.
enum MenuBarSecondaryClickHitTest {
    /// Convert a `CGEvent.location` (CG global: origin at the main display's
    /// top-left, y growing downward) into AppKit global coordinates (origin at
    /// the main display's bottom-left, y growing upward). x is identical in
    /// both systems; only y flips around the main display height.
    ///
    /// `mainDisplayHeight` must be the height of the display that contains the
    /// global origin — `CGDisplayBounds(CGMainDisplayID()).height` — so the
    /// flip lines up with the shared origin of both coordinate spaces.
    static func appKitPoint(
        fromCGGlobal cg: CGPoint,
        mainDisplayHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: cg.x, y: mainDisplayHeight - cg.y)
    }

    /// Whether a CG-global event location falls inside the status item button's
    /// current AppKit-global frame. The frame is read live by the caller on
    /// every event (never cached): the icon moves when other apps add/remove
    /// items, when the user drags it, hides icons, switches displays, or
    /// changes resolution.
    ///
    /// Fail-closed: a degenerate frame (empty, non-finite, or zero-sized) can
    /// never be a hit, so the caller falls back to Option+left-click instead of
    /// opening the panel at a bogus location. No tolerance is applied — a click
    /// that drifts onto a neighboring item must not count as a hit.
    static func isHit(
        cgEventLocation: CGPoint,
        buttonFrame: CGRect,
        mainDisplayHeight: CGFloat
    ) -> Bool {
        guard isUsableFrame(buttonFrame), mainDisplayHeight.isFinite else {
            return false
        }
        guard cgEventLocation.x.isFinite, cgEventLocation.y.isFinite else {
            return false
        }
        let point = appKitPoint(fromCGGlobal: cgEventLocation, mainDisplayHeight: mainDisplayHeight)
        return buttonFrame.contains(point)
    }

    /// A frame is usable only when it is finite and has positive area. `CGRect`
    /// can be `.null` / `.infinite` or carry NaN components; all of those must
    /// degrade to "no hit".
    private static func isUsableFrame(_ frame: CGRect) -> Bool {
        guard !frame.isNull, !frame.isEmpty, !frame.isInfinite else { return false }
        guard
            frame.origin.x.isFinite, frame.origin.y.isFinite,
            frame.size.width.isFinite, frame.size.height.isFinite
        else {
            return false
        }
        return frame.size.width > 0 && frame.size.height > 0
    }
}

// MARK: - MenuBarSecondaryClickTap

/// Listen-only CGEvent tap that revives the secondary (right) click on the
/// macOS 27 menu bar host.
///
/// Design constraints (all load-bearing):
/// - **Pure observer.** The tap is `.cgSessionEventTap` + `.listenOnly`; the
///   callback returns the event unmodified on every path so it is never
///   intercepted, rewritten, or swallowed. The panel is opened as a side
///   effect, the event itself always flows on untouched.
/// - **Live geometry, never cached.** Every event re-reads the button frame
///   through `buttonFrameProvider`. The icon position is not stable across
///   item add/remove, user drags, the hide-icons feature, display changes, or
///   resolution changes, so a remembered rect would mis-hit.
/// - **Fail-closed.** No Accessibility trust, tap-create failure, or missing
///   frame all leave the tap uninstalled (`start()` returns false); the caller
///   then relies on the always-available Option+left-click path.
/// - **Self-healing.** `.tapDisabledByTimeout` / `.tapDisabledByUserInput`
///   re-enable the tap in place, mirroring the existing MiddleClick /
///   PhysicalCleanMode tap sessions.
@MainActor
final class MenuBarSecondaryClickTap {
    /// Called with the hit click's location in AppKit global coordinates (the
    /// same space NSEvent screen locations use) so the caller can match it
    /// against the click suppressor that the outside-click monitors arm.
    private let onSecondaryClick: (CGPoint) -> Void
    private let buttonFrameProvider: () -> CGRect?
    private let mainDisplayHeightProvider: () -> CGFloat

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let logger = AppLog.menuBarSecondaryClickTap

    init(
        onSecondaryClick: @escaping (CGPoint) -> Void,
        buttonFrameProvider: @escaping () -> CGRect?,
        mainDisplayHeightProvider: @escaping () -> CGFloat = {
            CGDisplayBounds(CGMainDisplayID()).height
        }
    ) {
        self.onSecondaryClick = onSecondaryClick
        self.buttonFrameProvider = buttonFrameProvider
        self.mainDisplayHeightProvider = mainDisplayHeightProvider
    }

    /// Install the tap. Returns false (and stays uninstalled) on any failure so
    /// the caller degrades to Option+left-click.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Accessibility trust is required to create a session event tap. Do not
        // prompt here — the caller owns the permission UX; without trust the
        // secondary panel is still reachable via Option+left-click.
        guard AccessibilityCheck.isTrusted() else {
            logger.info("secondary-click tap not started: Accessibility not trusted")
            return false
        }

        // Listen only to rightMouseDown. Down alone is the de-dupe key (one open
        // per physical click); the paired up is irrelevant and ignored.
        let mask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue)

        // The @convention(c) callback captures nothing; `self` is passed
        // through `userInfo` as a raw pointer (Sendable) and resolved back to
        // the instance only inside the main-actor hop, so no non-Sendable value
        // crosses the isolation boundary. The tap source lives on the main run
        // loop, so the callback already runs on the main thread and
        // `assumeIsolated` only satisfies the type system.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let passthrough = Unmanaged.passUnretained(event)
            guard let userInfo else { return passthrough }

            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // Self-heal: the system disabled the tap (slow callback or a
                // user-input storm). Re-enable in place.
                MainActor.assumeIsolated {
                    let tap = Unmanaged<MenuBarSecondaryClickTap>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    tap.reEnable()
                }
                return passthrough
            case .rightMouseDown:
                let location = event.location
                MainActor.assumeIsolated {
                    let tap = Unmanaged<MenuBarSecondaryClickTap>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    // Frame read live on every event — never cached, the icon
                    // moves for many reasons (see type doc comment).
                    tap.handleRightMouseDown(at: location)
                }
                // Listen-only: always return the event unmodified. The host
                // still does nothing with the right-click; we just observe it.
                return passthrough
            default:
                return passthrough
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("failed to create secondary-click CGEvent tap; check Accessibility permission")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.error("failed to create run loop source for secondary-click tap")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        logger.info("secondary-click tap started")
        return true
    }

    /// Tear the tap down. Idempotent: safe to call when nothing is installed.
    func stop() {
        guard let tap = eventTap else {
            runLoopSource = nil
            return
        }
        if CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
        logger.info("secondary-click tap stopped")
    }

    // MARK: - Private

    private func reEnable() {
        guard let tap = eventTap, CFMachPortIsValid(tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("secondary-click tap re-enabled after system disable")
    }

    private func handleRightMouseDown(at cgLocation: CGPoint) {
        // Frame read live on every event; a missing frame fails closed.
        guard let frame = buttonFrameProvider() else {
            MenuBarStatusItemDiagnostics.trace("secondary-click tap: rightDown cg=\(cgLocation) frame=nil → no-hit")
            return
        }
        let mainDisplayHeight = mainDisplayHeightProvider()
        let didHit = MenuBarSecondaryClickHitTest.isHit(
            cgEventLocation: cgLocation,
            buttonFrame: frame,
            mainDisplayHeight: mainDisplayHeight
        )
        MenuBarStatusItemDiagnostics.trace(
            "secondary-click tap: rightDown cg=\(cgLocation) frame=\(NSStringFromRect(frame)) mainH=\(mainDisplayHeight) hit=\(didHit)"
        )
        guard didHit else {
            return
        }
        // Hand back the click location in AppKit global coordinates so the
        // caller can match it against the same suppressor the outside-click
        // monitors arm (they record screen locations).
        let appKitLocation = MenuBarSecondaryClickHitTest.appKitPoint(
            fromCGGlobal: cgLocation,
            mainDisplayHeight: mainDisplayHeight
        )
        onSecondaryClick(appKitLocation)
    }
}
