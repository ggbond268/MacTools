import CoreAudio
import CoreWLAN
import Foundation
import IOKit.ps

// The volume reads, the CoreAudio helpers, and the Wi-Fi classification inputs
// are adapted from Status Trio (https://github.com/lingyired/status-trio,
// Apache-2.0). AirPods battery, output-device enumeration, and SSID lookups are
// intentionally absent.

/// Reduces an `NWPath` to the fields the snapshot and the Wi-Fi classifier need.
struct DuoNetworkPathSnapshot: Equatable, Sendable {
    var status: DuoSystemStatusSnapshot.Network
    var usesWiFi: Bool
    var usesWiredEthernet: Bool
    var isExpensive: Bool

    init(
        status: DuoSystemStatusSnapshot.Network = .unknown,
        usesWiFi: Bool = false,
        usesWiredEthernet: Bool = false,
        isExpensive: Bool = false
    ) {
        self.status = status
        self.usesWiFi = usesWiFi
        self.usesWiredEthernet = usesWiredEthernet
        self.isExpensive = isExpensive
    }

    var isSatisfied: Bool { status == .connected }

    /// Wired wins over Wi-Fi when both are active so the icon reflects the
    /// interface the system prefers; anything else satisfied is `other`.
    var connectionKind: DuoSystemStatusSnapshot.ConnectionKind? {
        guard isSatisfied else { return nil }
        if usesWiredEthernet { return .ethernet }
        if usesWiFi { return .wifi }
        return .other
    }
}

/// Wi-Fi state plus the signal strength that survives the precise states.
struct DuoWiFiReading: Equatable, Sendable {
    var state: DuoSystemStatusSnapshot.WiFi
    var signalLevel: Int

    init(state: DuoSystemStatusSnapshot.WiFi, signalLevel: Int = 0) {
        self.state = state
        self.signalLevel = signalLevel
    }
}

/// Synchronous system reads. Implementations must be safe to call from a
/// background queue; the monitor never calls them on the main actor.
protocol DuoSystemStatusReading: Sendable {
    func readBattery() -> DuoSystemStatusSnapshot.Battery
    func readWiFi(path: DuoNetworkPathSnapshot?) -> DuoWiFiReading
    func readVolume() -> DuoSystemStatusSnapshot.Volume
}

struct DuoSystemStatusReader: DuoSystemStatusReading {
    init() {}

    // MARK: Battery

