import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

@MainActor
public final class StorageExplorerScanStatus: ObservableObject {
    @Published public var progress = StorageExplorerScanProgress()
}

@MainActor
public final class StorageExplorerController: ObservableObject {
    @Published public private(set) var scanState: StorageExplorerScanState = .idle
    @Published public private(set) var scanRootURL: URL?
    @Published public private(set) var currentPath: String?
    @Published public private(set) var navigationStack: [StorageItem] = []
    @Published public private(set) var basket: Set<String> = []
    @Published public var searchQuery = "" { didSet { refreshPresentation() } }
    @Published public var mode: StorageExplorerMode = .folders { didSet { selectedPath = nil; refreshPresentation() } }
    @Published public var metric: StorageExplorerMetric = .logical { didSet { refreshPresentation() } }
    @Published public var selectedPath: String?
    @Published public var isConfirmingTrash = false
    @Published public private(set) var reviewItems: [StorageItem] = []
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastSuccessMessage: String?
    @Published public private(set) var isExecutingTrash = false
    @Published public private(set) var isStale = false
    @Published public private(set) var rows: [StorageExplorerRow] = []
    @Published public private(set) var chartRows: [StorageExplorerRow] = []
    @Published public private(set) var matchingCount = 0
    @Published public private(set) var displayedBytes: Int64 = 0
    public let status = StorageExplorerScanStatus()
    public let scanner: any StorageExplorerScanning
    public let safetyPolicy: StorageExplorerSafetyPolicy

    private(set) var snapshot = StorageExplorerSnapshot(rootPath: "")
    private var activeScanTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var generation = UUID()
    private var receivedGeneration: UUID?
    private var presentationRevision = 0
    private var navigationRevision = 0
    private var sort: StorageExplorerSort = .size
    private var ascending = false
    private var observer: StorageExplorerFileObserver?
    private var observerGeneration = UUID()
    private let observeChanges: Bool

    public init(scanner: any StorageExplorerScanning = StorageExplorerScanner(),
                safetyPolicy: StorageExplorerSafetyPolicy = StorageExplorerSafetyPolicy(),
                observeChanges: Bool = true) {
        self.scanner = scanner
        self.safetyPolicy = safetyPolicy
        self.observeChanges = observeChanges
    }

    deinit { activeScanTask?.cancel(); presentationTask?.cancel() }

    public var isScanning: Bool { if case .scanning = scanState { true } else { false } }
    public var rootItem: StorageItem? { snapshot.items[snapshot.rootPath] }
    public var currentDirectory: StorageItem? { currentPath.flatMap { snapshot.items[$0] } }
    public var inspectedItem: StorageItem? {
        guard let selectedPath else { return nil }
        return snapshot.items[selectedPath] ?? rows.first { $0.id == selectedPath }?.item
    }

