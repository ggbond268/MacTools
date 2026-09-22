import Darwin
import Foundation

struct MoleEnginePlan: Decodable, Sendable {
    struct Engine: Decodable, Sendable {
        let name: String
        let revision: String
    }

    struct Application: Decodable, Sendable {
        let name: String
        let path: String
        let bundleID: String
        let identity: String
        let infoIdentity: String

        enum CodingKeys: String, CodingKey {
            case name, path, identity
            case bundleID = "bundle_id"
            case infoIdentity = "info_identity"
        }
    }

    struct Candidate: Decodable, Sendable {
        let id: String
        let path: String
        let kind: String
        let selectedByDefault: Bool
        let reviewOnly: Bool

        enum CodingKeys: String, CodingKey {
            case id, path, kind
            case selectedByDefault = "selected_by_default"
            case reviewOnly = "review_only"
        }
    }

    let schemaVersion: Int
    let engine: Engine
    let planID: String
    let status: String
    let source: String
    let blockedReason: String?
    let application: Application
    let requiresSudo: Bool
    let homebrewCask: String?
    let siblingGuard: String
    let estimatedKilobytes: Int64
    let candidates: [Candidate]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case engine, status, source, application, candidates, warnings
        case schemaVersion = "schema_version"
        case planID = "plan_id"
        case blockedReason = "blocked_reason"
        case requiresSudo = "requires_sudo"
        case homebrewCask = "homebrew_cask"
        case siblingGuard = "sibling_guard"
        case estimatedKilobytes = "estimated_kilobytes"
    }
}

enum MoleEngineError: LocalizedError, Sendable {
    case unavailable
    case timedOut
    case outputTooLarge
    case rejected(String)
    case incompatible

    var errorDescription: String? {
        switch self {
        case .unavailable: "The embedded Mole engine is unavailable."
        case .timedOut: "The embedded Mole review timed out without changing files."
        case .outputTooLarge: "The embedded Mole review produced too much output."
        case let .rejected(message): message.isEmpty ? "The embedded Mole review could not be completed." : message
        case .incompatible: "The embedded Mole engine returned an unsupported plan format."
        }
    }
}

protocol MoleEnginePlanning: Sendable {
    func plan(applicationPath: String) async throws -> MoleEnginePlan
}

struct BundledMoleEngine: MoleEnginePlanning, Sendable {
    let rootURL: URL
    let temporaryDirectory: URL
    var timeout: TimeInterval = 90
    var maximumOutputBytes = 4 * 1_024 * 1_024

    func plan(applicationPath: String) async throws -> MoleEnginePlan {
        let task = Task.detached(priority: .userInitiated) {
            try runPlan(applicationPath: applicationPath)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runPlan(applicationPath: String) throws -> MoleEnginePlan {
        let fileManager = FileManager.default
        let script = rootURL.appendingPathComponent("mactools-engine.sh")
        let revisionURL = rootURL.appendingPathComponent("REVISION")
        guard fileManager.isReadableFile(atPath: script.path),
              let expectedRevision = try? String(contentsOf: revisionURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedRevision.isEmpty
        else { throw MoleEngineError.unavailable }

        let runDirectory = temporaryDirectory.appendingPathComponent("MoleEngine", isDirectory: true)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "plan", "--app", applicationPath]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "NO_COLOR": "1",
            "TMPDIR": runDirectory.path,
            "MO_NO_OPLOG": "1",
            "MOLE_LOG_FILE": runDirectory.appendingPathComponent("mole.log").path,
            "MOLE_DEBUG_LOG_FILE": runDirectory.appendingPathComponent("debug.log").path,
            "MOLE_OPERATIONS_LOG": runDirectory.appendingPathComponent("operations.log").path,
            "MOLE_PKG_RECEIPT_CACHE_FILE": runDirectory.appendingPathComponent("pkg-receipts").path,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let errorDescriptor = errorPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outputDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(errorDescriptor, F_SETFL, O_NONBLOCK)
        try process.run()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        var output = Data()
        var errors = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            try drain(outputDescriptor, into: &output)
            try drain(errorDescriptor, into: &errors)
            guard output.count + errors.count <= maximumOutputBytes else { throw MoleEngineError.outputTooLarge }
            guard Date() < deadline else { throw MoleEngineError.timedOut }
            usleep(20_000)
        }
        try drain(outputDescriptor, into: &output)
        try drain(errorDescriptor, into: &errors)
        guard output.count + errors.count <= maximumOutputBytes else { throw MoleEngineError.outputTooLarge }

        guard process.terminationStatus == 0 else {
            let message = String(data: errors.prefix(4_096), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MoleEngineError.rejected(message)
        }
        let value = try JSONDecoder().decode(MoleEnginePlan.self, from: output)
        guard value.schemaVersion == 1, value.engine.name == "Mole",
              value.engine.revision == expectedRevision,
              value.application.path == applicationPath,
              !value.planID.isEmpty,
              value.candidates.allSatisfy({ !$0.id.isEmpty && $0.path.hasPrefix("/") })
        else { throw MoleEngineError.incompatible }
        return value
    }

    private func drain(_ descriptor: Int32, into data: inout Data) throws {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw AppUninstallerError.io(errno)
        }
    }
}
