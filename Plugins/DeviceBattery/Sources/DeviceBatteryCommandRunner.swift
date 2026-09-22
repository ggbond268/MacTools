import Darwin
import Foundation

enum DeviceBatteryCommandCompletion: Equatable, Sendable {
    case completed
    case timedOut
}

struct DeviceBatteryCommandResult: Equatable, Sendable {
    let output: String
    let completion: DeviceBatteryCommandCompletion
}

enum DeviceBatteryCommandRunner {
    static func run(
        path: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLineFilter: ((String) -> Bool)? = nil
    ) async -> DeviceBatteryCommandResult? {
        await DeviceBatteryCommandExecution(
            path: path,
            arguments: arguments,
            timeout: timeout,
            outputLineFilter: outputLineFilter
        ).run()
    }
}

private final class DeviceBatteryCommandExecution: @unchecked Sendable {
    private enum Stream {
        case standardOutput
        case standardError
    }

    private typealias Continuation = CheckedContinuation<DeviceBatteryCommandResult?, Never>

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "cc.ggbond.mactools.device-battery.command-io")
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let outputAccumulator: DeviceBatteryCommandOutputAccumulator
    private let timeout: TimeInterval

    private var continuation: Continuation?
    private var timeoutWorkItem: DispatchWorkItem?
    private var pipeCloseWorkItem: DispatchWorkItem?
    private var didLaunch = false
    private var didFinish = false
    private var cancellationRequested = false
    private var terminationRequested = false
    private var timedOut = false
    private var outputDrainScheduled = false
    private var errorDrainScheduled = false

    // Accessed only from ioQueue.
    private var processExited = false
    private var outputReachedEOF = false
    private var errorReachedEOF = false
    private var pipesClosed = false

    init(
        path: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLineFilter: ((String) -> Bool)?
    ) {
        self.timeout = timeout
        self.outputAccumulator = DeviceBatteryCommandOutputAccumulator(lineFilter: outputLineFilter)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.qualityOfService = .utility
    }

    func run() async -> DeviceBatteryCommandResult? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            requestCancellation(timedOut: false)
        }
    }

    private func start(continuation: Continuation) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        let shouldSkipLaunch = cancellationRequested
        lock.unlock()

        guard !shouldSkipLaunch else {
            completeWithoutLaunching()
            return
        }

        guard configureNonblockingReads() else {
            completeWithoutLaunching()
            return
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.scheduleDrain(.standardOutput)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.scheduleDrain(.standardError)
        }
        process.terminationHandler = { [weak self] _ in
            self?.ioQueue.async { [weak self] in
                self?.handleProcessExit()
            }
        }

        do {
            try process.run()
        } catch {
            completeWithoutLaunching()
            return
        }
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()

        lock.lock()
        didLaunch = true
        let shouldScheduleTimeout = !didFinish && !cancellationRequested
        let shouldTerminate = !didFinish && cancellationRequested && !terminationRequested
        if shouldTerminate {
            terminationRequested = true
        }
        lock.unlock()

        if shouldScheduleTimeout {
            scheduleTimeout()
        }
        if shouldTerminate {
            terminateLaunchedProcess()
        }
    }

    private func scheduleTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.requestCancellation(timedOut: true)
        }

        lock.lock()
        guard !didFinish, !cancellationRequested else {
            lock.unlock()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )
    }

    private func requestCancellation(timedOut: Bool) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        self.timedOut = self.timedOut || timedOut
        let shouldTerminate = didLaunch && !terminationRequested
        if shouldTerminate {
            terminationRequested = true
        }
        lock.unlock()

        if shouldTerminate {
            terminateLaunchedProcess()
        }
    }

    private func terminateLaunchedProcess() {
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak process] in
            guard let process, process.isRunning else { return }
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func scheduleDrain(_ stream: Stream) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        switch stream {
        case .standardOutput:
            guard !outputDrainScheduled else {
                lock.unlock()
                return
            }
            outputDrainScheduled = true
        case .standardError:
            guard !errorDrainScheduled else {
                lock.unlock()
                return
            }
            errorDrainScheduled = true
        }
        lock.unlock()

        ioQueue.async { [weak self] in
            self?.drain(stream)
        }
    }

    private func drain(_ stream: Stream) {
        guard !pipesClosed else {
            clearDrainScheduled(stream)
            return
        }

        if drainAvailableBytes(from: stream) {
            markReachedEOF(stream)
        }

        clearDrainScheduled(stream)
        completeIfReady()
    }

    private func configureNonblockingReads() -> Bool {
        [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading].allSatisfy { handle in
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0 else { return false }
            return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
        }
    }

    /// Returns true when the stream reached EOF or an unrecoverable read error.
    private func drainAvailableBytes(from stream: Stream) -> Bool {
        let descriptor: Int32
        switch stream {
        case .standardOutput:
            descriptor = outputPipe.fileHandleForReading.fileDescriptor
        case .standardError:
            descriptor = errorPipe.fileHandleForReading.fileDescriptor
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }

            if byteCount > 0 {
                switch stream {
                case .standardOutput:
                    outputAccumulator.append(Data(buffer.prefix(byteCount)))
                case .standardError:
                    break
                }
                continue
            }
            if byteCount == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }
            return errno != EAGAIN && errno != EWOULDBLOCK
        }
    }

    private func markReachedEOF(_ stream: Stream) {
        switch stream {
        case .standardOutput:
            outputReachedEOF = true
            outputPipe.fileHandleForReading.readabilityHandler = nil
        case .standardError:
            errorReachedEOF = true
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func clearDrainScheduled(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .standardOutput:
            outputDrainScheduled = false
        case .standardError:
            errorDrainScheduled = false
        }
        lock.unlock()
    }

    private func handleProcessExit() {
        guard !processExited else { return }
        processExited = true
        completeIfReady()
        guard !pipesClosed else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.forceClosePipesAfterProcessExit()
        }
        pipeCloseWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func completeIfReady() {
        guard processExited, outputReachedEOF, errorReachedEOF else { return }
        finishAfterProcessExit()
    }

    private func forceClosePipesAfterProcessExit() {
        guard processExited, !pipesClosed else { return }
        _ = drainAvailableBytes(from: .standardOutput)
        _ = drainAvailableBytes(from: .standardError)
        outputReachedEOF = true
        errorReachedEOF = true
        finishAfterProcessExit()
    }

    private func finishAfterProcessExit() {
        pipeCloseWorkItem?.cancel()
        pipeCloseWorkItem = nil
        closePipes()
        let output = outputAccumulator.output()

        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        process.terminationHandler = nil
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancellationRequested
        let wasTimedOut = timedOut
        lock.unlock()

        let result: DeviceBatteryCommandResult?
        if wasTimedOut {
            result = DeviceBatteryCommandResult(output: output, completion: .timedOut)
        } else if wasCancelled {
            result = nil
        } else {
            result = DeviceBatteryCommandResult(output: output, completion: .completed)
        }
        continuation?.resume(returning: result)
    }

    private func completeWithoutLaunching() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.closePipes()

            self.lock.lock()
            guard !self.didFinish else {
                self.lock.unlock()
                return
            }
            self.didFinish = true
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            self.process.terminationHandler = nil
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    private func closePipes() {
        guard !pipesClosed else { return }
        pipesClosed = true
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputPipe.fileHandleForReading.closeFile()
        errorPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
    }
}

