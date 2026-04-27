import Foundation

enum DiskCleanChoice: String, CaseIterable, Identifiable, Equatable, Sendable {
    case cache
    case developer
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cache:
            return "缓存清理"
        case .developer:
            return "开发者缓存清理"
        case .browser:
            return "浏览器缓存清理"
        }
    }
}

enum DiskCleanRisk: Equatable, Sendable {
    case low
    case medium
    case high
}

enum DiskCleanSafetyStatus: Equatable, Sendable {
    case allowed
    case whitelisted(rule: String)
    case protected(reason: String)
    case invalid(reason: String)
    case requiresAdmin(reason: String)
    case inUse(processName: String)

    var isCleanable: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }
}

enum DiskCleanScanLogTone: Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

struct DiskCleanScanLogMessage: Equatable, Sendable {
    let text: String
    let tone: DiskCleanScanLogTone
}

struct DiskCleanScanLogEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let tone: DiskCleanScanLogTone
}

struct DiskCleanCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let ruleID: String
    let choice: DiskCleanChoice
    let title: String
    let path: String
    let sizeBytes: Int64
    let safety: DiskCleanSafetyStatus
    let risk: DiskCleanRisk
}

struct DiskCleanScanResult: Equatable, Sendable {
    let choices: Set<DiskCleanChoice>
    let candidates: [DiskCleanCandidate]
    let scannedAt: Date

    var cleanableCandidates: [DiskCleanCandidate] {
        candidates.filter { $0.safety.isCleanable }
    }

    var cleanableSizeBytes: Int64 {
        cleanableCandidates.reduce(0) { $0 + max($1.sizeBytes, 0) }
    }

    var protectedCount: Int {
        candidates.filter {
            if case .protected = $0.safety {
                return true
            }
            if case .whitelisted = $0.safety {
                return true
            }
            return false
        }.count
    }
}
