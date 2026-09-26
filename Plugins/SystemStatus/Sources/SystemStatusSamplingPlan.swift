import Foundation

struct SystemStatusSamplingSchedule: Sendable {
    let backgroundFastInterval: Duration
    let menuBarFastInterval: Duration
    let foregroundFastInterval: Duration
    let backgroundSlowInterval: TimeInterval
    let menuBarSlowInterval: TimeInterval
    let foregroundSlowInterval: TimeInterval
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
        foregroundProcessInterval: 3,
        backgroundHistoryInterval: 300,
        foregroundHistoryInterval: 60
    )
}

struct SystemStatusSamplingPlan: Equatable, Sendable {
    let intervals: [SystemStatusSamplingDemand: TimeInterval]

    var demand: SystemStatusSamplingDemand { intervals.keys.reduce(into: .init()) { $0.formUnion($1) } }

    init(background: SystemStatusSamplingDemand, menuBar: SystemStatusSamplingDemand,
         foreground: SystemStatusSamplingDemand, schedule: SystemStatusSamplingSchedule) {
        var intervals: [SystemStatusSamplingDemand: TimeInterval] = [:]
        for source in SystemStatusSamplingDemand.sources {
            var interval = TimeInterval.infinity
            let fast = source.needsFast
            if background.contains(source) {
                interval = fast ? schedule.backgroundFastInterval.timeInterval : schedule.backgroundSlowInterval
            }
            if menuBar.contains(source) {
                interval = min(interval, fast ? schedule.menuBarFastInterval.timeInterval : schedule.menuBarSlowInterval)
            }
            if foreground.contains(source) {
                let visible = source == .processes ? schedule.foregroundProcessInterval
                    : fast ? schedule.foregroundFastInterval.timeInterval : schedule.foregroundSlowInterval
                interval = min(interval, visible)
            }
            if interval.isFinite { intervals[source] = max(0.01, interval) }
        }
        // Both GPU values must refer to the same selected device. The registry
        // enumeration is shared, so refreshing them together adds no enumeration.
        if let usage = intervals[.gpuUsage], let temperature = intervals[.gpuTemperature] {
            intervals[.gpuUsage] = min(usage, temperature)
            intervals[.gpuTemperature] = min(usage, temperature)
        }
        self.intervals = intervals
    }

    func due(at uptime: TimeInterval, lastSamples: [SystemStatusSamplingDemand: TimeInterval]) -> SystemStatusSamplingDemand {
        var due = intervals.reduce(into: SystemStatusSamplingDemand()) { due, entry in
            if lastSamples[entry.key].map({ uptime - $0 >= entry.value }) ?? true { due.insert(entry.key) }
        }
        // A newly enabled temperature reader must use the same GPU selection as usage,
        // even if the usage deadline has not arrived yet.
        if demand.contains(.gpu), !due.intersection(.gpu).isEmpty { due.formUnion(.gpu) }
        return due
    }

    func delay(at uptime: TimeInterval, lastSamples: [SystemStatusSamplingDemand: TimeInterval]) -> TimeInterval {
        let next = intervals.map { source, interval in (lastSamples[source] ?? uptime - interval) + interval - uptime }.min()
        return max(0.01, next ?? 300)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
