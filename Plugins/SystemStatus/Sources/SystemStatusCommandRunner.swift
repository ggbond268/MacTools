import Darwin
import Foundation
import MacToolsPluginKit

enum SystemStatusCommandCompletion: Equatable, Sendable {
    case completed
    case timedOut
}

struct SystemStatusCommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
    let completion: SystemStatusCommandCompletion
}

enum SystemStatusCommandRunner {
    static func run(
        path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> SystemStatusCommandResult? {
        await withCheckedContinuation { continuation in
            SystemStatusCommandExecution(
                path: path,
                arguments: arguments,
                timeout: timeout,
                continuation: continuation
            ).start()
        }
    }
}

private final class SystemStatusCommandExecution: @unchecked Sendable {
    private enum Stream {
        case standardOutput
        case standardError
    }

    private struct LaunchResult {
        let processID: pid_t
        let outputDescriptor: Int32
        let errorDescriptor: Int32
    }

    typealias Continuation = CheckedContinuation<SystemStatusCommandResult?, Never>

    private static let forcedKillDelay: TimeInterval = 0.25
    private static let drainDeadline: TimeInterval = 0.20

    private let path: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let controlQueue = DispatchQueue(
        label: "cc.ggbond.mactools.system-status.command-control",
        qos: .utility
    )
    private let ioQueue = DispatchQueue(
        label: "cc.ggbond.mactools.system-status.command-io",
        qos: .utility
    )

    private var continuation: Continuation?
    private var lease: PluginProcessGroupLease?
    private var timeoutWorkItem: DispatchWorkItem?
    private var forcedKillWorkItem: DispatchWorkItem?
    private var drainWorkItem: DispatchWorkItem?
    private var leaderDidExit = false
    private var didTimeOut = false
    private var closedStreamCount = 0
    private var didFinish = false

    // Accessed only from ioQueue.
    private var outputData = Data()
    private var errorData = Data()
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var outputDescriptor: Int32 = -1
    private var errorDescriptor: Int32 = -1
    private var outputDidClose = false
    private var errorDidClose = false

    init(
        path: String,
        arguments: [String],
        timeout: TimeInterval,
        continuation: Continuation
    ) {
        self.path = path
        self.arguments = arguments
        self.timeout = max(0, timeout)
        self.continuation = continuation
    }

    func start() {
        controlQueue.async { [self] in
            do {
                let launch = try spawn()
                let processLease = PluginProcessGroupLease(processID: launch.processID)
                lease = processLease
                startReading(
                    outputDescriptor: launch.outputDescriptor,
                    errorDescriptor: launch.errorDescriptor
                )
                scheduleTimeout()
                DispatchQueue.global(qos: .utility).async { [self] in
                    let observedExit = processLease.waitForLeaderExit()
                    controlQueue.async { [self] in
                        processDidExit(observedExit: observedExit)
                    }
                }
            } catch {
                finishWithoutResult()
            }
        }
    }

    private func startReading(outputDescriptor: Int32, errorDescriptor: Int32) {
        ioQueue.async { [self] in
            self.outputDescriptor = outputDescriptor
            self.errorDescriptor = errorDescriptor
            outputSource = makeReadSource(
                descriptor: outputDescriptor,
                stream: .standardOutput
            )
            errorSource = makeReadSource(
                descriptor: errorDescriptor,
                stream: .standardError
            )
            outputSource?.resume()
            errorSource?.resume()
        }
    }

    private func makeReadSource(
        descriptor: Int32,
        stream: Stream
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: ioQueue
        )
        source.setEventHandler { [self] in
            drain(descriptor: descriptor, stream: stream)
        }
        source.setCancelHandler { [self] in
            Darwin.close(descriptor)
            controlQueue.async { [self] in
                closedStreamCount += 1
                finishIfReady()
            }
        }
        return source
    }