    func readBattery() -> DuoSystemStatusSnapshot.Battery {
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unavailable
        }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        guard descriptions.count == sources.count else { return .unavailable }
        return Self.battery(from: descriptions, isLowPowerMode: isLowPowerMode)
    }

    static func battery(
        from descriptions: [[String: Any]]?,
        isLowPowerMode: Bool = false
    ) -> DuoSystemStatusSnapshot.Battery {
        guard let descriptions else { return .unavailable }
        guard let battery = descriptions.first(where: {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && $0[kIOPSIsPresentKey] as? Bool != false
        }) else {
            return .notPresent
        }
        guard let current = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              current.isFinite, maximum.isFinite, maximum > 0, current >= 0 else {
            return .unavailable
        }
        return .level(
            fraction: min(current / maximum, 1),
            isCharging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            isExternalPowerConnected: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            isLowPowerMode: isLowPowerMode
        )
    }

    // MARK: Wi-Fi

    func readWiFi(path: DuoNetworkPathSnapshot?) -> DuoWiFiReading {
        guard let interface = CWWiFiClient.shared().interface() else {
            return DuoWiFiReading(state: .unavailable)
        }
        let powerOn = interface.powerOn()
        // Association mode remains available without requesting location access for an SSID.
        let mode = interface.interfaceMode()
        let isAssociated = mode != CWInterfaceMode.none
        // Internet Sharing only matters while the interface is up and associated,
        // so the SystemConfiguration read is skipped otherwise.
        let sharingActive = powerOn && isAssociated
            && DuoWiFiClassifier.isInternetSharingActive() == true

        let classification = DuoWiFiClassifier.classify(
            powerOn: powerOn,
            serviceActive: isAssociated,
            isIBSS: mode == .IBSS,
            sharingActive: sharingActive,
            pathSatisfied: path?.isSatisfied,
            usesWiFi: path?.usesWiFi ?? false,
            isExpensive: path?.isExpensive ?? false
        )
        return Self.wifi(classification: classification, rssi: interface.rssiValue())
    }

    /// Maps a classification plus an RSSI reading to the snapshot's Wi-Fi state.
    /// A plain connection without a usable RSSI stays `unavailable` rather than
    /// claiming full signal; a precise state keeps its own glyph and simply
    /// reports no bars.
    static func wifi(
        classification: DuoWiFiClassification,
        rssi: Int
    ) -> DuoWiFiReading {
        let level = signalLevel(rssi: rssi)
        switch classification {
        case .off:
            return DuoWiFiReading(state: .off)
        case .notAssociated:
            return DuoWiFiReading(state: .disconnected)
        case .shared:
            return DuoWiFiReading(state: .shared, signalLevel: level ?? 0)
        case .temporary:
            return DuoWiFiReading(state: .temporary, signalLevel: level ?? 0)
        case .hotspot:
            return DuoWiFiReading(state: .hotspot, signalLevel: level ?? 0)
        case .noInternet:
            return DuoWiFiReading(state: .noInternet, signalLevel: level ?? 0)
        case .connected:
            guard let level else { return DuoWiFiReading(state: .unavailable) }
            return DuoWiFiReading(state: .connected(level: level), signalLevel: level)
        }
    }

    /// CoreWLAN reports zero when RSSI is unavailable. It is not a strong signal.
    static func signalLevel(rssi: Int) -> Int? {
        guard rssi < 0, rssi >= -127 else { return nil }
        // Parentheses are required for these negative partial ranges in Swift 6.
        let level: Int = switch rssi {
        case (-55)...: 4
        case (-65)...: 3
        case (-75)...: 2
        case (-85)...: 1
        default: 0
        }
        return level
    }

    /// Path-free convenience used where only the interface flags are known.
    static func wifi(
        isPowered: Bool,
        isAssociated: Bool,
        rssi: Int
    ) -> DuoSystemStatusSnapshot.WiFi {
        wifi(
            classification: DuoWiFiClassifier.classify(
                powerOn: isPowered,
                serviceActive: isAssociated,
                isIBSS: false,
                sharingActive: false,
                pathSatisfied: nil,
                usesWiFi: false,
                isExpensive: false
            ),
            rssi: rssi
        ).state
    }

    // MARK: Volume

    func readVolume() -> DuoSystemStatusSnapshot.Volume {
        guard let deviceID = DuoStatusCoreAudio.validDefaultOutputDevice() else {
            return .unknown
        }
        let scalars = DuoStatusCoreAudio.outputElements.compactMap { element in
            DuoStatusCoreAudio.readFloat32(
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            )
        }
        let mutes = DuoStatusCoreAudio.outputElements.compactMap { element in
            DuoStatusCoreAudio.readUInt32(
                objectID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            )
        }
        let transport = DuoStatusCoreAudio.readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return DuoSystemStatusSnapshot.Volume(
            scalar: Self.averageScalar(scalars),
            isMuted: mutes.first == 1,
            isBluetoothOutput: Self.isBluetoothTransport(transport)
        )
    }

    /// Averages every channel that exposes a volume; devices without any
    /// software volume (for example some HDMI outputs) yield `nil`.
    static func averageScalar(_ scalars: [Float32]) -> Double? {
        let finite = scalars.filter(\.isFinite).map { min(1, max(0, Double($0))) }
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    static func isBluetoothTransport(_ transport: UInt32?) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

// MARK: - CoreAudio helpers

/// Thin wrappers over `AudioObjectGetPropertyData` that turn every failure into
/// `nil`. Shared by the volume reader and the CoreAudio event monitor.
enum DuoStatusCoreAudio {
    /// Main element first, then the left and right channels for devices without
    /// a master control.
    static let outputElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain,
        1,
        2
    ]

    static func defaultOutputDevice() -> AudioDeviceID? {
        guard let deviceID = readUInt32(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        ), deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    /// The default device can briefly point at a stale ID while Bluetooth
    /// devices disconnect; only a live audio device is worth reading.
    static func validDefaultOutputDevice() -> AudioDeviceID? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        let classID = readUInt32(
            objectID: deviceID,
            selector: kAudioObjectPropertyClass,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        guard classID == kAudioDeviceClassID else { return nil }
        let isAlive = readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        guard isAlive == 1 else { return nil }
        return deviceID
    }

    static func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        return AudioObjectHasProperty(objectID, &address)
    }

    static func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        readScalar(
            objectID: objectID, selector: selector, scope: scope, element: element,
            defaultValue: UInt32(0)
        )
    }

    static func readFloat32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        readScalar(
            objectID: objectID, selector: selector, scope: scope, element: element,
            defaultValue: Float32(0)
        )
    }

    private static func readScalar<Value>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        defaultValue: Value
    ) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value = defaultValue
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr, size == MemoryLayout<Value>.size else { return nil }
        return value
    }
}
