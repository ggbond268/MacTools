import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

@MainActor
public final class StorageExplorerController: ObservableObject {
    @Published public var scanState: StorageExplorerScanState = .idle
    @Published public var scanRootURL: URL?
    @Published public var rootItem: StorageItem?
    @Published public var currentDirectory: StorageItem?
    @Published public var navigationStack: [StorageItem] = []
    @Published public var basket: Set<String> = []
    @Published public var searchQuery: String = ""
    @Published public var isConfirmingTrash: Bool = false
    @Published public var lastErrorMessage: String?
    @Published public var lastSuccessMessage: String?
    @Published public var isExecutingTrash: Bool = false

    public let scanner: StorageExplorerScanner
    public let safetyPolicy: StorageExplorerSafetyPolicy

    private var activeScanTask: Task<Void, Never>?

    public init(
        scanner: StorageExplorerScanner = StorageExplorerScanner(),
        safetyPolicy: StorageExplorerSafetyPolicy = StorageExplorerSafetyPolicy()
    ) {
        self.scanner = scanner
        self.safetyPolicy = safetyPolicy
    }

    public func startScan(at url: URL) {
        cancelScan()
        scanRootURL = url
        basket.removeAll()
        searchQuery = ""
        lastErrorMessage = nil
        lastSuccessMessage = nil
        scanState = .scanning(StorageExplorerScanProgress(currentPath: url.path))

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.scanner.scan(rootURL: url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .scanning = self.scanState {
                            self.scanState = .scanning(progress)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self.rootItem = result
                self.currentDirectory = result
                self.navigationStack = [result]
                self.scanState = .completed
            } catch is CancellationError {
                self.scanState = .cancelled
            } catch {
                self.scanState = .failed(error.localizedDescription)
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    public func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        if case .scanning = scanState {
            scanState = .cancelled
        }
    }

    public func selectFolderAndScan() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择要分析的文件夹"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()

        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            startScan(at: selectedURL)
        }
    }

    public func scanHomeFolder() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        startScan(at: homeURL)
    }

    public func drillDown(to item: StorageItem) {
        guard item.isDirectory && !item.isPackage else { return }
        navigationStack.append(item)
        currentDirectory = item
    }

    public func navigateUp() {
        guard navigationStack.count > 1 else { return }
        navigationStack.removeLast()
        currentDirectory = navigationStack.last
    }

    public func navigateToBreadcrumb(at index: Int) {
        guard index >= 0 && index < navigationStack.count else { return }
        navigationStack = Array(navigationStack.prefix(index + 1))
        currentDirectory = navigationStack.last
    }

    public func toggleSelection(path: String) {
        if basket.contains(path) {
            basket.remove(path)
        } else {
            basket.insert(path)
        }
    }

    public func selectAllVisible(items: [StorageItem]) {
        for item in items {
            basket.insert(item.path)
        }
    }

    public func clearSelection() {
        basket.removeAll()
    }

    public func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public var selectedItemsForReview: [StorageItem] {
        guard let current = currentDirectory else { return [] }
        return current.children.filter { basket.contains($0.path) }
    }

    public var totalSelectedBytes: Int64 {
        selectedItemsForReview.reduce(0) { $0 + $1.size }
    }

    public func confirmTrash() {
        guard !basket.isEmpty else { return }
        isConfirmingTrash = true
    }

    public func executeTrash() async {
        guard let rootURL = scanRootURL, !basket.isEmpty else {
            isConfirmingTrash = false
            return
        }

        isExecutingTrash = true
        defer {
            isExecutingTrash = false
            isConfirmingTrash = false
        }

        let pathsToTrash = Array(basket)
        let rootPath = rootURL.path

        do {
            _ = try await safetyPolicy.recycleItems(at: pathsToTrash, withinRoot: rootPath)

            // Update in-memory tree
            if let root = rootItem {
                let updatedRoot = Self.pruneItems(from: root, targetPaths: Set(pathsToTrash))
                self.rootItem = updatedRoot

                // Re-sync navigation stack
                var updatedStack: [StorageItem] = []
                for segment in navigationStack {
                    if let found = Self.findNode(in: updatedRoot, matchingPath: segment.path) {
                        updatedStack.append(found)
                    } else {
                        break
                    }
                }

                if updatedStack.isEmpty {
                    self.navigationStack = [updatedRoot]
                    self.currentDirectory = updatedRoot
                } else {
                    self.navigationStack = updatedStack
                    self.currentDirectory = updatedStack.last
                }
            }

            basket.removeAll()
            lastSuccessMessage = "已成功移至废纸篓"
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Tree Pruning Helpers

    private static func pruneItems(from root: StorageItem, targetPaths: Set<String>) -> StorageItem {
        var newChildren: [StorageItem] = []
        var totalSize: Int64 = 0
        var totalAllocated: Int64 = 0

        for child in root.children {
            if targetPaths.contains(child.path) {
                continue
            }
            if child.isDirectory && !child.isPackage {
                let prunedChild = pruneItems(from: child, targetPaths: targetPaths)
                newChildren.append(prunedChild)
                totalSize += prunedChild.size
                totalAllocated += prunedChild.allocatedSize
            } else {
                newChildren.append(child)
                totalSize += child.size
                totalAllocated += child.allocatedSize
            }
        }

        var copy = root
        copy.children = newChildren.sorted { $0.size > $1.size }
        copy.size = totalSize
        copy.allocatedSize = totalAllocated
        copy.childCount = newChildren.count
        return copy
    }

    private static func findNode(in root: StorageItem, matchingPath: String) -> StorageItem? {
        if root.path == matchingPath {
            return root
        }
        for child in root.children {
            if child.path == matchingPath {
                return child
            }
            if child.isDirectory, let match = findNode(in: child, matchingPath: matchingPath) {
                return match
            }
        }
        return nil
    }
}
