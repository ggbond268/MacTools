import Darwin
import Foundation

struct SystemStatusPowerEnergySample: Equatable, Sendable {
    let joules: Double
    let date: Date
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

    func readCPUEnergySample(referenceDate: Date) -> SystemStatusPowerEnergySample? {
        guard
            let functions,
            let channels,
            let sample = functions.createSamples(subscription, channels, nil)?.takeRetainedValue(),
            let sampleDictionary = sample as? [String: Any],
            let rawItems = sampleDictionary["IOReportChannels"]
        else {
            return nil
        }

        let items = rawItems as! CFArray
        var cpuEnergyJoules: Double?
        for index in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, index), to: CFDictionary.self)
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

            cpuEnergyJoules = joules
        }

        guard let cpuEnergyJoules else {
            return nil
        }

        return SystemStatusPowerEnergySample(joules: cpuEnergyJoules, date: referenceDate)
    }
}

private struct IOReportFunctions {
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
        guard
            let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY),
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

    private static func loadFunction<T>(named name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(symbol, to: type)
    }
}
