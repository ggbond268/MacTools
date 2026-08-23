import Darwin
import Foundation
import MacToolsPluginKit

struct SavedScriptProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
}

enum SavedScriptProcessError: Error, Equatable {
    case executableUnavailable
    case invalidWorkingDirectory
    case timedOut
}

protocol SavedScriptRunning: Sendable {
    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult
}

struct ProcessSavedScriptRunner: SavedScriptRunning {
    static let maximumCapturedByteCount = 64 * 1_024
    static let runDirectoryPrefix = "run-"
    /// Allows bounded pipe draining and process-group cleanup after the script's own deadline.
    static let actionExecutionTimeoutGraceSeconds: TimeInterval = 1
    /// Script timeouts are capped at five minutes. Keeping abandoned source for at most
    /// fifteen minutes leaves generous teardown headroom while also handling PID reuse.
    static let maximumRunDirectoryLifetime: TimeInterval = 15 * 60

    private let temporaryDirectory: URL

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
        Self.removeAbandonedRunDirectories(in: temporaryDirectory)
    }

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        guard FileManager.default.isExecutableFile(atPath: script.kind.executableURL.path) else {
            throw SavedScriptProcessError.executableUnavailable
        }

        let workingDirectory = try resolvedWorkingDirectory(script.workingDirectory)
        let runDirectory = try makeRunDirectory()
        let sourceURL = try writeTemporarySource(for: script, in: runDirectory)
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        return try await SavedScriptProcessExecution(
            executableURL: script.kind.executableURL,
            sourceURL: sourceURL,
            workingDirectory: workingDirectory,
            environment: safeEnvironment(),
            timeout: TimeInterval(script.timeoutSeconds),
            maximumCapturedByteCount: Self.maximumCapturedByteCount
        ).run()
    }

    private func resolvedWorkingDirectory(_ rawPath: String) throws -> URL {
        guard !rawPath.isEmpty else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SavedScriptProcessError.invalidWorkingDirectory
        }
        return url
    }

    private func makeRunDirectory() throws -> URL {
        let parent = temporaryDirectory.appendingPathComponent("SavedScripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = parent.appendingPathComponent(
            "\(Self.runDirectoryPrefix)\(getpid())-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func writeTemporarySource(for script: SavedScript, in directory: URL) throws -> URL {
        let url = directory
            .appendingPathComponent("source")
            .appendingPathExtension(script.kind.fileExtension)
        try Data(script.source.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func safeEnvironment() -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["LANG", "LC_ALL", "USER", "LOGNAME"] {
            if let value = inherited[key] { environment[key] = value }
        }
        if let context = PluginActionExecutionContext.cliInvocation {
            environment[PluginCLIInvocationContext.chainEnvironmentKey] =
                context.chainID.uuidString
            environment[PluginCLIInvocationContext.depthEnvironmentKey] =
                String(context.depth + 1)
        }
        return environment
    }

    static func removeAbandonedRunDirectories(in temporaryDirectory: URL) {
        let parent = temporaryDirectory.appendingPathComponent("SavedScripts", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children {
            guard let values = try? child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]
            ), values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true,
               let ownerPID = ownerPID(from: child.lastPathComponent) {
                let isExpired = values.contentModificationDate.map {
                    Date().timeIntervalSince($0) > maximumRunDirectoryLifetime
                } ?? false
                if isExpired || !processIsAlive(ownerPID) {
                    try? FileManager.default.removeItem(at: child)
                }
            } else if values.isDirectory != true, isLegacySourceFile(child) {
                // Remove plaintext files written by runner versions before per-run directories.
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    private static func isLegacySourceFile(_ url: URL) -> Bool {
        let supportedExtensions = Set(SavedScriptKind.allCases.map(\.fileExtension))
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    private static func ownerPID(from name: String) -> pid_t? {
        guard name.hasPrefix(runDirectoryPrefix) else { return nil }
        let suffix = name.dropFirst(runDirectoryPrefix.count)
        guard let separator = suffix.firstIndex(of: "-"),
              let pid = Int32(suffix[..<separator]), pid > 0 else {
            return nil
        }
        return pid
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

private enum SavedScriptStopReason {
    case cancelled
    case timedOut
}

private final class SavedScriptProcessExecution: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<SavedScriptProcessResult, Error>

    private let executableURL: URL
    private let sourceURL: URL
    private let workingDirectory: URL
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let outputBuffer: SavedScriptOutputBuffer
    private let errorBuffer: SavedScriptOutputBuffer
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "cc.ggbond.mactools.saved-scripts.io")
    private let controlQueue = DispatchQueue(label: "cc.ggbond.mactools.saved-scripts.control")

    private var continuation: Continuation?
    private var processLease: PluginProcessGroupLease?
    private var outputDescriptor: Int32 = -1
    private var errorDescriptor: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var timeoutWorkItem: DispatchWorkItem?
    private var killWorkItem: DispatchWorkItem?
    private var completionWorkItem: DispatchWorkItem?
    private var requestedStopReason: SavedScriptStopReason?
    private var processExited = false
    private var didFinish = false

    init(
        executableURL: URL,
        sourceURL: URL,
        workingDirectory: URL,
        environment: [String: String],
        timeout: TimeInterval,
        maximumCapturedByteCount: Int
    ) {
        self.executableURL = executableURL
        self.sourceURL = sourceURL
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.outputBuffer = SavedScriptOutputBuffer(maximumByteCount: maximumCapturedByteCount)
        self.errorBuffer = SavedScriptOutputBuffer(maximumByteCount: maximumCapturedByteCount)
    }

    func run() async throws -> SavedScriptProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            requestStop(.cancelled)
        }
    }

    private func start(continuation: Continuation) {
        lock.withLock { self.continuation = continuation }

        do {
            let launch = try spawn()
            let lease = PluginProcessGroupLease(processID: launch.processID)
            lock.withLock {
                processLease = lease
                outputDescriptor = launch.outputDescriptor
                errorDescriptor = launch.errorDescriptor
            }
            startReading(descriptor: launch.outputDescriptor, stream: .standardOutput)
            startReading(descriptor: launch.errorDescriptor, stream: .standardError)
            scheduleTimeout()

            let requested = lock.withLock { requestedStopReason }
            if requested != nil {
                signalProcessGroup(SIGTERM)
                scheduleForcedKill()
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let observedExit = lease.waitForLeaderExit()
                self.markProcessExited()
                self.controlQueue.async { [weak self] in
                    self?.processDidExit(lease: lease, observedExit: observedExit)
                }
            }
        } catch {
            finish(throwing: error)
        }
    }

    private enum Stream {
        case standardOutput
        case standardError
    }

    private struct LaunchResult {
        let processID: pid_t
        let outputDescriptor: Int32
        let errorDescriptor: Int32
    }

    private func spawn() throws -> LaunchResult {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw POSIXError(.EIO) }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0]); close(outputPipe[1])
            throw POSIXError(.EIO)
        }

        func closePipes() {
            outputPipe.filter { $0 >= 0 }.forEach { close($0) }
            errorPipe.filter { $0 >= 0 }.forEach { close($0) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[1]) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }

        var pid: pid_t = 0
        let arguments = [executableURL.path, sourceURL.path]
        let environment = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let spawnResult = withCStringArray(arguments) { argv in
            withCStringArray(environment) { environmentPointer in
                posix_spawn(
                    &pid,
                    executableURL.path,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        guard spawnResult == 0 else {
            closePipes()
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }

        close(outputPipe[1])
        close(errorPipe[1])
        outputPipe[1] = -1
        errorPipe[1] = -1
        for descriptor in [outputPipe[0], errorPipe[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        return LaunchResult(
            processID: pid,
            outputDescriptor: outputPipe[0],
            errorDescriptor: errorPipe[0]
        )
    }

    private func startReading(descriptor: Int32, stream: Stream) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in self?.drain(descriptor: descriptor, stream: stream) }
        source.resume()
        lock.withLock {
            switch stream {
            case .standardOutput: outputSource = source
            case .standardError: errorSource = source
            }
        }
    }

    private func drain(descriptor: Int32, stream: Stream) {
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        // A permanently writable descendant must not monopolize the serial I/O queue.
        // DispatchSource will schedule another callback while unread bytes remain.
        for _ in 0 ..< 16 {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                let data = Data(bytes.prefix(count))
                switch stream {
                case .standardOutput: outputBuffer.append(data)
                case .standardError: errorBuffer.append(data)
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
    }

    private func scheduleTimeout() {
        let workItem = DispatchWorkItem { [weak self] in self?.requestStop(.timedOut) }
        lock.withLock { timeoutWorkItem = workItem }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )
    }

    private func requestStop(_ reason: SavedScriptStopReason) {
        let lease = lock.withLock { () -> PluginProcessGroupLease? in
            guard !didFinish else { return nil }
            if requestedStopReason == nil { requestedStopReason = reason }
            return processLease
        }
        guard let lease else { return }
        lease.signal(SIGTERM)
        scheduleForcedKill()
    }

    private func scheduleForcedKill() {
        let workItem = DispatchWorkItem { [weak self] in self?.signalProcessGroup(SIGKILL) }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard killWorkItem == nil else { return false }
            killWorkItem = workItem
            return true
        }
        if shouldSchedule {
            controlQueue.asyncAfter(
                deadline: .now() + 0.25,
                execute: workItem
            )
        }
    }

    private func signalProcessGroup(_ signal: Int32) {
        lock.withLock { processLease }?.signal(signal)
    }

    private func markProcessExited() {
        lock.withLock {
            processExited = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        }
    }

    private func processDidExit(lease: PluginProcessGroupLease, observedExit: Bool) {
        guard observedExit else {
            _ = lease.reapLeader()
            lock.withLock {
                if processLease === lease {
                    processLease = nil
                }
            }
            completeAfterExit(status: nil)
            return
        }
        // A background descendant may still own the pipes. Process control intentionally uses
        // a queue independent from pipe draining so continuous output cannot delay termination.
        lease.signal(SIGTERM)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lease.signal(SIGKILL)
            let status = lease.reapLeader()
            self.lock.withLock {
                if self.processLease === lease {
                    self.processLease = nil
                }
            }
            self.completeAfterExit(status: status)
        }
        lock.withLock { completionWorkItem = workItem }
        controlQueue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func completeAfterExit(status: Int32?) {
        // Serialize the last bounded reads with source callbacks before closing descriptors.
        ioQueue.sync {
            drain(descriptor: outputDescriptor, stream: .standardOutput)
            drain(descriptor: errorDescriptor, stream: .standardError)
            closeStreams()
        }
        let reason = lock.withLock { requestedStopReason }
        switch reason {
        case .cancelled:
            finish(throwing: CancellationError())
        case .timedOut:
            finish(throwing: SavedScriptProcessError.timedOut)
        case nil:
            guard let status else {
                finish(throwing: POSIXError(.ECHILD))
                return
            }
            finish(returning: SavedScriptProcessResult(
                exitCode: Self.exitCode(from: status),
                standardOutput: outputBuffer.string,
                standardError: errorBuffer.string,
                outputWasTruncated: outputBuffer.wasTruncated || errorBuffer.wasTruncated
            ))
        }
    }

    private func closeStreams() {
        let resources = lock.withLock { () -> (DispatchSourceRead?, DispatchSourceRead?, Int32, Int32) in
            let resources = (outputSource, errorSource, outputDescriptor, errorDescriptor)
            outputSource = nil
            errorSource = nil
            outputDescriptor = -1
            errorDescriptor = -1
            return resources
        }
        resources.0?.cancel()
        resources.1?.cancel()
        if resources.2 >= 0 { close(resources.2) }
        if resources.3 >= 0 { close(resources.3) }
    }

    private func finish(returning result: SavedScriptProcessResult) {
        let continuation = takeContinuation()
        continuation?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        closeStreams()
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> Continuation? {
        lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true
            timeoutWorkItem?.cancel()
            killWorkItem?.cancel()
            completionWorkItem?.cancel()
            let continuation = continuation
            self.continuation = nil
            return continuation
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.compactMap { $0 }.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private final class SavedScriptOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    private var data = Data()
    private var truncated = false

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, maximumByteCount - data.count)
            if newData.count > remaining { truncated = true }
            if remaining > 0 { data.append(newData.prefix(remaining)) }
        }
    }

    var wasTruncated: Bool { lock.withLock { truncated } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
