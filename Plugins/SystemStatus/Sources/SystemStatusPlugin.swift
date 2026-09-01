import AppKit
import SwiftUI
import MacToolsPluginKit

public final class SystemStatusPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemStatusPluginProvider(context: context)
    }
}

@MainActor
private struct SystemStatusPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SystemStatusPlugin(
            storage: context.storage,
            supportDirectory: context.supportDirectory,
            localization: PluginLocalization(bundle: context.resourceBundle)
        )]
    }
}

@MainActor
final class SystemStatusPlugin:
    MacToolsPlugin,
    PluginComponentPanel,
    PluginPanelSurfaceLifecycleHandling,
    PluginSettingsPresenting,
    PluginDashboardPresenting,
    PluginComponentDetailPresenting,
    PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting,
    PluginPersistentPreferencesChangeSignaling
{
    let metadata: PluginMetadata

    var descriptor: PluginComponentDescriptor {
        PluginComponentDescriptor(
            span: PluginComponentSpan(
                width: 4,
                height: PluginComponentPanelLayoutMetrics.default.heightSpan(
                    fittingContentHeight: SystemStatusComponentLayout.contentHeight(
                        for: settingsController.configuration.visiblePanelMetricKinds
                    )
                )
            )!
        )
    }

    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    private let menuBarMetricsController: SystemStatusMenuBarMetricsController
    private let localization: PluginLocalization
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()
    private var isActivated = true

    init(
        viewModel: SystemStatusViewModel? = nil,
        settingsController: SystemStatusSettingsController? = nil,
        storage: PluginStorage? = nil,
        supportDirectory: URL? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        let resolvedViewModel = viewModel
            ?? SystemStatusViewModel(
                sampler: SystemStatusSampler(localization: localization),
                historyStore: SystemStatusHistoryStore(
                    fileURL: SystemStatusHistoryStore.defaultFileURL(supportDirectory: supportDirectory)
                )
            )
        let resolvedSettingsController = settingsController
            ?? SystemStatusSettingsController(
                store: SystemStatusPluginStorageConfigurationStore(
                    storage: storage ?? UserDefaultsPluginStorage(pluginID: "system-status")
                )
            )
        self.viewModel = resolvedViewModel
        self.settingsController = resolvedSettingsController
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "system-status",
            title: localization.string("metadata.title", defaultValue: "系统状态"),
            iconName: "gauge.with.dots.needle.67percent",
            iconTint: Color(nsColor: .systemTeal),
            order: 10,
            defaultDescription: localization.string("metadata.description", defaultValue: "实时查看系统状态")
        )
        self.menuBarMetricsController = SystemStatusMenuBarMetricsController(
            viewModel: resolvedViewModel,
            settingsController: resolvedSettingsController,
            localization: localization
        )
        resolvedSettingsController.onConfigurationChange = { [weak self] in
            self?.onStateChange?()
            self?.persistentPreferencesChanges.didPersist()
        }
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)? {
        didSet {
            menuBarMetricsController.requestConfigurationPresentation = requestSettingsPresentation
        }
    }
    var requestDashboardPresentation: (() -> Void)? {
        didSet {
            menuBarMetricsController.requestDashboardPresentation = requestDashboardPresentation
        }
    }
    var requestComponentDetailPresentation: ((String) -> Void)?
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: metadata.defaultDescription,
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "panel-metrics",
                title: localization.string("settings.panel.title", defaultValue: "组件面板"),
                systemImage: "square.grid.2x2",
                footer: localization.string(
                    "settings.panel.description",
                    defaultValue: "选择组件面板显示的内容，并拖拽调整顺序。"
                ),
                presentation: .edgeToEdge
            ) { [settingsController, viewModel, localization] _ in
                SystemStatusSettingsView(
                    controller: settingsController,
                    viewModel: viewModel,
                    localization: localization,
                    section: .panel
                )
            },
            PluginSettingsSection(
                id: "menu-bar-metrics",
                title: localization.string("settings.menuBar.title", defaultValue: "菜单栏指标"),
                systemImage: "menubar.rectangle",
                footer: localization.string(
                    "settings.menuBar.description",
                    defaultValue: "选择要显示在菜单栏里的指标。"
                ),
                presentation: .edgeToEdge
            ) { [settingsController, viewModel, localization] _ in
                SystemStatusSettingsView(
                    controller: settingsController,
                    viewModel: viewModel,
                    localization: localization,
                    section: .menuBar
                )
            }
        ])
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(
            SystemStatusComponentView(
                viewModel: viewModel,
                settingsController: settingsController,
                localization: localization,
                onMetricDetail: { [weak self] kind in
                    self?.requestComponentDetailPresentation?(kind.rawValue)
                }
            )
        )
    }

    func makeComponentDetailContent(
        detailID: String,
        dismiss: @escaping () -> Void
    ) -> PluginComponentDetailContent? {
        guard
            let kind = SystemStatusMetricKind(rawValue: detailID),
            kind != .topProcesses
        else {
            return nil
        }

        return PluginComponentDetailContent(
            id: detailID,
            title: kind.title(localization: localization),
            content: AnyView(
                SystemStatusMetricDetailView(
                    viewModel: viewModel,
                    kind: kind,
                    localization: localization
                )
            )
        )
    }

    func refresh() {
        guard isActivated else {
            return
        }

        viewModel.startBackground()
        menuBarMetricsController.activate()
    }

    func activate(context: PluginRuntimeContext) {
        isActivated = true
        refresh()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActivated = false
        menuBarMetricsController.stop()
        viewModel.stop()
    }

    func makePortablePreferencesBackup() -> Data? {
        settingsController.makePortablePreferencesBackup()
    }

    func restorePortablePreferences(from data: Data) {
        _ = settingsController.restorePortablePreferences(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        settingsController.restorePortablePreferences(from: data)
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        guard surface == .component else {
            return
        }

        viewModel.startForeground()
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        guard surface == .component else {
            return
        }

        viewModel.returnToBackground()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
struct SystemStatusSamplingSchedule: Sendable {
    let backgroundFastInterval: Duration
    let menuBarFastInterval: Duration
    let foregroundFastInterval: Duration
    let backgroundSlowInterval: TimeInterval
    let menuBarSlowInterval: TimeInterval
    let foregroundSlowInterval: TimeInterval
    let backgroundProcessInterval: TimeInterval
    let foregroundProcessInterval: TimeInterval
    let backgroundHistoryInterval: TimeInterval
    let foregroundHistoryInterval: TimeInterval

    static let production = SystemStatusSamplingSchedule(
        backgroundFastInterval: .seconds(30),
        menuBarFastInterval: .seconds(3),
        foregroundFastInterval: .seconds(3),
        backgroundSlowInterval: 300,
        menuBarSlowInterval: 3,
        foregroundSlowInterval: 15,
        backgroundProcessInterval: 300,
        foregroundProcessInterval: 15,
        backgroundHistoryInterval: 300,
        foregroundHistoryInterval: 60
    )
}

@MainActor
final class SystemStatusViewModel: ObservableObject {
    enum ForegroundConsumer: Hashable {
        case dashboard
        case menuBarPopover
    }

    private static let processCandidateLimit = 6
    @Published private(set) var snapshot = SystemStatusSnapshot.empty

    private enum SamplingMode: Equatable {
        case background
        case menuBar(requiresSlowSampling: Bool)
        case foreground

        func fastInterval(schedule: SystemStatusSamplingSchedule) -> Duration {
            switch self {
            case .background:
                return schedule.backgroundFastInterval
            case .menuBar:
                return schedule.menuBarFastInterval
            case .foreground:
                return schedule.foregroundFastInterval
            }
        }

        func slowInterval(schedule: SystemStatusSamplingSchedule) -> TimeInterval {
            switch self {
            case .background:
                return schedule.backgroundSlowInterval
            case let .menuBar(requiresSlowSampling):
                return requiresSlowSampling ? schedule.menuBarSlowInterval : schedule.backgroundSlowInterval
            case .foreground:
                return schedule.foregroundSlowInterval
            }
        }

        func processInterval(schedule: SystemStatusSamplingSchedule) -> TimeInterval {
            switch self {
            case .background, .menuBar:
                return schedule.backgroundProcessInterval
            case .foreground:
                return schedule.foregroundProcessInterval
            }
        }

        func historyInterval(schedule: SystemStatusSamplingSchedule) -> TimeInterval {
            switch self {
            case .background, .menuBar:
                return schedule.backgroundHistoryInterval
            case .foreground:
                return schedule.foregroundHistoryInterval
            }
        }
    }

    private let sampler: any SystemStatusSampling
    private let historyStore: any SystemStatusHistoryStoring
    private let schedule: SystemStatusSamplingSchedule
    private var samplingTask: Task<Void, Never>?
    private var mode: SamplingMode = .background
    private var menuBarMode: SamplingMode?
    private(set) var foregroundConsumers: Set<ForegroundConsumer> = []

    var isSamplingForeground: Bool { mode == .foreground }
    private var lastSlowDate: Date?
    private var lastProcessDate: Date?
    private var lastHistoryDate: Date?
    private var displayHistory: [SystemStatusHistoryPoint] = []
    private var didLoadHistory = false
    private var lastDisplayHistoryPublishDate: Date?

    private static let displayHistoryRetention: TimeInterval = 24 * 60 * 60
    private static let highResolutionDisplayHistoryRetention: TimeInterval = 30 * 60
    private static let historicalDisplayHistoryBucket: TimeInterval = 60
    private static let maximumDisplayHistoryCount = SystemStatusHistoryStore.maximumSampleCount
    private static let foregroundDisplayHistoryInterval: TimeInterval = 2
    private static let backgroundDisplayHistoryInterval: TimeInterval = 30

    init(
        sampler: any SystemStatusSampling = SystemStatusSampler(),
        historyStore: (any SystemStatusHistoryStoring)? = nil,
        schedule: SystemStatusSamplingSchedule = .production
    ) {
        self.sampler = sampler
        self.historyStore = historyStore ?? SystemStatusHistoryStore(
            fileURL: SystemStatusHistoryStore.defaultFileURL(supportDirectory: nil)
        )
        self.schedule = schedule
    }

    func start() {
        startForeground()
    }

    func startForeground(for consumer: ForegroundConsumer = .dashboard) {
        guard foregroundConsumers.insert(consumer).inserted else { return }
        let previousMode = mode
        mode = .foreground

        if previousMode != .foreground, samplingTask != nil {
            restartSamplingLoop()
            return
        }

        startSamplingIfNeeded()
    }

    func startMenuBar(requiresSlowSampling: Bool) {
        menuBarMode = .menuBar(requiresSlowSampling: requiresSlowSampling)
        guard mode != .foreground else {
            startSamplingIfNeeded()
            return
        }

        let previousMode = mode
        mode = menuBarMode ?? .background

        if previousMode != mode, samplingTask != nil {
            restartSamplingLoop()
            return
        }

        startSamplingIfNeeded()
    }

    func stopMenuBar() {
        menuBarMode = nil
        guard mode != .foreground else {
            return
        }

        mode = .background
    }

    func startBackground() {
        startSamplingIfNeeded()
    }

    func returnToBackground(from consumer: ForegroundConsumer = .dashboard) {
        foregroundConsumers.remove(consumer)
        guard foregroundConsumers.isEmpty else { return }
        mode = menuBarMode ?? .background
    }

    func refreshSnapshotNow(referenceDate: Date = Date()) async {
        await collectFast(referenceDate: referenceDate, mode: .foreground, forcePublishHistory: true)

        let slowSample = await sampler.collectSlow()
        guard !Task.isCancelled else { return }
        var slowSnapshot = snapshot
        slowSnapshot.disk = slowSnapshot.disk.replacingCapacity(from: slowSample.disk)
        slowSnapshot.battery = slowSample.battery
        slowSnapshot.gpu = slowSample.gpu
        slowSnapshot.hardware = slowSample.hardware
        publishSnapshotIfChanged(slowSnapshot)

        let processes = await sampler.collectTopProcesses(limit: Self.processCandidateLimit)
        guard !Task.isCancelled else { return }
        var processSnapshot = snapshot
        processSnapshot.topProcesses = await Self.resolveApplicationNames(for: processes)
        publishSnapshotIfChanged(processSnapshot)

        let point = SystemStatusHistoryPoint(timestamp: referenceDate.timeIntervalSince1970, snapshot: snapshot)
        appendDisplayHistoryPoint(point, referenceDate: referenceDate)
        publishDisplayHistory(referenceDate: referenceDate, force: true)
        _ = await historyStore.append(point, referenceDate: referenceDate)
        guard !Task.isCancelled else { return }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        mode = .background
        menuBarMode = nil
        foregroundConsumers.removeAll()
    }

    private func startSamplingIfNeeded() {
        guard samplingTask == nil else {
            return
        }

        samplingTask = Task { @MainActor [weak self] in
            await self?.loadHistory()
            await self?.runSamplingLoop()
        }
    }

    private func restartSamplingLoop() {
        samplingTask?.cancel()
        samplingTask = nil
        startSamplingIfNeeded()
    }

    private func loadHistory() async {
        guard !didLoadHistory else {
            return
        }

        let referenceDate = Date()
        displayHistory = Self.prunedDisplayHistory(
            await historyStore.load(referenceDate: referenceDate),
            referenceDate: referenceDate
        )
        publishDisplayHistory(referenceDate: referenceDate, force: true)
        didLoadHistory = true
    }

    private func runSamplingLoop() async {
        while !Task.isCancelled {
            let currentMode = mode
            let now = Date()
            await collectFast(referenceDate: now, mode: currentMode)
            guard !Task.isCancelled else { return }
            await collectSlowIfNeeded(referenceDate: now, mode: currentMode)
            guard !Task.isCancelled else { return }
            await collectProcessesIfNeeded(referenceDate: now, mode: currentMode)
            guard !Task.isCancelled else { return }
            await persistHistoryIfNeeded(referenceDate: now, mode: currentMode)
            guard !Task.isCancelled else { return }

            do {
                try await Task.sleep(for: currentMode.fastInterval(schedule: schedule))
            } catch {
                return
            }
        }
    }

    private func collectFast(
        referenceDate: Date,
        mode: SamplingMode,
        forcePublishHistory: Bool = false
    ) async {
        let sample = await sampler.collectFast(referenceDate: referenceDate)
        guard !Task.isCancelled else { return }

        var updatedSnapshot = snapshot
        updatedSnapshot.cpu = sample.cpu
        updatedSnapshot.memory = sample.memory
        updatedSnapshot.network = sample.network
        updatedSnapshot.disk = updatedSnapshot.disk.replacingActivity(from: sample.disk)
        appendDisplayHistoryPoint(
            SystemStatusHistoryPoint(timestamp: referenceDate.timeIntervalSince1970, snapshot: updatedSnapshot),
            referenceDate: referenceDate
        )

        if shouldPublishDisplayHistory(referenceDate: referenceDate, mode: mode) || forcePublishHistory {
            updatedSnapshot.history = displayHistory
            lastDisplayHistoryPublishDate = referenceDate
        } else {
            updatedSnapshot.history = snapshot.history
        }
        publishSnapshotIfChanged(updatedSnapshot)
    }

    private func collectSlowIfNeeded(referenceDate: Date, mode: SamplingMode) async {
        guard shouldRun(lastDate: lastSlowDate, referenceDate: referenceDate, interval: mode.slowInterval(schedule: schedule)) else {
            return
        }

        lastSlowDate = referenceDate
        let sample = await sampler.collectSlow()
        guard !Task.isCancelled else { return }
        var updatedSnapshot = snapshot
        updatedSnapshot.disk = updatedSnapshot.disk.replacingCapacity(from: sample.disk)
        updatedSnapshot.battery = sample.battery
        updatedSnapshot.gpu = sample.gpu
        updatedSnapshot.hardware = sample.hardware
        publishSnapshotIfChanged(updatedSnapshot)
    }

    private func collectProcessesIfNeeded(referenceDate: Date, mode: SamplingMode) async {
        guard shouldRun(lastDate: lastProcessDate, referenceDate: referenceDate, interval: mode.processInterval(schedule: schedule)) else {
            return
        }

        lastProcessDate = referenceDate
        let processes = await sampler.collectTopProcesses(limit: Self.processCandidateLimit)
        guard !Task.isCancelled else { return }
        var updatedSnapshot = snapshot
        updatedSnapshot.topProcesses = await Self.resolveApplicationNames(for: processes)
        publishSnapshotIfChanged(updatedSnapshot)
    }

    private func persistHistoryIfNeeded(referenceDate: Date, mode: SamplingMode) async {
        guard shouldRun(lastDate: lastHistoryDate, referenceDate: referenceDate, interval: mode.historyInterval(schedule: schedule)) else {
            return
        }

        lastHistoryDate = referenceDate
        let point = SystemStatusHistoryPoint(timestamp: referenceDate.timeIntervalSince1970, snapshot: snapshot)
        appendDisplayHistoryPoint(point, referenceDate: referenceDate)
        publishDisplayHistory(referenceDate: referenceDate, force: true)
        _ = await historyStore.append(point, referenceDate: referenceDate)
        guard !Task.isCancelled else { return }
    }

    private func shouldRun(lastDate: Date?, referenceDate: Date, interval: TimeInterval) -> Bool {
        guard let lastDate else {
            return true
        }

        return referenceDate.timeIntervalSince(lastDate) >= interval
    }

    private func appendDisplayHistoryPoint(_ point: SystemStatusHistoryPoint, referenceDate: Date) {
        if let lastIndex = displayHistory.indices.last,
           displayHistory[lastIndex].timestamp == point.timestamp {
            displayHistory[lastIndex] = point
            displayHistory = Self.prunedSortedDisplayHistory(displayHistory, referenceDate: referenceDate)
            return
        }

        if let lastTimestamp = displayHistory.last?.timestamp,
           point.timestamp < lastTimestamp {
            displayHistory.append(point)
            displayHistory = Self.prunedDisplayHistory(displayHistory, referenceDate: referenceDate)
            return
        }

        displayHistory.append(point)
        displayHistory = Self.prunedSortedDisplayHistory(displayHistory, referenceDate: referenceDate)
    }

    private func shouldPublishDisplayHistory(referenceDate: Date, mode: SamplingMode) -> Bool {
        let interval: TimeInterval
        switch mode {
        case .foreground:
            interval = Self.foregroundDisplayHistoryInterval
        case .background, .menuBar:
            interval = Self.backgroundDisplayHistoryInterval
        }

        return shouldRun(lastDate: lastDisplayHistoryPublishDate, referenceDate: referenceDate, interval: interval)
    }

    private func publishDisplayHistory(referenceDate: Date, force: Bool = false) {
        guard force || shouldPublishDisplayHistory(referenceDate: referenceDate, mode: mode) else {
            return
        }

        var updatedSnapshot = snapshot
        updatedSnapshot.history = displayHistory
        lastDisplayHistoryPublishDate = referenceDate
        publishSnapshotIfChanged(updatedSnapshot)
    }

    private func publishSnapshotIfChanged(_ updatedSnapshot: SystemStatusSnapshot) {
        guard updatedSnapshot != snapshot else {
            return
        }

        snapshot = updatedSnapshot
    }

    static func prunedSortedDisplayHistory(
        _ points: [SystemStatusHistoryPoint],
        referenceDate: Date
    ) -> [SystemStatusHistoryPoint] {
        guard !points.isEmpty else {
            return []
        }

        let cutoff = referenceDate.timeIntervalSince1970 - displayHistoryRetention
        let upperBound = referenceDate.timeIntervalSince1970 + 60
        var startIndex = points.startIndex

        while startIndex < points.endIndex, points[startIndex].timestamp < cutoff {
            startIndex = points.index(after: startIndex)
        }

        var endIndex = points.endIndex
        var currentIndex = startIndex
        while currentIndex < points.endIndex {
            if points[currentIndex].timestamp > upperBound {
                endIndex = currentIndex
                break
            }

            currentIndex = points.index(after: currentIndex)
        }

        guard startIndex < endIndex else {
            return []
        }

        return compactedDisplayHistory(
            points[startIndex..<endIndex],
            referenceDate: referenceDate
        )
    }

    static func prunedDisplayHistory(
        _ points: [SystemStatusHistoryPoint],
        referenceDate: Date
    ) -> [SystemStatusHistoryPoint] {
        let cutoff = referenceDate.timeIntervalSince1970 - displayHistoryRetention
        let recentPoints = points
            .filter { $0.timestamp >= cutoff && $0.timestamp <= referenceDate.timeIntervalSince1970 + 60 }
            .sorted { $0.timestamp < $1.timestamp }

        return compactedDisplayHistory(recentPoints[...], referenceDate: referenceDate)
    }

    private static func compactedDisplayHistory(
        _ points: ArraySlice<SystemStatusHistoryPoint>,
        referenceDate: Date
    ) -> [SystemStatusHistoryPoint] {
        let highResolutionCutoff = referenceDate.timeIntervalSince1970 - highResolutionDisplayHistoryRetention
        var compacted: [SystemStatusHistoryPoint] = []
        compacted.reserveCapacity(min(points.count, maximumDisplayHistoryCount))
        var pendingHistoricalPoint: SystemStatusHistoryPoint?
        var pendingHistoricalBucket: Int?

        for point in points {
            guard point.timestamp < highResolutionCutoff else {
                if let pendingHistoricalPoint {
                    compacted.append(pendingHistoricalPoint)
                    pendingHistoricalBucket = nil
                }
                compacted.append(point)
                pendingHistoricalPoint = nil
                continue
            }

            let bucket = Int(floor(point.timestamp / historicalDisplayHistoryBucket))
            if bucket == pendingHistoricalBucket {
                pendingHistoricalPoint = point
            } else {
                if let pendingHistoricalPoint {
                    compacted.append(pendingHistoricalPoint)
                }
                pendingHistoricalBucket = bucket
                pendingHistoricalPoint = point
            }
        }

        if let pendingHistoricalPoint {
            compacted.append(pendingHistoricalPoint)
        }
        enforceHistoryCapacity(&compacted)
        return compacted
    }

    private static func enforceHistoryCapacity(_ points: inout [SystemStatusHistoryPoint]) {
        guard points.count > maximumDisplayHistoryCount else {
            return
        }
        points = Array(points.suffix(maximumDisplayHistoryCount))
    }

    private static func resolveApplicationNames(for processes: [SystemStatusTopProcess]) async -> [SystemStatusTopProcess] {
        processes.map { process in
            guard
                let application = NSRunningApplication(processIdentifier: pid_t(process.pid)),
                let localizedName = application.localizedName,
                !localizedName.isEmpty
            else {
                return process
            }

            return process.replacingDisplayName(localizedName)
        }
    }
}

struct SystemStatusComponentView: View {
    private enum Layout {
        static let spacing = SystemStatusComponentLayout.cardSpacing
    }

    @ObservedObject var viewModel: SystemStatusViewModel
    @ObservedObject var settingsController: SystemStatusSettingsController
    let localization: PluginLocalization
    let onMetricDetail: (SystemStatusMetricKind) -> Void

    var body: some View {
        SystemStatusDashboardView(
            snapshot: viewModel.snapshot,
            visibleKinds: settingsController.configuration.visiblePanelMetricKinds,
            processSort: settingsController.configuration.processSort,
            onProcessSortChange: settingsController.setProcessSort,
            localization: localization,
            onMetricDetail: onMetricDetail
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var compactCPUCard: some View {
        let cpu = viewModel.snapshot.cpu
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.cpu.title(localization: localization),
            percentText: cpu.isCollecting ? "--" : SystemStatusFormatter.percent(cpu.usage),
            detailLines: [
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(cpu.temperatureCelsius)
                ),
                localization.format(
                    "metric.powerFormat",
                    defaultValue: "功率 %@",
                    SystemStatusFormatter.power(cpu.systemPowerWatts)
                )
            ],
            progress: cpu.usage
        )
    }

    private var compactMemoryCard: some View {
        let memory = viewModel.snapshot.memory
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.memory.title(localization: localization),
            percentText: SystemStatusFormatter.percent(memory.usage),
            detailLines: [
                localization.format(
                    "metric.usedFormat",
                    defaultValue: "已用 %@",
                    SystemStatusFormatter.bytes(memory.usedBytes)
                ),
                localization.format(
                    "metric.totalFormat",
                    defaultValue: "总量 %@",
                    SystemStatusFormatter.bytes(memory.totalBytes)
                )
            ],
            progress: memory.usage
        )
    }

    private var compactDiskCard: some View {
        let disk = viewModel.snapshot.disk
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.disk.title(localization: localization),
            percentText: SystemStatusFormatter.percent(disk.usage),
            detailLines: [
                localization.format(
                    "metric.usedFormat",
                    defaultValue: "已用 %@",
                    SystemStatusFormatter.bytes(disk.usedBytes)
                ),
                localization.format(
                    "metric.totalFormat",
                    defaultValue: "总量 %@",
                    SystemStatusFormatter.bytes(disk.totalBytes)
                )
            ],
            progress: disk.usage
        )
    }

    private var compactBatteryCard: some View {
        let battery = viewModel.snapshot.battery
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.battery.title(localization: localization),
            percentText: battery.isAvailable ? SystemStatusFormatter.percent(battery.level) : "--",
            detailLines: [
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(battery.temperatureCelsius)
                ),
                batteryHealthText(for: battery)
            ],
            progress: battery.level,
            centerSubtext: batteryCircleStatusText(for: battery),
            centerHelpText: batteryShortText(for: battery)
        )
    }

    private var networkCard: some View {
        let network = viewModel.snapshot.network
        return SystemStatusWideInfoCard(
            title: SystemStatusMetricKind.network.title(localization: localization),
            iconName: "wifi",
            tint: Color(nsColor: .systemCyan),
            headerLeadingPadding: 4
        ) {
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 2) {
                    SystemStatusNetworkSpeedRow(
                        iconName: "arrow.down",
                        value: SystemStatusFormatter.speed(network.downloadBytesPerSecond),
                        tint: Color(nsColor: .systemBlue)
                    )
                    SystemStatusNetworkSpeedRow(
                        iconName: "arrow.up",
                        value: SystemStatusFormatter.speed(network.uploadBytesPerSecond),
                        tint: Color(nsColor: .systemGreen)
                    )
                }

                VStack(alignment: .leading, spacing: 1) {
                    SystemStatusKeyValueLine(
                        label: localization.string("network.publicIP", defaultValue: "公网"),
                        value: network.publicIPAddress
                            ?? localization.string("network.publicIP.collecting", defaultValue: "获取中"),
                        copyValue: network.publicIPAddress,
                        localization: localization
                    )
                    SystemStatusKeyValueLine(
                        label: localization.string("network.localIP", defaultValue: "内网"),
                        value: network.ipAddress ?? "—",
                        copyValue: network.ipAddress,
                        localization: localization
                    )
                }
            }
        }
    }

    private var topProcessesCard: some View {
        SystemStatusTopProcessesCard(
            processes: Array(viewModel.snapshot.topProcesses.prefix(3)),
            localization: localization
        )
    }

    private func batteryShortText(for battery: SystemStatusBatterySnapshot) -> String {
        guard battery.isAvailable else {
            return battery.state.title(localization: localization)
        }

        if battery.state == .charged {
            return localization.string("battery.state.charged", defaultValue: "已充满")
        }

        if battery.state == .charging || battery.state == .acPower {
            return battery.state.title(localization: localization)
        }

        return SystemStatusFormatter.timeRemaining(minutes: battery.timeRemainingMinutes, localization: localization)
    }

    private func batteryHealthText(for battery: SystemStatusBatterySnapshot) -> String {
        guard let healthPercent = battery.healthPercent else {
            return localization.string("battery.healthUnavailable", defaultValue: "健康度 —")
        }

        return localization.format("battery.healthFormat", defaultValue: "健康度 %d%%", healthPercent)
    }

    private func batteryCircleStatusText(for battery: SystemStatusBatterySnapshot) -> String? {
        guard battery.isAvailable else {
            return nil
        }

        switch battery.state {
        case .charging, .charged, .acPower, .unplugged:
            return battery.state.title(localization: localization)
        case .unavailable, .unknown:
            return nil
        }
    }
}

