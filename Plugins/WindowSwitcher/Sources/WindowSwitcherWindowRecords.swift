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

struct WindowSwitcherWindowRecordSnapshot: Sendable {
    let records: [WindowSwitcherWindowRecord]
    let isFresh: Bool
}

/// The all-Spaces CG reader is kept separate from AX discovery and actions.
/// Slow system reads are bounded and stale data can never authorize an action.
@MainActor
final class WindowSwitcherWindowRecords {
    private static let maxWindowRecordRefreshesInFlight = 2
    private let windowRecordProvider: @Sendable () -> [WindowSwitcherWindowRecord]?
    private let windowRecordRefreshTimeout: TimeInterval
    private var windowRecords: [WindowSwitcherWindowRecord] = []
    private var windowRecordRefreshTask: Task<[WindowSwitcherWindowRecord]?, Never>?
    private var windowRecordRefreshGeneration: UInt64 = 0
    private var windowRecordRefreshLastCompletedGeneration: UInt64?
    private var windowRecordRefreshInFlightCount = 0

    init(windowRecordRefreshTimeout: TimeInterval = 0.75,
         windowRecordProvider: @escaping @Sendable () -> [WindowSwitcherWindowRecord]? = {
             guard let info = CGWindowListCopyWindowInfo(
                 [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
             return WindowSwitcherWindowRecord.parse(info)
         }) {
        self.windowRecordRefreshTimeout = windowRecordRefreshTimeout.isFinite ? max(0, windowRecordRefreshTimeout) : 0.75
        self.windowRecordProvider = windowRecordProvider
    }

    func stop() {
        windowRecordRefreshGeneration &+= 1
        windowRecordRefreshTask?.cancel()
        windowRecordRefreshTask = nil
        windowRecordRefreshLastCompletedGeneration = nil
        windowRecords.removeAll()
    }

    func windowRecordsSnapshot() async -> [WindowSwitcherWindowRecord] {
        await freshWindowRecords()
    }

    func freshRecordsForActivation() async -> [WindowSwitcherWindowRecord] {
        let snapshot = await freshWindowRecordSnapshot()
        return snapshot.isFresh && !Task.isCancelled ? snapshot.records : []
    }

    func isCurrentFallback(_ entry: WindowSwitcherAppEntry) async -> Bool {
        let snapshot = await freshWindowRecordSnapshot()
        return !Task.isCancelled && snapshot.isFresh && currentWindowRecord(for: entry, in: snapshot.records) != nil
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
            // Failure is not a successful empty scan. Retain the last snapshot
            // for presentation, but never mark it fresh enough for an action.
            if let records {
                self.windowRecordRefreshLastCompletedGeneration = generation
                self.windowRecords = records
            } else {
                self.windowRecordRefreshLastCompletedGeneration = nil
            }
        }
    }

    private func freshWindowRecords() async -> [WindowSwitcherWindowRecord] {
        await freshWindowRecordSnapshot().records
    }

    func freshWindowRecordSnapshot() async -> WindowSwitcherWindowRecordSnapshot {
        refreshWindowRecords()
        guard windowRecordRefreshTask != nil else {
            return WindowSwitcherWindowRecordSnapshot(records: windowRecords, isFresh: false)
        }
        let generation = windowRecordRefreshGeneration
        let refreshDeadline = ContinuousClock.now + .seconds(windowRecordRefreshTimeout)

        while windowRecordRefreshTask != nil,
              windowRecordRefreshGeneration == generation {
            guard !Task.isCancelled,
                  ContinuousClock.now < refreshDeadline
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

}
