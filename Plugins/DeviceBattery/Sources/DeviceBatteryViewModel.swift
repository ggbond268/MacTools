import Combine
import Foundation

@MainActor
final class DeviceBatteryViewModel: ObservableObject {
    @Published private(set) var snapshot: DeviceBatterySnapshot = .idle {
        didSet {
            guard oldValue != snapshot else {
                return
            }
            onSnapshotChange?()
        }
    }

    private let sampler: any DeviceBatterySampling
    private let rapooMonitor: any RapooBatteryMonitoring
    private var samplingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var systemItems: [DeviceBatteryItem] = []
    private var rapooSnapshot = RapooMouseBatterySnapshot.idle
    private var lastSystemUpdate: Date?
    private var isStarted = false
    private var includeInternalBattery = true
    private var includeBluetoothDevices = true
    private var includeRapooDevices = true

    var onSnapshotChange: (() -> Void)?

    convenience init() {
        self.init(
            sampler: DeviceBatterySampler(),
            rapooMonitor: RapooHIDBatteryMonitor()
        )
    }

    init(
        sampler: any DeviceBatterySampling,
        rapooMonitor: any RapooBatteryMonitoring
    ) {
        self.sampler = sampler
        self.rapooMonitor = rapooMonitor
        rapooSnapshot = rapooMonitor.snapshot
    }

    func start(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeRapooDevices: Bool
    ) {
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeRapooDevices: includeRapooDevices
        )

        if isStarted {
            collectNow()
            return
        }

        isStarted = true
        rapooMonitor.onSnapshotChange = { [weak self] snapshot in
            self?.rapooSnapshot = snapshot
            self?.rebuildSnapshot()
        }

        if includeRapooDevices {
            rapooMonitor.start()
            rapooSnapshot = rapooMonitor.snapshot
        }

        samplingTask = Task { @MainActor [weak self] in
            await self?.runSamplingLoop()
        }
    }

    func stop() {
        samplingTask?.cancel()
        refreshTask?.cancel()
        samplingTask = nil
        refreshTask = nil
        rapooMonitor.stop()
        rapooMonitor.onSnapshotChange = nil
        isStarted = false
    }

    func refresh(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeRapooDevices: Bool
    ) {
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeRapooDevices: includeRapooDevices
        )

        if includeRapooDevices {
            rapooMonitor.refresh()
            rapooSnapshot = rapooMonitor.snapshot
        } else {
            rapooMonitor.stop()
            rapooSnapshot = .idle
        }

        collectNow()
    }

    private func updateOptions(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeRapooDevices: Bool
    ) {
        self.includeInternalBattery = includeInternalBattery
        self.includeBluetoothDevices = includeBluetoothDevices
        self.includeRapooDevices = includeRapooDevices
    }

    private func collectNow() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.collectOnce()
        }
    }

    private func runSamplingLoop() async {
        while !Task.isCancelled {
            await collectOnce()

            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
        }
    }

    private func collectOnce() async {
        rebuildSnapshot(accessOverride: .scanning)

        let referenceDate = Date()
        let collectedItems = await sampler.collectSystemDevices(referenceDate: referenceDate)
        // collectSystemDevices 会跑 system_profiler 子进程（~1s+）。期间面板可能被关闭
        // （onDisappear -> stop()）；普通 await 不会因取消提前返回，续体仍会写入陈旧快照。
        guard !Task.isCancelled, isStarted else { return }
        systemItems = collectedItems
        lastSystemUpdate = referenceDate
        rebuildSnapshot()
    }

    private func rebuildSnapshot(
        accessOverride: DeviceBatteryAccessState? = nil
    ) {
        var items = systemItems.filter { item in
            switch item.kind {
            case .internalBattery:
                return includeInternalBattery
            case .bluetooth, .magicAccessory, .airPodsPart, .other:
                return includeBluetoothDevices
            case .rapooMouse:
                return includeRapooDevices
            }
        }

        if includeRapooDevices, let rapooItem = rapooSnapshot.batteryItem {
            items.append(rapooItem)
        }

        let accessState = accessOverride ?? resolvedAccessState(items: items)
        snapshot = DeviceBatterySnapshot(
            accessState: accessState,
            items: deduplicated(items),
            lastUpdated: lastSystemUpdate ?? rapooSnapshot.lastUpdated,
            rapooState: includeRapooDevices ? rapooSnapshot.accessState : .idle
        )
    }

    private func resolvedAccessState(items: [DeviceBatteryItem]) -> DeviceBatteryAccessState {
        if rapooSnapshot.accessState == .permissionDenied {
            return items.isEmpty ? .permissionDenied : .ready
        }

        if case let .failed(message) = rapooSnapshot.accessState, items.isEmpty {
            return .failed(message)
        }

        return items.isEmpty ? .noDevices : .ready
    }

    private func deduplicated(_ items: [DeviceBatteryItem]) -> [DeviceBatteryItem] {
        var seen: Set<String> = []
        return items.filter { item in
            let key = "\(item.kind.title)-\(item.name.lowercased())-\(item.parentName ?? "")"
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }
}
