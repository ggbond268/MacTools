import Foundation

protocol SystemStatusHistoryStoring: Sendable {
    func load(referenceDate: Date) async -> [SystemStatusHistoryPoint]
    func append(_ point: SystemStatusHistoryPoint, referenceDate: Date) async -> [SystemStatusHistoryPoint]
    func appendBatch(_ points: [SystemStatusHistoryPoint], referenceDate: Date) async -> [SystemStatusHistoryPoint]
}

extension SystemStatusHistoryStoring {
    func appendBatch(_ points: [SystemStatusHistoryPoint], referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        var result: [SystemStatusHistoryPoint] = []
        for point in points { result = await append(point, referenceDate: referenceDate) }
        return result
    }
}

actor SystemStatusHistoryStore: SystemStatusHistoryStoring {
    static let retention: TimeInterval = 24 * 60 * 60
    static let maximumSampleCount = 8_640

    private let fileURL: URL
    private var samples: [SystemStatusHistoryPoint] = []
    private var didLoad = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL(supportDirectory: URL?) -> URL {
        if let supportDirectory {
            return supportDirectory.appendingPathComponent("system-status-history.json", isDirectory: false)
        }

        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("MacTools", isDirectory: true)
            .appendingPathComponent("SystemStatus", isDirectory: true)
            .appendingPathComponent("system-status-history.json", isDirectory: false)
    }

    func load(referenceDate: Date = Date()) async -> [SystemStatusHistoryPoint] {
        if !didLoad {
            samples = loadFromDisk()
            didLoad = true
        }

        samples = Self.pruned(samples, referenceDate: referenceDate)
        return samples
    }

    func append(_ point: SystemStatusHistoryPoint, referenceDate: Date = Date()) async -> [SystemStatusHistoryPoint] {
        await appendBatch([point], referenceDate: referenceDate)
    }

    func appendBatch(_ points: [SystemStatusHistoryPoint], referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        if !didLoad {
            samples = loadFromDisk()
            didLoad = true
        }

        samples.append(contentsOf: points)
        samples = SystemStatusHistoryProcessing.pruned(samples, referenceDate: referenceDate, highResolutionInterval: 0)
        persist(samples)
        return samples
    }

    nonisolated static func pruned(
        _ points: [SystemStatusHistoryPoint],
        referenceDate: Date
    ) -> [SystemStatusHistoryPoint] {
        let cutoff = referenceDate.timeIntervalSince1970 - retention
        let recentPoints = points
            .filter { $0.timestamp >= cutoff && $0.timestamp <= referenceDate.timeIntervalSince1970 + 60 }
            .sorted { $0.timestamp < $1.timestamp }

        guard recentPoints.count > maximumSampleCount else {
            return recentPoints
        }

        return Array(recentPoints.suffix(maximumSampleCount))
    }

    private func loadFromDisk() -> [SystemStatusHistoryPoint] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return []
        }

        guard
            let document = try? JSONDecoder().decode(SystemStatusHistoryDocument.self, from: data),
            document.schemaVersion == 1
        else {
            return []
        }

        return document.samples
    }

    private func persist(_ samples: [SystemStatusHistoryPoint]) {
        let document = SystemStatusHistoryDocument(schemaVersion: 1, samples: samples)
        guard let data = try? JSONEncoder.systemStatusHistoryEncoder.encode(document) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let temporaryURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(fileURL.lastPathComponent).tmp", isDirectory: false)
            try data.write(to: temporaryURL, options: [.atomic])

            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            return
        }
    }
}

private extension JSONEncoder {
    static var systemStatusHistoryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
