import AppKit
import Darwin
import Foundation

struct UninstallProcessSnapshot: Sendable {
    let paths: [String]
    let complete: Bool
}

struct UninstallEnvironmentSnapshot: Sendable {
    let runningPaths: [String]
    let isManaged: Bool
    let homebrewApps: Set<String>
    let restrictions: [String]
    let coverage: [UninstallCoverage]
    var activeExecutables: [String] = []
    var complete: Bool { coverage.allSatisfy { $0.issue == nil } }
}

protocol UninstallEnvironmentChecking: Sendable {
    func inspect(applicationPath: String) async throws -> UninstallEnvironmentSnapshot
    func validateRunning(applicationPath: String, additionalPath: String?) throws
}

struct UninstallSystemEnvironment: UninstallEnvironmentChecking {
    let configuration: UninstallConfiguration

    func validateRunning(applicationPath: String, additionalPath: String?) throws {
        let state = try Self.processSnapshot()
        if state.paths.contains(where: { path in
            UninstallPaths.contains(path, in: applicationPath) || additionalPath.map { UninstallPaths.contains(path, in: $0) } == true
        }) { throw AppUninstallerError.running }
        guard state.complete else { throw AppUninstallerError.incomplete }
    }

    /// Include command-line helpers which never register as NSRunningApplication instances.
    static func processPaths() throws -> [String] {
        let state = try processSnapshot()
        guard state.complete else { throw AppUninstallerError.incomplete }
        return state.paths
    }

    static func processSnapshot() throws -> UninstallProcessSnapshot {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0, needed < 100_000 else { throw AppUninstallerError.incomplete }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 256)
        let capacity = pids.count
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard count > 0, count < capacity else { throw AppUninstallerError.incomplete }
        var paths: [String] = []
        var complete = true
        for pid in pids.prefix(Int(count)) where pid > 0 {
            try Task.checkCancellation()
            var buffer = [CChar](repeating: 0, count: 4_096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                paths.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            } else {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
                if result == size {
                    if info.pbi_status == UInt32(SZOMB) { continue }
                    // Other users' privileged processes are outside this user-domain removal flow.
                    // Their services are handled separately by installation/source checks and vendor guidance.
                    if info.pbi_uid != getuid() && info.pbi_ruid != getuid() { continue }
                    complete = false
                    continue
                }
                if errno != ESRCH { complete = false }
            }
        }
        return .init(paths: paths, complete: complete)
    }

    /// Attribute declared paths as evidence only; never evaluate launchd arguments or shell text.
    static func launchServiceReferencesApplication(_ plist: [String: Any], applicationPath: String) -> Bool {
        let root = URL(fileURLWithPath: applicationPath).standardizedFileURL.path.lowercased()
        let paths = ["Program", "BundleProgram", "WorkingDirectory"].compactMap { plist[$0] as? String }
            + (plist["ProgramArguments"] as? [String] ?? [])
        return paths.contains { value in
            guard value.hasPrefix("/"), !value.contains("\0") else { return false }
            let path = URL(fileURLWithPath: value).standardizedFileURL.path.lowercased()
            return UninstallPaths.contains(path, in: root)
        }
    }

    func inspect(applicationPath: String) async throws -> UninstallEnvironmentSnapshot {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleURL).map(\.path).filter { $0.lowercased().hasSuffix(".app") }
        }
        let fs = UninstallFileSystem()
        var coverage: [UninstallCoverage] = []
        var restrictions: [String] = []
        var managed = false
        do {
            let output = try Self.command("/usr/bin/profiles", ["status", "-type", "enrollment"])
            let lines = Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            let unmanaged = lines.contains("Enrolled via DEP: No") && lines.contains("MDM enrollment: No")
            managed = !unmanaged
            if managed { restrictions.append("设备已注册管理或管理状态不明确，请联系管理员。") }
            coverage.append(.init(path: "设备管理", issue: unmanaged ? nil : "设备管理状态阻止移除。"))
        } catch {
            try Task.checkCancellation()
            restrictions.append("无法确认设备管理状态，仅可检查文件。")
            coverage.append(.init(path: "设备管理", issue: "管理状态检查未完成。"))
        }
        var brewApps = Set<String>()
        for root in configuration.caskRoots {
            do {
                let tokens = try fs.children(root, limit: 5_000)
                for token in tokens where !token.hasPrefix(".") {
                    try Task.checkCancellation()
                    for version in try fs.children(root + "/" + token, limit: 100) where !version.hasPrefix(".") {
                        let versionPath = root + "/" + token + "/" + version
                        for name in try fs.children(versionPath, limit: 500) where name.lowercased().hasSuffix(".app") {
                            let path = versionPath + "/" + name
                            // Resolving here only discovers package-manager claims; it never grants removal authority.
                            brewApps.insert(UninstallFileSystem.physicalHome(path))
                        }
                    }
                }
                coverage.append(.init(path: root, issue: nil))
            } catch {
            try Task.checkCancellation()
                coverage.append(.init(path: root, issue: fs.isMissingCandidate(root, error: error) ? nil : "Homebrew 安装记录检查未完成。"))
            }
        }
        // Launchd plists are read as data. Never execute shell commands or scripts found in application metadata.
        for root in [configuration.home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            do {
                for name in try fs.children(root, limit: 5_000) where name.lowercased().hasSuffix(".plist") {
                    let plist = try fs.plist(root + "/" + name)
                    if Self.launchServiceReferencesApplication(plist, applicationPath: applicationPath) {
                        restrictions.append("存在关联的启动服务：\(name)。请使用开发者提供的卸载方式。")
                    }
                }
                coverage.append(.init(path: root, issue: nil))
            } catch {
            try Task.checkCancellation()
                coverage.append(.init(path: root, issue: fs.isMissingCandidate(root, error: error) ? nil : "后台服务检查未完成。"))
            }
        }
        var executables: [String] = []
        do {
            let processes = try Self.processSnapshot()
            executables = processes.paths
            if !processes.complete { coverage.append(.init(path: "运行进程", issue: "部分运行进程的可执行文件路径不可用，无法确认应用已完全退出。")) }
        }
        catch { try Task.checkCancellation(); coverage.append(.init(path: "运行进程", issue: "运行进程检查不完整。")) }
        return .init(runningPaths: Array(Set(running)).sorted(), isManaged: managed, homebrewApps: brewApps,
                     restrictions: restrictions, coverage: coverage, activeExecutables: executables)
    }

    /// Fixed read-only system command, bounded output and deadline, no shell or inherited application input.
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardOutput = pipe; process.standardError = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let deadline = Date().addingTimeInterval(5)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if !process.isRunning { break }
            guard data.count <= 65_536, Date() < deadline else { throw AppUninstallerError.incomplete }
            if count <= 0 { usleep(10_000) }
        }
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { throw AppUninstallerError.incomplete }
        return output
    }

    @MainActor
    static func isRunning(_ app: UninstallApplication) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleID || $0.bundleURL.map { UninstallPaths.contains($0.path, in: app.path) } == true
                || $0.executableURL.map { UninstallPaths.contains($0.path, in: app.path) } == true
        }
    }
}
