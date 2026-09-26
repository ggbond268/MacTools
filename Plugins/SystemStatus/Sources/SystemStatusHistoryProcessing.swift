import Foundation

// Share retention and compaction between the live history and the disk archive.
// Keep real peak observations and availability/session boundaries at their timestamps.
enum SystemStatusHistoryProcessing {
    static func pruned(_ points: [SystemStatusHistoryPoint], referenceDate: Date,
                       highResolutionInterval: TimeInterval = 30 * 60, sorted: Bool = false) -> [SystemStatusHistoryPoint] {
        let cutoff = referenceDate.timeIntervalSince1970 - SystemStatusHistoryStore.retention
        let upper = referenceDate.timeIntervalSince1970 + 60
        let retained = points.filter { $0.timestamp.isFinite && $0.timestamp >= cutoff && $0.timestamp <= upper }
        let ordered = sorted ? retained : retained.sorted { $0.timestamp < $1.timestamp }
        let highResolutionCutoff = referenceDate.timeIntervalSince1970 - highResolutionInterval
        var output: [SystemStatusHistoryPoint] = []
        output.reserveCapacity(min(ordered.count, SystemStatusHistoryStore.maximumSampleCount))
        var last: SystemStatusHistoryPoint?
        var minimum: SystemStatusHistoryPoint?
        var maximum: SystemStatusHistoryPoint?
        var boundary: SystemStatusHistoryPoint?
        var rates = SystemStatusHistoryRates()
        func flush() {
            let selected = [boundary, minimum, maximum, last].compactMap { $0 }.sorted { $0.timestamp < $1.timestamp }
            for var point in selected where output.last?.timestamp != point.timestamp {
                // The final retained point owns the bucket's interval integrals.
                // Pressure extrema must not duplicate the same rate observations.
                point.rates = point.timestamp == last?.timestamp && !rates.isEmpty ? rates : nil
                output.append(point)
            }
        }
        for point in ordered {
            guard point.timestamp < highResolutionCutoff else {
                flush(); last = nil; minimum = nil; maximum = nil; boundary = nil
                rates = SystemStatusHistoryRates()
                output.append(point)
                continue
            }
            let sharesBucket = last.map {
                floor($0.timestamp / 60) == floor(point.timestamp / 60)
                    && $0.collectionID == point.collectionID && $0.availability == point.availability
                    && $0.memoryPressure == point.memoryPressure
                    && ($0.validMemoryPressurePercent != nil) == (point.validMemoryPressurePercent != nil)
            } ?? false
            if !sharesBucket {
                flush()
                rates = SystemStatusHistoryRates()
                minimum = nil; maximum = nil
                boundary = last == nil || last?.collectionID != point.collectionID || last?.availability != point.availability
                    || last?.memoryPressure != point.memoryPressure
                    || (last?.validMemoryPressurePercent != nil) != (point.validMemoryPressurePercent != nil)
                    ? point : nil
            }
            if let value = point.validMemoryPressurePercent {
                if value < (minimum?.validMemoryPressurePercent ?? .infinity) { minimum = point }
                if value > (maximum?.validMemoryPressurePercent ?? -.infinity) { maximum = point }
            }
            rates.merge(point.rates)
            last = point
        }
        flush()
        // Preserve the first observation after a boundary even within one bucket.
        return Array(output.suffix(SystemStatusHistoryStore.maximumSampleCount))
    }
}

extension SystemStatusHistoryPoint {
    var availability: SystemStatusSamplingDemand {
        var result = SystemStatusSamplingDemand()
        if cpuUsage != nil { result.insert(.cpuUsage) }
        if cpuTemperatureCelsius != nil { result.insert(.cpuTemperature) }
        if cpuPowerWatts != nil { result.insert(.cpuPower) }
        if cpuLoadAverage1Minute != nil { result.insert(.cpuLoad) }
        if gpuUsage != nil { result.insert(.gpuUsage) }
        if gpuTemperatureCelsius != nil { result.insert(.gpuTemperature) }
        if memoryUsage != nil || memoryUsedBytes != nil { result.insert(.memoryUsage) }
        if memoryPressure != nil || validMemoryPressurePercent != nil { result.insert(.memoryPressure) }
        if memorySwapUsedBytes != nil { result.insert(.swap) }
        if diskUsage != nil || diskFreeBytes != nil { result.insert(.diskCapacity) }
        if diskReadBytesPerSecond != nil || diskWriteBytesPerSecond != nil { result.insert(.diskActivity) }
        if networkDownloadBytesPerSecond != nil || networkUploadBytesPerSecond != nil { result.insert(.network) }
        if batteryLevel != nil { result.insert(.battery) }
        if batteryPowerWatts != nil || batteryTemperatureCelsius != nil { result.insert(.batteryDetails) }
        return result
    }
}
