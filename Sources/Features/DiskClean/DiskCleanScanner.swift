import Foundation

typealias DiskCleanScanProgressHandler = @Sendable (DiskCleanScanLogMessage) async -> Void

protocol DiskCleanScanning: Sendable {
    func scan(
        choices: Set<DiskCleanChoice>,
        progress: DiskCleanScanProgressHandler
    ) async throws -> DiskCleanScanResult
}

extension DiskCleanScanning {
    func scan(choices: Set<DiskCleanChoice>) async throws -> DiskCleanScanResult {
        try await scan(choices: choices, progress: { _ in })
    }
}

protocol DiskCleanProcessInspecting: Sendable {
    func runningProcessName(from names: [String]) -> String?
}

struct LocalDiskCleanProcessInspector: DiskCleanProcessInspecting {
    func runningProcessName(from names: [String]) -> String? {
        for name in names where isProcessRunning(name) {
            return name
        }
        return nil
    }

    private func isProcessRunning(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

struct DiskCleanScanner: DiskCleanScanning {
    private struct ExpandedItem {
        let rule: DiskCleanRule
        let item: DiskCleanFileItem
    }

    let ruleCatalog: DiskCleanRuleCatalog
    let fileSystem: DiskCleanFileSystemProviding
    let safetyPolicy: DiskCleanSafetyPolicy
    let processInspector: DiskCleanProcessInspecting
    let now: @Sendable () -> Date

    init(
        ruleCatalog: DiskCleanRuleCatalog = .moleFirstVersion,
        fileSystem: DiskCleanFileSystemProviding = LocalDiskCleanFileSystem(),
        safetyPolicy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy(),
        processInspector: DiskCleanProcessInspecting = LocalDiskCleanProcessInspector(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.ruleCatalog = ruleCatalog
        self.fileSystem = fileSystem
        self.safetyPolicy = safetyPolicy
        self.processInspector = processInspector
        self.now = now
    }

    func scan(
        choices: Set<DiskCleanChoice>,
        progress: DiskCleanScanProgressHandler
    ) async throws -> DiskCleanScanResult {
        var expandedItems: [ExpandedItem] = []
        var currentChoice: DiskCleanChoice?

        for rule in ruleCatalog.rules where choices.contains(rule.choice) {
            try Task.checkCancellation()

            if currentChoice != rule.choice {
                currentChoice = rule.choice
                await progress(
                    DiskCleanScanLogMessage(
                        text: "扫描范围：\(rule.choice.title)",
                        tone: .info
                    )
                )
            }

            await progress(
                DiskCleanScanLogMessage(
                    text: "展开规则：\(rule.title)",
                    tone: .info
                )
            )

            for target in rule.targets {
                try Task.checkCancellation()
                let items = try expand(target)
                await progress(
                    DiskCleanScanLogMessage(
                        text: "匹配 \(items.count) 项：\(rule.title)",
                        tone: items.isEmpty ? .info : .success
                    )
                )
                expandedItems += items.map { ExpandedItem(rule: rule, item: $0) }
            }
        }

        let firstItemByPath = Dictionary(
            expandedItems.map { ($0.item.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let deduplicatedPaths = fileSystem.deduplicatedParentChildPaths(expandedItems.map(\.item.path))
        var candidates: [DiskCleanCandidate] = []
        for path in deduplicatedPaths {
            try Task.checkCancellation()
            guard let expandedItem = firstItemByPath[path] else {
                continue
            }
            let candidate = makeCandidate(from: expandedItem)
            candidates.append(candidate)
            await progress(logMessage(for: candidate))
        }

        await progress(
            DiskCleanScanLogMessage(
                text: "扫描完成：\(candidates.count) 项，\(candidates.filter { $0.safety.isCleanable }.count) 项可清理",
                tone: .success
            )
        )

        return DiskCleanScanResult(
            choices: choices,
            candidates: candidates,
            scannedAt: now()
        )
    }

    private func expand(_ target: DiskCleanRule.Target) throws -> [DiskCleanFileItem] {
        switch target {
        case let .path(pattern):
            return try fileSystem.expandPathPattern(pattern)
        case let .dynamic(dynamicRule):
            return try expand(dynamicRule)
        }
    }

    private func expand(_ dynamicRule: DiskCleanDynamicRule) throws -> [DiskCleanFileItem] {
        var items: [DiskCleanFileItem] = []
        for pattern in staticFallbackPatterns(for: dynamicRule) {
            items += try fileSystem.expandPathPattern(pattern)
        }
        return items
    }

    private func staticFallbackPatterns(for dynamicRule: DiskCleanDynamicRule) -> [String] {
        switch dynamicRule {
        case .xcodeDerivedData:
            return ["~/Library/Developer/Xcode/DerivedData/*"]
        case .unavailableSimulators:
            return []
        case .npmCache:
            return [
                "~/.npm/_cacache/*",
                "~/.npm/_npx/*",
                "~/.npm/_logs/*",
                "~/.npm/_prebuilds/*"
            ]
        case .pnpmStore:
            return ["~/Library/pnpm/store/*"]
        case .bunCache:
            return ["~/.bun/install/cache/*"]
        case .pipCache:
            return [
                "~/Library/Caches/pip/*",
                "~/.cache/pip/*"
            ]
        case .goBuildCache:
            return [
                "~/Library/Caches/go-build/*",
                "~/.cache/go-build/*"
            ]
        case .goModuleCache:
            return ["~/go/pkg/mod/*"]
        case .miseCache:
            return ["~/Library/Caches/mise/*"]
        case .jetbrainsToolboxOldVersions:
            return []
        case .aiAgentOldVersions:
            return []
        case .serviceWorkerCache:
            return [
                "~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Arc/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Vivaldi/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Code/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Cursor/Service Worker/CacheStorage/*/*"
            ]
        case .oldBrowserVersions:
            return []
        }
    }

    private func makeCandidate(from expandedItem: ExpandedItem) -> DiskCleanCandidate {
        let rule = expandedItem.rule
        let item = expandedItem.item
        let safety = safetyStatus(for: rule, item: item)
        let size = (try? fileSystem.sizeOfItem(at: item.path)) ?? 0

        return DiskCleanCandidate(
            id: "\(rule.id)::\(item.path)",
            ruleID: rule.id,
            choice: rule.choice,
            title: rule.title,
            path: item.path,
            sizeBytes: size,
            safety: safety,
            risk: rule.risk
        )
    }

    private func logMessage(for candidate: DiskCleanCandidate) -> DiskCleanScanLogMessage {
        switch candidate.safety {
        case .allowed:
            return DiskCleanScanLogMessage(text: "可清理：\(candidate.path)", tone: .success)
        case .whitelisted:
            return DiskCleanScanLogMessage(text: "白名单保护：\(candidate.path)", tone: .warning)
        case .protected:
            return DiskCleanScanLogMessage(text: "敏感数据保护：\(candidate.path)", tone: .warning)
        case .invalid:
            return DiskCleanScanLogMessage(text: "路径安全保护：\(candidate.path)", tone: .warning)
        case .requiresAdmin:
            return DiskCleanScanLogMessage(text: "需要管理员权限：\(candidate.path)", tone: .warning)
        case let .inUse(processName):
            return DiskCleanScanLogMessage(text: "正在使用(\(processName))：\(candidate.path)", tone: .warning)
        }
    }

    private func safetyStatus(
        for rule: DiskCleanRule,
        item: DiskCleanFileItem
    ) -> DiskCleanSafetyStatus {
        if let processName = processInspector.runningProcessName(from: rule.skipWhenProcessIsRunning) {
            return .inUse(processName: processName)
        }

        if rule.requiresAdmin {
            return .requiresAdmin(reason: "admin privileges required")
        }

        return safetyPolicy.safetyStatus(
            for: item.path,
            isSymlink: item.isSymlink,
            resolvedSymlinkTarget: item.resolvedSymlinkTarget
        )
    }
}
