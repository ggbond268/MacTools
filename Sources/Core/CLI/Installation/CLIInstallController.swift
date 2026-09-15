import Foundation

enum CLIInstallPhase: Equatable, Sendable {
    case notInstalled, downloading, verifying, installing, installed, updateAvailable
    case failed(String)
}

enum CLIInstallLaunchPolicy {
    static func shouldUpdate(receipt: CLIManagedReceipt?, target: CLIReleaseManifest, rollbackForRelease: String? = nil) -> Bool {
        // The managed receipt is the installation opt-in; the legacy update preference no longer gates updates.
        guard let receipt, rollbackForRelease != target.directoryName else { return false }
        return receipt.manifest != target
    }
}

enum CLIInstallOperation: Equatable, Sendable {
    case refresh(updateOnLaunch: Bool)
    case install(enableIntegration: Bool, rollback: Bool)
    case remove
}

@MainActor
final class CLIInstallController: ObservableObject {
    static let shared = CLIInstallController()
    @Published private(set) var manifest: CLIReleaseManifest?
    @Published private(set) var receipt: CLIManagedReceipt?
    @Published private(set) var phase: CLIInstallPhase = .notInstalled
    @Published private(set) var rollbackForRelease: String?
    @Published private(set) var busy = false
    @Published private(set) var canRollback = false
    private(set) var failedOperation: CLIInstallOperation?
    private(set) var lastError: Error?
    private var didStart = false
    private let home: URL
    private let authenticate: @Sendable () throws -> CLIReleaseManifest
    private let dependencies: CLIInstaller.Dependencies
    private let prepareIntegration: (Bool) -> Bool

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         authenticate: @escaping @Sendable () throws -> CLIReleaseManifest = { try CLIReleaseManifest.authenticated() },
         dependencies: CLIInstaller.Dependencies = .live,
         prepareIntegration: @escaping (Bool) -> Bool = { enable in
             if enable { CLIBrokerServiceController.shared.ensureRegistered() }
             return CLIBrokerServiceController.shared.status == .enabled
         }) {
        self.home = home
        self.authenticate = authenticate
        self.dependencies = dependencies
        self.prepareIntegration = prepareIntegration
    }

    func retry() {
        guard !busy, let operation = failedOperation else { return }
        switch operation {
        case let .refresh(updateOnLaunch): refresh(updateOnLaunch: updateOnLaunch)
        case let .install(enableIntegration, rollback):
            install(enableIntegration: enableIntegration, rollback: rollback)
        case .remove: remove()
        }
    }

    private func begin() {
        busy = true
        failedOperation = nil
        lastError = nil
    }

    private nonisolated static func snapshot(_ store: CLIManagedStore) throws -> (CLIManagedState?, CLIManagedReceipt?) {
        guard try CLIManagedStore.entry(store.root) != nil else { return (nil, nil) }
        let lock = try store.lock(create: false)
        defer { close(lock) }
        let state = try store.recover()
        return (state, try state?.active.map { try store.receipt($0) })
    }

    private func apply(_ snapshot: (CLIManagedState?, CLIManagedReceipt?)) {
        receipt = snapshot.1
        rollbackForRelease = snapshot.0?.rollbackForRelease
        canRollback = snapshot.0?.previous != nil && receipt != nil
    }

    private func failed(_ error: Error, operation: CLIInstallOperation) async {
        // A removal may already have committed an empty state before cleanup failed.
        // Never keep a stale receipt or infer the retry operation from installed state.
        if let store {
            let snapshot = try? await Task.detached(priority: .utility) { try Self.snapshot(store) }.value
            apply(snapshot ?? (nil, nil))
        }
        lastError = error
        failedOperation = operation
        phase = .failed(error.localizedDescription)
        busy = false
    }

    static var isSupportedChannel: Bool {
        #if arch(arm64)
        CLIInstallChannel.isAvailable(
            channel: Bundle.main.object(forInfoDictionaryKey: "MTReleaseChannel") as? String,
            hasManifest: Bundle.main.url(forResource: "cli-install", withExtension: "json") != nil)
        #else
        false
        #endif
    }

    var isRollbackHeld: Bool {
        guard let manifest else { return false }
        return receipt != nil && rollbackForRelease == manifest.directoryName
    }

    var store: CLIManagedStore? { manifest.map { CLIManagedStore(manifest: $0, home: home) } }

    func start() {
        guard Self.isSupportedChannel, !didStart else { return }
        didStart = true
        refresh(updateOnLaunch: true)
    }

    func refresh(updateOnLaunch: Bool = false) {
        guard !busy else { return }
        begin()
        let authenticate = authenticate
        let home = home
        Task {
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    let manifest = try authenticate()
                    let state = try Self.snapshot(CLIManagedStore(manifest: manifest, home: home))
                    return (manifest, state)
                }.value
                manifest = snapshot.0
                apply(snapshot.1)
                if let receipt {
                    phase = receipt.manifest == manifest ? .installed : .updateAvailable
                    if !receipt.manifest.isCompatible {
                        lastError = CLIInstallError.incompatible
                        failedOperation = .install(enableIntegration: false, rollback: false)
                        phase = .failed(CLIInstallError.incompatible.localizedDescription)
                    }
                } else { phase = .notInstalled }
                busy = false
                if updateOnLaunch, CLIInstallLaunchPolicy.shouldUpdate(receipt: receipt, target: snapshot.0, rollbackForRelease: rollbackForRelease) {
                    install()
                }
            } catch {
                await failed(error, operation: .refresh(updateOnLaunch: updateOnLaunch))
            }
        }
    }

    func install(enableIntegration: Bool = false, rollback: Bool = false) {
        guard !busy, let manifest else { return }
        begin()
        phase = .downloading
        let doctor = prepareIntegration(enableIntegration)
        let home = home
        let dependencies = dependencies
        let progress: @Sendable (CLIInstallPhase) async -> Void = { [weak self] phase in
            await MainActor.run { self?.phase = phase }
        }
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await CLIInstaller.install(manifest: manifest, automaticUpdates: true,
                                                   doctor: doctor, rollback: rollback, home: home,
                                                   dependencies: dependencies, progress: progress)
                }.value
                receipt = result.0
                canRollback = result.1.previous != nil
                self.rollbackForRelease = result.1.rollbackForRelease
                phase = receipt?.manifest == manifest ? .installed : .updateAvailable
            } catch {
                await failed(error, operation: .install(enableIntegration: enableIntegration, rollback: rollback))
            }
            busy = false
        }
    }

    func remove() { mutate(.remove) { try $0.remove() } }

    private func mutate(_ operation: CLIInstallOperation, _ action: @escaping @Sendable (CLIManagedStore) throws -> Void) {
        guard !busy, let store else { return }
        begin()
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    let lock = try store.lock(create: false)
                    defer { close(lock) }
                    try action(store)
                }.value
                busy = false
                refresh()
            } catch {
                await failed(error, operation: operation)
            }
        }
    }
}

