import Combine
import Foundation
import MacToolsPluginKit

struct DeviceBatterySamplingSchedule: Equatable, Sendable {
    let internalBatteryFallback: TimeInterval
    let bluetoothBackground: TimeInterval
    let bluetoothComponentVisible: TimeInterval
    let appleMobileBackground: TimeInterval
    let appleMobileComponentVisible: TimeInterval
    let bluetoothConnectionDebounce: TimeInterval
    let activityResumeDelay: TimeInterval

    static let standard = DeviceBatterySamplingSchedule(
        internalBatteryFallback: 5 * 60,
        bluetoothBackground: 5 * 60,
        bluetoothComponentVisible: 60,
        appleMobileBackground: 5 * 60,
        appleMobileComponentVisible: 90,
        bluetoothConnectionDebounce: 2.5,
        activityResumeDelay: 2
    )
}

@MainActor
final class DeviceBatteryViewModel: ObservableObject {
    private static let appleMobileVisibleRevalidationInterval: TimeInterval = 15

    @Published private(set) var snapshot: DeviceBatterySnapshot = .idle {
        didSet {
            guard oldValue != snapshot else { return }
            onSnapshotChange?()
        }
    }

    private let sampler: any DeviceBatterySampling
    private let vendorHIDMonitor: any VendorHIDBatteryMonitoring
    private let powerSourceObserver: any DeviceBatteryPowerSourceObserving
    private let bluetoothConnectionObserver: any DeviceBatteryBluetoothConnectionObserving
    private let localization: PluginLocalization
    private let schedule: DeviceBatterySamplingSchedule

    private var internalBatteryTask: Task<Void, Never>?
    private var bluetoothTask: Task<Void, Never>?
    private var appleMobileTask: Task<Void, Never>?
    private var bluetoothEventTask: Task<Void, Never>?
    private var activityResumeTask: Task<Void, Never>?
    private var pendingVisibleBluetoothRefresh = false
    private var pendingVisibleAppleMobileRefresh = false
    private var activeCollectionIDs: Set<UUID> = []
    private var collectionSourcesByID: [UUID: DeviceBatterySource] = [:]

    private var internalBatteryItems: [DeviceBatteryItem] = []
    private var bluetoothItems: [DeviceBatteryItem] = []
    private var appleMobileItems: [DeviceBatteryItem] = []
    private var vendorHIDSnapshot = VendorHIDMouseBatterySnapshot.idle
    private var vendorHIDSnapshots: [VendorHIDMouseBatterySnapshot] = []
    private var sourceUpdateDates: [DeviceBatterySource: Date] = [:]
    private var activityState: PluginApplicationActivityState = .interactive
    private var needsBluetoothRefreshOnResume = false
    private var isStarted = false
    private var includeInternalBattery = true
    private var includeBluetoothDevices = true
    private var includeAppleMobileDevices = true
    private var includeVendorHIDDevices = true
    private var isComponentPanelVisible = false
    private var isLowBatteryMonitoringEnabled = false

    var onSnapshotChange: (() -> Void)?

    convenience init() {
        let localization = PluginLocalization(bundle: .main)
        self.init(
            sampler: DeviceBatterySampler(localization: localization),
            vendorHIDMonitor: VendorHIDBatteryMonitor(localization: localization),
            powerSourceObserver: SystemDeviceBatteryPowerSourceObserver(),
            bluetoothConnectionObserver: SystemDeviceBatteryBluetoothConnectionObserver(),
            localization: localization
        )
    }

