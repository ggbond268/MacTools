import Darwin
import Foundation

private final class ClipboardPasteboardReaderTerminationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var process: Process?

    func launchGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func isCurrent(generation expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }

    func install(_ process: Process, generation expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        self.process = process
        return true
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func terminateImmediately() {
        lock.lock()
        generation &+= 1
        let process = self.process
        self.process = nil
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

actor ClipboardPasteboardReaderProcess {
    struct TimeoutError: Error {}

    private struct Session {
        let id: UUID
        let process: Process
        let input: FileHandle
        let output: FileHandle
    }

    private let helperURL: @Sendable () -> URL?
    private let helperArguments: [String]
    private let requestTimeout: Duration
    private var session: Session?
    private var timedOutSessionIDs = Set<UUID>()
    private var requestIsInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var launchCountForTesting = 0
    private nonisolated let terminationHandle = ClipboardPasteboardReaderTerminationHandle()

    init(
        helperURL: @escaping @Sendable () -> URL?,
        helperArguments: [String] = [],
        requestTimeout: Duration = .seconds(5)
    ) {
        self.helperURL = helperURL
        self.helperArguments = helperArguments
        self.requestTimeout = requestTimeout
    }

    func read(_ request: ClipboardPasteboardReaderRequest) async throws -> ClipboardPasteboardReaderResponse {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        try Task.checkCancellation()
        let requestData = try ClipboardPasteboardReaderWire.encode(request)
        let operationGeneration = terminationHandle.launchGeneration()
        return try await read(
            request,
            requestData: requestData,
            canRetryAfterSessionFailure: true,
            operationGeneration: operationGeneration
        )
    }

    private func read(
        _ request: ClipboardPasteboardReaderRequest,
        requestData: Data,
        canRetryAfterSessionFailure: Bool,
        operationGeneration: UInt64
    ) async throws -> ClipboardPasteboardReaderResponse {
        guard terminationHandle.isCurrent(generation: operationGeneration) else {
            throw CancellationError()
        }
        let activeSession = try reusableSession()
        let sessionID = activeSession.id
        do {
            try ClipboardPasteboardReaderWire.writeFrame(requestData, to: activeSession.input)
        } catch {
            terminateSession(id: sessionID)
            if canRetryAfterSessionFailure, !Task.isCancelled {
                return try await read(
                    request,
                    requestData: requestData,
                    canRetryAfterSessionFailure: false,
                    operationGeneration: operationGeneration
                )
            }
            throw error
        }

        let maximumPayload = min(max(request.maximumByteCount, 0), 256 * 1_024 * 1_024)
        let maximumResponseFrameByteCount = maximumPayload * 2 + 1_048_576
        let output = activeSession.output
        let responseTask = Task.detached(priority: .userInitiated) {
            try ClipboardPasteboardReaderWire.readFrame(
                from: output,
                maximumByteCount: maximumResponseFrameByteCount
            )
        }
        let timeout = requestTimeout

        do {
            let responseData = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await responseTask.value }
                    group.addTask { [weak self] in
                        try await Task.sleep(for: timeout)
                        await self?.terminateTimedOutSession(id: sessionID)
                        throw TimeoutError()
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    return first
                }
            } onCancel: {
                Task { await self.terminateSession(id: sessionID) }
            }
            return try ClipboardPasteboardReaderWire.decode(
                ClipboardPasteboardReaderResponse.self,
                from: responseData
            )
        } catch {
            responseTask.cancel()
            let didTimeOut = timedOutSessionIDs.remove(sessionID) != nil
            terminateSession(id: sessionID)
            if canRetryAfterSessionFailure,
               !Task.isCancelled,
               terminationHandle.isCurrent(generation: operationGeneration),
               !didTimeOut,
               !(error is TimeoutError),
               !(error is CancellationError) {
                return try await read(
                    request,
                    requestData: requestData,
                    canRetryAfterSessionFailure: false,
                    operationGeneration: operationGeneration
                )
            }
            throw error
        }
    }

    func stop() {
        guard let session else { return }
        terminateSession(id: session.id)
    }

    nonisolated func stopImmediately() {
        terminationHandle.terminateImmediately()
    }

    private func acquireRequestSlot() async {
        guard requestIsInFlight else {
            requestIsInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        guard !requestWaiters.isEmpty else {
            requestIsInFlight = false
            return
        }
        requestWaiters.removeFirst().resume()
    }

    private func reusableSession() throws -> Session {
        if let session {
            if session.process.isRunning {
                return session
            }
            terminateSession(id: session.id)
        }
        let launchedSession = try launchSession()
        session = launchedSession
        return launchedSession
    }

    private func launchSession() throws -> Session {
        guard let helperURL = helperURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = helperArguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let launchGeneration = terminationHandle.launchGeneration()
        try process.run()
        guard terminationHandle.install(process, generation: launchGeneration) else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CancellationError()
        }
        launchCountForTesting += 1
        return Session(
            id: UUID(),
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading
        )
    }

    var hasLiveSessionForTesting: Bool {
        session?.process.isRunning == true
    }

    private func terminateTimedOutSession(id: UUID) {
        timedOutSessionIDs.insert(id)
        terminateSession(id: id)
    }

    private func terminateSession(id: UUID) {
        guard let activeSession = session, activeSession.id == id else { return }
        session = nil
        terminationHandle.clear(activeSession.process)
        try? activeSession.input.close()
        try? activeSession.output.close()
        guard activeSession.process.isRunning else { return }
        kill(activeSession.process.processIdentifier, SIGKILL)
    }
}
