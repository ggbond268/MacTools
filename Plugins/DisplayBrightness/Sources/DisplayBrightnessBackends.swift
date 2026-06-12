import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

final class SystemDisplayBrightnessBackendBuilder: DisplayBrightnessBackendBuilding {
    typealias Arm64ServiceResolver = ([DisplayInfo]) -> [CGDirectDisplayID: CFTypeRef]
    typealias AppleBackendFactory = (DisplayInfo) -> (any DisplayBrightnessBackend)?
    typealias DDCBackendFactory = (DisplayInfo, CFTypeRef?) -> (any DisplayBrightnessBackend)?
    typealias SoftwareBackendFactory = (DisplayInfo) -> (any DisplayBrightnessBackend)?

    private enum BackendCandidate: Equatable {
        case appleNative
        case ddc
        case gamma
        case shade

        init(kind: DisplayBrightnessBackendKind) {
            switch kind {
            case .appleNative:
                self = .appleNative
            case .ddc:
                self = .ddc
            case .gamma:
                self = .gamma
            case .shade:
                self = .shade
            }
        }
    }

    private let resolveArm64Services: Arm64ServiceResolver
    private let appleFactory: AppleBackendFactory
    private let ddcFactory: DDCBackendFactory
    private let gammaFactory: SoftwareBackendFactory
    private let shadeFactory: SoftwareBackendFactory

    init(
        resolveArm64Services: @escaping Arm64ServiceResolver = Arm64DDCServiceMatcher.resolveServices,
        appleFactory: AppleBackendFactory? = nil,
        ddcFactory: DDCBackendFactory? = nil,
        gammaFactory: SoftwareBackendFactory? = nil,
        shadeFactory: SoftwareBackendFactory? = nil
    ) {
        let displayServicesBridge = DisplayServicesBrightnessBridge()

        self.resolveArm64Services = resolveArm64Services
        self.appleFactory = appleFactory ?? { display in
            let backend = AppleNativeBrightnessBackend(
                display: display,
                bridge: displayServicesBridge
            )

            do {
                _ = try backend.readBrightness()
                return backend
            } catch {
                return nil
            }
        }
        self.ddcFactory = ddcFactory ?? { display, matchedService in
            if let transport = Arm64DDCTransport(display: display, service: nil) {
                return DDCBrightnessBackend(display: display, transport: transport)
            }

            if let matchedService,
               let transport = Arm64DDCTransport(display: display, service: matchedService) {
                return DDCBrightnessBackend(display: display, transport: transport)
            }

            if let transport = IntelDDCTransport(display: display) {
                return DDCBrightnessBackend(display: display, transport: transport)
            }

            return nil
        }
        self.gammaFactory = gammaFactory ?? { display in
            GammaBrightnessBackend(display: display)
        }
        self.shadeFactory = shadeFactory ?? { display in
            ShadeBrightnessBackend(display: display)
        }
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend] {
        var arm64Services: [CGDirectDisplayID: CFTypeRef]?
        var result: [CGDirectDisplayID: any DisplayBrightnessBackend] = [:]

        for display in displays {
            for candidate in backendCandidates(for: display) {
                guard let backend = makeBackend(
                    candidate,
                    for: display,
                    in: displays,
                    previous: previous,
                    cache: &arm64Services
                ) else {
                    continue
                }

                result[display.id] = backend
                break
            }
        }

        return result
    }

    func fallbackBackend(
        after failedBackend: any DisplayBrightnessBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        let candidates = backendCandidates(for: display)
        guard let failedIndex = candidates.firstIndex(of: BackendCandidate(kind: failedBackend.kind)) else {
            return nil
        }

        var arm64Services: [CGDirectDisplayID: CFTypeRef]?
        for candidate in candidates.dropFirst(failedIndex + 1) {
            guard let backend = makeBackend(
                candidate,
                for: display,
                in: [display],
                previous: previous.filter { $0.key != display.id },
                cache: &arm64Services
            ) else {
                continue
            }

            return backend
        }

        return nil
    }

    private func backendCandidates(for display: DisplayInfo) -> [BackendCandidate] {
        if display.isBuiltin {
            return [.appleNative, .gamma, .shade]
        }

        if display.supportsAppleNativeBrightness {
            return [.appleNative, .ddc, .gamma, .shade]
        }

        return [.ddc, .gamma, .shade]
    }