    public func startScan(at url: URL, force: Bool = false) {
        guard !isExecutingTrash else { return }
        cancelScan()
        let id = UUID()
        generation = id
        let previousPath = currentPath
        let previousNavigationRevision = navigationRevision
        let sameRoot = url.path == scanRootURL?.path
        scanRootURL = url
        basket.removeAll()
        reviewItems = []
        isConfirmingTrash = false
        lastErrorMessage = nil
        lastSuccessMessage = nil
        isStale = false
        if force || !sameRoot || (observeChanges && observer == nil) { scanner.clearCache() }
        if !sameRoot {
            observerGeneration = UUID()
            observer = nil
            snapshot = StorageExplorerSnapshot(rootPath: url.path)
            currentPath = nil
            selectedPath = nil
            navigationStack = []
            rows = []; chartRows = []
            searchQuery = ""
        }
        if observeChanges && observer == nil {
            let observerID = observerGeneration
            observer = StorageExplorerFileObserver(path: url.path) { [weak self, scanner] paths in
                if let paths { scanner.invalidate(paths: paths) } else { scanner.clearCache() }
                MainActor.assumeIsolated {
                    guard let self, self.observerGeneration == observerID else { return }
                    self.isStale = true
                }
            }
        }
        status.progress = StorageExplorerScanProgress(currentPath: url.path)
        scanState = .scanning(status.progress)
        activeScanTask = Task { [weak self, scanner] in
            do {
                // Drain events from earlier writes before admitting any cached directory listing.
                if let observer = self?.observer { await observer.flush() }
                guard self?.generation == id, !Task.isCancelled else { return }
                self?.isStale = false
                let result = try await scanner.scanSnapshot(rootURL: url) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, self.isScanning else { return }
                        self.receive(update, replacing: self.receivedGeneration != id)
                        self.receivedGeneration = id
                    }
                }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.snapshot = result
                self.status.progress = result.progress
                self.scanRootURL = URL(fileURLWithPath: result.rootPath)
                let preferredPath = self.navigationRevision == previousNavigationRevision ? previousPath : self.currentPath
                self.currentPath = preferredPath.flatMap { result.items[$0] == nil ? nil : $0 } ?? result.rootPath
                self.scanState = .completed
                self.rebuildNavigation()
                self.refreshPresentation()
            } catch {
                guard let self, self.generation == id else { return }
                if error is CancellationError { self.scanState = .cancelled }
                else {
                    self.scanState = .failed(error.localizedDescription)
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func receive(_ update: StorageExplorerScanUpdate, replacing: Bool) {
        if replacing {
            let root = update.items.first { $0.parentPath == nil }?.path ?? scanRootURL?.path ?? ""
            snapshot = StorageExplorerSnapshot(rootPath: root)
            currentPath = root
            scanRootURL = URL(fileURLWithPath: root)
        }
        snapshot.apply(update.items)
        status.progress = update.progress
        rebuildNavigation()
        refreshPresentation()
    }

    public func cancelScan() {
        generation = UUID()
        activeScanTask?.cancel()
        activeScanTask = nil
        if isScanning { scanState = .cancelled }
    }

    public func selectFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()
        if panel.runModal() == .OK, let url = panel.url { startScan(at: url) }
    }

    public func scanHomeFolder() { startScan(at: FileManager.default.homeDirectoryForCurrentUser) }
    public func drillDown(to item: StorageItem) {
        guard item.isDirectory && !item.isPackage, snapshot.items[item.path] != nil else { return }
        navigationRevision += 1
        currentPath = item.path
        mode = .folders
        selectedPath = nil
        rebuildNavigation()
        refreshPresentation()
    }
    public func navigateUp() {
        guard let parent = currentDirectory?.parentPath, let item = snapshot.items[parent] else { return }
        drillDown(to: item)
    }
    public func navigateToBreadcrumb(at index: Int) {
        guard navigationStack.indices.contains(index) else { return }
        drillDown(to: navigationStack[index])
    }
    private func rebuildNavigation() {
        var stack: [StorageItem] = []
        var path = currentPath
        while let current = path, let item = snapshot.items[current] { stack.append(item); path = item.parentPath }
        navigationStack = stack.reversed()
    }

    public func setSort(_ value: StorageExplorerSort, ascending: Bool) {
        sort = value
        self.ascending = ascending
        refreshPresentation()
    }

    private func refreshPresentation() {
        presentationRevision += 1
        guard presentationTask == nil else { return }
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            let revision = self.presentationRevision
            let generation = self.generation
            let snapshot = self.snapshot, directory = self.currentPath ?? snapshot.rootPath
            let mode = self.mode, metric = self.metric, query = self.searchQuery, sort = self.sort, ascending = self.ascending
            let result = await Task.detached(priority: .userInitiated) {
                StorageExplorerPresentation.make(snapshot: snapshot, directory: directory, mode: mode,
                    metric: metric, query: query, sort: sort, ascending: ascending)
            }.value
            self.presentationTask = nil
            if generation == self.generation && directory == self.currentPath && mode == self.mode
                && metric == self.metric && query == self.searchQuery && sort == self.sort && ascending == self.ascending {
                self.rows = result.rows
                self.chartRows = result.chart
                self.matchingCount = result.matchingCount
                self.displayedBytes = result.total
            }
            if revision != self.presentationRevision { self.refreshPresentation() }
        }
    }

    public func canStage(_ item: StorageItem) -> Bool {
        !isScanning && !isExecutingTrash && !isStale && !item.isIncomplete
            && snapshot.items[item.path] != nil
            && safetyPolicy.validatePathForRemoval(item.path, withinRoot: snapshot.rootPath).isAllowed
    }
    public func toggleSelection(path: String) {
        if basket.contains(path) { basket.remove(path); return }
        guard let item = snapshot.items[path], canStage(item) else { return }
        // A selected ancestor already includes this item; selecting an ancestor replaces descendants.
        guard !basket.contains(where: { path.hasPrefix($0 + "/") }) else { return }
        basket = basket.filter { !$0.hasPrefix(path + "/") }
        basket.insert(path)
    }
    public func selectAllVisible(items: [StorageItem]) { for item in items { if !basket.contains(item.path) { toggleSelection(path: item.path) } } }
    public func clearSelection() { basket.removeAll() }
    public var selectedItemsForReview: [StorageItem] { basket.sorted().compactMap { snapshot.items[$0] } }
    public var totalSelectedBytes: Int64 { selectedItemsForReview.reduce(0) { $0 + metric.bytes($1) } }

    public func revealInFinder(path: String) {
        guard snapshot.items[path] != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    public func confirmTrash() {
        let items = selectedItemsForReview
        guard !items.isEmpty, items.allSatisfy(canStage) else { return }
        reviewItems = items
        isConfirmingTrash = true
    }
    public func executeTrash() async {
        guard !reviewItems.isEmpty, reviewItems.allSatisfy(canStage) else { isConfirmingTrash = false; return }
        let paths = reviewItems.map(\.path)
        let root = snapshot.rootPath
        isExecutingTrash = true
        do {
            _ = try await safetyPolicy.recycleItems(at: paths, withinRoot: root)
            isExecutingTrash = false
            isConfirmingTrash = false
            // Recompute accounting, including surviving hard links; never infer freed space from the basket.
            startScan(at: URL(fileURLWithPath: root), force: true)
            lastSuccessMessage = "已移至废纸篓"
        } catch {
            isExecutingTrash = false
            isConfirmingTrash = false
            isStale = true
            scanner.clearCache()
            lastErrorMessage = error.localizedDescription
        }
    }
}
