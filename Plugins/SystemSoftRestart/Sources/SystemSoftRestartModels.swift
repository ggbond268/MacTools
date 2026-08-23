import Foundation

enum SystemSoftRestartPhase: String, Codable, Sendable {
    case preparing
    case backingUpDock
    case restartingServices
    case waitingForServices
    case reopeningApplications
    case restoringDock
    case completed
}

enum SystemSoftRestartDiagnosticKind: String, Codable, Sendable {
    case applicationValidation
    case launchdJob
    case essentialServices
    case dockRestore
    case applicationReopen
    case summary
}

struct SystemSoftRestartDiagnostic: Codable, Equatable, Sendable {
    let kind: SystemSoftRestartDiagnosticKind
    let subject: String
    let message: String
}

struct SystemSoftRestartEvent: Codable, Equatable, Sendable {
    let phase: SystemSoftRestartPhase
    let applicationCount: Int
    let warningCount: Int
    let diagnostics: [SystemSoftRestartDiagnostic]

    init(
        phase: SystemSoftRestartPhase,
        applicationCount: Int = 0,
        warningCount: Int = 0,
        diagnostics: [SystemSoftRestartDiagnostic] = []
    ) {
        self.phase = phase
        self.applicationCount = applicationCount
        self.warningCount = warningCount
        self.diagnostics = diagnostics
    }
}

struct SystemSoftRestartRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let hostProcessIdentifier: Int32
    let applicationPaths: [String]
    let reopensApplications: Bool
    let preservesDockLayout: Bool
    let dockBackupPath: String?

    init(
        hostProcessIdentifier: Int32,
        applicationPaths: [String],
        reopensApplications: Bool,
        preservesDockLayout: Bool,
        dockBackupPath: String?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.hostProcessIdentifier = hostProcessIdentifier
        self.applicationPaths = applicationPaths
        self.reopensApplications = reopensApplications
        self.preservesDockLayout = preservesDockLayout
        self.dockBackupPath = dockBackupPath
    }
}

struct SystemSoftRestartPlan: Equatable, Sendable {
    let applicationURLs: [URL]
    let reopensApplications: Bool
    let preservesDockLayout: Bool

    var applicationCount: Int {
        reopensApplications ? applicationURLs.count : 0
    }
}

struct SystemSoftRestartResult: Equatable, Sendable {
    let warningCount: Int
    let diagnostics: [SystemSoftRestartDiagnostic]

    init(
        warningCount: Int,
        diagnostics: [SystemSoftRestartDiagnostic] = []
    ) {
        self.warningCount = warningCount
        self.diagnostics = diagnostics
    }
}
