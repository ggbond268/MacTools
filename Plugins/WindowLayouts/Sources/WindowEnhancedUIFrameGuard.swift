import Foundation

/// Some apps animate consecutive AX frame writes while enhanced accessibility is
/// enabled. Keep suppression synchronous and scoped to a single frame transaction,
/// including its rollback; never hold it across task suspension or a pointer gesture.
/// Compatibility precedent: https://github.com/Hammerspoon/hammerspoon/pull/3836.
enum WindowEnhancedUIFrameGuard {
    static func perform<Value>(
        preserveEnhancedUI: Bool,
        readEnabled: () -> Bool?,
        setEnabled: (Bool) -> Bool,
        operation: () throws -> Value
    ) throws -> Value {
        guard !preserveEnhancedUI, readEnabled() == true else {
            return try operation()
        }

        // Even a failed AX write can have taken effect before timing out. Restore
        // after every disable attempt, without consulting task cancellation.
        _ = setEnabled(false)
        let result = Result { try operation() }
        let restored = restoreEnabled(readEnabled: readEnabled, setEnabled: setEnabled)
        switch result {
        case .success(let value):
            guard restored else { throw WindowLayoutError.frameWriteFailed }
            return value
        case .failure(let error):
            // Preserve the original transaction/cancellation error after cleanup.
            throw error
        }
    }

    private static func restoreEnabled(
        readEnabled: () -> Bool?,
        setEnabled: (Bool) -> Bool
    ) -> Bool {
        // Bound recovery for transient AX failures. Readback also handles apps
        // exposing a read-only attribute that was never actually disabled.
        for _ in 0..<3 {
            if setEnabled(true) || readEnabled() == true { return true }
        }
        return false
    }
}