    private func makeBackend(
        _ candidate: BackendCandidate,
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend],
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
    ) -> (any DisplayBrightnessBackend)? {
        switch candidate {
        case .appleNative:
            return appleBackend(for: display, previous: previous)
        case .ddc:
            return ddcBackend(
                for: display,
                in: displays,
                previous: previous,
                cache: &arm64Services
            )
        case .gamma:
            return softwareBackend(
                kind: .gamma,
                label: "Gamma",
                for: display,
                previous: previous,
                factory: gammaFactory
            )
        case .shade:
            return softwareBackend(
                kind: .shade,
                label: "Shade",
                for: display,
                previous: previous,
                factory: shadeFactory
            )
        }
    }

    private func appleBackend(
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        guard display.isAppleDisplay else {
            return nil
        }

        guard let backend = reuse(previous[display.id], kind: .appleNative, display: display)
            ?? appleFactory(display) else {
            return nil
        }

        DisplayBrightnessLog.backend.debug(
            "selected Apple native brightness backend for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func softwareBackend(
        kind: DisplayBrightnessBackendKind,
        label: String,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend],
        factory: SoftwareBackendFactory
    ) -> (any DisplayBrightnessBackend)? {
        guard let backend = reuse(previous[display.id], kind: kind, display: display)
            ?? factory(display) else {
            return nil
        }

        DisplayBrightnessLog.backend.info(
            "using \(label, privacy: .public) software brightness fallback for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func ddcBackend(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend],
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
    ) -> (any DisplayBrightnessBackend)? {
        guard let backend = reuse(previous[display.id], kind: .ddc, display: display)
            ?? ddcFactory(display, resolvedArm64Service(for: display, in: displays, cache: &arm64Services)) else {
            return nil
        }

        DisplayBrightnessLog.backend.debug(
            "selected DDC brightness backend for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func resolvedArm64Service(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
    ) -> CFTypeRef? {
        if arm64Services == nil {
            arm64Services = resolveArm64Services(displays)
        }

        return arm64Services?[display.id]
    }

    private func reuse(
        _ previous: (any DisplayBrightnessBackend)?,
        kind: DisplayBrightnessBackendKind,
        display: DisplayInfo
    ) -> (any DisplayBrightnessBackend)? {
        guard let backend = previous, backend.kind == kind else {
            return nil
        }

        backend.display = display
        return backend
    }
}

final class AppleNativeBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .appleNative
    var display: DisplayInfo

    private let bridge: DisplayServicesBrightnessBridge

    init(
        display: DisplayInfo,
        bridge: DisplayServicesBrightnessBridge
    ) {
        self.display = display
        self.bridge = bridge
    }

    func readBrightness() throws -> Double {
        try bridge.readBrightness(displayID: display.id)
    }

    func writeBrightness(_ value: Double) throws {
        try bridge.writeBrightness(value, displayID: display.id)
    }

    func cleanup() {}
}

final class DDCBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .ddc
    var display: DisplayInfo

    private let transport: any DDCBrightnessTransport
    private var maximumValue: UInt16

    init?(display: DisplayInfo, transport: any DDCBrightnessTransport) {
        guard !display.isBuiltin else {
            return nil
        }

        self.display = display
        self.transport = transport
        self.maximumValue = (try? transport.readBrightness().maximum).flatMap(Self.validMaximum) ?? 100
    }

    func readBrightness() throws -> Double {
        let brightness = try transport.readBrightness()
        maximumValue = Self.validMaximum(brightness.maximum) ?? maximumValue
        return maximumValue == 0 ? 1 : Double(brightness.current) / Double(maximumValue)
    }

    func writeBrightness(_ value: Double) throws {
        let clampedValue = max(0, min(value, 1))
        let rawValue = UInt16((Double(maximumValue) * clampedValue).rounded())
        try transport.writeBrightness(rawValue)
    }

    func cleanup() {}

    private static func validMaximum(_ maximum: UInt16) -> UInt16? {
        maximum == 0 ? nil : maximum
    }
}

