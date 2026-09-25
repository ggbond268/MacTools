import Darwin
import Foundation

struct SystemStatusPowerEnergySample: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        let joules: Double
        let sourceUptime: TimeInterval?
    }

    let uptime: TimeInterval
    let channels: [String: Channel]

    var joules: Double { channels.values.reduce(0) { $0 + $1.joules } }
    var channelNames: Set<String> { Set(channels.keys) }
}

final class SystemStatusCPUPowerReader {
    private let functions: IOReportFunctions?
    private let channels: CFMutableDictionary?
    private let subscription: OpaquePointer?

    init() {
        guard
            let functions = IOReportFunctions(),
            let baseChannels = functions.copyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
            let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, baseChannels)
        else {
            self.functions = nil
            self.channels = nil
            self.subscription = nil
            return
        }

        var subscriptionChannels: Unmanaged<CFMutableDictionary>?
        self.functions = functions
        self.channels = channels
        self.subscription = functions.createSubscription(nil, channels, &subscriptionChannels, 0, nil)
        subscriptionChannels?.release()
    }

    deinit {
        // IOReport subscriptions are retained CF objects and own a Mach port.
        // Release the subscription while its dynamically loaded code is alive.
        if let subscription {
            Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(subscription)).release()
        }
    }

    func readCPUEnergySample() -> SystemStatusPowerEnergySample? {
        guard
            let functions,
            let channels,
            let subscription,
            let sample = functions.createSamples(subscription, channels, nil)?.takeRetainedValue(),
            let sampleDictionary = sample as? [String: Any],
            let rawItems = sampleDictionary["IOReportChannels"]
        else {
            return nil
        }

        let rawItemsReference = rawItems as CFTypeRef
        guard CFGetTypeID(rawItemsReference) == CFArrayGetTypeID() else {
            return nil
        }
        let items = unsafeDowncast(rawItemsReference, to: CFArray.self)
        var energyByChannel: [String: Double] = [:]
        var sourceUptimes: [String: TimeInterval] = [:]
        for index in 0..<CFArrayGetCount(items) {
            let rawItem = CFArrayGetValueAtIndex(items, index)
            let itemReference = unsafeBitCast(rawItem, to: CFTypeRef.self)
            guard CFGetTypeID(itemReference) == CFDictionaryGetTypeID() else {
                continue
            }
            let item = unsafeDowncast(itemReference, to: CFDictionary.self)
            guard
                let group = functions.channelGetGroup(item)?.takeUnretainedValue() as String?,
                group == "Energy Model",
                let channelName = functions.channelGetChannelName(item)?.takeUnretainedValue() as String?,
                channelName.hasSuffix("CPU Energy"),
                let unit = functions.channelGetUnitLabel(item)?.takeUnretainedValue() as String?,
                let joules = SystemStatusPowerNormalizer.energyJoules(
                    from: Double(functions.simpleGetIntegerValue(item, 0)),
                    unit: unit
                )
            else {
                continue
            }

            energyByChannel[channelName] = joules
            sourceUptimes[channelName] = Self.channelUptime(rawElements: (item as NSDictionary)["RawElements"] as? Data)
        }

        return Self.cpuEnergySample(
            channels: energyByChannel, uptime: ProcessInfo.processInfo.systemUptime, sourceUptimes: sourceUptimes
        )
    }

    static func cpuEnergySample(
        channels: [String: Double], uptime: TimeInterval, sourceUptimes: [String: TimeInterval] = [:]
    ) -> SystemStatusPowerEnergySample? {
        // Ultra chips expose one CPU Energy channel per die. Prefer a package
        // total if present; otherwise sum the die channels without double counting.
        let selected = channels["CPU Energy"].map { ["CPU Energy": $0] }
            ?? channels.filter { $0.key.hasSuffix("CPU Energy") }
        guard !selected.isEmpty, selected.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return SystemStatusPowerEnergySample(
            uptime: uptime,
            channels: Dictionary(uniqueKeysWithValues: selected.map { name, joules in
                (name, .init(joules: joules, sourceUptime: sourceUptimes[name]))
            })
        )
    }

    static func channelUptime(rawElements: Data?) -> TimeInterval? {
        // Apple's packed IOReportElement is 64 bytes: the simple format is at
        // offset 16 and its mach_absolute_time timestamp is at offset 24.
        // Unknown layouts keep the collection-time fallback; zero energy alone
        // is not evidence of a stalled driver.
        guard let rawElements, rawElements.count == 64, let secondsPerTick else { return nil }
        return rawElements.withUnsafeBytes { bytes in
            guard bytes[16] == 1,
                  bytes.loadUnaligned(fromByteOffset: 20, as: UInt16.self) == 1,
                  bytes.loadUnaligned(fromByteOffset: 22, as: Int16.self) == 0 else { return nil }
            let timestamp = bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            return timestamp > 0 ? Double(timestamp) * secondsPerTick : nil
        }
    }

    private static let secondsPerTick: Double? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return nil }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}

private final class IOReportFunctions {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary?,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        CFTypeRef?
    ) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    let handle: UnsafeMutableRawPointer
    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let channelGetGroup: ChannelString
    let channelGetChannelName: ChannelString
    let channelGetUnitLabel: ChannelString
    let simpleGetIntegerValue: SimpleGetIntegerValue

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        guard
            let copyChannelsInGroup = Self.loadFunction(
                named: "IOReportCopyChannelsInGroup",
                from: handle,
                as: CopyChannelsInGroup.self
            ),
            let createSubscription = Self.loadFunction(
                named: "IOReportCreateSubscription",
                from: handle,
                as: CreateSubscription.self
            ),
            let createSamples = Self.loadFunction(
                named: "IOReportCreateSamples",
                from: handle,
                as: CreateSamples.self
            ),
            let channelGetGroup = Self.loadFunction(
                named: "IOReportChannelGetGroup",
                from: handle,
                as: ChannelString.self
            ),
            let channelGetChannelName = Self.loadFunction(
                named: "IOReportChannelGetChannelName",
                from: handle,
                as: ChannelString.self
            ),
            let channelGetUnitLabel = Self.loadFunction(
                named: "IOReportChannelGetUnitLabel",
                from: handle,
                as: ChannelString.self
            ),
            let simpleGetIntegerValue = Self.loadFunction(
                named: "IOReportSimpleGetIntegerValue",
                from: handle,
                as: SimpleGetIntegerValue.self
            )
        else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.channelGetGroup = channelGetGroup
        self.channelGetChannelName = channelGetChannelName
        self.channelGetUnitLabel = channelGetUnitLabel
        self.simpleGetIntegerValue = simpleGetIntegerValue
    }

    deinit {
        dlclose(handle)
    }

    private static func loadFunction<T>(named name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(symbol, to: type)
    }
}
