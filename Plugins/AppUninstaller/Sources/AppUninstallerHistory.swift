import Darwin
import Foundation

actor UninstallHistory {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func save(_ run: UninstallRun) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(run)
        let path = directory.appendingPathComponent(run.id.uuidString + ".json")
        try data.write(to: path, options: .atomic)
        let descriptor = try UninstallFileSystem().open(path.path)
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AppUninstallerError.io(errno) }
        let parent = try UninstallFileSystem().open(directory.path, directory: true)
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw AppUninstallerError.io(errno) }
    }

    func load() throws -> [UninstallRun] {
        let fs = UninstallFileSystem()
        let names: [String]
        do { names = try fs.children(directory.path, limit: 10_000) }
        catch { if UninstallFileSystem.isAbsent(error) { return [] }; throw error }
        return try names.filter { $0.hasSuffix(".json") }.map {
            try JSONDecoder().decode(UninstallRun.self, from: fs.read(directory.path + "/" + $0, maximumBytes: 4_194_304))
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Attention records survive ordinary retention and Clear History.
    func prune(clear: Bool = false) throws {
        let runs = try load()
        let ordinary = runs.filter { $0.finishedAt != nil && !$0.results.contains { $0.disposition == .needsAttention } }
        for run in ordinary.dropFirst(clear ? 0 : 50) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(run.id.uuidString + ".json"))
        }
    }
}

enum UninstallDiagnostics {
    static func redacted(_ run: UninstallRun, home: String) -> String {
        let lines = ["App Uninstaller", "Run: \(run.id)", "Application: \(run.application.bundleID)",
                     "Estimated bytes: \(run.estimatedBytes)", "Actual reclaimed space: unknown (items move to Trash)"]
            + run.results.map { "\($0.disposition.rawValue): \($0.originalPath) → \($0.destinationPath ?? "—") \($0.message ?? "")" }
        return lines.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
    }
}
