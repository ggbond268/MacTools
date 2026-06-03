import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class IPOverviewViewModel: ObservableObject {
    @Published private(set) var snapshot: IPOverviewSnapshot = .empty {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var connectivityResults: [IPOverviewConnectivityResult] = [] {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isCheckingConnectivity = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var webRTCResults: [IPOverviewLeakTestResult] = [] {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var dnsLeakResults: [IPOverviewLeakTestResult] = [] {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isCheckingWebRTC = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isCheckingDNSLeak = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isShowingDetails = false {
        didSet {
            onSnapshotChange?()
        }
    }
    private let provider: any IPOverviewProviding
    private let connectivityChecker: any IPOverviewConnectivityChecking
    private let leakTester: any IPOverviewLeakTesting
    private let storage: PluginStorage
    private var refreshTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private var webRTCTask: Task<Void, Never>?
    private var dnsLeakTask: Task<Void, Never>?
    var onSnapshotChange: (() -> Void)?

    var isRefreshingAll: Bool {
        snapshot.isRefreshing || isCheckingConnectivity || isCheckingWebRTC || isCheckingDNSLeak
    }

    init(
        provider: any IPOverviewProviding = IPOverviewService(),
        connectivityChecker: any IPOverviewConnectivityChecking = IPOverviewConnectivityService(),
        leakTester: any IPOverviewLeakTesting = IPOverviewLeakTestService(),
        storage: PluginStorage = UserDefaultsPluginStorage(pluginID: "ip-overview")
    ) {
        self.provider = provider
        self.connectivityChecker = connectivityChecker
        self.leakTester = leakTester
        self.storage = storage
        self.connectivityResults = Self.loadConnectivityTargets(storage: storage).map {
            IPOverviewConnectivityResult(id: $0.id, target: $0, status: .waiting)
        }
        self.webRTCResults = IPOverviewWebRTCTarget.defaults.map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .waiting)
        }
        self.dnsLeakResults = (1...4).map {
            IPOverviewLeakTestResult(id: "dns-\($0)", name: "DNS 出口检测 #\($0)", status: .waiting)
        }
    }

    deinit {
        refreshTask?.cancel()
        connectivityTask?.cancel()
        webRTCTask?.cancel()
        dnsLeakTask?.cancel()
    }

    func refreshIfNeeded() {
        guard snapshot.lastUpdated == nil else {
            return
        }

        refresh()
    }

    func refresh() {
        guard refreshTask == nil else {
            return
        }

        snapshot.isRefreshing = true
        snapshot.errorMessage = nil
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nextSnapshot = await provider.collectSnapshot()
            defer { refreshTask = nil }
            guard !Task.isCancelled else { return }
            snapshot = nextSnapshot
        }
    }

    func refreshAll() {
        refresh()
        checkConnectivity()
        checkWebRTCLeak()
        checkDNSLeak()
    }

    func showDetails() {
        isShowingDetails = true
        checkDiagnosticsIfNeeded()
    }

    func showSummary() {
        isShowingDetails = false
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        snapshot.isRefreshing = false
        connectivityTask?.cancel()
        connectivityTask = nil
        isCheckingConnectivity = false
        webRTCTask?.cancel()
        webRTCTask = nil
        isCheckingWebRTC = false
        dnsLeakTask?.cancel()
        dnsLeakTask = nil
        isCheckingDNSLeak = false
    }

    func copy(_ value: String?) {
        guard let value, !value.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func checkConnectivity() {
        guard connectivityTask == nil else {
            return
        }

        isCheckingConnectivity = true
        connectivityResults = connectivityResults.map {
            IPOverviewConnectivityResult(id: $0.id, target: $0.target, status: .checking)
        }

        let targets = connectivityResults.map(\.target)
        connectivityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                connectivityTask = nil
                isCheckingConnectivity = false
            }

            for target in targets {
                guard !Task.isCancelled else { return }
                let result = await connectivityChecker.check(target: target)
                // 就地合并到当前发布数组，而不是从过期快照整体重建：
                // 检测期间（最长十几秒）用户增删目标不会被覆盖——新增的不丢、删除的不复活。
                if let index = connectivityResults.firstIndex(where: { $0.id == result.id }) {
                    connectivityResults[index] = result
                }
            }
        }
    }

    func addConnectivityTarget(name: String, urlString: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURLString = Self.normalizedURLString(urlString)
        guard !trimmedName.isEmpty else {
            return "请输入名称"
        }
        guard let normalizedURLString, URL(string: normalizedURLString) != nil else {
            return "请输入有效 URL"
        }

        let target = IPOverviewConnectivityTarget(
            id: "custom-\(UUID().uuidString)",
            name: trimmedName,
            urlString: normalizedURLString,
            isCustom: true
        )
        let targets = connectivityResults.map(\.target) + [target]
        saveConnectivityTargets(targets)
        connectivityResults.append(IPOverviewConnectivityResult(
            id: target.id,
            target: target,
            status: .waiting
        ))
        return nil
    }

    func removeConnectivityTarget(id: String) {
        guard connectivityResults.contains(where: { $0.id == id && $0.target.isCustom }) else {
            return
        }

        let targets = connectivityResults
            .map(\.target)
            .filter { $0.id != id }
        saveConnectivityTargets(targets)
        connectivityResults.removeAll { $0.id == id }
    }

    func checkWebRTCLeak() {
        guard webRTCTask == nil else {
            return
        }

        isCheckingWebRTC = true
        let targets = IPOverviewWebRTCTarget.defaults
        webRTCResults = targets.map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .checking)
        }

        webRTCTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                webRTCTask = nil
                isCheckingWebRTC = false
            }

            var nextResults: [IPOverviewLeakTestResult] = []
            for target in targets {
                guard !Task.isCancelled else { return }
                let result = await leakTester.checkWebRTC(target: target)
                nextResults.append(result)
                webRTCResults = targets.map { candidate in
                    nextResults.first(where: { $0.id == candidate.id })
                        ?? IPOverviewLeakTestResult(id: candidate.id, name: candidate.name, status: .checking)
                }
            }
        }
    }

    func checkDNSLeak() {
        guard dnsLeakTask == nil else {
            return
        }

        isCheckingDNSLeak = true
        let probes = (1...4).map { (id: "dns-\($0)", name: "DNS 出口检测 #\($0)") }
        dnsLeakResults = probes.map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .checking)
        }

        dnsLeakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                dnsLeakTask = nil
                isCheckingDNSLeak = false
            }

            var nextResults: [IPOverviewLeakTestResult] = []
            for probe in probes {
                guard !Task.isCancelled else { return }
                let result = await leakTester.checkDNS(id: probe.id, name: probe.name)
                nextResults.append(result)
                dnsLeakResults = probes.map { candidate in
                    nextResults.first(where: { $0.id == candidate.id })
                        ?? IPOverviewLeakTestResult(id: candidate.id, name: candidate.name, status: .checking)
                }
            }
        }
    }

    func checkDiagnosticsIfNeeded() {
        if connectivityResults.contains(where: { $0.status == .waiting }) {
            checkConnectivity()
        }

        if webRTCResults.contains(where: { $0.status == .waiting }) {
            checkWebRTCLeak()
        }

        if dnsLeakResults.contains(where: { $0.status == .waiting }) {
            checkDNSLeak()
        }
    }

    private func saveConnectivityTargets(_ targets: [IPOverviewConnectivityTarget]) {
        guard let data = try? JSONEncoder().encode(targets.filter(\.isCustom)) else {
            return
        }

        storage.set(data, forKey: "customConnectivityTargets")
    }

    private static func loadConnectivityTargets(storage: PluginStorage) -> [IPOverviewConnectivityTarget] {
        guard
            let data = storage.data(forKey: "customConnectivityTargets"),
            let customTargets = try? JSONDecoder().decode([IPOverviewConnectivityTarget].self, from: data)
        else {
            return IPOverviewConnectivityTarget.defaults
        }

        return IPOverviewConnectivityTarget.defaults + customTargets
    }

    private static func normalizedURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }

        return "https://\(trimmed)"
    }
}