    private func drain(descriptor: Int32, stream: Stream) {
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        // Bound each callback so sustained output cannot monopolize ioQueue and
        // delay a timeout-driven stream close.
        for _ in 0 ..< 16 {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                switch stream {
                case .standardOutput:
                    outputData.append(contentsOf: bytes.prefix(count))
                case .standardError:
                    errorData.append(contentsOf: bytes.prefix(count))
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count == 0 { close(stream: stream) }
            break
        }
    }

    private func close(stream: Stream) {
        switch stream {
        case .standardOutput:
            guard !outputDidClose else { return }
            outputDidClose = true
            outputSource?.cancel()
            outputSource = nil
            outputDescriptor = -1
        case .standardError:
            guard !errorDidClose else { return }
            errorDidClose = true
            errorSource?.cancel()
            errorSource = nil
            errorDescriptor = -1
        }
    }

    private func scheduleTimeout() {
        let workItem = DispatchWorkItem { [self] in
            guard !leaderDidExit, !didFinish else { return }
            didTimeOut = true
            lease?.signal(SIGTERM)
            scheduleForcedKill()
        }
        timeoutWorkItem = workItem
        controlQueue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func scheduleForcedKill() {
        guard forcedKillWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [self] in
            guard !leaderDidExit, !didFinish else { return }
            lease?.signal(SIGKILL)
        }
        forcedKillWorkItem = workItem
        controlQueue.asyncAfter(
            deadline: .now() + Self.forcedKillDelay,
            execute: workItem
        )
    }

    private func processDidExit(observedExit: Bool) {
        guard !didFinish else { return }
        leaderDidExit = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        forcedKillWorkItem?.cancel()
        forcedKillWorkItem = nil

        guard observedExit else {
            closeStreamsAndFinish()
            return
        }
        if closedStreamCount == 2 {
            finishIfReady()
            return
        }

        let workItem = DispatchWorkItem { [self] in
            guard !didFinish else { return }
            // An exited leader can leave descendants holding inherited pipe
            // descriptors. The retained leader keeps the process-group ID owned
            // until those descendants are stopped and the streams are closed.
            lease?.signal(SIGKILL)
            closeStreamsAndFinish()
        }
        drainWorkItem = workItem
        controlQueue.asyncAfter(
            deadline: .now() + Self.drainDeadline,
            execute: workItem
        )
    }

    private func finishIfReady() {
        guard leaderDidExit, closedStreamCount == 2, !didFinish else { return }
        captureOutputAndFinish()
    }

    private func closeStreamsAndFinish() {
        ioQueue.async { [self] in
            if outputDescriptor >= 0 {
                drain(descriptor: outputDescriptor, stream: .standardOutput)
            }
            if errorDescriptor >= 0 {
                drain(descriptor: errorDescriptor, stream: .standardError)
            }
            close(stream: .standardOutput)
            close(stream: .standardError)
            let output = outputData
            let error = errorData
            controlQueue.async { [self] in
                finish(output: output, error: error)
            }
        }
    }

    private func captureOutputAndFinish() {
        ioQueue.async { [self] in
            let output = outputData
            let error = errorData
            controlQueue.async { [self] in
                finish(output: output, error: error)
            }
        }
    }

    private func finish(output: Data, error: Data) {
        guard !didFinish else { return }
        didFinish = true
        drainWorkItem?.cancel()
        drainWorkItem = nil
        let rawStatus = lease?.reapLeader()
        lease = nil
        let result = SystemStatusCommandResult(
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: String(decoding: error, as: UTF8.self),
            terminationStatus: rawStatus.map(Self.terminationStatus(from:)) ?? -1,
            completion: didTimeOut ? .timedOut : .completed
        )
        let pendingContinuation = continuation
        continuation = nil
        pendingContinuation?.resume(returning: result)
    }

    private func finishWithoutResult() {
        guard !didFinish else { return }
        didFinish = true
        let pendingContinuation = continuation
        continuation = nil
        pendingContinuation?.resume(returning: nil)
    }

    private func spawn() throws -> LaunchResult {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw POSIXError(.EIO) }
        guard pipe(&errorPipe) == 0 else {
            Darwin.close(outputPipe[0])
            Darwin.close(outputPipe[1])
            throw POSIXError(.EIO)
        }

        func closePipes() {
            outputPipe.filter { $0 >= 0 }.forEach { Darwin.close($0) }
            errorPipe.filter { $0 >= 0 }.forEach { Darwin.close($0) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
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
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }

        var processID: pid_t = 0
        let launchArguments = [path] + arguments
        let environment = ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let result = withSystemStatusCStringArray(launchArguments) { argv in
            withSystemStatusCStringArray(environment) { environmentPointer in
                posix_spawn(
                    &processID,
                    path,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        guard result == 0 else {
            closePipes()
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        Darwin.close(outputPipe[1])
        outputPipe[1] = -1
        Darwin.close(errorPipe[1])
        errorPipe[1] = -1
        for descriptor in [outputPipe[0], errorPipe[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        return LaunchResult(
            processID: processID,
            outputDescriptor: outputPipe[0],
            errorDescriptor: errorPipe[0]
        )
    }

    private static func terminationStatus(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }
}

private func withSystemStatusCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
