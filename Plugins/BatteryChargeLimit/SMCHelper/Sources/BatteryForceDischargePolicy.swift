enum BatteryForceDischargePolicyError: Swift.Error {
    case noAvailableKey
    case noKeyCleared
    case activeKeyClearFailed(key: String, underlying: Swift.Error)
    case indeterminateKeyClearFailed(key: String, underlying: Swift.Error)
}

enum BatteryForceDischargePolicy {
    struct Candidate: Equatable {
        let key: String
        let enabledValue: UInt8
    }

    static let tahoeAdapterKey = "CHIE"
    static let secondaryAdapterKey = "CH0J"
    static let legacyAdapterKey = "CH0I"

    static let candidates = [
        Candidate(key: tahoeAdapterKey, enabledValue: 0x08),
        Candidate(key: secondaryAdapterKey, enabledValue: 0x20),
        Candidate(key: legacyAdapterKey, enabledValue: 0x01),
    ]

    static func availableCandidates(hasKey: (String) -> Bool) -> [Candidate] {
        candidates.filter { hasKey($0.key) }
    }

    static func activeState(for value: UInt8?, enabledValue: UInt8) -> Bool? {
        guard let value else { return nil }
        if value == 0 { return false }
        return value == enabledValue ? true : nil
    }

    static func enable(
        _ candidates: [Candidate],
        write: (Candidate) throws -> Void
    ) throws {
        guard !candidates.isEmpty else {
            throw BatteryForceDischargePolicyError.noAvailableKey
        }

        var lastError: Swift.Error?
        for candidate in candidates {
            do {
                try write(candidate)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BatteryForceDischargePolicyError.noAvailableKey
    }

    static func disable(
        _ candidates: [Candidate],
        isActive: (Candidate) throws -> Bool?,
        clear: (Candidate) throws -> Void
    ) throws {
        guard !candidates.isEmpty else {
            throw BatteryForceDischargePolicyError.noAvailableKey
        }

        var clearedAnyKey = false
        var activeKeyFailure: (key: String, error: Swift.Error)?
        var indeterminateKeyFailure: (key: String, error: Swift.Error)?

        for candidate in candidates {
            let wasActive: Bool?
            do {
                wasActive = try isActive(candidate)
            } catch {
                wasActive = nil
            }

            do {
                try clear(candidate)
                clearedAnyKey = true
            } catch {
                if wasActive == true {
                    activeKeyFailure = (candidate.key, error)
                } else if wasActive == nil {
                    indeterminateKeyFailure = (candidate.key, error)
                }
            }
        }

        if let activeKeyFailure {
            throw BatteryForceDischargePolicyError.activeKeyClearFailed(
                key: activeKeyFailure.key,
                underlying: activeKeyFailure.error
            )
        }
        if let indeterminateKeyFailure {
            throw BatteryForceDischargePolicyError.indeterminateKeyClearFailed(
                key: indeterminateKeyFailure.key,
                underlying: indeterminateKeyFailure.error
            )
        }
        if !clearedAnyKey {
            throw BatteryForceDischargePolicyError.noKeyCleared
        }
    }
}
