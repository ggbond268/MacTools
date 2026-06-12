import CoreGraphics

/// Pure down/up pairing state machine behind the middle-click CGEvent tap.
///
/// Extracted from the tap callback so the pairing rules are unit-testable
/// without a live event tap. `decide` runs on the tap thread for every masked
/// mouse event and must stay allocation-free (value types only, no captures).
enum MiddleClickPairing {

    /// Tap-side flags mirrored from `MiddleClickSession`.
    struct State: Equatable {
        /// The required finger count is currently touching the trackpad.
        var threeDown: Bool
        /// A converted otherMouseDown is waiting for its paired up.
        var wasThreeDown: Bool
    }

    /// In-place rewrite the tap callback should apply to the current event.
    enum Rewrite: Equatable {
        case none
        case middleDown
        case middleUp
    }

    struct Decision: Equatable {
        var rewrite: Rewrite
        var state: State
    }

    static func decide(type: CGEventType, state: State) -> Decision {
        var state = state
        switch type {
        case .leftMouseDown, .rightMouseDown:
            if state.threeDown {
                state.threeDown = false
                state.wasThreeDown = true
                return Decision(rewrite: .middleDown, state: state)
            }
            // An armed flag at this point means the up paired with an earlier
            // converted down never reached the tap (seen on macOS 27 beta when
            // the rewritten down targets the synthesized menu bar window). On a
            // single-pointer device a new physical down can only follow the
            // previous up, so this down is sufficient proof the up was lost:
            // disarm and let this ordinary click pass through untouched.
            // Deliberately no wall-clock timeout — a legitimate middle-button
            // press (autoscroll, drag) may stay down arbitrarily long.
            state.wasThreeDown = false
            return Decision(rewrite: .none, state: state)
        case .leftMouseUp, .rightMouseUp:
            if state.wasThreeDown {
                state.wasThreeDown = false
                return Decision(rewrite: .middleUp, state: state)
            }
            return Decision(rewrite: .none, state: state)
        default:
            // Non-mouse callbacks (e.g. tapDisabledByTimeout) must not disturb
            // pairing state.
            return Decision(rewrite: .none, state: state)
        }
    }
}