enum CLIInstaller {
    struct Dependencies: Sendable {
        var download: @Sendable (CLIReleaseManifest, URL) async throws -> Void
        var verify: @Sendable (URL, CLIReleaseManifest) throws -> Void
        var execute: @Sendable (URL, CLIReleaseManifest, Bool) throws -> Void
        static let live = Dependencies(download: { try await CLIBoundedDownload.fetch($0, to: $1) },
            verify: { try CLIArtifactVerifier.verifyExecutable($0, manifest: $1) },
            execute: { try CLIArtifactVerifier.validateExecution($0, manifest: $1, doctor: $2) })
    }

    static func install(manifest: CLIReleaseManifest, automaticUpdates: Bool, doctor: Bool,
                        rollback: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        dependencies: Dependencies = .live,
                        progress: @Sendable (CLIInstallPhase) async -> Void) async throws
        -> (CLIManagedReceipt, CLIManagedState) {
        let store = CLIManagedStore(manifest: manifest, home: home)
        let lock = try store.lock(create: true)
        defer { close(lock) }
        let state = try store.recover()
        try store.cleanStaging()
        try store.checkCommand(allowMissing: state?.active == nil)
        let name: String
        if rollback {
            guard let previous = state?.previous else { throw CLIInstallError.ownership }
            name = previous
            guard try store.receipt(name).manifest.isCompatible else { throw CLIInstallError.incompatible }
        } else { name = manifest.directoryName }

        // Prune only unreferenced versions before any activation. Keep both journal references
        // and a matching retained candidate; a successful update leaves at most three versions
        // until the next managed operation. Cleanup failure never misreports an activated update.
        try store.prune(keeping: state ?? CLIManagedState(owner: store.owner, active: nil, previous: nil,
            automaticUpdates: automaticUpdates, pending: false), additionallyKeeping: name)
        let destination = store.root.appendingPathComponent(name)
        if try CLIManagedStore.entry(destination) == nil {
            guard !rollback else { throw CLIInstallError.ownership }
            let stage = store.root.appendingPathComponent(".stage-" + UUID().uuidString)
            guard mkdir(stage.path, 0o700) == 0 else { throw CLIInstallError.filesystem }
            try Data(store.owner.utf8).write(to: stage.appendingPathComponent("owner"), options: .withoutOverwriting)
            defer {
                // Only our own staging names; no recursive traversal or symlink following.
                for file in ["archive.zip", "mactools", "LICENSE", "receipt.json", "owner"] {
                    unlink(stage.appendingPathComponent(file).path)
                }
                rmdir(stage.path)
            }
            let archiveURL = stage.appendingPathComponent("archive.zip")
            try await dependencies.download(manifest, archiveURL)
            await progress(.verifying)
            try CLIManagedStore.regular(archiveURL)
            let archive = try Data(contentsOf: archiveURL)
            guard archive.count == manifest.size, cliSHA256(archive) == manifest.sha256 else { throw CLIInstallError.archive }
            try CLIArchive.validate(archive)
            try CLIArtifactVerifier.quarantine(archiveURL)
            for file in ["mactools", "LICENSE"] {
                let data = try CLIProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                    ["-p", archiveURL.path, file],
                    limit: file == "mactools" ? CLIReleaseManifest.maximumArchiveSize : 65536)
                let url = stage.appendingPathComponent(file)
                try data.write(to: url, options: .withoutOverwriting)
                guard chmod(url.path, file == "mactools" ? 0o755 : 0o644) == 0 else { throw CLIInstallError.filesystem }
                try CLIArtifactVerifier.quarantine(url)
            }
            let executable = stage.appendingPathComponent("mactools")
            try dependencies.verify(executable, manifest)
            try dependencies.execute(executable, manifest, false)
            let receipt = CLIManagedReceipt(owner: store.owner, manifest: manifest,
                executableHash: cliSHA256(try Data(contentsOf: executable)),
                managedPath: destination.appendingPathComponent("mactools").path, linkPath: store.command.path)
            try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
            for file in ["mactools", "LICENSE", "receipt.json"] {
                try CLIManagedStore.synchronizeFile(stage.appendingPathComponent(file))
            }
            guard unlink(archiveURL.path) == 0, unlink(stage.appendingPathComponent("owner").path) == 0,
                  renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw CLIInstallError.filesystem
            }
        }
        await progress(.verifying)
        let candidate = try store.receipt(name)
        guard rollback || candidate.manifest == manifest else { throw CLIInstallError.ownership }
        try dependencies.verify(URL(fileURLWithPath: candidate.managedPath), candidate.manifest)
        await progress(.installing)
        let active = try store.activate(name, automaticUpdates: automaticUpdates,
                                        rollbackForRelease: rollback && candidate.manifest != manifest ? manifest.directoryName : nil) { executable, release in
            try dependencies.execute(executable, release, false)
            if doctor { try dependencies.execute(executable, manifest, true) }
        }
        return (try store.receipt(name), active)
    }
}
