import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

protocol UninstallReviewProviding: Sendable {
    func review(_ path: String) async throws -> UninstallScan
    func installedApplications() async throws -> UninstallInventory
}

struct UninstallReviewService: UninstallReviewProviding {
    let scanner: UninstallScanner
    let environment: any UninstallEnvironmentChecking
    func review(_ path: String) async throws -> UninstallScan {
        let state = try await environment.inspect(applicationPath: path)
        try Task.checkCancellation()
        return try scanner.scan(path: path, environment: state)
    }
    func installedApplications() async throws -> UninstallInventory {
        let paths = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleURL).map(\.path).filter { $0.lowercased().hasSuffix(".app") }
        }
        return try scanner.inventory(runningPaths: paths)
    }
}

@MainActor
final class AppUninstallerController: ObservableObject {
    @Published private(set) var scan: UninstallScan?
    @Published private(set) var inventory: UninstallInventory?
    @Published private(set) var isScanning = false
    @Published private(set) var isBrowsing = false
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isMainAppRunning = false
    @Published private(set) var hasRunningHelpers = false
    @Published private(set) var processCheckIncomplete = false
    @Published private(set) var selectedPath: String?
    @Published private(set) var selectedIDs = Set<String>()
    @Published var pendingPlan: UninstallPlan?
    @Published private(set) var isRemoving = false
    @Published private(set) var isQuitting = false
    @Published private(set) var runs: [UninstallRun] = []
    var onStateChange: (() -> Void)?
    var openHomebrew: (() -> Void)?
    var openFullDiskAccess: (() -> Void)?
    private let service: any UninstallReviewProviding
    private let executor: UninstallExecutor?
    private let history: UninstallHistory?
    private let processProvider: @Sendable () -> UninstallProcessSnapshot
    private var removalTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var generation = UUID()
    private var browseGeneration = UUID()
    private var runningGeneration = UUID()
    private var observers = Set<AnyCancellable>()

    init(service: any UninstallReviewProviding, executor: UninstallExecutor? = nil, history: UninstallHistory? = nil,
         processProvider: @escaping @Sendable () -> UninstallProcessSnapshot = {
             (try? UninstallSystemEnvironment.processSnapshot()) ?? .init(paths: [], complete: false)
         }) {
        self.service = service; self.executor = executor; self.history = history
        self.processProvider = processProvider
    }

