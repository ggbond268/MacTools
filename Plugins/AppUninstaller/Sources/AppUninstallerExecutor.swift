import Darwin
import Foundation

protocol UninstallTrashing: Sendable {
    func trash(_ url: URL) throws -> URL?
}

struct UninstallSystemTrash: UninstallTrashing {
    func trash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
}

struct UninstallExecutor: Sendable {
    let scanner: UninstallScanner
    let environment: any UninstallEnvironmentChecking
    let history: UninstallHistory
    var trash: any UninstallTrashing = UninstallSystemTrash()

    func execute(_ plan: UninstallPlan, now: @Sendable () -> Date = { Date() }) async throws -> UninstallRun {
        guard now() < plan.expiresAt, now() >= plan.createdAt else { throw AppUninstallerError.expired }
        var run = UninstallRun(id: plan.id, scanID: plan.scanID, application: plan.application, startedAt: now(),
                               estimatedBytes: plan.estimatedBytes, selectedCount: plan.items.count,
                               results: plan.retained.map { .init(originalPath: $0.path, destinationPath: nil, disposition: .retained, message: $0.blockedReason) })
        try await history.save(run)
        var stop = false
        for item in plan.items {
            if Task.isCancelled || stop {
                run.results.append(.init(originalPath: item.path, destinationPath: nil, disposition: .cancelled, message: "操作已停止，项目保留原位。"))
                continue
            }
            do {
                guard now() < plan.expiresAt else { throw AppUninstallerError.expired }
                let state = try await environment.inspect(applicationPath: plan.application.path)
                guard !(state.runningPaths + state.activeExecutables).contains(where: { UninstallPaths.contains($0, in: plan.application.path) }) else {
                    throw AppUninstallerError.running
                }
                let current = try scanner.scan(path: plan.application.path, environment: state)
                guard current.canPlan, current.application.bundleID == plan.application.bundleID,
                      current.application.metadataDigest == plan.application.metadataDigest,
                      current.application.identity == plan.application.identity else { throw AppUninstallerError.changed }
                guard !current.inventory.contains(where: { $0.bundleID.lowercased() == plan.application.bundleID.lowercased() && state.runningPaths.contains($0.path) }) else {
                    throw AppUninstallerError.running
                }
                guard let fresh = current.candidates.first(where: { $0.path == item.path }), fresh.eligible,
                      fresh.snapshot == item.snapshot,
                      scanner.configuration.permitted(item.path, kind: item.dataClass, app: current.application) else {
                    throw AppUninstallerError.changed
                }
                try Task.checkCancellation()
                let staged = try prepareStage(item)
                defer { close(staged.parentFD); close(staged.stageFD) }
                // The durable record precedes rename. Crashes remain visible as attention records on restart.
                run.results.append(.init(originalPath: item.path, destinationPath: staged.path,
                                         disposition: .needsAttention, message: "操作中断时，请检查原位置及暂存位置。"))
                do { try await history.save(run) }
                catch { _ = unlinkat(staged.parentFD, staged.directoryName, AT_REMOVEDIR); throw error }
                let result = move(item, staged: staged, plan: plan, now: now)
                run.results[run.results.count - 1] = result
                stop = result.disposition != .trashed
                try await history.save(run)
            } catch {
                stop = true
                let disposition: UninstallDisposition
                switch error {
                case AppUninstallerError.running: disposition = .running
                case AppUninstallerError.changed, AppUninstallerError.expired: disposition = .changed
                case is CancellationError: disposition = .cancelled
                default: disposition = .blocked
                }
                // Never replace a pending journal entry or an already-completed Trash result with a retryable result.
                if !run.results.contains(where: { $0.originalPath == item.path }) {
                    run.results.append(.init(originalPath: item.path, destinationPath: nil, disposition: disposition, message: error.localizedDescription))
                }
                try await history.save(run)
            }
        }
        run.finishedAt = now()
        try await history.save(run)
        if !Task.isCancelled { try await history.prune() }
        return run
    }

    private struct Stage {
        let parentFD: Int32
        let stageFD: Int32
        let parentIdentity: UninstallFileIdentity
        let directoryName: String
        let parentPath: String
        let name: String
        var path: String { parentPath + "/" + directoryName + "/" + name }
    }