// Internal so byte-boundary behavior can be tested without subprocess scheduling.
final class DeviceBatteryCommandOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let lineFilter: ((String) -> Bool)?
    private var bufferedOutput = ""
    private var unfilteredBytes = Data()
    private var pendingLineBytes = Data()

    init(lineFilter: ((String) -> Bool)?) {
        self.lineFilter = lineFilter
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        if let lineFilter {
            appendFiltered(data, lineFilter: lineFilter)
        } else {
            unfilteredBytes.append(data)
        }
        lock.unlock()
    }

    func output() -> String {
        lock.lock()
        let currentOutput: String
        if let lineFilter {
            if !pendingLineBytes.isEmpty {
                let pendingLine = String(decoding: pendingLineBytes, as: UTF8.self)
                if lineFilter(pendingLine) {
                    bufferedOutput.append(pendingLine)
                    bufferedOutput.append("\n")
                }
            }
            pendingLineBytes.removeAll(keepingCapacity: false)
            currentOutput = bufferedOutput
        } else {
            currentOutput = String(decoding: unfilteredBytes, as: UTF8.self)
            unfilteredBytes.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        return currentOutput
    }

    private func appendFiltered(
        _ data: Data,
        lineFilter: (String) -> Bool
    ) {
        pendingLineBytes.append(data)
        var lineStart = pendingLineBytes.startIndex
        while let newlineIndex = pendingLineBytes[lineStart...].firstIndex(of: 0x0A) {
            let text = String(
                decoding: pendingLineBytes[lineStart..<newlineIndex],
                as: UTF8.self
            )
            if lineFilter(text) {
                bufferedOutput.append(text)
                bufferedOutput.append("\n")
            }
            lineStart = pendingLineBytes.index(after: newlineIndex)
        }

        if lineStart != pendingLineBytes.startIndex {
            pendingLineBytes.removeSubrange(pendingLineBytes.startIndex..<lineStart)
        }
    }
}