private enum SystemStatusCircleStyle {
    static let tint = Color(nsColor: .systemBlue)
}

private struct SystemStatusCompactMetricCard: View {
    let title: String
    let percentText: String
    let detailLines: [String]
    let progress: Double?
    var centerSubtext: String? = nil
    var centerHelpText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                SystemStatusCircularProgress(value: progress, tint: SystemStatusCircleStyle.tint)
                    .frame(width: 58, height: 58)

                VStack(spacing: centerSubtext == nil ? 1 : 0) {
                    Text(title)
                        .font(.system(size: centerSubtext == nil ? 9 : 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(percentText)
                        .font(.system(size: centerSubtext == nil ? 12 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if let centerSubtext {
                        Text(centerSubtext)
                            .font(.system(size: 6.8, weight: .semibold, design: .rounded))
                            .foregroundStyle(SystemStatusCircleStyle.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
                .padding(.horizontal, 5)
                .help(centerHelpText ?? "")
            }

            Spacer(minLength: 5)

            VStack(spacing: 1) {
                ForEach(Array(detailLines.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 7.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .help(detailLines.joined(separator: "\n"))
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            PluginComponentCardBackground(
                cornerRadius: SystemStatusComponentLayout.cardCornerRadius
            )
        )
    }
}
private struct SystemStatusWideInfoCard<Content: View>: View {
    let title: String
    let iconName: String
    let tint: Color
    var headerLeadingPadding: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: PluginSystemImage.resolvedName(iconName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.leading, headerLeadingPadding)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            PluginComponentCardBackground(
                cornerRadius: SystemStatusComponentLayout.cardCornerRadius
            )
        )
    }
}

private enum SystemStatusNetworkRowLayout {
    static let leadingColumnWidth: CGFloat = 22
    static let columnSpacing: CGFloat = 5
}

private struct SystemStatusNetworkSpeedRow: View {
    let iconName: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: SystemStatusNetworkRowLayout.columnSpacing) {
            Image(systemName: PluginSystemImage.resolvedName(iconName))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: SystemStatusNetworkRowLayout.leadingColumnWidth, alignment: .center)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemStatusKeyValueLine: View {
    let label: String
    let value: String
    let copyValue: String?
    let localization: PluginLocalization

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SystemStatusNetworkRowLayout.columnSpacing) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: SystemStatusNetworkRowLayout.leadingColumnWidth, alignment: .center)

            Text(value)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
                .help(value)
                .layoutPriority(1)

            if canCopy {
                Button(action: copyToPasteboard) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .disabled(!isHovering)
                .help(localization.format("network.copyIPHelpFormat", defaultValue: "复制%@ IP", label))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
    }

    private var canCopy: Bool {
        guard let copyValue else {
            return false
        }

        return !copyValue.isEmpty
    }

    private func copyToPasteboard() {
        guard let copyValue, !copyValue.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyValue, forType: .string)
    }
}

private struct SystemStatusTopProcessesCard: View {
    let processes: [SystemStatusTopProcess]
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if processes.isEmpty {
                Text(localization.string("topProcesses.collecting", defaultValue: "采集中…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 4) {
                    ForEach(processes) { process in
                        SystemStatusProcessRow(process: process)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            PluginComponentCardBackground(
                cornerRadius: SystemStatusComponentLayout.cardCornerRadius
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemPink))
                .frame(width: 14, height: 14)

            Text(SystemStatusMetricKind.topProcesses.title(localization: localization))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            SystemStatusProcessMetricHeader()
                .layoutPriority(1)
        }
    }
}

private struct SystemStatusProcessMetricHeader: View {
    var body: some View {
        HStack(spacing: SystemStatusProcessRow.metricColumnSpacing) {
            Text("CPU")
                .frame(width: SystemStatusProcessRow.cpuColumnWidth, alignment: .trailing)
            Text("MEM")
                .frame(width: SystemStatusProcessRow.memoryColumnWidth, alignment: .trailing)
        }
        .font(.system(size: 7.5, weight: .bold, design: .rounded))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SystemStatusProcessRow: View {
    static let cpuColumnWidth: CGFloat = 28
    static let memoryColumnWidth: CGFloat = 26
    static let metricColumnSpacing: CGFloat = 1

    let process: SystemStatusTopProcess

    var body: some View {
        HStack(spacing: 4) {
            Text(process.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(process.displayName)

            Spacer(minLength: 1)

            HStack(spacing: Self.metricColumnSpacing) {
                metricText(SystemStatusFormatter.wholePercent(process.cpuPercent, fractionDigits: 0))
                    .frame(width: Self.cpuColumnWidth, alignment: .trailing)
                metricText(SystemStatusFormatter.wholePercent(process.memoryPercent, fractionDigits: 0))
                    .frame(width: Self.memoryColumnWidth, alignment: .trailing)
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func metricText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
private struct SystemStatusCircularProgress: View {
    let value: Double?
    let tint: Color

    @Environment(\.pluginComponentTheme) private var theme

    private var clampedValue: Double {
        min(max(value ?? 0, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.surfaces.track, lineWidth: 4)

            Circle()
                .trim(from: 0, to: clampedValue)
                .stroke(
                    tint.opacity(value == nil ? 0.22 : 0.86),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}