    private func prepareStage(_ item: UninstallCandidate) throws -> Stage {
        let url = URL(fileURLWithPath: item.path)
        let parentPath = url.deletingLastPathComponent().path
        let parentFD = try scanner.fileSystem.open(parentPath, directory: true)
        do {
            let parentIdentity = try scanner.fileSystem.identity(parentFD)
            let name = ".mactools-uninstall-" + UUID().uuidString
            guard mkdirat(parentFD, name, 0o700) == 0 else { throw AppUninstallerError.io(errno) }
            let stageFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard stageFD >= 0 else {
                _ = unlinkat(parentFD, name, AT_REMOVEDIR)
                throw AppUninstallerError.io(errno)
            }
            return Stage(parentFD: parentFD, stageFD: stageFD, parentIdentity: parentIdentity,
                         directoryName: name, parentPath: parentPath, name: url.lastPathComponent)
        } catch { close(parentFD); throw error }
    }

    private func move(_ item: UninstallCandidate, staged: Stage, plan: UninstallPlan, now: @Sendable () -> Date) -> UninstallItemResult {
        let fs = scanner.fileSystem
        var moved = false
        func result(_ status: UninstallDisposition, destination: String? = nil, message: String? = nil) -> UninstallItemResult {
            .init(originalPath: item.path, destinationPath: destination, disposition: status, message: message)
        }
        func sameObject(_ first: UninstallFileIdentity, _ second: UninstallFileIdentity) -> Bool {
            first.device == second.device && first.inode == second.inode && first.mode == second.mode
        }
        do {
            try Task.checkCancellation()
            try environment.validateRunning(applicationPath: plan.application.path, additionalPath: nil)
            guard let expected = item.snapshot, try fs.tree(item.path) == expected,
                  sameObject(try fs.identity(at: staged.parentPath), staged.parentIdentity) else { throw AppUninstallerError.changed }
            try environment.validateRunning(applicationPath: plan.application.path, additionalPath: nil)
            guard try fs.identity(at: item.path) == expected.identity else { throw AppUninstallerError.changed }
            guard now() < plan.expiresAt else { throw AppUninstallerError.expired }
            try Task.checkCancellation()
            guard renameatx_np(staged.parentFD, staged.name, staged.stageFD, staged.name, UInt32(RENAME_EXCL)) == 0 else {
                throw AppUninstallerError.io(errno)
            }
            moved = true
            try environment.validateRunning(applicationPath: plan.application.path,
                                                  additionalPath: item.dataClass == .application ? staged.path : nil)
            let frozen = try fs.tree(staged.path)
            guard sameObject(frozen.identity, expected.identity), frozen.digest == expected.digest,
                  sameObject(try fs.identity(at: staged.parentPath), staged.parentIdentity) else { throw AppUninstallerError.changed }
            try environment.validateRunning(applicationPath: plan.application.path, additionalPath: item.dataClass == .application ? staged.path : nil)
            guard try fs.identity(at: staged.path) == frozen.identity else { throw AppUninstallerError.changed }
            guard now() < plan.expiresAt else { throw AppUninstallerError.expired }
            try Task.checkCancellation()
            let destination = try trash.trash(URL(fileURLWithPath: staged.path))
            _ = unlinkat(staged.parentFD, staged.directoryName, AT_REMOVEDIR)
            return result(.trashed, destination: destination?.path, message: "已移入废纸篓；未测量实际回收空间。")
        } catch {
            if moved {
                // Rollback never overwrites a rebuilt original or moves a substituted staged object.
                guard let expected = item.snapshot,
                      let current = try? fs.identity(at: staged.path), sameObject(current, expected.identity),
                      renameatx_np(staged.stageFD, staged.name, staged.parentFD, staged.name, UInt32(RENAME_EXCL)) == 0 else {
                    return result(.needsAttention, destination: staged.path, message: "未能恢复原位置：\(error.localizedDescription)")
                }
            }
            _ = unlinkat(staged.parentFD, staged.directoryName, AT_REMOVEDIR)
            let status: UninstallDisposition = error is CancellationError ? .cancelled
                : error as? AppUninstallerError == .expired || error as? AppUninstallerError == .changed ? .changed
                : error as? AppUninstallerError == .running ? .running : .failed
            return result(status, message: error.localizedDescription)
        }
    }
}
