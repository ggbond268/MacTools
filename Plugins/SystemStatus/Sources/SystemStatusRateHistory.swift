import Foundation

struct SystemStatusSampleInterval: Equatable, Sendable {
    let endTimestamp: TimeInterval
    let duration: TimeInterval
    // CPU weights by total native ticks; byte rates weight by elapsed seconds.
    var counterWeight: Double? = nil
}

// Counter-derived readings describe the preceding interval, not an instantaneous
// value. Preserve their integral when minute buckets discard individual points.
struct SystemStatusRateAggregate: Codable, Equatable, Sendable {
    let startTimestamp: TimeInterval
    let endTimestamp: TimeInterval
    let duration: TimeInterval
    let counterWeight: Double?
    let integral: Double
    let minimum: Double
    let maximum: Double

    init?(value: Double?, interval: SystemStatusSampleInterval?) {
        guard let value, let interval, value.isFinite, value >= 0,
              interval.endTimestamp.isFinite, interval.duration.isFinite, interval.duration > 0 else { return nil }
        let weight = interval.counterWeight ?? interval.duration
        guard weight.isFinite, weight > 0 else { return nil }
        self.init(startTimestamp: interval.endTimestamp - interval.duration,
            endTimestamp: interval.endTimestamp, duration: interval.duration,
            counterWeight: interval.counterWeight, integral: value * weight, minimum: value, maximum: value)
    }

    private init(startTimestamp: TimeInterval, endTimestamp: TimeInterval, duration: TimeInterval,
                 counterWeight: Double?, integral: Double, minimum: Double, maximum: Double) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.duration = duration
        self.counterWeight = counterWeight
        self.integral = integral
        self.minimum = minimum
        self.maximum = maximum
    }

    var weight: Double { counterWeight ?? duration }

    var isValid: Bool {
        [startTimestamp, endTimestamp, duration, weight, integral, minimum, maximum].allSatisfy(\.isFinite)
            && endTimestamp > startTimestamp && duration > 0
            && weight > 0
            && duration <= endTimestamp - startTimestamp + 0.001
            && integral >= 0 && minimum >= 0 && maximum >= minimum
    }

    func merging(_ next: Self) -> Self {
        guard next.isValid else { return self }
        guard isValid else { return next }
        // Repeated snapshots and overlapping archives must not count a window twice.
        guard next.endTimestamp > endTimestamp,
              next.startTimestamp >= endTimestamp - 0.001 else { return self }
        return Self(startTimestamp: startTimestamp, endTimestamp: next.endTimestamp,
            duration: duration + next.duration,
            counterWeight: counterWeight == nil && next.counterWeight == nil ? nil : weight + next.weight,
            integral: integral + next.integral,
            minimum: min(minimum, next.minimum), maximum: max(maximum, next.maximum))
    }
}

struct SystemStatusHistoryRates: Codable, Equatable, Sendable {
    var cpu: SystemStatusRateAggregate?
    var disk: SystemStatusRateAggregate?
    var network: SystemStatusRateAggregate?

    var isEmpty: Bool { cpu == nil && disk == nil && network == nil }

    init(cpu: SystemStatusRateAggregate? = nil, disk: SystemStatusRateAggregate? = nil,
         network: SystemStatusRateAggregate? = nil) {
        self.cpu = cpu
        self.disk = disk
        self.network = network
    }

    init(snapshot: SystemStatusSnapshot, sampled: SystemStatusSamplingDemand) {
        cpu = sampled.contains(.cpuUsage)
            ? .init(value: snapshot.cpu.usage.map { $0 * 100 }, interval: snapshot.cpu.usageInterval) : nil
        disk = sampled.contains(.diskActivity)
            ? .init(value: SystemStatusChartMetric.activity.value(in: snapshot, kind: .disk),
                interval: snapshot.disk.activityInterval) : nil
        network = sampled.contains(.network)
            ? .init(value: SystemStatusChartMetric.activity.value(in: snapshot, kind: .network),
                interval: snapshot.network.activityInterval) : nil
    }

    func value(for kind: SystemStatusMetricKind) -> SystemStatusRateAggregate? {
        switch kind {
        case .cpu: cpu
        case .disk: disk
        case .network: network
        default: nil
        }
    }

    mutating func merge(_ next: Self?) {
        guard let next else { return }
        func merged(_ old: SystemStatusRateAggregate?, _ new: SystemStatusRateAggregate?) -> SystemStatusRateAggregate? {
            guard let new, new.isValid else { return old }
            return old?.merging(new) ?? new
        }
        cpu = merged(cpu, next.cpu)
        disk = merged(disk, next.disk)
        network = merged(network, next.network)
    }
}