final class GammaBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    /// Injection seams over the CoreGraphics gamma-table calls so the
    /// original-table load and the cleanup restore chain are testable without
    /// a live display. Signatures mirror the imported C functions exactly, so
    /// the defaults are the real functions and production behavior is
    /// unchanged.
    typealias GammaTableCapacityFunction = (CGDirectDisplayID) -> UInt32
    typealias GammaTableReadFunction = (
        CGDirectDisplayID,
        UInt32,
        UnsafeMutablePointer<CGGammaValue>?,
        UnsafeMutablePointer<CGGammaValue>?,
        UnsafeMutablePointer<CGGammaValue>?,
        UnsafeMutablePointer<UInt32>?
    ) -> CGError
    typealias GammaTableWriteFunction = (
        CGDirectDisplayID,
        UInt32,
        UnsafePointer<CGGammaValue>?,
        UnsafePointer<CGGammaValue>?,
        UnsafePointer<CGGammaValue>?
    ) -> CGError

    private struct TransferTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    let kind: DisplayBrightnessBackendKind = .gamma
    var display: DisplayInfo

    private let tableCapacity: GammaTableCapacityFunction
    private let readTransferTable: GammaTableReadFunction
    private let writeTransferTable: GammaTableWriteFunction
    private var originalTransferTable: TransferTable?
    private var currentBrightness = 1.0

    init?(
        display: DisplayInfo,
        tableCapacity: @escaping GammaTableCapacityFunction = CGDisplayGammaTableCapacity,
        readTransferTable: @escaping GammaTableReadFunction = CGGetDisplayTransferByTable,
        writeTransferTable: @escaping GammaTableWriteFunction = CGSetDisplayTransferByTable
    ) {
        // See loadOriginalTransferTableIfNeeded for why the capacity check
        // must use CGDisplayGammaTableCapacity rather than the historical
        // size-query idiom.
        guard Self.gammaTableCapacityIsControllable(tableCapacity(display.id)) else {
            return nil
        }

        self.display = display
        self.tableCapacity = tableCapacity
        self.readTransferTable = readTransferTable
        self.writeTransferTable = writeTransferTable
    }

    func readBrightness() throws -> Double {
        currentBrightness
    }

    func writeBrightness(_ value: Double) throws {
        let clampedValue = max(0, min(value, 1))
        let transferTable = try loadOriginalTransferTableIfNeeded()
        let result = applyTransferTable(
            red: transferTable.red.map { $0 * Float(clampedValue) },
            green: transferTable.green.map { $0 * Float(clampedValue) },
            blue: transferTable.blue.map { $0 * Float(clampedValue) }
        )

        guard result == .success else {
            throw DisplayBrightnessControllerError.softwareBrightnessFailed
        }

        currentBrightness = clampedValue
    }

    func cleanup() {
        guard let originalTransferTable else {
            return
        }

        // Restore failure cannot be retried here (the backend is being torn
        // down), but it must not pass silently — a display left dimmed by an
        // unrestored gamma table is exactly the side effect the safety
        // boundary requires us to surface.
        let result = applyTransferTable(
            red: originalTransferTable.red,
            green: originalTransferTable.green,
            blue: originalTransferTable.blue
        )
        if result != .success {
            DisplayBrightnessLog.backend.error(
                "Gamma restore failed on cleanup for display \(self.display.id, privacy: .public): CGError \(result.rawValue, privacy: .public)"
            )
        }
        currentBrightness = 1
    }

    private func applyTransferTable(
        red: [CGGammaValue],
        green: [CGGammaValue],
        blue: [CGGammaValue]
    ) -> CGError {
        red.withUnsafeBufferPointer { redBuffer in
            green.withUnsafeBufferPointer { greenBuffer in
                blue.withUnsafeBufferPointer { blueBuffer in
                    writeTransferTable(
                        display.id,
                        UInt32(redBuffer.count),
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress
                    )
                }
            }
        }
    }

    private func loadOriginalTransferTableIfNeeded() throws -> TransferTable {
        if let originalTransferTable {
            return originalTransferTable
        }

        // macOS 27 beta: the historical "capacity = 0, nil buffers" size-query
        // idiom regressed (CGGetDisplayTransferByTable returns 1001 instead of
        // .success on 26A5353q), collapsing the whole gamma fallback. Query the
        // table capacity with the public CGDisplayGammaTableCapacity instead —
        // it returns a valid capacity on every shipping macOS (verified 1024 on
        // beta; valid on 14…26 too), so this needs no OS gate.
        let capacity = tableCapacity(display.id)
        guard Self.gammaTableCapacityIsControllable(capacity) else {
            throw DisplayBrightnessControllerError.brightnessUnavailable(displayName: display.name)
        }
        var sampleCount = capacity

        let red = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
        let green = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
        let blue = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
        defer {
            red.deallocate()
            green.deallocate()
            blue.deallocate()
        }

        let readResult = withUnsafeMutablePointer(to: &sampleCount) { sampleCountPointer in
            readTransferTable(
                display.id,
                capacity,
                red,
                green,
                blue,
                sampleCountPointer
            )
        }

        guard readResult == .success else {
            throw DisplayBrightnessControllerError.brightnessUnavailable(displayName: display.name)
        }

        // The reported sample count must never exceed the buffers we
        // allocated; clamp before building the cached table. A zero count on
        // a .success read would cache an empty table and turn every later
        // write and the restore into a 0-sample no-op — treat it as the read
        // failure it effectively is instead of caching it.
        let resolvedCount = Int(min(sampleCount, capacity))
        guard resolvedCount > 0 else {
            throw DisplayBrightnessControllerError.brightnessUnavailable(displayName: display.name)
        }
        let transferTable = TransferTable(
            red: Array(UnsafeBufferPointer(start: red, count: resolvedCount)),
            green: Array(UnsafeBufferPointer(start: green, count: resolvedCount)),
            blue: Array(UnsafeBufferPointer(start: blue, count: resolvedCount))
        )
        originalTransferTable = transferTable
        return transferTable
    }

    /// Pure capacity gate, extracted so the gamma-capacity fix path is testable
    /// without a live display.
    static func gammaTableCapacityIsControllable(_ capacity: UInt32) -> Bool {
        capacity > 0
    }
}