    init(
        sampler: any DeviceBatterySampling,
        vendorHIDMonitor: any VendorHIDBatteryMonitoring,
        powerSourceObserver: any DeviceBatteryPowerSourceObserving = NullDeviceBatteryPowerSourceObserver(),
        bluetoothConnectionObserver: any DeviceBatteryBluetoothConnectionObserving = NullDeviceBatteryBluetoothConnectionObserver(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        schedule: DeviceBatterySamplingSchedule = .standard
    ) {
        self.sampler = sampler
        self.vendorHIDMonitor = vendorHIDMonitor
        self.powerSourceObserver = powerSourceObserver
        self.bluetoothConnectionObserver = bluetoothConnectionObserver
        self.localization = localization
        self.schedule = schedule
        vendorHIDSnapshot = vendorHIDMonitor.snapshot
        vendorHIDSnapshots = vendorHIDMonitor.deviceSnapshots
    }

    func start(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeVendorHIDDevices: Bool
    ) {
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeAppleMobileDevices: includeAppleMobileDevices,
            includeVendorHIDDevices: includeVendorHIDDevices
        )

        guard !isStarted else {
            reconcileSamplingDemand(forceBluetoothProfileRefresh: false)
            return
        }

        isStarted = true
        vendorHIDMonitor.onSnapshotChange = { [weak self] snapshot in
            self?.vendorHIDSnapshot = snapshot
            self?.vendorHIDSnapshots = self?.vendorHIDMonitor.deviceSnapshots ?? []
            self?.rebuildSnapshot()
        }
        powerSourceObserver.onChange = { [weak self] in
            self?.handlePowerSourceChange()
        }
        bluetoothConnectionObserver.onConnectionChange = { [weak self] in
            self?.handleBluetoothConnectionChange()
        }
        reconcileSamplingDemand(forceBluetoothProfileRefresh: true)
    }

    func stop() {
        cancelSampling()
        powerSourceObserver.stop()
        bluetoothConnectionObserver.stop()
        powerSourceObserver.onChange = nil
        bluetoothConnectionObserver.onConnectionChange = nil
        vendorHIDMonitor.stop()
        vendorHIDMonitor.onSnapshotChange = nil
        isComponentPanelVisible = false
        isStarted = false
        clearCollectedSnapshots()
    }

    func refresh(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeVendorHIDDevices: Bool
    ) {
        let wasIncludingBluetoothDevices = self.includeBluetoothDevices
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeAppleMobileDevices: includeAppleMobileDevices,
            includeVendorHIDDevices: includeVendorHIDDevices
        )
        rebuildSnapshot()

