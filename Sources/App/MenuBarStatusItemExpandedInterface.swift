import AppKit
import OSLog

// MARK: - MenuBarStatusItemExpandedInterface
//
// Runtime-only bridge to the macOS 27 `NSStatusItem.expandedInterfaceDelegate`
// channel. The app builds against the 26.5 SDK with a macOS 14.0 target, so no
// macOS 27 symbol may be referenced directly: every touchpoint goes through
// selector-based dispatch with the exact selector strings probed on 26A5353q.
// Behavior contract verified on device:
// - The status item holds the delegate WEAKLY; whoever attaches must keep a
//   strong reference to the adapter or callbacks silently stop.
// - Attaching the delegate REPLACES the button target/action channel (the
//   action never fires again while attached); it does not augment it.
// - The host never ends a session on its own (outside clicks produce no
//   didEnd); the only termination is `cancel`, which fires didEnd
//   synchronously on the same call stack with the session property already
//   cleared to nil.
// - On macOS <= 26 the delegate setter selector does not exist, so
//   `isSupported(by:)` is false and the legacy action route stays unchanged.

@MainActor
final class MenuBarStatusItemExpandedInterfaceAdapter: NSObject {
    // Exact ObjC selector strings probed on 26A5353q. One wrong character
    // means the host silently never calls back; tests pin every literal.
    static let delegateSetterSelectorName = "setExpandedInterfaceDelegate:"
    static let delegateGetterKey = "expandedInterfaceDelegate"
    static let sessionGetterSelectorName = "expandedInterfaceSession"
    static let sessionDidBeginSelectorName = "statusItem:didBeginExpandedInterfaceSession:"
    static let sessionDidEndSelectorName = "statusItemDidEndExpandedInterfaceSession:animated:"
    static let sessionCancelSelectorName = "cancel"

    var onSessionBegin: ((_ session: NSObject) -> Void)?
    var onSessionEnd: ((_ animated: Bool) -> Void)?

    /// The host does not check protocol conformance (the protocol is not even
    /// registered with the ObjC runtime on 26A5353q); responding to the
    /// delegate setter is the entire support gate.
    static func isSupported(by item: NSStatusItem) -> Bool {
        item.responds(to: NSSelectorFromString(delegateSetterSelectorName))
    }

    /// Sets this adapter as the item's expanded-interface delegate and
    /// verifies the write by reading the property back. Returns true only
    /// when the read-back is this exact adapter. The caller must retain the
    /// adapter for as long as it is attached (the item's reference is weak).
    func attach(to item: NSStatusItem) -> Bool {
        guard Self.isSupported(by: item) else { return false }
        // perform(_:with:), not KVC: setValue(forKey:) with a wrong key
        // raises an ObjC exception Swift cannot catch.
        _ = item.perform(NSSelectorFromString(Self.delegateSetterSelectorName), with: self)

        // The read-back KVC key resolves through the property getter; a
        // responds check must guard it for the same uncatchable-exception
        // reason as above.
        guard item.responds(to: NSSelectorFromString(Self.delegateGetterKey)) else {
            rollBackAttach(on: item)
            AppLog.pluginHost.error(
                "Status item responds to the expanded-interface delegate setter but not the getter; attach aborted"
            )
            return false
        }
        guard (item.value(forKey: Self.delegateGetterKey) as? NSObject) === self else {
            rollBackAttach(on: item)
            AppLog.pluginHost.error(
                "Expanded-interface delegate read-back mismatch after attach; falling back to the action route"
            )
            return false
        }
        return true
    }

    /// Every failed attach must end with the delegate cleared: an attached
    /// delegate replaces the button action channel, so a false return that
    /// leaves it set would strand the status item with neither route.
    private func rollBackAttach(on item: NSStatusItem) {
        _ = item.perform(NSSelectorFromString(Self.delegateSetterSelectorName), with: nil)
    }

    /// Clears the item's expanded-interface delegate. A no-op (not a failure)
    /// where the API does not exist.
    func detach(from item: NSStatusItem) {
        guard Self.isSupported(by: item) else { return }
        _ = item.perform(NSSelectorFromString(Self.delegateSetterSelectorName), with: nil)
    }

