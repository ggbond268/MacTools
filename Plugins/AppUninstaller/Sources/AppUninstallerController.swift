import AppKit
import Combine
import Foundation
import MacToolsPluginKit
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
    @Published private(set) var inventoryError: String?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isMainAppRunning = false
    @Published private(set) var hasRunningHelpers = false
    @Published private(set) var processCheckIncomplete = false
    @Published private(set) var selectedPath: String?
    @Published private(set) var selectedIDs = Set<String>()
    @Published private(set) var selectedApplicationPaths = Set<String>()
    @Published private(set) var batchScans: [UninstallScan] = []
    @Published private(set) var batchSelections: [String: Set<String>] = [:]
    @Published private(set) var isPreparingBatch = false
    @Published private(set) var batchProgress = 0
    @Published private(set) var batchProcessCheckIncomplete = false
    @Published private(set) var batchRunningPaths = Set<String>()
    @Published private(set) var batchResult: (completed: Int, total: Int)?
    @Published var pendingPlan: UninstallPlan?
    @Published var pendingBatchPlan: UninstallBatchPlan?
    @Published private(set) var isRemoving = false
    @Published private(set) var isQuitting = false
    @Published private(set) var runs: [UninstallRun] = []
    var onStateChange: (() -> Void)?
    var openHomebrew: (() -> Void)?
    var openXcodeStorage: (() -> Void)?
    var openFullDiskAccess: (() -> Void)?
    private let service: any UninstallReviewProviding
    private let localization: PluginLocalization
    private let executor: UninstallExecutor?
    private let history: UninstallHistory?
    private let processProvider: @Sendable () -> UninstallProcessSnapshot
    private var removalTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var selectionOverrides: [String: [String: Bool]] = [:]
    private var generation = UUID()
    private var browseGeneration = UUID()
    private var batchGeneration = UUID()
    private var batchRunningGeneration = UUID()
    private var runningGeneration = UUID()
    private var observers = Set<AnyCancellable>()

    init(service: any UninstallReviewProviding, executor: UninstallExecutor? = nil, history: UninstallHistory? = nil,
         localization: PluginLocalization = PluginLocalization(bundle: .main),
         processProvider: @escaping @Sendable () -> UninstallProcessSnapshot = {
             (try? UninstallSystemEnvironment.processSnapshot()) ?? .init(paths: [], complete: false)
         }) {
        self.service = service; self.executor = executor; self.history = history; self.localization = localization
        self.processProvider = processProvider
    }

    private func message(_ key: String, _ fallback: String) -> String {
        localization.string("error." + key, defaultValue: fallback)
    }

    private func describe(_ error: Error) -> String {
        guard let error = error as? AppUninstallerError else { return error.localizedDescription }
        switch error {
        case .invalidApplication: return message("invalidApplication", "无法读取有效的应用身份。")
        case .unsafePath: return message("unsafePath", "路径包含链接、受保护位置或不支持的卷。")
        case .incomplete: return message("incomplete", "检查未完成，请查看扫描范围并重新扫描。")
        case .changed: return message("changed", "项目已变化，请重新扫描。")
        case .expired: return message("expired", "检查结果已过期，请重新扫描。")
        case .running: return message("running", "应用或其组件仍在运行，请退出后重试。")
        case .blocked: return message("blocked", "此项目需要使用原安装工具或由管理员处理。")
        case let .io(code): return String(format: message("io", "无法访问项目（%d）。"), code)
        }
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addApplications(panel.urls)
        }
    }

    func addApplications(_ urls: [URL]) {
        guard !isRemoving else { return }
        let valid = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "app" }
        guard valid.count == urls.count, !valid.isEmpty else {
            error = describe(AppUninstallerError.invalidApplication)
            return
        }
        for url in valid { selectedApplicationPaths.insert(url.path) }
        pendingBatchPlan = nil
        if let first = valid.first { review(first, includeInBatch: false) }
    }

    func canIncludeInBatch(_ app: UninstallApplication) -> Bool {
        app.restrictions.isEmpty && ![.homebrew, .system, .managed, .vendorRequired].contains(app.source)
    }

    func review(_ url: URL, includeInBatch: Bool = true) {
        guard !isRemoving else { return }
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else {
            error = describe(AppUninstallerError.invalidApplication)
            return
        }
        task?.cancel()
        generation = UUID()
        let token = generation
        if includeInBatch { selectedApplicationPaths.insert(url.path) }
        selectedPath = url.path; scan = nil; selectedIDs = []; pendingPlan = nil; pendingBatchPlan = nil
        error = nil; isRunning = false; isScanning = true
        onStateChange?()
        let service = service
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let value = try await service.review(url.path)
                try Task.checkCancellation()
                await self?.finish(value, token: token)
            } catch is CancellationError {
                await self?.failCancelled(token: token)
            } catch {
                await self?.fail(error, token: token)
            }
        }
    }

    private func finish(_ value: UninstallScan, token: UUID) {
        guard token == generation else { return }
        scan = value; isScanning = false; task = nil
        selectedIDs = selection(for: value)
        if let index = batchScans.firstIndex(where: { $0.application.path == value.application.path }) {
            batchScans[index] = value
            batchSelections[value.application.path] = selectedIDs
        }
        refreshRunningState(); onStateChange?()
    }

    private func fail(_ message: String, token: UUID) {
        guard token == generation else { return }
        error = message; isScanning = false; task = nil; onStateChange?()
    }

    private func fail(_ error: Error, token: UUID) { fail(describe(error), token: token) }
    private func failCancelled(token: UUID) { fail(message("cancelled", "扫描已取消，结果不完整。"), token: token) }

    func browseIfNeeded() { if inventory == nil && !isBrowsing { browse() } }

    func browse() {
        guard !isRemoving else { return }
        browseTask?.cancel(); browseGeneration = UUID()
        let token = browseGeneration
        isBrowsing = true; inventoryError = nil
        let service = service
        browseTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let inventory = try await service.installedApplications()
                try Task.checkCancellation()
                await self?.finishBrowse(inventory, error: nil, token: token)
            } catch {
                await self?.failBrowse(error, token: token)
            }
        }
    }

    private func finishBrowse(_ value: UninstallInventory?, error: String?, token: UUID) {
        guard token == browseGeneration else { return }
        if let value { inventory = value }
        inventoryError = error; isBrowsing = false; browseTask = nil
    }

    private func failBrowse(_ error: Error, token: UUID) {
        finishBrowse(nil, error: describe(error), token: token)
    }

    func cancel() {
        removalTask?.cancel()
        cancelScans()
    }

    func cancelScans() {
        batchTask?.cancel()
        let wasBusy = isScanning || isBrowsing || isPreparingBatch
        generation = UUID(); browseGeneration = UUID(); batchGeneration = UUID()
        task?.cancel(); browseTask?.cancel(); task = nil; browseTask = nil; batchTask = nil
        isScanning = false; isBrowsing = false; isPreparingBatch = false
        if wasBusy { error = message("cancelled", "扫描已取消，结果不完整。") }
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
        guard !isRemoving, let candidate = scan?.candidates.first(where: { $0.id == id }),
              candidate.eligible, candidate.dataClass != .application else { return }
        pendingPlan = nil; pendingBatchPlan = nil
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        if let selectedPath {
            selectionOverrides[selectedPath, default: [:]][id] = selected
            if batchSelections[selectedPath] != nil { batchSelections[selectedPath] = selectedIDs }
        }
    }

    private func selection(for scan: UninstallScan) -> Set<String> {
        let overrides = selectionOverrides[scan.application.path] ?? [:]
        return Set(scan.candidates.filter { candidate in
            if candidate.dataClass == .application {
                return candidate.eligible && selectedApplicationPaths.contains(scan.application.path)
            }
            return candidate.eligible && (overrides[candidate.id] ?? candidate.selectedByDefault)
        }.map(\.id))
    }

    func setApplicationSelected(_ path: String, selected: Bool) {
        guard !isRemoving, !isPreparingBatch else { return }
        guard selected
            ? (inventory?.apps.contains(where: { $0.path == path }) == true || selectedPath == path)
            : selectedApplicationPaths.contains(path) else { return }
        if selected, let app = inventory?.apps.first(where: { $0.path == path }), !canIncludeInBatch(app) { return }
        pendingBatchPlan = nil; batchResult = nil
        if selected { selectedApplicationPaths.insert(path) }
        else { selectedApplicationPaths.remove(path) }
        if selectedPath == path, scan?.candidates.contains(where: { $0.id == path && $0.eligible }) == true {
            if selected { selectedIDs.insert(path) } else { selectedIDs.remove(path) }
        }
        batchScans.removeAll { $0.application.path == path }
        batchSelections.removeValue(forKey: path)
    }

    func clearSelectedApplications() {
        guard !isRemoving, !isPreparingBatch else { return }
        selectedApplicationPaths = []
        if let selectedPath { selectedIDs.remove(selectedPath) }
        batchScans = []; batchSelections = [:]; pendingBatchPlan = nil; batchResult = nil
    }

    func setBatchCandidateSelected(appPath: String, itemID: String, selected: Bool) {
        guard !isRemoving,
              let candidate = batchScans.first(where: { $0.application.path == appPath })?.candidates.first(where: { $0.id == itemID }),
              candidate.eligible, candidate.dataClass != .application else { return }
        pendingBatchPlan = nil
        selectionOverrides[appPath, default: [:]][itemID] = selected
        if selected { batchSelections[appPath, default: []].insert(itemID) }
        else { batchSelections[appPath]?.remove(itemID) }
        if selectedPath == appPath { selectedIDs = batchSelections[appPath] ?? [] }
    }

    func reviewSelectedApplications() {
        guard !isRemoving, !selectedApplicationPaths.isEmpty else { return }
        batchTask?.cancel(); batchGeneration = UUID()
        let token = batchGeneration
        let paths = selectedApplicationPaths.sorted()
        batchScans = []; batchSelections = [:]; batchProgress = 0
        pendingBatchPlan = nil; error = nil; isPreparingBatch = true
        let service = service
        batchTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for path in paths {
                    try Task.checkCancellation()
                    let scan = try await service.review(path)
                    try Task.checkCancellation()
                    await self?.appendBatchScan(scan, token: token)
                }
                await self?.finishBatchReview(token: token)
            } catch is CancellationError {
                await self?.failBatchReviewCancelled(token: token)
            } catch {
                await self?.failBatchReview(error, token: token)
            }
        }
    }

    private func appendBatchScan(_ value: UninstallScan, token: UUID) {
        guard token == batchGeneration, selectedApplicationPaths.contains(value.application.path) else { return }
        batchScans.append(value)
        batchSelections[value.application.path] = selection(for: value)
        batchProgress = batchScans.count
        if selectedPath == value.application.path {
            scan = value; selectedIDs = batchSelections[value.application.path] ?? []
        }
    }

    private func finishBatchReview(token: UUID) {
        guard token == batchGeneration else { return }
        isPreparingBatch = false; batchTask = nil
        guard Set(batchScans.map(\.application.path)) == selectedApplicationPaths else {
            error = message("batchIncomplete", "应用检查未完成，请重新检查所选应用。")
            return
        }
        onStateChange?()
    }

    private func failBatchReview(_ message: String, token: UUID) {
        guard token == batchGeneration else { return }
        isPreparingBatch = false; batchTask = nil; error = message; onStateChange?()
    }

    private func failBatchReview(_ error: Error, token: UUID) { failBatchReview(describe(error), token: token) }
    private func failBatchReviewCancelled(token: UUID) {
        failBatchReview(message("cancelled", "扫描已取消，结果不完整。"), token: token)
    }

    func prepareBatchPlan() {
        guard executor != nil else {
            error = message("historyUnavailable", "无法初始化本地操作记录，移除不可用。")
            return
        }
        guard !isRemoving, !isPreparingBatch,
              Set(batchScans.map(\.application.path)) == selectedApplicationPaths else {
            error = message("batchReviewFirst", "请先检查所有选中的应用。")
            return
        }
        do {
            let plan = try UninstallBatchPlanner.make(scans: batchScans, selections: batchSelections)
            pendingBatchPlan = plan; error = nil
            refreshBatchRunningState()
        } catch { self.error = describe(error) }
    }

    func refreshBatchRunningState() {
        guard let plan = pendingBatchPlan else { return }
        batchRunningGeneration = UUID()
        let token = batchRunningGeneration
        batchProcessCheckIncomplete = true
        batchRunningPaths = []
        let provider = processProvider
        Task.detached { [weak self] in
            let state = provider()
            await self?.finishBatchRunningState(state, plan: plan, token: token)
        }
    }

    private func finishBatchRunningState(_ state: UninstallProcessSnapshot, plan: UninstallBatchPlan, token: UUID) {
        guard token == batchRunningGeneration, pendingBatchPlan?.id == plan.id else { return }
        batchProcessCheckIncomplete = !state.complete
        batchRunningPaths = Set(plan.plans.map(\.application).filter { app in
            state.paths.contains { UninstallPaths.contains($0, in: app.path) }
                || NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == app.path }
        }.map(\.path))
    }

    func removeReviewedBatch(_ batch: UninstallBatchPlan) {
        guard !isRemoving, pendingBatchPlan?.id == batch.id, let executor,
              !batchProcessCheckIncomplete, batchRunningPaths.isEmpty else { return }
        pendingBatchPlan = nil; isRemoving = true; batchResult = nil; batchProgress = 0; error = nil
        onStateChange?()
        removalTask = Task.detached(priority: .userInitiated) { [weak self] in
            var completedPaths: [String] = []
            var failure: String?
            for plan in batch.plans {
                if Task.isCancelled { failure = await self?.message("batchStopped", "批量操作已停止；后续应用未处理。"); break }
                do {
                    let run = try await executor.execute(plan)
                    if run.complete { completedPaths.append(plan.application.path) }
                    else { failure = await self?.message("batchPartial", "批量操作已停止；请查看该应用的逐项结果。") }
                    await self?.updateBatchProgress(completedPaths.count)
                    if failure != nil { break }
                } catch {
                    failure = await self?.describe(error)
                    break
                }
            }
            await self?.finishBatchRemoval(completedPaths: completedPaths, total: batch.applicationCount, failure: failure)
        }
    }

    private func updateBatchProgress(_ count: Int) { batchProgress = count }

    private func finishBatchRemoval(completedPaths: [String], total: Int, failure: String?) {
        isRemoving = false; removalTask = nil
        batchResult = (completedPaths.count, total)
        error = failure
        selectedApplicationPaths.subtract(completedPaths)
        batchScans = []; batchSelections = [:]
        if completedPaths.contains(selectedPath ?? "") { selectedPath = nil; scan = nil; selectedIDs = [] }
        loadHistory(); browse(); onStateChange?()
    }

    func preparePlan() {
        guard !isRemoving, let scan, executor != nil else {
            error = message("historyUnavailable", "无法初始化本地操作记录，移除不可用。"); return
        }
        do { pendingPlan = try UninstallPlanner.make(scan: scan, selectedIDs: selectedIDs); error = nil }
        catch { self.error = describe(error) }
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
            } catch { await self?.finishRemoval(error) }
        }
    }

    private func finishRemoval(_ message: String?) {
        isRemoving = false; removalTask = nil; error = message
        loadHistory(); onStateChange?()
    }

    private func finishRemoval(_ error: Error) { finishRemoval(describe(error)) }

    func loadHistory(clear: Bool = false) {
        guard let history else { return }
        Task { [weak self] in
            do {
                if clear { try await history.prune(clear: true) }
                let runs = try await history.load()
                self?.runs = runs
            } catch {
                let prefix = self?.message("historyRead", "无法读取操作记录：") ?? "无法读取操作记录："
                self?.error = prefix + error.localizedDescription
            }
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
            if targets.contains(where: { !$0.isTerminated }) {
                self?.error = self?.message("quitIncomplete", "应用尚未退出，请保存工作并手动退出。")
            }
        }
    }
}