        reconcileSamplingDemand(
            forceBluetoothProfileRefresh: includeBluetoothDevices && !wasIncludingBluetoothDevices
        )
    }

    func updateSources(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeVendorHIDDevices: Bool
    ) {
        let previousInternalBattery = self.includeInternalBattery
        let previousBluetoothDevices = self.includeBluetoothDevices
        let previousAppleMobileDevices = self.includeAppleMobileDevices
        let previousVendorHIDDevices = self.includeVendorHIDDevices
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeAppleMobileDevices: includeAppleMobileDevices,
            includeVendorHIDDevices: includeVendorHIDDevices
        )
        rebuildSnapshot()

        guard isStarted,
              activityState.allowsBackgroundWork,
              hasSamplingDemand else {
            return
        }
        guard activityResumeTask == nil else { return }

        if previousInternalBattery != includeInternalBattery {
            if includeInternalBattery {
                powerSourceObserver.start()
                restartInternalBatterySampling()
            } else {
                powerSourceObserver.stop()
                internalBatteryTask?.cancel()
                internalBatteryTask = nil
                discardCollections(for: .internalBattery)
            }
        }

        if previousBluetoothDevices != includeBluetoothDevices {
            if includeBluetoothDevices {
                bluetoothConnectionObserver.start()
                restartBluetoothSampling(
                    forceProfileRefresh: true,
                    performActiveScan: true,
                    revalidateSupplementalState: isComponentPanelVisible
                )
            } else {
                bluetoothConnectionObserver.stop()
                bluetoothTask?.cancel()
                bluetoothTask = nil
                bluetoothEventTask?.cancel()
                bluetoothEventTask = nil
                discardCollections(for: .bluetooth)
                pendingVisibleBluetoothRefresh = false
            }
        }

        if previousAppleMobileDevices != includeAppleMobileDevices {
            if includeAppleMobileDevices {
                restartAppleMobileSampling(
                    revalidateImmediately: isComponentPanelVisible
                )
            } else {
                appleMobileTask?.cancel()
                appleMobileTask = nil
                discardCollections(for: .appleMobile)
                pendingVisibleAppleMobileRefresh = false
            }
        }

        if previousVendorHIDDevices != includeVendorHIDDevices {
            reconcileVendorHIDMonitoring()
        }
    }

    func setComponentPanelVisible(_ isVisible: Bool) {
        guard isComponentPanelVisible != isVisible else { return }
        let hadSamplingDemand = hasSamplingDemand
        isComponentPanelVisible = isVisible
        let hasCurrentSamplingDemand = hasSamplingDemand

        guard hadSamplingDemand == hasCurrentSamplingDemand else {
            reconcileSamplingDemand(
                forceBluetoothProfileRefresh: isVisible && !hadSamplingDemand
            )
            return
        }
        guard isStarted, activityState.allowsBackgroundWork else { return }

        if isVisible {
            refreshVisibleSources()
        } else {
            pendingVisibleBluetoothRefresh = false
            pendingVisibleAppleMobileRefresh = false
            rescheduleBackgroundPolling()
        }
    }

    func setLowBatteryMonitoringEnabled(_ isEnabled: Bool) {
        guard isLowBatteryMonitoringEnabled != isEnabled else { return }
        let hadSamplingDemand = hasSamplingDemand
        isLowBatteryMonitoringEnabled = isEnabled
        guard hadSamplingDemand != hasSamplingDemand else { return }
        reconcileSamplingDemand(
            forceBluetoothProfileRefresh: isEnabled && !hadSamplingDemand
        )
    }

    func setApplicationActivityState(_ state: PluginApplicationActivityState) {
        guard activityState != state else { return }
        let previouslyAllowedBackgroundWork = activityState.allowsBackgroundWork
        activityState = state

        guard isStarted else { return }
        guard state.allowsBackgroundWork else {
            needsBluetoothRefreshOnResume = true
            activityResumeTask?.cancel()
            activityResumeTask = nil
            cancelSampling()
            powerSourceObserver.stop()
            bluetoothConnectionObserver.stop()
            vendorHIDMonitor.stop()
            return
        }

        guard !previouslyAllowedBackgroundWork else { return }
        guard hasSamplingDemand else { return }
        activityResumeTask?.cancel()
        activityResumeTask = Task { @MainActor [weak self, schedule] in
            do {
                try await Self.sleep(for: schedule.activityResumeDelay)
            } catch {
                return
            }

            guard let self,
                  self.isStarted,
                  self.activityState.allowsBackgroundWork else {
                return
            }
            self.activityResumeTask = nil
            self.reconcileSamplingDemand(
                forceBluetoothProfileRefresh: self.needsBluetoothRefreshOnResume
            )
            self.needsBluetoothRefreshOnResume = false
        }
    }

    var appleMobileRefreshInterval: TimeInterval {
        isComponentPanelVisible
            ? schedule.appleMobileComponentVisible
            : schedule.appleMobileBackground
    }

    var bluetoothRefreshInterval: TimeInterval {
        isComponentPanelVisible
            ? schedule.bluetoothComponentVisible
            : schedule.bluetoothBackground
    }

    private func updateOptions(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeVendorHIDDevices: Bool
    ) {
        self.includeInternalBattery = includeInternalBattery
        self.includeBluetoothDevices = includeBluetoothDevices
        self.includeAppleMobileDevices = includeAppleMobileDevices
        self.includeVendorHIDDevices = includeVendorHIDDevices

        if !includeInternalBattery {
            internalBatteryItems.removeAll()
            sourceUpdateDates.removeValue(forKey: .internalBattery)
        }
        if !includeBluetoothDevices {
            bluetoothItems.removeAll()
            sourceUpdateDates.removeValue(forKey: .bluetooth)
        }
        if !includeAppleMobileDevices {
            appleMobileItems.removeAll()
            sourceUpdateDates.removeValue(forKey: .appleMobile)
        }
        if !includeVendorHIDDevices {
            vendorHIDSnapshot = .idle
            vendorHIDSnapshots.removeAll()
        }
    }

    private func restartSampling(forceBluetoothProfileRefresh: Bool) {
        guard isStarted,
              activityState.allowsBackgroundWork,
              hasSamplingDemand else {
            return
        }
        restartInternalBatterySampling()
        restartBluetoothSampling(
            forceProfileRefresh: forceBluetoothProfileRefresh,
            performActiveScan: true,
            revalidateSupplementalState: isComponentPanelVisible
        )
        restartAppleMobileSampling(revalidateImmediately: isComponentPanelVisible)
    }

    private func restartInternalBatterySampling() {
        internalBatteryTask?.cancel()
        internalBatteryTask = nil
        guard includeInternalBattery else { return }

        internalBatteryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runInternalBatteryLoop()
        }
    }

    private func restartBluetoothSampling(
        forceProfileRefresh: Bool,
        performActiveScan: Bool,
        revalidateSupplementalState: Bool = false,
        initialDelay: TimeInterval = 0
    ) {
        bluetoothTask?.cancel()
        bluetoothTask = nil
        guard includeBluetoothDevices else { return }

        bluetoothTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runBluetoothLoop(
                forceProfileRefresh: forceProfileRefresh,
                performInitialActiveScan: performActiveScan,
                revalidateInitialSupplementalState: revalidateSupplementalState,
                initialDelay: initialDelay
            )
        }
    }

    private func restartAppleMobileSampling(
        revalidateImmediately: Bool = false,
        initialDelay: TimeInterval = 0
    ) {
        appleMobileTask?.cancel()
        appleMobileTask = nil
        guard includeAppleMobileDevices else { return }

        appleMobileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runAppleMobileLoop(
                revalidateImmediately: revalidateImmediately,
                initialDelay: initialDelay
            )
        }
    }

    private func runInternalBatteryLoop() async {
        while !Task.isCancelled {
            await refreshInternalBattery()
            do {
                try await Self.sleep(for: schedule.internalBatteryFallback)
            } catch {
                return
            }
        }
    }

    private func runBluetoothLoop(
        forceProfileRefresh: Bool,
        performInitialActiveScan: Bool,
        revalidateInitialSupplementalState: Bool,
        initialDelay: TimeInterval = 0
    ) async {
        if initialDelay > 0 {
            do {
                try await Self.sleep(for: initialDelay)
            } catch {
                return
            }
        }

        var shouldForceProfileRefresh = forceProfileRefresh
        var shouldPerformActiveScan = performInitialActiveScan
        var shouldRevalidateSupplementalState = revalidateInitialSupplementalState

        while !Task.isCancelled {
            await refreshBluetooth(
                forceProfileRefresh: shouldForceProfileRefresh,
                performActiveScan: shouldPerformActiveScan,
                revalidateSupplementalState: shouldRevalidateSupplementalState
            )
            if pendingVisibleBluetoothRefresh,
               isComponentPanelVisible,
               includeBluetoothDevices {
                pendingVisibleBluetoothRefresh = false
                shouldForceProfileRefresh = false
                shouldPerformActiveScan = false
                shouldRevalidateSupplementalState = true
                continue
            }
            shouldForceProfileRefresh = false
            shouldPerformActiveScan = true
            shouldRevalidateSupplementalState = false

            do {
                try await Self.sleep(for: bluetoothRefreshInterval)
            } catch {
                return
            }
        }
    }

    private func runAppleMobileLoop(
        revalidateImmediately: Bool,
        initialDelay: TimeInterval = 0
    ) async {
        if initialDelay > 0 {
            do {
                try await Self.sleep(for: initialDelay)
            } catch {
                return
            }
        }

        var minimumRefreshInterval = revalidateImmediately
            ? Self.appleMobileVisibleRevalidationInterval
            : appleMobileRefreshInterval
        while !Task.isCancelled {
            await refreshAppleMobileDevices(
                minimumRefreshInterval: minimumRefreshInterval
            )
            if pendingVisibleAppleMobileRefresh,
               isComponentPanelVisible,
               includeAppleMobileDevices {
                pendingVisibleAppleMobileRefresh = false
                minimumRefreshInterval = Self.appleMobileVisibleRevalidationInterval
                continue
            }
            minimumRefreshInterval = appleMobileRefreshInterval
            do {
                try await Self.sleep(for: appleMobileRefreshInterval)
            } catch {
                return
            }
        }
    }

    private func refreshInternalBattery() async {
        let collectionID = beginCollection(source: .internalBattery)
        defer { endCollection(collectionID) }
        let referenceDate = Date()
        let items = await sampler.collectInternalBattery(referenceDate: referenceDate)
        guard !Task.isCancelled else { return }
        internalBatteryItems = items
        sourceUpdateDates[.internalBattery] = referenceDate
        rebuildSnapshot()
    }

    private func refreshBluetooth(
        forceProfileRefresh: Bool,
        performActiveScan: Bool,
        revalidateSupplementalState: Bool
    ) async {
        let collectionID = beginCollection(source: .bluetooth)
        defer { endCollection(collectionID) }
        let referenceDate = Date()
        let items = await sampler.collectBluetoothDevices(
            referenceDate: referenceDate,
            options: DeviceBatteryBluetoothSamplingOptions(
                forceProfileRefresh: forceProfileRefresh,
                performActiveScan: performActiveScan,
                revalidateSupplementalState: revalidateSupplementalState
            )
        )
        guard !Task.isCancelled else { return }
        bluetoothItems = items
        sourceUpdateDates[.bluetooth] = referenceDate
        rebuildSnapshot()
    }

    private func refreshAppleMobileDevices(
        minimumRefreshInterval: TimeInterval
    ) async {
        let collectionID = beginCollection(source: .appleMobile)
        defer { endCollection(collectionID) }
        let referenceDate = Date()
        let items = await sampler.collectAppleMobileDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: minimumRefreshInterval
        )
        guard !Task.isCancelled else { return }
        appleMobileItems = items
        sourceUpdateDates[.appleMobile] = referenceDate
        rebuildSnapshot()
    }

    private func handlePowerSourceChange() {
        guard isStarted, includeInternalBattery else { return }
        guard activityState.allowsBackgroundWork, hasSamplingDemand else { return }
        guard activityResumeTask == nil else { return }
        restartInternalBatterySampling()
    }

    private func handleBluetoothConnectionChange() {
        guard isStarted, includeBluetoothDevices else { return }
        guard activityState.allowsBackgroundWork, hasSamplingDemand else {
            needsBluetoothRefreshOnResume = true
            return
        }
        guard activityResumeTask == nil else {
            needsBluetoothRefreshOnResume = true
            return
        }

        bluetoothEventTask?.cancel()
        bluetoothEventTask = Task { @MainActor [weak self, schedule] in
            do {
                try await Self.sleep(for: schedule.bluetoothConnectionDebounce)
            } catch {
                return
            }

            guard let self,
                  self.isStarted,
                  self.activityState.allowsBackgroundWork,
                  self.hasSamplingDemand else {
                return
            }
            self.bluetoothEventTask = nil
            self.restartBluetoothSampling(
                forceProfileRefresh: true,
                performActiveScan: true,
                revalidateSupplementalState: self.isComponentPanelVisible
            )
        }
    }

    private func reconcileVendorHIDMonitoring() {
        guard includeVendorHIDDevices,
              activityState.allowsBackgroundWork,
              hasSamplingDemand else {
            vendorHIDMonitor.stop()
            vendorHIDSnapshot = .idle
            vendorHIDSnapshots.removeAll()
            rebuildSnapshot()
            return
        }

        vendorHIDMonitor.start()
        vendorHIDSnapshot = vendorHIDMonitor.snapshot
        vendorHIDSnapshots = vendorHIDMonitor.deviceSnapshots
        rebuildSnapshot()
    }

    private func refreshVisibleSources() {
        activityResumeTask?.cancel()
        activityResumeTask = nil
        let shouldForceBluetoothProfileRefresh = needsBluetoothRefreshOnResume
        needsBluetoothRefreshOnResume = false

        if includeInternalBattery {
            powerSourceObserver.start()
            if !isCollecting(.internalBattery) {
                restartInternalBatterySampling()
            }
        }
        if includeBluetoothDevices {
            bluetoothConnectionObserver.start()
            if isCollecting(.bluetooth) {
                pendingVisibleBluetoothRefresh = true
            } else {
                restartBluetoothSampling(
                    forceProfileRefresh: shouldForceBluetoothProfileRefresh,
                    performActiveScan: true,
                    revalidateSupplementalState: true
                )
            }
        }
        if includeAppleMobileDevices {
            if isCollecting(.appleMobile) {
                pendingVisibleAppleMobileRefresh = true
            } else {
                restartAppleMobileSampling(revalidateImmediately: true)
            }
        }
        if includeVendorHIDDevices {
            vendorHIDMonitor.refresh()
            vendorHIDSnapshot = vendorHIDMonitor.snapshot
            vendorHIDSnapshots = vendorHIDMonitor.deviceSnapshots
            rebuildSnapshot()
        }
    }

    private func rescheduleBackgroundPolling(referenceDate: Date = Date()) {
        guard isLowBatteryMonitoringEnabled else { return }

        if includeBluetoothDevices, !isCollecting(.bluetooth) {
            restartBluetoothSampling(
                forceProfileRefresh: false,
                performActiveScan: true,
                initialDelay: remainingDelay(
                    since: sourceUpdateDates[.bluetooth],
                    interval: schedule.bluetoothBackground,
                    referenceDate: referenceDate
                )
            )
        }
        if includeAppleMobileDevices, !isCollecting(.appleMobile) {
            restartAppleMobileSampling(
                initialDelay: remainingDelay(
                    since: sourceUpdateDates[.appleMobile],
                    interval: schedule.appleMobileBackground,
                    referenceDate: referenceDate
                )
            )
        }
    }

    private func remainingDelay(
        since lastUpdateDate: Date?,
        interval: TimeInterval,
        referenceDate: Date
    ) -> TimeInterval {
        guard let lastUpdateDate else { return 0 }
        return max(0, interval - referenceDate.timeIntervalSince(lastUpdateDate))
    }

    private var hasSamplingDemand: Bool {
        isComponentPanelVisible || isLowBatteryMonitoringEnabled
    }

    private func reconcileSamplingDemand(forceBluetoothProfileRefresh: Bool) {
        guard isStarted else { return }
        guard activityState.allowsBackgroundWork else {
            cancelSampling()
            powerSourceObserver.stop()
            bluetoothConnectionObserver.stop()
            vendorHIDMonitor.stop()
            rebuildSnapshot()
            return
        }
        guard hasSamplingDemand else {
            cancelSampling()
            powerSourceObserver.stop()
            bluetoothConnectionObserver.stop()
            vendorHIDMonitor.stop()
            clearCollectedSnapshots()
            return
        }

        activityResumeTask?.cancel()
        activityResumeTask = nil
        let shouldForceBluetoothProfileRefresh = forceBluetoothProfileRefresh
            || needsBluetoothRefreshOnResume
        needsBluetoothRefreshOnResume = false
        if includeInternalBattery {
            powerSourceObserver.start()
        } else {
            powerSourceObserver.stop()
        }
        if includeBluetoothDevices {
            bluetoothConnectionObserver.start()
        } else {
            bluetoothConnectionObserver.stop()
        }
        reconcileVendorHIDMonitoring()
        restartSampling(
            forceBluetoothProfileRefresh: shouldForceBluetoothProfileRefresh
        )
    }

    private func cancelSampling() {
        internalBatteryTask?.cancel()
        bluetoothTask?.cancel()
        appleMobileTask?.cancel()
        bluetoothEventTask?.cancel()
        activityResumeTask?.cancel()
        internalBatteryTask = nil
        bluetoothTask = nil
        appleMobileTask = nil
        bluetoothEventTask = nil
        activityResumeTask = nil
        pendingVisibleBluetoothRefresh = false
        pendingVisibleAppleMobileRefresh = false
        activeCollectionIDs.removeAll()
        collectionSourcesByID.removeAll()
        rebuildSnapshot()
    }

    private func clearCollectedSnapshots() {
        internalBatteryItems.removeAll()
        bluetoothItems.removeAll()
        appleMobileItems.removeAll()
        vendorHIDSnapshot = .idle
        vendorHIDSnapshots.removeAll()
        sourceUpdateDates.removeAll()
        rebuildSnapshot()
    }

    private func beginCollection(source: DeviceBatterySource) -> UUID {
        let id = UUID()
        activeCollectionIDs.insert(id)
        collectionSourcesByID[id] = source
        rebuildSnapshot()
        return id
    }

    private func endCollection(_ id: UUID) {
        guard activeCollectionIDs.remove(id) != nil else { return }
        collectionSourcesByID.removeValue(forKey: id)
        rebuildSnapshot()
    }

    private func isCollecting(_ source: DeviceBatterySource) -> Bool {
        collectionSourcesByID.values.contains(source)
    }

    private func discardCollections(for source: DeviceBatterySource) {
        let collectionIDs = collectionSourcesByID.compactMap { id, collectionSource in
            collectionSource == source ? id : nil
        }
        guard !collectionIDs.isEmpty else { return }

        for id in collectionIDs {
            activeCollectionIDs.remove(id)
            collectionSourcesByID.removeValue(forKey: id)
        }
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        var items = internalBatteryItems + bluetoothItems + appleMobileItems
        items = items.filter { item in
            switch item.kind {
            case .internalBattery:
                return includeInternalBattery
            case .phone, .tablet, .mediaPlayer, .watch, .spatialComputer:
                return includeAppleMobileDevices
            case .bluetooth, .magicAccessory, .airPodsPart, .other:
                return includeBluetoothDevices
            case .vendorHIDMouse:
                return includeVendorHIDDevices
            }
        }

        if includeVendorHIDDevices {
            items.append(contentsOf: vendorHIDSnapshots.compactMap {
                $0.batteryItem(localization: localization)
            })
        }

        let accessState = items.isEmpty && !activeCollectionIDs.isEmpty
            ? DeviceBatteryAccessState.scanning
            : resolvedAccessState(items: items)
        let visibleSourceUpdateDates = [
            includeInternalBattery ? sourceUpdateDates[.internalBattery] : nil,
            includeBluetoothDevices ? sourceUpdateDates[.bluetooth] : nil,
            includeAppleMobileDevices ? sourceUpdateDates[.appleMobile] : nil,
            includeVendorHIDDevices
                ? vendorHIDSnapshots.compactMap(\.lastUpdated).max() ?? vendorHIDSnapshot.lastUpdated
                : nil
        ].compactMap { $0 }
        snapshot = DeviceBatterySnapshot(
            accessState: accessState,
            items: deduplicated(
                DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(items)
            ),
            lastUpdated: visibleSourceUpdateDates.max(),
            vendorHIDState: includeVendorHIDDevices ? vendorHIDSnapshot.accessState : .idle
        )
    }

    private func resolvedAccessState(items: [DeviceBatteryItem]) -> DeviceBatteryAccessState {
        if vendorHIDSnapshot.accessState == .permissionDenied {
            return items.isEmpty ? .permissionDenied : .ready
        }
        if case let .failed(message) = vendorHIDSnapshot.accessState, items.isEmpty {
            return .failed(message)
        }
        return items.isEmpty ? .noDevices : .ready
    }

    private func deduplicated(_ items: [DeviceBatteryItem]) -> [DeviceBatteryItem] {
        DeviceBatterySampler.deduplicated(items)
    }

    private static func sleep(for interval: TimeInterval) async throws {
        let tolerance = min(max(interval * 0.15, 0.1), 30)
        try await Task.sleep(
            for: .seconds(interval),
            tolerance: .seconds(tolerance)
        )
    }
}

private enum DeviceBatterySource: Hashable {
    case internalBattery
    case bluetooth
    case appleMobile
}

@MainActor
private final class NullDeviceBatteryPowerSourceObserver: DeviceBatteryPowerSourceObserving {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class NullDeviceBatteryBluetoothConnectionObserver:
    DeviceBatteryBluetoothConnectionObserving {
    var onConnectionChange: (() -> Void)?
    func start() {}
    func stop() {}
}
