import Foundation

/// A deliberately narrow ZIP dialect matching the publisher. Validate both directory and local
/// records before invoking the system decompressor; filenames never become filesystem paths.
enum CLIArchive {
    static func validate(_ data: Data) throws {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - count else { throw CLIInstallError.archive }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 22, bytes.count <= CLIReleaseManifest.maximumArchiveSize else {
            throw CLIInstallError.archive
        }
        let end = bytes.count - 22
        guard try number(end, 4) == 0x06054b50, try number(end + 4, 4) == 0,
              try number(end + 8, 2) == 2, try number(end + 10, 2) == 2,
              try number(end + 20, 2) == 0 else { throw CLIInstallError.archive }
        let centralSize = try number(end + 12, 4)
        let centralStart = try number(end + 16, 4)
        guard centralStart + centralSize == end else { throw CLIInstallError.archive }
        var cursor = centralStart
        var localCursor = 0
        var names = Set<String>()
        for _ in 0..<2 {
            guard try number(cursor, 4) == 0x02014b50, try number(cursor + 5, 1) == 3,
                  try number(cursor + 8, 2) == 0, try number(cursor + 34, 2) == 0 else {
                throw CLIInstallError.archive
            }
            let method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4)
            let compressed = try number(cursor + 20, 4)
            let expanded = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2)
            let extraLength = try number(cursor + 30, 2)
            let commentLength = try number(cursor + 32, 2)
            let mode = try number(cursor + 38, 4) >> 16
            let local = try number(cursor + 42, 4)
            guard nameLength > 0, cursor + 46 + nameLength <= end,
                  extraLength == 0, commentLength == 0, local == localCursor else { throw CLIInstallError.archive }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            guard names.insert(name).inserted, ["mactools", "LICENSE"].contains(name),
                  mode == (name == "mactools" ? 0o100755 : 0o100644),
                  method == 0 || method == 8, compressed > 0, expanded > 0,
                  expanded <= (name == "mactools" ? CLIReleaseManifest.maximumArchiveSize : 65536),
                  local + 30 + nameLength + compressed <= centralStart,
                  try number(local, 4) == 0x04034b50, try number(local + 6, 2) == 0,
                  try number(local + 8, 2) == method, try number(local + 14, 4) == crc,
                  try number(local + 18, 4) == compressed, try number(local + 22, 4) == expanded,
                  try number(local + 26, 2) == nameLength, try number(local + 28, 2) == 0,
                  Array(bytes[(local + 30)..<(local + 30 + nameLength)]) == Array(name.utf8)
            else { throw CLIInstallError.archive }
            localCursor = local + 30 + nameLength + compressed
            cursor += 46 + nameLength
        }
        guard cursor == end, localCursor == centralStart else { throw CLIInstallError.archive }
    }
}

enum CLIProcess {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func append(_ chunk: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            if data.count + chunk.count > limit { overflow = true } else { data.append(chunk) }
        }
        func snapshot() -> (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, overflow)
        }
    }

    /// Runs on the installation worker, with a scrubbed environment and bounded output/deadline.
    static func run(_ executable: URL, _ arguments: [String], limit: Int = 65536,
                    timeout: TimeInterval = 20) throws -> Data {
        let result = try runResult(executable, arguments, limit: limit, timeout: timeout)
        guard result.status == 0 else { throw CLIInstallError.validation }
        return result.data
    }

    /// Assessment tools may return a nonzero verdict without failing to perform the assessment.
    /// Keep that verdict separate from launch failures, timeouts, and cancellation.
    static func runResult(_ executable: URL, _ arguments: [String], limit: Int = 65536,
                          timeout: TimeInterval = 20) throws -> (data: Data, status: Int32) {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let output = Output()
        let group = DispatchGroup()
        try process.run()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk, limit: limit)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline || output.snapshot().1 || Task.isCancelled {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                group.wait()
                try Task.checkCancellation()
                throw CLIInstallError.validation
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        group.wait()
        let (data, overflow) = output.snapshot()
        try Task.checkCancellation()
        guard !overflow else { throw CLIInstallError.validation }
        return (data, process.terminationStatus)
    }
}
