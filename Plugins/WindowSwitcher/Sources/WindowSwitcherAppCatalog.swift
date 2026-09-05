import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct WindowSwitcherWindowRecord: Equatable, Sendable {
    static let minimumWindowSize = CGSize(width: 80, height: 60)

    let windowNumber: CGWindowID
    let processIdentifier: pid_t
    let title: String
    let isOnScreen: Bool?
    let bounds: CGRect

    static func parse(_ windowInfo: [[String: Any]]) -> [Self] {
        var seenWindowNumbers = Set<CGWindowID>()
        var records: [WindowSwitcherWindowRecord] = []

        for item in windowInfo {
            guard let windowNumber = number(in: item, forKey: kCGWindowNumber),
                  windowNumber > 0,
                  let processIdentifier = processIdentifier(in: item),
                  processIdentifier > 0,
                  number(in: item, forKey: kCGWindowLayer) == 0,
                  let alpha = numericValue(in: item, forKey: kCGWindowAlpha),
                  alpha > 0,
                  alpha <= 1,
                  let bounds = rect(in: item[kCGWindowBounds as String]),
                  bounds.width >= minimumWindowSize.width,
                  bounds.height >= minimumWindowSize.height
            else {
                continue
            }

            guard seenWindowNumbers.insert(windowNumber).inserted else {
                continue
            }

            records.append(
                WindowSwitcherWindowRecord(
                    windowNumber: windowNumber,
                    processIdentifier: processIdentifier,
                    title: item[kCGWindowName as String] as? String ?? "",
                    isOnScreen: boolean(in: item, forKey: kCGWindowIsOnscreen),
                    bounds: bounds
                )
            )
        }

        return records
    }

    private static func number(in item: [String: Any], forKey key: CFString) -> UInt32? {
        guard let rawValue = numericValue(in: item, forKey: key),
              rawValue.rounded() == rawValue,
              rawValue >= 0,
              rawValue <= Double(UInt32.max)
        else {
            return nil
        }

        return UInt32(rawValue)
    }

    private static func boolean(in item: [String: Any], forKey key: CFString) -> Bool? {
        guard let value = item[key as String] as? NSNumber else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFBooleanGetTypeID() else {
            return nil
        }

        return value.boolValue
    }

    private static func numericValue(in item: [String: Any], forKey key: CFString) -> Double? {
        guard let value = item[key as String] as? NSNumber else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) != CFBooleanGetTypeID() else {
            return nil
        }

        let rawValue = value.doubleValue
        guard rawValue.isFinite else {
            return nil
        }

        return rawValue
    }

    private static func processIdentifier(in item: [String: Any]) -> pid_t? {
        guard let rawValue = numericValue(in: item, forKey: kCGWindowOwnerPID),
              rawValue.rounded() == rawValue,
              rawValue > 0,
              rawValue <= Double(pid_t.max)
        else {
            return nil
        }

        return pid_t(rawValue)
    }

    private static func rect(in value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary),
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite
        else {
            return nil
        }

        return rect
    }
}

struct WindowSwitcherWindowSnapshot {
    let element: AXUIElement?
    let windowNumber: CGWindowID?
    let title: String
    let isMinimized: Bool
    let position: CGPoint
    let size: CGSize
}

private struct WindowSwitcherWindowRecordSnapshot {
    let records: [WindowSwitcherWindowRecord]
    let isFresh: Bool
}

@MainActor
protocol WindowSwitcherApplicationControlling: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var launchDate: Date? { get }
    var isTerminated: Bool { get }

    @discardableResult
    func unhide() -> Bool
    @discardableResult
    func activate(options: NSApplication.ActivationOptions) -> Bool
    @discardableResult
    func terminate() -> Bool
}

extension NSRunningApplication: WindowSwitcherApplicationControlling {}

private struct WindowSwitcherWindowMatchKey: Hashable {
    let title: String
    let positionX: Double
    let positionY: Double
    let sizeWidth: Double
    let sizeHeight: Double

    init(title: String, bounds: CGRect) {
        self.title = title
        positionX = Double(bounds.origin.x)
        positionY = Double(bounds.origin.y)
        sizeWidth = Double(bounds.size.width)
        sizeHeight = Double(bounds.size.height)
    }
}

private struct WindowSwitcherWindowBoundsKey: Hashable {
    let positionX: Double
    let positionY: Double
    let sizeWidth: Double
    let sizeHeight: Double

    init(bounds: CGRect) {
        positionX = Double(bounds.origin.x)
        positionY = Double(bounds.origin.y)
        sizeWidth = Double(bounds.size.width)
        sizeHeight = Double(bounds.size.height)
    }
}

@MainActor
final class WindowSwitcherAppCatalog {
    var onChange: (() -> Void)?

    private static let axTimeout: Float = 0.2
    private static let axScanBudget: TimeInterval = 0.75
    private static let defaultWindowRecordRefreshTimeout: TimeInterval = 0.75
    private static let maxWindowRecordRefreshesInFlight = 2

