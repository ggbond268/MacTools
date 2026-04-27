import Foundation

protocol DiskCleanExecuting: Sendable {
    func clean(
        candidates: [DiskCleanCandidate],
        selectedCandidateIDs: Set<DiskCleanCandidate.ID>
    ) async throws -> DiskCleanExecutionResult
}

struct DiskCleanExecutionItemResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case removed(reclaimedBytes: Int64)
        case skipped(DiskCleanSafetyStatus)
        case failed(message: String)
    }

    let candidateID: DiskCleanCandidate.ID
    let path: String
    let outcome: Outcome

    var reclaimedBytes: Int64 {
        if case let .removed(reclaimedBytes) = outcome {
            return max(reclaimedBytes, 0)
        }
        return 0
    }
}

struct DiskCleanExecutionResult: Equatable, Sendable {
    let itemResults: [DiskCleanExecutionItemResult]

    var removedCount: Int {
        itemResults.filter {
            if case .removed = $0.outcome { return true }
            return false
        }.count
    }

    var skippedCount: Int {
        itemResults.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }.count
    }

    var failedCount: Int {
        itemResults.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
    }

    var reclaimedBytes: Int64 {
        itemResults.reduce(0) { $0 + $1.reclaimedBytes }
    }
}

struct DiskCleanExecutor: DiskCleanExecuting {
    let fileSystem: DiskCleanFileSystemProviding
    let safetyPolicy: DiskCleanSafetyPolicy

    init(
        fileSystem: DiskCleanFileSystemProviding = LocalDiskCleanFileSystem(),
        safetyPolicy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy()
    ) {
        self.fileSystem = fileSystem
        self.safetyPolicy = safetyPolicy
    }

    func clean(
        candidates: [DiskCleanCandidate],
        selectedCandidateIDs: Set<DiskCleanCandidate.ID>
    ) async throws -> DiskCleanExecutionResult {
        var itemResults: [DiskCleanExecutionItemResult] = []

        for candidate in candidates where selectedCandidateIDs.contains(candidate.id) {
            try Task.checkCancellation()
            itemResults.append(try clean(candidate))
        }

        return DiskCleanExecutionResult(itemResults: itemResults)
    }

    private func clean(_ candidate: DiskCleanCandidate) throws -> DiskCleanExecutionItemResult {
        guard candidate.safety.isCleanable else {
            return itemResult(for: candidate, outcome: .skipped(candidate.safety))
        }

        guard let item = try fileSystem.itemInfo(at: candidate.path) else {
            return itemResult(
                for: candidate,
                outcome: .skipped(.invalid(reason: "path no longer exists"))
            )
        }

        let finalSafety = safetyPolicy.safetyStatus(
            for: item.path,
            isSymlink: item.isSymlink,
            resolvedSymlinkTarget: item.resolvedSymlinkTarget
        )
        guard finalSafety.isCleanable else {
            return itemResult(for: candidate, outcome: .skipped(finalSafety))
        }

        do {
            try fileSystem.removeItem(at: item.path)
            return itemResult(
                for: candidate,
                outcome: .removed(reclaimedBytes: candidate.sizeBytes)
            )
        } catch {
            return itemResult(
                for: candidate,
                outcome: .failed(message: error.localizedDescription)
            )
        }
    }

    private func itemResult(
        for candidate: DiskCleanCandidate,
        outcome: DiskCleanExecutionItemResult.Outcome
    ) -> DiskCleanExecutionItemResult {
        DiskCleanExecutionItemResult(
            candidateID: candidate.id,
            path: candidate.path,
            outcome: outcome
        )
    }
}