    /// Cancels an expanded-interface session. `cancel` triggers the didEnd
    /// callback synchronously on this same call stack; callers must have
    /// their state ready for that re-entry BEFORE calling this.
    static func cancel(session: NSObject) {
        let selector = NSSelectorFromString(sessionCancelSelectorName)
        guard session.responds(to: selector) else {
            // A session that cannot be cancelled stays active host-side and
            // leaves the status item inert; this must never be silent.
            AppLog.pluginHost.error(
                "Expanded-interface session \(String(describing: type(of: session)), privacy: .public) does not respond to cancel; session left active"
            )
            return
        }
        _ = session.perform(selector)
    }

    // MARK: ObjC delegate callbacks (host-invoked; selectors must match the
    // probed strings exactly)

    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func statusItemDidBeginExpandedInterfaceSession(_ statusItem: NSStatusItem, session: NSObject) {
        MenuBarStatusItemDiagnostics.trace(
            "expandedInterface didBegin session=\(Unmanaged.passUnretained(session).toOpaque())"
        )
        onSessionBegin?(session)
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        MenuBarStatusItemDiagnostics.trace("expandedInterface didEnd animated=\(animated)")
        onSessionEnd?(animated)
    }
}

// MARK: - MenuBarExpandedSessionCoordinator

/// Pure expanded-session bookkeeping, free of AppKit so it is testable
/// headless. Invariants it encodes:
/// - `cancel` fires didEnd synchronously on the same call stack, so any state
///   that must not be observed by that re-entry is cleared BEFORE cancelling.
/// - The host never auto-ends a session; a stored session stays active until
///   the app cancels it.
@MainActor
final class MenuBarExpandedSessionCoordinator {
    private(set) var activeSession: NSObject?
    private(set) var isHandlingSessionEnd = false
    /// One-shot takeover marker. Set when `sessionDidBegin` returns a
    /// replaced session: the caller cancels that session, and the cancel
    /// fires didEnd synchronously on the same stack. That didEnd belongs to
    /// the SUPERSEDED session — without this marker it would wipe the
    /// just-stored new session and dismiss, leaving the live host session
    /// uncancellable (the item stays inert until the app restarts).
    private var expectsReplacedSessionEnd = false

    /// Stores the new session and returns the replaced previous one; the
    /// caller is responsible for cancelling the returned session (its
    /// synchronous didEnd is absorbed by `sessionDidEnd`). Returns nil when
    /// nothing was replaced, including a re-begin of the identical session
    /// object (cancelling it would tear down the session just stored).
    func sessionDidBegin(_ session: NSObject) -> NSObject? {
        let previous = activeSession
        activeSession = session
        guard let previous, previous !== session else { return nil }
        expectsReplacedSessionEnd = true
        return previous
    }

    /// Single close gate. With an active session the close must go through
    /// `cancel(session)`: `activeSession` is cleared first because cancel
    /// synchronously re-enters via didEnd. Without a session the request
    /// falls through to `directDismiss()` (the macOS <= 26 path).
    func requestClose(cancel: (NSObject) -> Void, directDismiss: () -> Void) {
        // Any takeover expectation is stale by close time (the takeover
        // caller cancels the replaced session synchronously right after
        // sessionDidBegin returns); it must not swallow the didEnd produced
        // by this close.
        expectsReplacedSessionEnd = false
        guard let session = activeSession else {
            directDismiss()
            return
        }
        activeSession = nil
        cancel(session)
    }

    /// didEnd handler. The first guard absorbs the synchronous didEnd of a
    /// session superseded during takeover: `activeSession` already holds the
    /// live replacement, so neither it nor the panel may be torn down here
    /// (the begin caller settles any stale panels itself). The second guard
    /// absorbs re-entry: a `dismiss` implementation that itself routes back
    /// into a close path must not recurse.
    func sessionDidEnd(dismiss: () -> Void) {
        if expectsReplacedSessionEnd {
            expectsReplacedSessionEnd = false
            return
        }
        if isHandlingSessionEnd { return }
        isHandlingSessionEnd = true
        defer { isHandlingSessionEnd = false }
        activeSession = nil
        dismiss()
    }
}