    func activate() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningState() }
            }.store(in: &observers)
        }
        refreshRunningState()
        loadHistory()
    }

    func deactivate() { cancel(); observers.removeAll() }

    func choose() {
        guard !isRemoving else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.review(url)
        }
    }

    func review(_ url: URL) {
        guard !isRemoving else { return }
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else {
            error = AppUninstallerError.invalidApplication.localizedDescription
            return
        }
        task?.cancel()
        generation = UUID()
        let token = generation
        selectedPath = url.path; scan = nil; selectedIDs = []; pendingPlan = nil; error = nil; isRunning = false; isScanning = true
        onStateChange?()
        let service = service
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let value = try await service.review(url.path)
                try Task.checkCancellation()
                await self?.finish(value, token: token)
            } catch is CancellationError {
                await self?.fail("扫描已取消，结果不完整。", token: token)
            } catch {
                await self?.fail(error.localizedDescription, token: token)
            }
        }
    }

    private func finish(_ value: UninstallScan, token: UUID) {
        guard token == generation else { return }
        scan = value; isScanning = false; task = nil
        selectedIDs = Set(value.candidates.filter(\.selectedByDefault).map(\.id))
        refreshRunningState(); onStateChange?()
    }

    private func fail(_ message: String, token: UUID) {
        guard token == generation else { return }
        error = message; isScanning = false; task = nil; onStateChange?()
    }

    func browse() {
        guard !isRemoving else { return }
        browseTask?.cancel(); browseGeneration = UUID()
        let token = browseGeneration
        isBrowsing = true; inventory = nil; error = nil
        let service = service
        browseTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let inventory = try await service.installedApplications()
                try Task.checkCancellation()
                await self?.finishBrowse(inventory, error: nil, token: token)
            } catch {
                await self?.finishBrowse(nil, error: error.localizedDescription, token: token)
            }
        }
    }

    private func finishBrowse(_ value: UninstallInventory?, error: String?, token: UUID) {
        guard token == browseGeneration else { return }
        inventory = value; self.error = error; isBrowsing = false; browseTask = nil
    }

    func cancel() {
        removalTask?.cancel()
        let wasBusy = isScanning || isBrowsing
        generation = UUID(); browseGeneration = UUID()
        task?.cancel(); browseTask?.cancel(); task = nil; browseTask = nil
        isScanning = false; isBrowsing = false
        if wasBusy { error = "扫描已取消，结果不完整。" }
        onStateChange?()
    }

    func rescan() { if let selectedPath { review(URL(fileURLWithPath: selectedPath)) } }

    func refreshRunningState() {
        guard let app = scan?.application ?? pendingPlan?.application else { isRunning = false; return }
        isMainAppRunning = UninstallSystemEnvironment.isRunning(app)
        isRunning = isMainAppRunning
        runningGeneration = UUID()
        let token = runningGeneration
        let processProvider = processProvider
        Task.detached { [weak self] in
            let state = processProvider()
            await self?.finishRunning(state, token: token, app: app)
        }
        onStateChange?()
    }

    private func finishRunning(_ state: UninstallProcessSnapshot, token: UUID, app: UninstallApplication) {
        guard token == runningGeneration, selectedPath == app.path else { return }
        isMainAppRunning = UninstallSystemEnvironment.isRunning(app)
        hasRunningHelpers = state.paths.contains { UninstallPaths.contains($0, in: app.path) && $0 != app.executable }
            || (!isMainAppRunning && state.paths.contains { UninstallPaths.contains($0, in: app.path) })
        processCheckIncomplete = !state.complete
        isRunning = isMainAppRunning || hasRunningHelpers
        onStateChange?()
    }

    func reveal(_ path: String) {
        // Reveal never opens an application or a candidate's contents.
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func setSelected(_ id: String, selected: Bool) {
        guard !isRemoving, scan?.candidates.first(where: { $0.id == id })?.eligible == true else { return }
        pendingPlan = nil
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }

    func preparePlan() {
        guard !isRemoving, let scan, executor != nil else { error = "无法初始化本地操作记录，移除不可用。"; return }
        do { pendingPlan = try UninstallPlanner.make(scan: scan, selectedIDs: selectedIDs); error = nil }
        catch { self.error = error.localizedDescription }
    }

    /// Called only by the explicit confirmation button for the currently presented immutable plan.
    func removeReviewedPlan(_ plan: UninstallPlan) {
        guard !isRemoving, pendingPlan?.id == plan.id, let executor else { return }
        pendingPlan = nil; isRemoving = true; error = nil; scan = nil; selectedIDs = []
        onStateChange?()
        removalTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try await executor.execute(plan)
                await self?.finishRemoval(nil)
            } catch { await self?.finishRemoval(error.localizedDescription) }
        }
    }

    private func finishRemoval(_ message: String?) {
        isRemoving = false; removalTask = nil; error = message
        loadHistory(); onStateChange?()
    }

    func loadHistory(clear: Bool = false) {
        guard let history else { return }
        Task { [weak self] in
            do {
                if clear { try await history.prune(clear: true) }
                let runs = try await history.load()
                self?.runs = runs
            } catch { self?.error = "无法读取操作记录：\(error.localizedDescription)" }
        }
    }

    func quit(_ app: UninstallApplication, force: Bool = false) {
        guard !isRemoving, !isQuitting else { return }
        let targets = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.path && $0.bundleIdentifier == app.bundleID }
        guard !targets.isEmpty else { refreshRunningState(); return }
        isQuitting = true
        for target in targets { if force { _ = target.forceTerminate() } else { _ = target.terminate() } }
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(10)
            while targets.contains(where: { !$0.isTerminated }), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            self?.isQuitting = false; self?.refreshRunningState()
            if targets.contains(where: { !$0.isTerminated }) { self?.error = "应用尚未退出，请保存工作并手动退出。" }
        }
    }
}
