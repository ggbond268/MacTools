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
    case cleanupFailed
    case rejected(String)
    case incompatible

    var errorDescription: String? {
        switch self {
        case .unavailable: "The embedded Mole engine is unavailable."
        case .timedOut: "The embedded Mole review timed out without changing files."
        case .outputTooLarge: "The embedded Mole review produced too much output."
        case .cleanupFailed: "The embedded Mole review stopped, but a helper process could not be cleaned up."
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

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let environment = [
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
        var descriptors = try Self.duplicatedSpawnDescriptors([
            outputPipe.fileHandleForReading.fileDescriptor,
            errorPipe.fileHandleForReading.fileDescriptor,
            outputPipe.fileHandleForWriting.fileDescriptor,
            errorPipe.fileHandleForWriting.fileDescriptor,
        ])
        defer { descriptors.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) } }
        let outputDescriptor = descriptors[0]
        let errorDescriptor = descriptors[1]
        _ = fcntl(outputDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(errorDescriptor, F_SETFL, O_NONBLOCK)
        let processID = try spawnBash(
            arguments: [script.path, "plan", "--app", applicationPath],
            environment: environment,
            outputDescriptor: descriptors[2],
            errorDescriptor: descriptors[3],
            closedDescriptors: [outputDescriptor, errorDescriptor]
        )
        _ = Darwin.close(descriptors[2])
        descriptors[2] = -1
        _ = Darwin.close(descriptors[3])
        descriptors[3] = -1
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        defer { try? outputPipe.fileHandleForReading.close(); try? errorPipe.fileHandleForReading.close() }

        var output = Data()
        var errors = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var processStatus: Int32?
        do {
            while processStatus == nil {
                try drain(outputDescriptor, into: &output, otherByteCount: errors.count, deadline: deadline)
                try drain(errorDescriptor, into: &errors, otherByteCount: output.count, deadline: deadline)
                var status: Int32 = 0
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID {
                    processStatus = status
                } else if result < 0, errno != EINTR {
                    throw AppUninstallerError.io(errno)
                }
                if processStatus == nil { usleep(20_000) }
            }
            try drain(outputDescriptor, into: &output, otherByteCount: errors.count, deadline: deadline)
            try drain(errorDescriptor, into: &errors, otherByteCount: output.count, deadline: deadline)
        } catch {
            let executionError = error
            try terminateProcessSession(processID)
            throw executionError
        }
        // A successful adapter should leave no descendants. Clean up any process that
        // inherited the dedicated group before accepting its output.
        try terminateProcessSession(processID)

        guard let processStatus, exitedSuccessfully(processStatus) else {
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

    private func drain(
        _ descriptor: Int32,
        into data: inout Data,
        otherByteCount: Int,
        deadline: Date
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw MoleEngineError.timedOut }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + otherByteCount + count <= maximumOutputBytes else {
                    throw MoleEngineError.outputTooLarge
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            throw AppUninstallerError.io(errno)
        }
    }

    private func spawnBash(
        arguments: [String],
        environment: [String: String],
        outputDescriptor: Int32,
        errorDescriptor: Int32,
        closedDescriptors: [Int32]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AppUninstallerError.incomplete
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AppUninstallerError.incomplete
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let descriptorsToClose = closedDescriptors + [outputDescriptor, errorDescriptor]
        let standardInputResult = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0)
        }
        guard standardInputResult == 0,
              posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorDescriptor, STDERR_FILENO) == 0,
              descriptorsToClose.allSatisfy({ posix_spawn_file_actions_addclose(&actions, $0) == 0 }) else {
            throw AppUninstallerError.incomplete
        }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        [SIGALRM, SIGCHLD, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM].forEach {
            sigaddset(&defaultSignals, $0)
        }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else {
            throw AppUninstallerError.incomplete
        }
        let executable = "/bin/bash"
        let argumentValues = [executable] + arguments
        let environmentValues = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        var processID: pid_t = 0
        let result = withCStringArray(argumentValues) { argumentPointers in
            withCStringArray(environmentValues) { environmentPointers in
                executable.withCString { executablePointer in
                    posix_spawn(&processID, executablePointer, &actions, &attributes,
                                argumentPointers, environmentPointers)
                }
            }
        }
        guard result == 0, processID > 0 else { throw AppUninstallerError.io(result) }
        return processID
    }

    static func duplicatedSpawnDescriptors(_ sourceDescriptors: [Int32]) throws -> [Int32] {
        var duplicates: [Int32] = []
        do {
            for descriptor in sourceDescriptors {
                let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
                guard duplicate >= 3 else { throw AppUninstallerError.io(errno) }
                duplicates.append(duplicate)
            }
            return duplicates
        } catch {
            duplicates.forEach { _ = Darwin.close($0) }
            throw error
        }
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private func exitedSuccessfully(_ status: Int32) -> Bool {
        status & 0x7f == 0 && (status >> 8) & 0xff == 0
    }

    private func terminateProcessSession(_ processID: pid_t) throws {
        guard processID > 0 else { return }
        guard var members = sessionProcessIDs(sessionID: processID).map(Set.init) else {
            throw MoleEngineError.cleanupFailed
        }
        members.forEach { _ = kill($0, SIGTERM) }
        _ = kill(-processID, SIGTERM)
        let deadline = Date().addingTimeInterval(0.5)
        var status: Int32 = 0
        var reaped = false
        while Date() < deadline {
            guard let currentMembers = sessionProcessIDs(sessionID: processID) else {
                throw MoleEngineError.cleanupFailed
            }
            members.formUnion(currentMembers)
            currentMembers.forEach { _ = kill($0, SIGTERM) }
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID || (result < 0 && errno == ECHILD) {
                reaped = true
                break
            }
            if result < 0, errno != EINTR { break }
            usleep(10_000)
        }
        guard let finalMembers = sessionProcessIDs(sessionID: processID) else {
            throw MoleEngineError.cleanupFailed
        }
        members.formUnion(finalMembers)
        members.forEach { _ = kill($0, SIGKILL) }
        _ = kill(-processID, SIGKILL)
        if !reaped {
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
        }
        let verificationDeadline = Date().addingTimeInterval(0.5)
        while true {
            guard let remaining = sessionProcessIDs(sessionID: processID) else {
                throw MoleEngineError.cleanupFailed
            }
            if remaining.isEmpty { return }
            remaining.forEach { _ = kill($0, SIGKILL) }
            guard Date() < verificationDeadline else { throw MoleEngineError.cleanupFailed }
            usleep(10_000)
        }
    }

    private func sessionProcessIDs(sessionID: pid_t) -> [pid_t]? {
        Self.listedProcessIDs()?.filter { processID in
            processID > 0 && getsid(processID) == sessionID
        }
    }

    static func listedProcessIDs(
        listAll: (_ buffer: UnsafeMutableRawPointer?, _ byteCount: Int32) -> Int32 = {
            proc_listallpids($0, $1)
        }
    ) -> [pid_t]? {
        let needed = listAll(nil, 0)
        guard needed > 0, needed < 100_000 else { return nil }
        var capacity = Int(needed) + 256
        for _ in 0..<4 {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBytes { buffer in
                listAll(buffer.baseAddress, Int32(buffer.count))
            }
            guard count > 0 else { return nil }
            if count < capacity { return Array(processIDs.prefix(Int(count))) }
            guard capacity < 100_000 else { return nil }
            capacity = min(capacity * 2, 100_000)
        }
        return nil
    }
}
