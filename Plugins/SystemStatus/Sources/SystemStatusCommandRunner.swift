import Darwin
import Foundation

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.qualityOfService = .utility

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputTask = readToEnd(fileHandle: outputPipe.fileHandleForReading)
        let errorTask = readToEnd(fileHandle: errorPipe.fileHandleForReading)
        let terminationSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSignal.signal()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            _ = await outputTask.value
            _ = await errorTask.value
            return nil
        }

        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()

        let completion = await wait(
            for: terminationSignal,
            timeout: timeout
        )

        if completion == .timedOut {
            await terminate(process, signal: terminationSignal)
        }

        process.terminationHandler = nil
        let outputData = await outputTask.value
        let errorData = await errorTask.value

        return SystemStatusCommandResult(
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self),
            terminationStatus: process.terminationStatus,
            completion: completion
        )
    }

    private static func readToEnd(fileHandle: FileHandle) -> Task<Data, Never> {
        Task.detached(priority: .utility) {
            (try? fileHandle.readToEnd()) ?? Data()
        }
    }

    private static func wait(
        for signal: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> SystemStatusCommandCompletion {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let completion: SystemStatusCommandCompletion =
                    signal.wait(timeout: .now() + timeout) == .success
                        ? .completed
                        : .timedOut
                continuation.resume(returning: completion)
            }
        }
    }

    private static func terminate(_ process: Process, signal: DispatchSemaphore) async {
        guard process.isRunning else { return }

        let processIdentifier = process.processIdentifier
        process.terminate()
        if await wait(for: signal, timeout: 0.25) == .timedOut {
            Darwin.kill(processIdentifier, SIGKILL)
            _ = await wait(for: signal, timeout: 1)
        }
    }
}