    private let notificationCenter: NotificationCenter
    private let windowRecordProvider: @Sendable () -> [WindowSwitcherWindowRecord]
    private let windowRecordRefreshTimeout: TimeInterval
    private let applicationProvider: (pid_t) -> WindowSwitcherApplicationControlling?
    private let activationWindowSnapshotProvider: ((pid_t, WindowSwitcherAppEntry) -> WindowSwitcherWindowSnapshot?)?
    private let focusWindowHandler: ((AXUIElement, Bool) -> Void)?
    private var mruIDs: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var windowRecords: [WindowSwitcherWindowRecord] = []
    private var windowRecordRefreshTask: Task<[WindowSwitcherWindowRecord], Never>?
    private var windowRecordRefreshGeneration: UInt64 = 0
    private var windowRecordRefreshLastCompletedGeneration: UInt64?
    private var windowRecordRefreshInFlightCount = 0

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        windowRecordProvider: @escaping @Sendable () -> [WindowSwitcherWindowRecord] = {
            WindowSwitcherWindowRecord.parse(
                CGWindowListCopyWindowInfo(
                    [.optionAll, .excludeDesktopElements],
                    kCGNullWindowID
                ) as? [[String: Any]] ?? []
            )
        },
        windowRecordRefreshTimeout: TimeInterval = WindowSwitcherAppCatalog.defaultWindowRecordRefreshTimeout,
        applicationProvider: @escaping (pid_t) -> WindowSwitcherApplicationControlling? = {
            NSRunningApplication(processIdentifier: $0)
        },
        activationWindowSnapshotProvider: ((pid_t, WindowSwitcherAppEntry) -> WindowSwitcherWindowSnapshot?)? = nil,
        focusWindowHandler: ((AXUIElement, Bool) -> Void)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.windowRecordProvider = windowRecordProvider
        self.windowRecordRefreshTimeout = windowRecordRefreshTimeout.isFinite
            ? max(0, windowRecordRefreshTimeout)
            : Self.defaultWindowRecordRefreshTimeout
        self.applicationProvider = applicationProvider
        self.activationWindowSnapshotProvider = activationWindowSnapshotProvider
        self.focusWindowHandler = focusWindowHandler
    }

    func start() {
        guard observers.isEmpty else {
            refreshFrontmostApplication()
            refreshWindowRecords()
            return
        }

        refreshFrontmostApplication()
        refreshWindowRecords()
        let activated = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let appID: String?
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               Self.isUserFacingApplication(app) {
                appID = Self.identifier(for: app)
            } else {
                appID = nil
            }

            Task { @MainActor [weak self, appID] in
                if let appID {
                    self?.recordActivationID(appID)
                }
                self?.onChange?()
            }
        }

        let launched = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onChange?()
            }
        }

        let terminated = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                .map(Self.identifier(for:))

            Task { @MainActor [weak self, appID] in
                if let appID {
                    self?.removeApplicationID(appID)
                }
                self?.onChange?()
            }
        }

        observers = [activated, launched, terminated]
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        windowRecordRefreshGeneration &+= 1
        windowRecordRefreshTask?.cancel()
        windowRecordRefreshTask = nil
        windowRecordRefreshLastCompletedGeneration = nil
        windowRecords.removeAll()
    }

    func entries(sortMode: WindowSwitcherSortMode) async -> [WindowSwitcherAppEntry] {
        refreshFrontmostApplication()
        let ranks = Dictionary(uniqueKeysWithValues: mruIDs.enumerated().map { ($0.element, $0.offset) })
        let windowRecords = await freshWindowRecords()
        let recordsByProcessIdentifier = Dictionary(grouping: windowRecords, by: \.processIdentifier)
        let axDeadline = Date().addingTimeInterval(Self.axScanBudget)
        let apps = NSWorkspace.shared.runningApplications.filter(Self.isUserFacingApplication)

        let sortedApps = apps
            .sorted { lhs, rhs in
                switch sortMode {
                case .recentUse:
                    let lhsID = Self.identifier(for: lhs)
                    let rhsID = Self.identifier(for: rhs)
                    let lhsRank = ranks[lhsID] ?? Int.max
                    let rhsRank = ranks[rhsID] ?? Int.max

                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }

                    let lhsLaunchDate = lhs.launchDate ?? .distantPast
                    let rhsLaunchDate = rhs.launchDate ?? .distantPast
                    if lhsLaunchDate != rhsLaunchDate {
                        return lhsLaunchDate > rhsLaunchDate
                    }
                case .fixed:
                    break
                }

                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }

                let lhsBundleID = lhs.bundleIdentifier ?? ""
                let rhsBundleID = rhs.bundleIdentifier ?? ""
                if lhsBundleID != rhsBundleID {
                    return lhsBundleID < rhsBundleID
                }

                return lhs.processIdentifier < rhs.processIdentifier
            }

        var entries: [WindowSwitcherAppEntry] = []
        for (appIndex, app) in sortedApps.enumerated() {
            guard !Task.isCancelled else {
                break
            }

            entries.append(contentsOf: self.entries(
                for: app,
                recordsForApplication: recordsByProcessIdentifier[app.processIdentifier] ?? [],
                axDeadline: Self.axDeadline(
                    sessionDeadline: axDeadline,
                    appIndex: appIndex,
                    appCount: sortedApps.count
                )
            ))
        }
        return entries
    }

    func frontmostApplicationID() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              Self.isUserFacingApplication(app)
        else {
            return nil
        }

        return Self.identifier(for: app)
    }

    func windowRecordsSnapshot() async -> [WindowSwitcherWindowRecord] {
        await freshWindowRecords()
    }

    func activate(_ entry: WindowSwitcherAppEntry) async {
        guard !Task.isCancelled else {
            return
        }

        let currentRecords: [WindowSwitcherWindowRecord]
        if entry.windowNumber != nil && entry.windowElement == nil {
            let snapshot = await freshWindowRecordSnapshot()
            guard snapshot.isFresh,
                  !Task.isCancelled
            else {
                return
            }
            currentRecords = snapshot.records
        } else {
            currentRecords = []
        }

        guard !Task.isCancelled,
              let app = applicationProvider(entry.processIdentifier),
              Self.isCurrentApplication(app, for: entry),
              entry.windowNumber == nil
                  || entry.windowElement != nil
                  || currentWindowRecord(for: entry, in: currentRecords) != nil
        else {
            return
        }

        guard !Task.isCancelled else {
            return
        }
        app.unhide()

        guard !Task.isCancelled else {
            return
        }
        app.activate(options: entry.windowNumber != nil && entry.windowElement == nil
            ? [.activateAllWindows]
            : [])
        let axDeadline = Date().addingTimeInterval(Self.axScanBudget)

        if let windowElement = entry.windowElement {
            focusWindow(
                windowElement,
                isMinimized: entry.isMinimized,
                deadline: axDeadline
            )
        } else if entry.windowNumber != nil,
                  let snapshot = windowSnapshot(
                      for: app,
                      matching: entry,
                      deadline: axDeadline
                  ),
                  let windowElement = snapshot.element {
            focusWindow(
                windowElement,
                isMinimized: snapshot.isMinimized,
                deadline: axDeadline
            )
        }

        guard !Task.isCancelled else {
            return
        }
        recordActivationID(Self.identifier(for: entry))
        onChange?()
    }

    func quitApplication(_ entry: WindowSwitcherAppEntry) {
        guard let app = applicationProvider(entry.processIdentifier),
              Self.isCurrentApplication(app, for: entry),
              !app.isTerminated,
              app.terminate()
        else {
            return
        }

        removeApplicationID(Self.identifier(for: entry))
        onChange?()
    }

    private func currentWindowRecord(
        for entry: WindowSwitcherAppEntry,
        in records: [WindowSwitcherWindowRecord]
    ) -> WindowSwitcherWindowRecord? {
        guard let windowNumber = entry.windowNumber,
              let expectedBounds = entry.windowBounds,
              let record = records.first(where: {
                  $0.windowNumber == windowNumber
                      && $0.processIdentifier == entry.processIdentifier
              }),
              record.bounds == expectedBounds
        else {
            return nil
        }

        if !record.title.isEmpty,
           let expectedTitle = entry.windowTitle,
           !expectedTitle.isEmpty,
           record.title != expectedTitle {
            return nil
        }

        return record
    }

    private func refreshFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return
        }

        recordActivation(app)
    }

    private func recordActivation(_ app: NSRunningApplication) {
        guard Self.isUserFacingApplication(app) else {
            return
        }

        recordActivationID(Self.identifier(for: app))
    }

    private func recordActivationID(_ id: String) {
        mruIDs.removeAll { $0 == id }
        mruIDs.insert(id, at: 0)
        mruIDs = Array(mruIDs.prefix(80))
    }

    private func removeApplicationID(_ id: String) {
        mruIDs.removeAll { $0 == id }
    }

    private func refreshWindowRecords() {
        guard windowRecordRefreshTask == nil,
              windowRecordRefreshInFlightCount < Self.maxWindowRecordRefreshesInFlight
        else {
            return
        }

        windowRecordRefreshGeneration &+= 1
        let generation = windowRecordRefreshGeneration
        let provider = windowRecordProvider
        windowRecordRefreshInFlightCount += 1
        let task = Task.detached(priority: .userInitiated) {
            provider()
        }
        windowRecordRefreshTask = task

        Task { @MainActor [weak self] in
            let records = await task.value
            guard let self,
                  self.windowRecordRefreshInFlightCount > 0
            else {
                return
            }
            self.windowRecordRefreshInFlightCount -= 1

            guard self.windowRecordRefreshGeneration == generation else {
                return
            }

            guard self.windowRecordRefreshTask != nil else {
                return
            }

            self.windowRecordRefreshTask = nil
            self.windowRecordRefreshLastCompletedGeneration = generation
            let didChange = self.windowRecords != records
            self.windowRecords = records
            if didChange {
                self.onChange?()
            }
        }
    }

    private func freshWindowRecords() async -> [WindowSwitcherWindowRecord] {
        await freshWindowRecordSnapshot().records
    }

    private func freshWindowRecordSnapshot() async -> WindowSwitcherWindowRecordSnapshot {
        refreshWindowRecords()
        guard windowRecordRefreshTask != nil else {
            return WindowSwitcherWindowRecordSnapshot(records: windowRecords, isFresh: false)
        }
        let generation = windowRecordRefreshGeneration
        let refreshDeadline = Date().addingTimeInterval(windowRecordRefreshTimeout)

        while windowRecordRefreshTask != nil,
              windowRecordRefreshGeneration == generation {
            guard !Task.isCancelled,
                  Date() < refreshDeadline
            else {
                abandonWindowRecordRefresh(generation: generation)
                return WindowSwitcherWindowRecordSnapshot(records: windowRecords, isFresh: false)
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return WindowSwitcherWindowRecordSnapshot(
            records: windowRecords,
            isFresh: windowRecordRefreshLastCompletedGeneration == generation
        )
    }

    private func abandonWindowRecordRefresh(generation: UInt64) {
        guard windowRecordRefreshGeneration == generation else {
            return
        }

        windowRecordRefreshTask?.cancel()
        windowRecordRefreshTask = nil
        windowRecordRefreshGeneration &+= 1
    }

    static func axDeadline(
        sessionDeadline: Date,
        appIndex: Int,
        appCount: Int,
        now: Date = Date()
    ) -> Date {
        guard appIndex < appCount else {
            return now
        }

        let remaining = sessionDeadline.timeIntervalSince(now)
        guard remaining > 0 else {
            return now
        }

        let remainingApplicationCount = max(1, appCount - appIndex)
        let fairShare = remaining / Double(remainingApplicationCount)
        return now.addingTimeInterval(fairShare)
    }

    private func entries(
        for app: NSRunningApplication,
        recordsForApplication: [WindowSwitcherWindowRecord],
        axDeadline: Date
    ) -> [WindowSwitcherAppEntry] {
        let appID = Self.identifier(for: app)
        let windows = windows(
            for: app,
            recordsForApplication: recordsForApplication,
            axDeadline: axDeadline
        )
        guard !windows.isEmpty else {
            return [Self.appEntry(for: app, id: appID)]
        }

        return Self.windowEntries(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? "App",
            icon: app.icon,
            applicationLaunchDate: app.launchDate,
            windows: windows
        )
    }

    static func windowEntries(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        appName: String,
        icon: NSImage?,
        applicationLaunchDate: Date? = nil,
        windows: [WindowSwitcherWindowSnapshot]
    ) -> [WindowSwitcherAppEntry] {
        windows.enumerated().map { index, window in
            WindowSwitcherAppEntry(
                id: window.windowNumber.map {
                    "window:\(processIdentifier):cg:\($0)"
                } ?? "window:\(processIdentifier):ax:\(index)",
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                windowTitle: window.title.isEmpty ? nil : window.title,
                icon: icon,
                windowElement: window.element,
                isMinimized: window.isMinimized,
                windowNumber: window.windowNumber,
                windowBounds: CGRect(origin: window.position, size: window.size),
                applicationLaunchDate: applicationLaunchDate,
                shortcutToken: nil
            )
        }
    }

    private static func appEntry(for app: NSRunningApplication, id: String) -> WindowSwitcherAppEntry {
        applicationEntry(
            id: id,
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? "App",
            icon: app.icon,
            applicationLaunchDate: app.launchDate
        )
    }

    static func applicationEntry(
        id: String,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        appName: String,
        icon: NSImage?,
        applicationLaunchDate: Date? = nil
    ) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: id,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: nil,
            icon: icon,
            windowElement: nil,
            isMinimized: false,
            windowNumber: nil,
            windowBounds: nil,
            applicationLaunchDate: applicationLaunchDate,
            shortcutToken: nil
        )
    }

    private func windows(
        for app: NSRunningApplication,
        recordsForApplication: [WindowSwitcherWindowRecord],
        axDeadline: Date
    ) -> [WindowSwitcherWindowSnapshot] {
        let recordsForApp = recordsForApplication
        guard !Task.isCancelled else {
            return []
        }
        guard Date() < axDeadline else {
            return Self.coreGraphicsSnapshots(for: recordsForApp)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let axWindows = Self.copyCandidateWindows(from: appElement, deadline: axDeadline)

        var axSnapshots: [WindowSwitcherWindowSnapshot] = []
        for window in axWindows {
            guard !Task.isCancelled,
                  Date() < axDeadline
            else {
                break
            }
            if let snapshot = Self.windowSnapshot(for: window, deadline: axDeadline) {
                axSnapshots.append(snapshot)
            }
        }
        guard !Task.isCancelled else {
            return []
        }

        return Self.mergeWindowSnapshots(axSnapshots: axSnapshots, records: recordsForApp)
            .sorted { lhs, rhs in
                if lhs.isMinimized != rhs.isMinimized {
                    return !lhs.isMinimized
                }
                if lhs.position.y != rhs.position.y {
                    return lhs.position.y < rhs.position.y
                }
                if lhs.position.x != rhs.position.x {
                    return lhs.position.x < rhs.position.x
                }

                let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }

                return (lhs.windowNumber ?? 0) < (rhs.windowNumber ?? 0)
            }
    }

    private static func coreGraphicsSnapshots(
        for records: [WindowSwitcherWindowRecord]
    ) -> [WindowSwitcherWindowSnapshot] {
        records.map {
            WindowSwitcherWindowSnapshot(
                element: nil,
                windowNumber: $0.windowNumber,
                title: $0.title,
                isMinimized: false,
                position: $0.bounds.origin,
                size: $0.bounds.size
            )
        }
    }

    static func mergeWindowSnapshots(
        axSnapshots: [WindowSwitcherWindowSnapshot],
        records: [WindowSwitcherWindowRecord]
    ) -> [WindowSwitcherWindowSnapshot] {
        var axSnapshotIndicesByKey: [WindowSwitcherWindowMatchKey: Set<Int>] = [:]
        var axSnapshotIndicesByBounds: [WindowSwitcherWindowBoundsKey: Set<Int>] = [:]
        for (index, snapshot) in axSnapshots.enumerated() {
            let bounds = CGRect(origin: snapshot.position, size: snapshot.size)
            let key = WindowSwitcherWindowMatchKey(
                title: snapshot.title,
                bounds: bounds
            )
            axSnapshotIndicesByKey[key, default: []].insert(index)
            axSnapshotIndicesByBounds[WindowSwitcherWindowBoundsKey(bounds: bounds), default: []].insert(index)
        }

        var unmatchedRecordIndicesByKey: [WindowSwitcherWindowMatchKey: Set<Int>] = [:]
        var unmatchedRecordIndicesByBounds: [WindowSwitcherWindowBoundsKey: Set<Int>] = [:]
        var unmatchedOnScreenRecordCountByKey: [WindowSwitcherWindowMatchKey: Int] = [:]
        var unmatchedOnScreenRecordCountByBounds: [WindowSwitcherWindowBoundsKey: Int] = [:]
        for (index, record) in records.enumerated() {
            let key = WindowSwitcherWindowMatchKey(title: record.title, bounds: record.bounds)
            let boundsKey = WindowSwitcherWindowBoundsKey(bounds: record.bounds)
            unmatchedRecordIndicesByKey[key, default: []].insert(index)
            unmatchedRecordIndicesByBounds[boundsKey, default: []].insert(index)
            if record.isOnScreen == true {
                unmatchedOnScreenRecordCountByKey[key, default: 0] += 1
                unmatchedOnScreenRecordCountByBounds[boundsKey, default: 0] += 1
            }
        }

        var matchedAXSnapshotIndices = Array<Int?>(repeating: nil, count: records.count)
        var remainingAXSnapshotIndicesByKey = axSnapshotIndicesByKey
        var remainingAXSnapshotIndicesByBounds = axSnapshotIndicesByBounds

        for recordIndex in records.indices {
            let key = WindowSwitcherWindowMatchKey(
                title: records[recordIndex].title,
                bounds: records[recordIndex].bounds
            )
            guard let index = uniqueAXSnapshotIndex(
                in: remainingAXSnapshotIndicesByKey[key],
                forRecordAt: recordIndex,
                recordIndices: unmatchedRecordIndicesByKey[key],
                onScreenRecordCount: unmatchedOnScreenRecordCountByKey[key] ?? 0,
                records: records
            ) else {
                continue
            }

            matchedAXSnapshotIndices[recordIndex] = index
            let boundsKey = WindowSwitcherWindowBoundsKey(bounds: records[recordIndex].bounds)
            remainingAXSnapshotIndicesByKey[key]?.remove(index)
            remainingAXSnapshotIndicesByBounds[boundsKey]?.remove(index)
            unmatchedRecordIndicesByKey[key]?.remove(recordIndex)
            unmatchedRecordIndicesByBounds[boundsKey]?.remove(recordIndex)
            if records[recordIndex].isOnScreen == true {
                unmatchedOnScreenRecordCountByKey[key, default: 0] -= 1
                unmatchedOnScreenRecordCountByBounds[boundsKey, default: 0] -= 1
            }
        }

        for recordIndex in records.indices where matchedAXSnapshotIndices[recordIndex] == nil {
            let record = records[recordIndex]
            let boundsKey = WindowSwitcherWindowBoundsKey(bounds: record.bounds)
            guard let candidateIndex = uniqueAXSnapshotIndex(
                in: remainingAXSnapshotIndicesByBounds[boundsKey],
                forRecordAt: recordIndex,
                recordIndices: unmatchedRecordIndicesByBounds[boundsKey],
                onScreenRecordCount: unmatchedOnScreenRecordCountByBounds[boundsKey] ?? 0,
                records: records
            ),
            record.title.isEmpty || axSnapshots[candidateIndex].title.isEmpty
            else {
                continue
            }

            matchedAXSnapshotIndices[recordIndex] = candidateIndex
            remainingAXSnapshotIndicesByBounds[boundsKey]?.remove(candidateIndex)
            unmatchedRecordIndicesByBounds[boundsKey]?.remove(recordIndex)
            if record.isOnScreen == true {
                unmatchedOnScreenRecordCountByBounds[boundsKey, default: 0] -= 1
            }
        }

        var merged: [WindowSwitcherWindowSnapshot] = []
        for (recordIndex, record) in records.enumerated() {
            if let index = matchedAXSnapshotIndices[recordIndex] {
                let snapshot = axSnapshots[index]
                merged.append(
                    WindowSwitcherWindowSnapshot(
                        element: snapshot.element,
                        windowNumber: record.windowNumber,
                        title: snapshot.title,
                        isMinimized: snapshot.isMinimized,
                        position: snapshot.position,
                        size: snapshot.size
                    )
                )
                continue
            }

            merged.append(
                WindowSwitcherWindowSnapshot(
                    element: nil,
                    windowNumber: record.windowNumber,
                    title: record.title,
                    isMinimized: false,
                    position: record.bounds.origin,
                    size: record.bounds.size
                )
            )
        }

        for boundsKey in remainingAXSnapshotIndicesByBounds.keys {
            guard let candidateIndices = remainingAXSnapshotIndicesByBounds[boundsKey],
                  !candidateIndices.isEmpty
            else {
                continue
            }

            let recordIndices = unmatchedRecordIndicesByBounds[boundsKey] ?? []
            let axOnlyIndices = Self.axOnlySnapshotIndices(
                candidateIndices: candidateIndices,
                recordIndices: recordIndices,
                axSnapshots: axSnapshots,
                records: records
            )
            for index in axOnlyIndices {
                merged.append(axSnapshots[index])
            }
        }

        return merged
    }

    private static func axOnlySnapshotIndices(
        candidateIndices: Set<Int>,
        recordIndices: Set<Int>,
        axSnapshots: [WindowSwitcherWindowSnapshot],
        records: [WindowSwitcherWindowRecord]
    ) -> [Int] {
        let sortedCandidateIndices = candidateIndices.sorted()
        guard !recordIndices.isEmpty else {
            return sortedCandidateIndices
        }

        var axTitleCounts: [String: Int] = [:]
        var titlelessAXCount = 0
        for index in candidateIndices {
            let title = axSnapshots[index].title
            if title.isEmpty {
                titlelessAXCount += 1
            } else {
                axTitleCounts[title, default: 0] += 1
            }
        }

        var recordTitleCounts: [String: Int] = [:]
        var titlelessRecordCount = 0
        for index in recordIndices {
            let title = records[index].title
            if title.isEmpty {
                titlelessRecordCount += 1
            } else {
                recordTitleCounts[title, default: 0] += 1
            }
        }

        let exactMatchCount = axTitleCounts.reduce(into: 0) { count, pair in
            count += min(pair.value, recordTitleCounts[pair.key] ?? 0)
        }
        let remainingAXCount = candidateIndices.count - exactMatchCount
        let remainingRecordCount = recordIndices.count - exactMatchCount
        let wildcardMatchCount: Int
        if titlelessAXCount > 0 && titlelessRecordCount > 0 {
            wildcardMatchCount = min(remainingAXCount, remainingRecordCount)
        } else if titlelessAXCount > 0 {
            wildcardMatchCount = min(titlelessAXCount, remainingRecordCount)
        } else if titlelessRecordCount > 0 {
            wildcardMatchCount = min(remainingAXCount, titlelessRecordCount)
        } else {
            wildcardMatchCount = 0
        }
        let maximumCompatibleCount = exactMatchCount + wildcardMatchCount
        let maximumAXOnlyCount = max(0, candidateIndices.count - maximumCompatibleCount)
        guard maximumAXOnlyCount > 0 else {
            return []
        }

        var residualRecordTitleCounts = recordTitleCounts
        for (title, candidateCount) in axTitleCounts {
            residualRecordTitleCounts[title] = max(
                0,
                (residualRecordTitleCounts[title] ?? 0) - candidateCount
            )
        }

        var forcedAXOnlyIndices: [Int] = []
        var compatibleIndices: [Int] = []
        for index in sortedCandidateIndices {
            let title = axSnapshots[index].title
            let canMatchResidualRecord = title.isEmpty
                || titlelessRecordCount > 0
                || (residualRecordTitleCounts[title] ?? 0) > 0
            if canMatchResidualRecord {
                compatibleIndices.append(index)
            } else {
                forcedAXOnlyIndices.append(index)
            }
        }

        return Array((forcedAXOnlyIndices + compatibleIndices).prefix(maximumAXOnlyCount))
    }

    private static func uniqueAXSnapshotIndex(
        in candidateIndices: Set<Int>?,
        forRecordAt recordIndex: Int,
        recordIndices: Set<Int>?,
        onScreenRecordCount: Int,
        records: [WindowSwitcherWindowRecord]
    ) -> Int? {
        guard let candidateIndices,
              candidateIndices.count == 1,
              let candidateIndex = candidateIndices.first,
              let recordIndices,
              recordIndices.contains(recordIndex)
        else {
            return nil
        }

        guard recordIndices.count > 1 else {
            return candidateIndex
        }

        guard onScreenRecordCount == 1,
              records[recordIndex].isOnScreen == true
        else {
            return nil
        }

        return candidateIndex
    }

    private static func matches(
        _ snapshot: WindowSwitcherWindowSnapshot,
        title: String?,
        bounds: CGRect
    ) -> Bool {
        guard snapshot.position == bounds.origin,
              snapshot.size == bounds.size
        else {
            return false
        }

        guard let title, !title.isEmpty else {
            return true
        }

        return snapshot.title == title
    }

    static func axTimeout(forRemaining remaining: TimeInterval) -> Float? {
        guard remaining > 0 else {
            return nil
        }

        return min(axTimeout, Float(remaining))
    }

    private static func setAXMessagingTimeout(
        on element: AXUIElement,
        deadline: Date?
    ) -> Bool {
        guard let deadline else {
            return AXUIElementSetMessagingTimeout(element, axTimeout) == .success
        }

        guard let timeout = axTimeout(forRemaining: deadline.timeIntervalSinceNow) else {
            return false
        }

        return AXUIElementSetMessagingTimeout(element, timeout) == .success
    }

    private static func copyWindows(
        from appElement: AXUIElement,
        deadline: Date? = nil
    ) -> [AXUIElement] {
        guard setAXMessagingTimeout(on: appElement, deadline: deadline) else {
            return []
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success,
              let windows = value as? [AXUIElement]
        else {
            return []
        }

        return windows
    }

    private static func copyCandidateWindows(
        from appElement: AXUIElement,
        deadline: Date? = nil
    ) -> [AXUIElement] {
        var windows = copyWindows(from: appElement, deadline: deadline)
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard deadline.map({ Date() < $0 }) ?? true else {
                break
            }

            if let window = copyWindowAttribute(
                appElement,
                attribute as String,
                deadline: deadline
            ) {
                appendUnique(window, to: &windows)
            }
        }
        return windows
    }

    private static func windowSnapshot(
        for window: AXUIElement,
        deadline: Date? = nil
    ) -> WindowSwitcherWindowSnapshot? {
        guard setAXMessagingTimeout(on: window, deadline: deadline) else {
            return nil
        }

        let attributes = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXMinimizedAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
        ] as CFArray
        var rawValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard result == .success,
              let values = rawValues as? [Any],
              values.count == 6,
              isUserFacingWindow(role: values[0] as? String, subrole: values[1] as? String)
        else {
            return nil
        }

        let isMinimized = (values[3] as? Bool) ?? false
        let size = decodeSize(values[5])
        guard isMinimized || isSwitchableWindowSize(size) else {
            return nil
        }

        return WindowSwitcherWindowSnapshot(
            element: window,
            windowNumber: nil,
            title: values[2] as? String ?? "",
            isMinimized: isMinimized,
            position: decodePoint(values[4]),
            size: size
        )
    }

    private static func isUserFacingWindow(role: String?, subrole: String?) -> Bool {
        guard role == (kAXWindowRole as String) else {
            return false
        }

        guard let subrole else {
            return true
        }

        return subrole == (kAXStandardWindowSubrole as String)
            || subrole == (kAXDialogSubrole as String)
            || subrole == "AXFullScreenWindow"
    }

    private static func isSwitchableWindowSize(_ size: CGSize) -> Bool {
        size.width >= WindowSwitcherWindowRecord.minimumWindowSize.width
            && size.height >= WindowSwitcherWindowRecord.minimumWindowSize.height
    }

    private static func decodePoint(_ value: Any) -> CGPoint {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return .zero
        }

        var point = CGPoint.zero
        AXValueGetValue(cfValue as! AXValue, .cgPoint, &point)
        return point
    }

    private static func decodeSize(_ value: Any) -> CGSize {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return .zero
        }

        var size = CGSize.zero
        AXValueGetValue(cfValue as! AXValue, .cgSize, &size)
        return size
    }

    private static func copyWindowAttribute(
        _ appElement: AXUIElement,
        _ attribute: String,
        deadline: Date? = nil
    ) -> AXUIElement? {
        guard setAXMessagingTimeout(on: appElement, deadline: deadline) else {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func windowSnapshot(
        for app: WindowSwitcherApplicationControlling,
        matching entry: WindowSwitcherAppEntry,
        deadline: Date
    ) -> WindowSwitcherWindowSnapshot? {
        guard let bounds = entry.windowBounds else {
            return nil
        }

        if let activationWindowSnapshotProvider {
            return activationWindowSnapshotProvider(app.processIdentifier, entry)
        }

        guard let app = app as? NSRunningApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = Self.copyCandidateWindows(from: appElement, deadline: deadline)

        return Self.firstMatchingWindow(
            in: windows,
            title: entry.windowTitle,
            bounds: bounds,
            deadline: deadline,
            now: { Date() },
            snapshotProvider: { window in
                Self.windowSnapshot(for: window, deadline: deadline)
            }
        )
    }

    static func firstMatchingWindow(
        in windows: [AXUIElement],
        title: String?,
        bounds: CGRect,
        deadline: Date,
        now: () -> Date,
        snapshotProvider: (AXUIElement) -> WindowSwitcherWindowSnapshot?
    ) -> WindowSwitcherWindowSnapshot? {
        var matchingSnapshot: WindowSwitcherWindowSnapshot?
        for window in windows {
            guard !Task.isCancelled,
                  now() < deadline
            else {
                return nil
            }

            guard let snapshot = snapshotProvider(window),
                  Self.matches(snapshot, title: title, bounds: bounds)
            else {
                continue
            }

            guard matchingSnapshot == nil else {
                return nil
            }

            matchingSnapshot = snapshot
        }

        return matchingSnapshot
    }

    private func focusWindow(
        _ window: AXUIElement,
        isMinimized: Bool,
        deadline: Date
    ) {
        if let focusWindowHandler {
            focusWindowHandler(window, isMinimized)
        } else {
            Self.focusWindow(window, isMinimized: isMinimized, deadline: deadline)
        }
    }

    private static func focusWindow(
        _ window: AXUIElement,
        isMinimized: Bool,
        deadline: Date
    ) {
        focusWindow(
            window,
            isMinimized: isMinimized,
            deadline: deadline,
            writeAttribute: setAXAttributeValue,
            performRaise: { element, deadline in
                guard !Task.isCancelled,
                      setAXMessagingTimeout(on: element, deadline: deadline)
                else {
                    return false
                }

                return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
            }
        )
    }

    static func focusWindow(
        _ window: AXUIElement,
        isMinimized: Bool,
        deadline: Date,
        writeAttribute: (AXUIElement, CFString, CFTypeRef, Date) -> Bool,
        performRaise: (AXUIElement, Date) -> Bool
    ) {
        if isMinimized {
            guard writeAttribute(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse,
                deadline
            ) else {
                return
            }
        }

        _ = writeAttribute(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue,
            deadline
        )
        guard !Task.isCancelled, Date() < deadline else {
            return
        }

        _ = writeAttribute(
            window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue,
            deadline
        )
        guard !Task.isCancelled, Date() < deadline else {
            return
        }

        _ = performRaise(window, deadline)
    }

    private static func setAXAttributeValue(
        _ element: AXUIElement,
        _ attribute: CFString,
        value: CFTypeRef,
        deadline: Date
    ) -> Bool {
        guard !Task.isCancelled,
              setAXMessagingTimeout(on: element, deadline: deadline)
        else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private static func appendUnique(_ window: AXUIElement, to windows: inout [AXUIElement]) {
        guard !windows.contains(where: { CFEqual($0, window) }) else {
            return
        }

        windows.append(window)
    }

    private static func isCurrentApplication(
        _ app: WindowSwitcherApplicationControlling,
        for entry: WindowSwitcherAppEntry
    ) -> Bool {
        guard app.processIdentifier == entry.processIdentifier,
              !app.isTerminated
        else {
            return false
        }

        if let currentLaunchDate = app.launchDate,
           let expectedLaunchDate = entry.applicationLaunchDate,
           currentLaunchDate != expectedLaunchDate {
            return false
        }

        guard let expectedBundleIdentifier = entry.bundleIdentifier,
              !expectedBundleIdentifier.isEmpty
        else {
            return true
        }

        return app.bundleIdentifier == expectedBundleIdentifier
    }

    nonisolated private static func identifier(for app: NSRunningApplication) -> String {
        if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(app.processIdentifier)"
    }

    nonisolated private static func identifier(for entry: WindowSwitcherAppEntry) -> String {
        if let bundleIdentifier = entry.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(entry.processIdentifier)"
    }

    nonisolated private static func isUserFacingApplication(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return false
        }

        if let hostBundleID = Bundle.main.bundleIdentifier,
           app.bundleIdentifier == hostBundleID {
            return false
        }

        return true
    }
}
