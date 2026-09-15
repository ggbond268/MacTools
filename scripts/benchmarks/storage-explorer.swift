import Foundation
import Darwin
final class Counts: @unchecked Sendable {
    let lock = NSLock()
    var callbacks = 0
    var first = 0.0
    var start = Date()
    func update(_ value: StorageExplorerScanUpdate) {
        lock.withLock {
            callbacks += 1
            if first == 0 && value.items.contains(where: { $0.parentPath != nil }) { first = Date().timeIntervalSince(start) }
        }
    }
}
@main struct Benchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for workers in [1, 2, 4] {
            let scanner = StorageExplorerScanner(workerCount: workers)
            for trial in 1...3 {
                let counts = Counts()
                if trial < 3 { scanner.clearCache() }
                let result = try await scanner.scanSnapshot(rootURL: root) { counts.update($0) }
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("workers=\(workers) trial=\(trial) seconds=\(Date().timeIntervalSince(counts.start)) first=\(counts.first) callbacks=\(counts.callbacks) nodes=\(result.items.count) skipped=\(result.progress.skippedCount) cached=\(result.progress.cachedDirectories) peakRSS=\(usage.ru_maxrss) bytes=\(result.items[result.rootPath]?.size ?? -1)")
            }
        }
    }
}
