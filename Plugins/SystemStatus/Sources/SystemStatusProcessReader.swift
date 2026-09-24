import Darwin
import Foundation

struct SystemStatusProcessSample: Sendable {
    let pid: Int
    let parentPID: Int
    let userID: UInt32
    let cpuPercent: Double
    var command: String
    var memoryBytes: UInt64?
    var responsiblePID: Int?
}

actor SystemStatusProcessReader {
    private var inFlight: Task<[SystemStatusTopProcess], Never>?

    func cancel() { inFlight?.cancel() }

    func collect(limit: Int) async -> [SystemStatusTopProcess] {
        guard limit > 0, !Task.isCancelled else { return [] }
        // Foreground transitions and explicit refreshes share one bounded scan.
        if let inFlight {
            return SystemStatusProcessAccounting.candidates(await inFlight.value, limit: limit)
        }
        let task = Task { await Self.sample() }
        inFlight = task
        let processes = await task.value
        inFlight = nil
        return SystemStatusProcessAccounting.candidates(processes, limit: limit)
    }

    private static func sample() async -> [SystemStatusTopProcess] {
        let startedAt = Date().timeIntervalSince1970
        guard let result = await SystemStatusCommandRunner.run(
            path: "/bin/ps",
            arguments: ["-ww", "-Aceo", "pid=,ppid=,uid=,pcpu=,comm="],
            timeout: 2
        ), result.completion == .completed, result.terminationStatus == 0 else {
            return []
        }

        let samples: [SystemStatusProcessSample] = SystemStatusProcessAccounting.parse(result.standardOutput).compactMap { sample in
            guard !Task.isCancelled else { return nil }
            var sample = sample
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let count = proc_pidinfo(Int32(sample.pid), PROC_PIDTBSDINFO, 0, &info, size)
            if count == size {
                let birth = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
                // Reject an exited/reused PID instead of joining two different processes.
                guard info.pbi_uid == sample.userID, birth <= startedAt else { return nil }
                sample.memoryBytes = footprint(pid: Int32(sample.pid))
                if sample.memoryBytes == nil, errno == ESRCH { return nil }
            } else if errno == ESRCH {
                return nil
            }
            // Read only the executable path; asking ps for full commands makes
            // it load process arguments and costs more on large process tables.
            // PROC_PIDPATHINFO_MAXSIZE is a compound C macro not imported by Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(Int32(sample.pid), &path, UInt32(path.count)) > 0 {
                sample.command = String(cString: path)
            }
            if let responsiblePID = responsibleProcess?(Int32(sample.pid)), responsiblePID > 1 {
                sample.responsiblePID = Int(responsiblePID)
            }
            return sample
        }
        return SystemStatusProcessAccounting.aggregate(samples)
    }

    private static func footprint(pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        // RSS is a different metric. A denied read must not become RSS or zero.
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    private typealias ResponsibleProcess = @convention(c) (pid_t) -> pid_t

    // Like Stats, use responsibility to attribute launchd-hosted XPC services.
    // This optional SPI is resolved at runtime; bundle/parent attribution remains
    // available when the symbol is absent or the OS rejects a query.
    private static let responsibleProcess: ResponsibleProcess? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"
        ) else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleProcess.self)
    }()
}

enum SystemStatusProcessAccounting {
    static func parse(_ output: String) -> [SystemStatusProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard fields.count == 5,
                  let pid = Int(fields[0]), pid > 0, pid <= Int(Int32.max),
                  let parent = Int(fields[1]), parent >= 0,
                  let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")),
                  cpu.isFinite, cpu >= 0 else { return nil }
            return SystemStatusProcessSample(
                pid: pid, parentPID: parent, userID: uid,
                cpuPercent: cpu, command: String(fields[4])
            )
        }
    }

    static func applicationPath(for command: String) -> String? {
        guard command.hasPrefix("/") else { return nil }
        let components = command.split(separator: "/")
        guard let end = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return "/" + components[...end].joined(separator: "/")
    }

    static func aggregate(_ samples: [SystemStatusProcessSample]) -> [SystemStatusTopProcess] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        let ownApplications = byPID.compactMapValues { applicationPath(for: $0.command) }
        var groups: [String: (path: String?, members: [SystemStatusProcessSample])] = [:]

        func ancestorApplication(of pid: Int, userID: UInt32) -> String? {
            var cursor = pid
            var visited = Set<Int>()
            while cursor > 1, visited.insert(cursor).inserted,
                  let process = byPID[cursor], process.userID == userID {
                if let path = ownApplications[cursor] { return path }
                cursor = process.parentPID
            }
            return nil
        }

        for sample in byPID.values {
            // A separately launched app keeps its own identity, even when a
            // terminal launched it. Helpers inside nested bundles share the outer app.
            let path = ownApplications[sample.pid]
                ?? sample.responsiblePID.flatMap { ancestorApplication(of: $0, userID: sample.userID) }
                ?? ancestorApplication(of: sample.parentPID, userID: sample.userID)
            let key = path.map { "app:\(sample.userID):\($0)" } ?? "pid:\(sample.pid)"
            groups[key, default: (path, [])].members.append(sample)
        }

        return groups.map { key, group in
            let members = group.members
            let representative = members.min { lhs, rhs in
                func isMainExecutable(_ sample: SystemStatusProcessSample) -> Bool {
                    guard let path = group.path else { return false }
                    return URL(fileURLWithPath: sample.command).deletingLastPathComponent().path == path + "/Contents/MacOS"
                }
                if isMainExecutable(lhs) != isMainExecutable(rhs) { return isMainExecutable(lhs) }
                return lhs.pid < rhs.pid
            }!
            // An incomplete sum is not the application's total footprint.
            let memory: UInt64? = members.reduce(UInt64(0) as UInt64?) { total, member in
                guard let total, let bytes = member.memoryBytes else { return nil }
                let sum = total.addingReportingOverflow(bytes)
                return sum.overflow ? nil : sum.partialValue
            }
            let command = group.path ?? representative.command
            let name = URL(fileURLWithPath: command).lastPathComponent
            return SystemStatusTopProcess(
                pid: representative.pid,
                displayName: group.path == nil ? name : String(name.dropLast(4)),
                command: command,
                cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: memory,
                applicationID: key,
                processCount: members.count
            )
        }
    }

    static func candidates(_ processes: [SystemStatusTopProcess], limit: Int) -> [SystemStatusTopProcess] {
        guard limit > 0 else { return [] }
        let cpu = processes.sorted { ordered($0, before: $1, by: .cpu) }.prefix(limit)
        let memory = processes.sorted { ordered($0, before: $1, by: .memory) }.prefix(limit)
        return Dictionary((Array(cpu) + Array(memory)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { ordered($0, before: $1, by: .cpu) }
    }

    static func ordered(_ lhs: SystemStatusTopProcess, before rhs: SystemStatusTopProcess, by sort: SystemStatusProcessSort) -> Bool {
        if sort == .cpu, lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
        if lhs.memoryBytes != rhs.memoryBytes {
            // Known zero is still a reading; unavailable memory sorts last.
            guard let left = lhs.memoryBytes else { return false }
            guard let right = rhs.memoryBytes else { return true }
            return left > right
        }
        if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
        return lhs.id < rhs.id
    }
}
