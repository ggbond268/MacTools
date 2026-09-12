import Foundation

enum AppUninstallerError: Error, LocalizedError, Equatable, Sendable {
    case invalidApplication
    case unsafePath
    case incomplete
    case changed
    case expired
    case running
    case blocked
    case io(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidApplication: "无法读取有效的应用身份。"
        case .unsafePath: "路径包含链接、受保护位置或不支持的卷。"
        case .incomplete: "检查未完成，请查看扫描范围并重新扫描。"
        case .changed: "项目已变化，请重新扫描。"
        case .expired: "检查结果已过期，请重新扫描。"
        case .running: "应用或其组件仍在运行，请退出后重试。"
        case .blocked: "此项目需要使用原安装工具或由管理员处理。"
        case let .io(code): "无法访问项目（\(code)）。"
        }
    }
}

struct UninstallFileIdentity: Hashable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct UninstallTreeSnapshot: Hashable, Codable, Sendable {
    let identity: UninstallFileIdentity
    let digest: String
    let allocatedBytes: Int64
    let entryCount: Int
}

enum UninstallDataClass: String, Codable, CaseIterable, Sendable {
    case application, cache, log, preference, savedState, support, container, groupContainer, launchAgent
    var isDisposable: Bool { [.application, .cache, .log, .preference, .savedState].contains(self) }
}

enum UninstallConfidence: String, Codable, CaseIterable, Sendable {
    case verified, strong, shared, possible, protected
}

enum UninstallEvidence: Hashable, Codable, Sendable {
    case selectedApplication
    case exactIdentifier(String)
    case preferenceDomain(String)
    case savedState(String)
    case containerMetadata(String)
    case groupEntitlement(String)
    case competingApplication(String)
    case executableInBundle(String)
    case conflictingMetadata
}

enum UninstallSource: String, Codable, Sendable {
    case unknown, appStoreReceipt, homebrew, system, managed, vendorRequired
}

struct UninstallApplication: Identifiable, Hashable, Codable, Sendable {
    var id: String { path }
    let path: String
    let bundleID: String
    let name: String
    let version: String
    let build: String
    let executable: String
    let teamID: String?
    let groups: [String]
    let signingMetadataAvailable: Bool
    let identity: UninstallFileIdentity
    let metadataDigest: String
    let source: UninstallSource
    let restrictions: [String]
    var vendorUninstallers: [String] = []
}

struct UninstallCandidate: Identifiable, Hashable, Codable, Sendable {
    var id: String { path }
    let path: String
    let dataClass: UninstallDataClass
    let confidence: UninstallConfidence
    let evidence: [UninstallEvidence]
    let snapshot: UninstallTreeSnapshot?
    let blockedReason: String?

}

struct UninstallCoverage: Hashable, Codable, Sendable {
    let path: String
    let issue: String?
}

struct UninstallScan: Identifiable, Sendable {
    let id: UUID
    let observedAt: Date
    let application: UninstallApplication
    let candidates: [UninstallCandidate]
    let coverage: [UninstallCoverage]
    let inventory: [UninstallApplication]
    let inventoryComplete: Bool
    let sourceChecksComplete: Bool
    let runningPaths: [String]
    var expiresAt: Date { observedAt.addingTimeInterval(300) }
}

enum UninstallPaths {
    static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
    static func validIdentifier(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && segments.count >= 2 && segments.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    static func component(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }
}