final class ShadeBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .shade
    var display: DisplayInfo

    private let overlayController = ShadeOverlayController()
    private var currentBrightness = 1.0

    init?(display: DisplayInfo) {
        guard Self.screen(for: display.id) != nil else {
            return nil
        }

        self.display = display
    }

    func readBrightness() throws -> Double {
        refreshOverlayFrameIfNeeded()
        return currentBrightness
    }

    func writeBrightness(_ value: Double) throws {
        let clampedValue = max(0, min(value, 1))
        guard Self.screen(for: display.id) != nil else {
            throw DisplayBrightnessControllerError.displayUnavailable(displayID: display.id)
        }

        applyOverlay(brightness: clampedValue)
        currentBrightness = clampedValue
    }

    func cleanup() {
        hideOverlay()
        currentBrightness = 1
    }

    private func refreshOverlayFrameIfNeeded() {
        guard currentBrightness < 0.999, Self.screen(for: display.id) != nil else {
            return
        }

        applyOverlay(brightness: currentBrightness)
    }

    private func applyOverlay(brightness: Double) {
        let displayID = display.id
        let overlayController = self.overlayController

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard let screen = Self.screen(for: displayID) else {
                    return
                }

                overlayController.apply(brightness: brightness, on: screen)
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let screen = Self.screen(for: displayID) else {
                    return
                }

                overlayController.apply(brightness: brightness, on: screen)
            }
        }
    }

    private func hideOverlay() {
        let overlayController = self.overlayController

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                overlayController.hide()
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                overlayController.hide()
            }
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        })
    }
}

@MainActor
private final class ShadeOverlayController {
    private var window: NSWindow?

    func apply(brightness: Double, on screen: NSScreen) {
        let alpha = max(0, min(1 - brightness, 0.92))

        guard alpha > 0.001 else {
            hide()
            return
        }

        let window = self.window ?? self.makeWindow(screen: screen)
        window.setFrame(screen.frame, display: true)
        window.alphaValue = alpha
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        guard let window else {
            return
        }

        window.orderOut(nil)
        self.window = nil
    }

    private func makeWindow(screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        return window
    }
}

final class DisplayServicesBrightnessBridge: @unchecked Sendable {
    private typealias GetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightnessFunction?
    private let setBrightness: SetBrightnessFunction?

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        self.getBrightness = Self.loadSymbol("DisplayServicesGetBrightness", from: handle)
        self.setBrightness = Self.loadSymbol("DisplayServicesSetBrightness", from: handle)
    }

    func readBrightness(displayID: CGDirectDisplayID) throws -> Double {
        guard let getBrightness else {
            throw DisplayBrightnessControllerError.nativeAPINotAvailable
        }

        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else {
            throw DisplayBrightnessControllerError.genericBrightnessUnavailable
        }

        return Double(max(0, min(value, 1)))
    }

    func writeBrightness(_ value: Double, displayID: CGDirectDisplayID) throws {
        guard let setBrightness else {
            throw DisplayBrightnessControllerError.nativeAPINotAvailable
        }

        guard setBrightness(displayID, Float(max(0, min(value, 1)))) == 0 else {
            throw DisplayBrightnessControllerError.nativeBrightnessWriteFailed
        }
    }

    private static func loadSymbol<T>(
        _ symbol: String,
        from handle: UnsafeMutableRawPointer?
    ) -> T? {
        guard let symbolPointer = dlsym(handle, symbol) else {
            return nil
        }

        return unsafeBitCast(symbolPointer, to: T.self)
    }
}
