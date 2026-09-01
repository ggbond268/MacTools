import AppKit
import CoreFoundation
import Darwin
import Foundation
import MacToolsPluginKit
import ObjectiveC.runtime

@_silgen_name("notify_post")
private func systemNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

enum SystemSettingAdapterError: LocalizedError, Equatable {
    case unreadable
    case invalidValue
    case writeFailed(String)
    case verificationMismatch(expected: SystemSettingValue, actual: SystemSettingValue)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            MacSettingsStrings.text("Could not read the current value.")
        case .invalidValue:
            MacSettingsStrings.text("This value is not valid for this setting.")
        case let .writeFailed(message):
            message
        case .verificationMismatch:
            MacSettingsStrings.text("The setting was written, but verification did not match.")
        case let .unsupported(message):
            message
        }
    }
}

enum SystemSettingVerification: Equatable {
    case verified(SystemSettingValue)
    case mismatch(actual: SystemSettingValue)
    case unavailable
}

private enum UniversalAccessPreferencesError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        MacSettingsStrings.text("This macOS version cannot update this accessibility setting immediately.")
    }
}

private enum TrackpadSecondaryClickMode: String {
    case off
    case twoFingers = "two-fingers"
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
}

@MainActor
private final class TrackpadPreferencesClient {
    typealias BooleanGetter = @convention(c) (AnyObject, Selector) -> Bool
    typealias BooleanSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
    typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int64
    typealias IntegerSetter = @convention(c) (AnyObject, Selector, Int64) -> Void
    typealias DoubleGetter = @convention(c) (AnyObject, Selector) -> Double
    typealias DoubleSetter = @convention(c) (AnyObject, Selector, Double) -> Void

    static let shared = TrackpadPreferencesClient()

    private let handle: UnsafeMutableRawPointer?
    private let backend: NSObject?

    private init() {
        let path = "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/Versions/A/PreferencePanesSupport"
        let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        self.handle = handle

        guard handle != nil,
              let backendClass = NSClassFromString("MTTGestureBackEnd"),
              let shared = (backendClass as AnyObject)
                .perform(NSSelectorFromString("shared"))?
                .takeUnretainedValue() as? NSObject else {
            backend = nil
            return
        }

        backend = shared
    }

    func threeFingerDrag() throws -> Bool {
        try booleanValue(getter: "threeFingerDrag")
    }

    func setThreeFingerDrag(_ enabled: Bool) throws {
        try setBooleanValue(enabled, setter: "setThreeFingerDrag:")
    }

    func tapToClick() throws -> Bool {
        try integerValue(getter: "tapBehavior") != 0
    }

    func setTapToClick(_ enabled: Bool) throws {
        try setIntegerValue(enabled ? 1 : 0, setter: "setTapBehavior:")
    }

    func trackingSpeed() throws -> Double {
        try doubleValue(getter: "trackSpeedRaw")
    }

    func setTrackingSpeed(_ value: Double) throws {
        try setDoubleValue(value, setter: "setTrackSpeedRaw:")
    }

    func secondaryClickMode() throws -> TrackpadSecondaryClickMode {
        if try booleanValue(getter: "twoFingerSecondaryClick") {
            return .twoFingers
        }
        switch try integerValue(getter: "cornerClickBehavior") {
        case 0: return .off
        case 1: return .bottomLeft
        case 2: return .bottomRight
        default:
            throw SystemSettingAdapterError.unreadable
        }
    }

    func setSecondaryClickMode(_ mode: TrackpadSecondaryClickMode) throws {
        switch mode {
        case .off:
            try setBooleanValue(false, setter: "setTwoFingerSecondaryClick:")
            try setIntegerValue(0, setter: "setCornerClickBehavior:")
        case .twoFingers:
            try setIntegerValue(0, setter: "setCornerClickBehavior:")
            try setBooleanValue(true, setter: "setTwoFingerSecondaryClick:")
        case .bottomRight:
            try setBooleanValue(false, setter: "setTwoFingerSecondaryClick:")
            try setIntegerValue(2, setter: "setCornerClickBehavior:")
        case .bottomLeft:
            try setBooleanValue(false, setter: "setTwoFingerSecondaryClick:")
            try setIntegerValue(1, setter: "setCornerClickBehavior:")
        }
    }

    func scrollSpeed() throws -> Double {
        try doubleValue(getter: "scrollSpeedRaw")
    }

    func setScrollSpeed(_ value: Double) throws {
        try setDoubleValue(value, setter: "setScrollSpeedRaw:")
    }

    private func booleanValue(getter name: String) throws -> Bool {
        let selector = NSSelectorFromString(name)
        let function: BooleanGetter = try implementation(
            selector: selector,
            encoding: "B16@0:8",
            as: BooleanGetter.self
        )
        return function(try requireBackend(), selector)
    }

    private func setBooleanValue(_ value: Bool, setter name: String) throws {
        let selector = NSSelectorFromString(name)
        let function: BooleanSetter = try implementation(
            selector: selector,
            encoding: "v20@0:8B16",
            as: BooleanSetter.self
        )
        function(try requireBackend(), selector, value)
    }

    private func integerValue(getter name: String) throws -> Int64 {
        let selector = NSSelectorFromString(name)
        let function: IntegerGetter = try implementation(
            selector: selector,
            encoding: "q16@0:8",
            as: IntegerGetter.self
        )
        return function(try requireBackend(), selector)
    }

    private func setIntegerValue(_ value: Int64, setter name: String) throws {
        let selector = NSSelectorFromString(name)
        let function: IntegerSetter = try implementation(
            selector: selector,
            encoding: "v24@0:8q16",
            as: IntegerSetter.self
        )
        function(try requireBackend(), selector, value)
    }

    private func doubleValue(getter name: String) throws -> Double {
        let selector = NSSelectorFromString(name)
        let function: DoubleGetter = try implementation(
            selector: selector,
            encoding: "d16@0:8",
            as: DoubleGetter.self
        )
        return function(try requireBackend(), selector)
    }

    private func setDoubleValue(_ value: Double, setter name: String) throws {
        let selector = NSSelectorFromString(name)
        let function: DoubleSetter = try implementation(
            selector: selector,
            encoding: "v24@0:8d16",
            as: DoubleSetter.self
        )
        function(try requireBackend(), selector, value)
    }

    private func requireBackend() throws -> NSObject {
        guard handle != nil, let backend else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This macOS version cannot update trackpad settings immediately."))
        }
        return backend
    }

    private func implementation<T>(
        selector: Selector,
        encoding: String,
        as type: T.Type
    ) throws -> T {
        let backend = try requireBackend()
        guard let backendClass = object_getClass(backend),
              let method = class_getInstanceMethod(backendClass, selector),
              let methodEncoding = method_getTypeEncoding(method),
              String(cString: methodEncoding) == encoding else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This macOS version cannot update trackpad settings immediately."))
        }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }
}

@MainActor
private final class MousePreferencesClient {
    typealias DoubleGetter = @convention(c) (AnyObject, Selector) -> Double
    typealias DoubleSetter = @convention(c) (AnyObject, Selector, Double) -> Void

    static let shared = MousePreferencesClient()

    private let handle: UnsafeMutableRawPointer?
    private let backend: NSObject?

    private init() {
        let path = "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/Versions/A/PreferencePanesSupport"
        let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        self.handle = handle

        guard handle != nil,
              let backendClass = NSClassFromString("MTMouseGesturesBackEnd"),
              let shared = (backendClass as AnyObject)
                .perform(NSSelectorFromString("sharedInstance"))?
                .takeUnretainedValue() as? NSObject else {
            backend = nil
            return
        }
        backend = shared
    }

    func scrollSpeed() throws -> Double {
        try doubleValue(getter: "scrollSpeedRaw")
    }

    func setScrollSpeed(_ value: Double) throws {
        try setDoubleValue(value, setter: "setScrollSpeedRaw:")
    }

    private func doubleValue(getter name: String) throws -> Double {
        let selector = NSSelectorFromString(name)
        let function: DoubleGetter = try implementation(
            selector: selector,
            encoding: "d16@0:8",
            as: DoubleGetter.self
        )
        return function(try requireBackend(), selector)
    }

    private func setDoubleValue(_ value: Double, setter name: String) throws {
        let selector = NSSelectorFromString(name)
        let function: DoubleSetter = try implementation(
            selector: selector,
            encoding: "v24@0:8d16",
            as: DoubleSetter.self
        )
        function(try requireBackend(), selector, value)
    }

    private func requireBackend() throws -> NSObject {
        guard handle != nil, let backend else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This macOS version cannot update mouse settings immediately."))
        }
        return backend
    }

    private func implementation<T>(
        selector: Selector,
        encoding: String,
        as type: T.Type
    ) throws -> T {
        let backend = try requireBackend()
        guard let backendClass = object_getClass(backend),
              let method = class_getInstanceMethod(backendClass, selector),
              let methodEncoding = method_getTypeEncoding(method),
              String(cString: methodEncoding) == encoding else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This macOS version cannot update mouse settings immediately."))
        }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }
}

@MainActor
private final class UniversalAccessRuntimeClient {
    private enum CursorPreference {
        static let domain = "com.apple.universalaccess"
        static let key = "mouseDriverCursorSize"
        static let defaultsExecutable = URL(filePath: "/usr/bin/defaults")
    }

    typealias BooleanGetter = @convention(c) () -> Bool
    typealias BooleanSetter = @convention(c) (Bool) -> Void
    typealias DoubleGetter = @convention(c) () -> Double
    typealias DoubleSetter = @convention(c) (Double) -> Void
    typealias IntegerGetter = @convention(c) () -> Int64
    typealias IntegerSetter = @convention(c) (Int64) -> Void
    typealias PreferenceDoubleGetter = @convention(c) (UnsafeRawPointer) -> Double
    typealias PreferenceDoubleSetter = @convention(c) (
        UnsafeRawPointer,
        Double,
        UnsafeRawPointer?
    ) -> Void
    typealias PreferencesSynchronizer = @convention(c) () -> Bool
    typealias MainConnectionGetter = @convention(c) () -> UInt32
    typealias CursorScaleGetter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    static let shared = UniversalAccessRuntimeClient()

    private let universalAccessHandle: UnsafeMutableRawPointer?
    private let skyLightHandle: UnsafeMutableRawPointer?

    private init() {
        universalAccessHandle = dlopen(
            "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Frameworks/UniversalAccessCore.framework/Versions/A/UniversalAccessCore",
            RTLD_NOW | RTLD_LOCAL
        )
        skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW | RTLD_LOCAL
        )
    }

    func activeCursorScale() throws -> Double {
        guard let skyLightHandle,
              let mainConnection = Self.function(
                handle: skyLightHandle,
                symbol: "SLSMainConnectionID",
                as: MainConnectionGetter.self
              ),
              let getCursorScale = Self.function(
                handle: skyLightHandle,
                symbol: "SLSGetCursorScale",
                as: CursorScaleGetter.self
              ) else {
            throw UniversalAccessPreferencesError.unavailable
        }
        var scale: Float = 0
        guard getCursorScale(mainConnection(), &scale) == 0 else {
            throw UniversalAccessPreferencesError.unavailable
        }
        return Double(scale)
    }

    func setCursorScale(_ value: Double) throws {
        try persistCursorScale(value)
        let key = try constant("UACursorScaleKey")
        let notification = try constant("UADomainMouseSettingsDidChangeNotification")
        let setPreference = try function(
            "UAPreferencesSetDouble",
            as: PreferenceDoubleSetter.self
        )
        let getPreference = try function(
            "UAPreferencesGetDouble",
            as: PreferenceDoubleGetter.self
        )
        let synchronizePreferences = try function(
            "UAPreferencesSynchronize",
            as: PreferencesSynchronizer.self
        )
        setPreference(key, value, notification)
        guard synchronizePreferences(),
              abs(getPreference(key) - value) <= 0.01 else {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not save the pointer size."))
        }
        try function("UACursorSetScale", as: DoubleSetter.self)(value)
    }

    private func persistCursorScale(_ value: Double) throws {
        let encoded = String(
            format: "%.17g",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        _ = try runDefaults([
            "write",
            CursorPreference.domain,
            CursorPreference.key,
            "-float",
            encoded,
        ])
        let output = try runDefaults([
            "read",
            CursorPreference.domain,
            CursorPreference.key,
        ])
        guard let persisted = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              abs(persisted - value) <= 0.01 else {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not save the pointer size."))
        }
    }

    private func runDefaults(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = CursorPreference.defaultsExecutable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not save the pointer size."))
        }
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            _ = errorData
            throw SystemSettingAdapterError.writeFailed(
                MacSettingsStrings.text("Changing pointer size requires Full Disk Access. Grant access, then quit and reopen MacTools.")
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    func keyboardZoomEnabled() throws -> Bool {
        try function("UAKeyboardZoomIsEnabled", as: BooleanGetter.self)()
    }

    func setKeyboardZoomEnabled(_ enabled: Bool) throws {
        try function("UAKeyboardZoomSetEnabled", as: BooleanSetter.self)(enabled)
    }

    func scrollZoomEnabled() throws -> Bool {
        try function("UAScrollZoomIsEnabled", as: BooleanGetter.self)()
    }

    func setScrollZoomEnabled(_ enabled: Bool) throws {
        try function("UAScrollZoomSetEnabled", as: BooleanSetter.self)(enabled)
    }

    func scrollZoomModifiers() throws -> Int {
        Int(try function("UAScrollZoomModifiers", as: IntegerGetter.self)())
    }

    func setScrollZoomModifiers(_ modifiers: Int) throws {
        try function("UAScrollZoomSetModifiers", as: IntegerSetter.self)(Int64(modifiers))
    }

    func fullKeyboardAccessEnabled() throws -> Bool {
        try function("UAKeyboardAccessIsEnabled", as: BooleanGetter.self)()
    }

    func setFullKeyboardAccessEnabled(_ enabled: Bool) throws {
        try function("UAKeyboardAccessSetEnabled", as: BooleanSetter.self)(enabled)
    }

    func stickyKeysEnabled() throws -> Bool {
        try function("UAStickyKeysIsEnabled", as: BooleanGetter.self)()
    }

    func setStickyKeysEnabled(_ enabled: Bool) throws {
        try function("UAStickyKeysSetEnabled", as: BooleanSetter.self)(enabled)
    }

    func slowKeysEnabled() throws -> Bool {
        try function("UASlowKeysIsEnabled", as: BooleanGetter.self)()
    }

    func setSlowKeysEnabled(_ enabled: Bool) throws {
        try function("UASlowKeysSetEnabled", as: BooleanSetter.self)(enabled)
    }

    private func function<T>(_ symbol: String, as type: T.Type) throws -> T {
        guard let function = Self.function(handle: universalAccessHandle, symbol: symbol, as: type) else {
            throw UniversalAccessPreferencesError.unavailable
        }
        return function
    }

    private func constant(_ symbol: String) throws -> UnsafeRawPointer {
        guard let universalAccessHandle,
              let storage = dlsym(universalAccessHandle, symbol),
              let value = storage.load(as: UnsafeRawPointer?.self) else {
            throw UniversalAccessPreferencesError.unavailable
        }
        return value
    }

    private static func function<T>(
        handle: UnsafeMutableRawPointer?,
        symbol: String,
        as type: T.Type
    ) -> T? {
        guard let handle, let function = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(function, to: type)
    }
}

@MainActor
protocol SystemSettingAdapter: AnyObject {
    func read() async throws -> SystemSettingValue
    func apply(_ value: SystemSettingValue) async throws
    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification
    func rollback(to value: SystemSettingValue) async throws
    func snapshot() async throws -> SystemSettingSnapshot
    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification
}

extension SystemSettingAdapter {
    func snapshot() async throws -> SystemSettingSnapshot {
        .init(value: try await read())
    }

    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        guard !snapshot.hasRestorationData else { throw SystemSettingAdapterError.invalidValue }
        try await rollback(to: snapshot.value)
        return try await verify(snapshot.value)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        let value = try await read()
        return value == expectedValue ? .verified(value) : .mismatch(actual: value)
    }

    func rollback(to value: SystemSettingValue) async throws {
        try await apply(value)
    }
}

@MainActor
protocol SystemDefaultsDomainStoring {
    func object(forKey key: String, inDomain domain: String) throws -> Any?
    func set(_ object: Any, forKey key: String, inDomain domain: String) throws
}

@MainActor
struct ProcessSystemDefaultsDomainStore: SystemDefaultsDomainStoring {
    private static let executable = URL(filePath: "/usr/bin/defaults")

    func object(forKey key: String, inDomain domain: String) throws -> Any? {
        _ = CFPreferencesAppSynchronize(domain as NSString)
        return CFPreferencesCopyAppValue(key as NSString, domain as NSString)
    }

    func set(_ object: Any, forKey key: String, inDomain domain: String) throws {
        let arguments = try Self.writeArguments(for: object)
        let result = try run(["write", domain, key] + arguments)
        guard result.status == 0 else {
            let message = String(data: result.error, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemSettingAdapterError.writeFailed(
                message?.isEmpty == false ? message! : MacSettingsStrings.text("Could not save system settings.")
            )
        }
    }

    static func writeArguments(for object: Any) throws -> [String] {
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ["-bool", number.boolValue ? "true" : "false"]
            }
            let type = String(cString: number.objCType)
            if ["f", "d"].contains(type) {
                return [
                    "-float",
                    String(
                        format: "%.17g",
                        locale: Locale(identifier: "en_US_POSIX"),
                        number.doubleValue
                    ),
                ]
            }
            return ["-int", String(number.intValue)]
        }
        if let string = object as? String {
            return ["-string", string]
        }
        throw SystemSettingAdapterError.invalidValue
    }

    private func run(_ arguments: [String]) throws -> (
        status: Int32,
        output: Data,
        error: Data
    ) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = Self.executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not run the system settings tool."))
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, outputData, errorData)
    }
}

@MainActor
final class DefaultsSystemSettingAdapter: SystemSettingAdapter {
    typealias Decoder = (Any?) throws -> SystemSettingValue
    typealias Encoder = (SystemSettingValue) throws -> Any

    private let readObject: () throws -> Any?
    private let writeObject: (Any) throws -> Void
    private let decode: Decoder
    private let encode: Encoder
    private let notificationName: Notification.Name?

    init(
        domain: String,
        key: String,
        notificationName: Notification.Name? = nil,
        decode: @escaping Decoder,
        encode: @escaping Encoder,
        store: any SystemDefaultsDomainStoring = ProcessSystemDefaultsDomainStore()
    ) {
        self.readObject = { try store.object(forKey: key, inDomain: domain) }
        self.writeObject = { try store.set($0, forKey: key, inDomain: domain) }
        self.decode = decode
        self.encode = encode
        self.notificationName = notificationName
    }

    init(
        defaults: UserDefaults,
        key: String,
        notificationName: Notification.Name? = nil,
        decode: @escaping Decoder,
        encode: @escaping Encoder
    ) {
        self.readObject = { defaults.object(forKey: key) }
        self.writeObject = {
            defaults.set($0, forKey: key)
            guard defaults.synchronize() else {
                throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not save the setting."))
            }
        }
        self.decode = decode
        self.encode = encode
        self.notificationName = notificationName
    }

    func read() async throws -> SystemSettingValue {
        try decode(try readObject())
    }

    func apply(_ value: SystemSettingValue) async throws {
        let encoded = try encode(value)
        try writeObject(encoded)
        if let notificationName {
            DistributedNotificationCenter.default().postNotificationName(
                notificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            notificationName.rawValue.withCString { name in
                _ = systemNotifyPost(name)
            }
        }
    }
}

enum DockSystemEventsPreference: Equatable {
    case dockSize
    case screenEdge
    case magnification
    case magnificationSize
    case minimizeEffect
    case showRecents
    case minimizeIntoApplication
    case animate
    case showIndicators

    func script(for value: SystemSettingValue) throws -> String {
        let assignment: String
        switch (self, value) {
        case let (.dockSize, .decimal(size)):
            assignment = "set dock size to \(normalizedSize(size))"
        case let (.magnificationSize, .decimal(size)):
            assignment = "set magnification size to \(normalizedSize(size))"
        case let (.screenEdge, .choice(edge)) where ["left", "bottom", "right"].contains(edge):
            assignment = "set screen edge to \(edge)"
        case let (.minimizeEffect, .choice(effect)) where ["genie", "scale"].contains(effect):
            assignment = "set minimize effect to \(effect)"
        case let (.magnification, .boolean(enabled)):
            assignment = booleanAssignment(property: "magnification", enabled: enabled)
        case let (.showRecents, .boolean(enabled)):
            assignment = booleanAssignment(property: "show recents", enabled: enabled)
        case let (.minimizeIntoApplication, .boolean(enabled)):
            assignment = booleanAssignment(property: "minimize into application", enabled: enabled)
        case let (.animate, .boolean(enabled)):
            assignment = booleanAssignment(property: "animate", enabled: enabled)
        case let (.showIndicators, .boolean(enabled)):
            assignment = booleanAssignment(property: "show indicators", enabled: enabled)
        default:
            throw SystemSettingAdapterError.invalidValue
        }

        return """
        tell application "System Events"
            tell dock preferences
                \(assignment)
            end tell
        end tell
        """
    }

    private func normalizedSize(_ size: Double) -> String {
        let normalized = min(max((size - 16) / 112, 0), 1)
        return String(
            format: "%.17g",
            locale: Locale(identifier: "en_US_POSIX"),
            normalized
        )
    }

    private func booleanAssignment(property: String, enabled: Bool) -> String {
        "set \(property) to \(enabled ? "true" : "false")"
    }
}

@MainActor
final class DockSystemEventsSettingAdapter: SystemSettingAdapter {
    typealias ScriptExecutor = @MainActor (String) throws -> Void
    typealias VerificationDelay = @MainActor () async -> Void

    private let persistedAdapter: any SystemSettingAdapter
    private let preference: DockSystemEventsPreference
    private let executeScript: ScriptExecutor
    private let persistenceDelay: VerificationDelay
    private let verificationAttempts: Int
    private let verificationDelay: VerificationDelay

    init(
        persistedAdapter: any SystemSettingAdapter,
        preference: DockSystemEventsPreference,
        executeScript: @escaping ScriptExecutor = DockSystemEventsSettingAdapter.execute,
        persistenceDelay: @escaping VerificationDelay = {
            try? await Task.sleep(for: .milliseconds(200))
        },
        verificationAttempts: Int = 8,
        verificationDelay: @escaping VerificationDelay = {
            try? await Task.sleep(for: .milliseconds(75))
        }
    ) {
        self.persistedAdapter = persistedAdapter
        self.preference = preference
        self.executeScript = executeScript
        self.persistenceDelay = persistenceDelay
        self.verificationAttempts = max(verificationAttempts, 1)
        self.verificationDelay = verificationDelay
    }

    func read() async throws -> SystemSettingValue {
        try await persistedAdapter.read()
    }

    func apply(_ value: SystemSettingValue) async throws {
        try executeScript(preference.script(for: value))
        await persistenceDelay()
        try await persistedAdapter.apply(value)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        var latest: SystemSettingVerification = .unavailable
        for attempt in 0 ..< verificationAttempts {
            latest = try await persistedAdapter.verify(expectedValue)
            if case .verified = latest {
                return latest
            }
            if attempt + 1 < verificationAttempts {
                await verificationDelay()
            }
        }
        return latest
    }

    func rollback(to value: SystemSettingValue) async throws {
        try await apply(value)
    }

    private static func execute(_ source: String) throws {
        guard let appleScript = NSAppleScript(source: source) else {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not create the system settings command."))
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard let error else { return }
        let message = (error[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw SystemSettingAdapterError.writeFailed(
            message?.isEmpty == false ? message! : MacSettingsStrings.text("Could not apply the Dock setting immediately.")
        )
    }
}

extension DefaultsSystemSettingAdapter {
    static func boolean(
        domain: String,
        key: String,
        defaultValue: Bool,
        inverted: Bool = false,
        notificationName: Notification.Name? = nil
    ) -> DefaultsSystemSettingAdapter {
        DefaultsSystemSettingAdapter(
            domain: domain,
            key: key,
            notificationName: notificationName,
            decode: { object in
                let raw = (object as? NSNumber)?.boolValue ?? defaultValue
                return .boolean(inverted ? !raw : raw)
            },
            encode: { value in
                guard case let .boolean(raw) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return NSNumber(value: inverted ? !raw : raw)
            }
        )
    }

    static func integer(
        domain: String,
        key: String,
        defaultValue: Int
    ) -> DefaultsSystemSettingAdapter {
        DefaultsSystemSettingAdapter(
            domain: domain,
            key: key,
            decode: { object in
                .integer((object as? NSNumber)?.intValue ?? defaultValue)
            },
            encode: { value in
                guard case let .integer(raw) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return NSNumber(value: raw)
            }
        )
    }

    static func decimal(
        domain: String,
        key: String,
        defaultValue: Double,
        notificationName: Notification.Name? = nil
    ) -> DefaultsSystemSettingAdapter {
        DefaultsSystemSettingAdapter(
            domain: domain,
            key: key,
            notificationName: notificationName,
            decode: { object in
                let value = (object as? NSNumber)?.doubleValue ?? defaultValue
                guard value.isFinite else { throw SystemSettingAdapterError.unreadable }
                return .decimal(value)
            },
            encode: { value in
                guard case let .decimal(raw) = value, raw.isFinite else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return NSNumber(value: raw)
            }
        )
    }

    static func choice(
        domain: String,
        key: String,
        defaultValue: String,
        notificationName: Notification.Name? = nil
    ) -> DefaultsSystemSettingAdapter {
        DefaultsSystemSettingAdapter(
            domain: domain,
            key: key,
            notificationName: notificationName,
            decode: { object in
                .choice(id: (object as? String) ?? defaultValue)
            },
            encode: { value in
                guard case let .choice(id) = value, !id.isEmpty else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return id
            }
        )
    }

    static func directoryURL(
        domain: String,
        key: String,
        defaultValue: URL
    ) -> DefaultsSystemSettingAdapter {
        DefaultsSystemSettingAdapter(
            domain: domain,
            key: key,
            decode: { object in
                let path = (object as? String) ?? defaultValue.path(percentEncoded: false)
                return .url(URL(filePath: path, directoryHint: .isDirectory))
            },
            encode: { value in
                guard case let .url(url) = value, url.isFileURL else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return url.path(percentEncoded: false)
            }
        )
    }
}

@MainActor
final class UniversalAccessSystemSettingAdapter: SystemSettingAdapter {
    typealias Reader = () throws -> SystemSettingValue
    typealias Writer = (SystemSettingValue) throws -> Void
    typealias Matcher = (SystemSettingValue, SystemSettingValue) -> Bool

    private let readPersistedValue: Reader
    private let readActiveValue: Reader
    private let write: Writer
    private let valuesMatch: Matcher

    init(
        read: @escaping Reader,
        readActive: Reader? = nil,
        valuesMatch: @escaping Matcher = { $0 == $1 },
        write: @escaping Writer
    ) {
        self.readPersistedValue = read
        self.readActiveValue = readActive ?? read
        self.write = write
        self.valuesMatch = valuesMatch
    }

    func read() async throws -> SystemSettingValue {
        try readPersistedValue()
    }

    func apply(_ value: SystemSettingValue) async throws {
        try write(value)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        let persistedValue = try readPersistedValue()
        guard valuesMatch(persistedValue, expectedValue) else {
            return .mismatch(actual: persistedValue)
        }
        let activeValue = try readActiveValue()
        return valuesMatch(activeValue, expectedValue)
            ? .verified(activeValue)
            : .mismatch(actual: activeValue)
    }
}

extension UniversalAccessSystemSettingAdapter {
    static func cursorSize() -> UniversalAccessSystemSettingAdapter {
        UniversalAccessSystemSettingAdapter(
            read: { .decimal(try UniversalAccessRuntimeClient.shared.activeCursorScale()) },
            readActive: { .decimal(try UniversalAccessRuntimeClient.shared.activeCursorScale()) },
            valuesMatch: { lhs, rhs in
                guard case let .decimal(lhsValue) = lhs,
                      case let .decimal(rhsValue) = rhs else { return false }
                return abs(lhsValue - rhsValue) <= 0.01
            },
            write: { value in
                guard case let .decimal(scale) = value,
                      scale.isFinite,
                      (1 ... 4).contains(scale) else {
                    throw SystemSettingAdapterError.invalidValue
                }
                try UniversalAccessRuntimeClient.shared.setCursorScale(scale)
            }
        )
    }

    static func keyboardZoom() -> UniversalAccessSystemSettingAdapter {
        UniversalAccessSystemSettingAdapter(
            read: { .boolean(try UniversalAccessRuntimeClient.shared.keyboardZoomEnabled()) },
            write: { value in
                guard case let .boolean(enabled) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                try UniversalAccessRuntimeClient.shared.setKeyboardZoomEnabled(enabled)
            }
        )
    }

    static func scrollZoom() -> UniversalAccessSystemSettingAdapter {
        UniversalAccessSystemSettingAdapter(
            read: { .boolean(try UniversalAccessRuntimeClient.shared.scrollZoomEnabled()) },
            write: { value in
                guard case let .boolean(enabled) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                try UniversalAccessRuntimeClient.shared.setScrollZoomEnabled(enabled)
            }
        )
    }

    static func scrollZoomModifier(
        defaultID: String,
        values: [String: Int]
    ) -> UniversalAccessSystemSettingAdapter {
        func decode(_ rawValue: Int) throws -> SystemSettingValue {
            guard let id = values.first(where: { $0.value == rawValue })?.key else {
                if rawValue == 0 { return .choice(id: defaultID) }
                throw SystemSettingAdapterError.unreadable
            }
            return .choice(id: id)
        }

        return UniversalAccessSystemSettingAdapter(
            read: {
                try decode(UniversalAccessRuntimeClient.shared.scrollZoomModifiers())
            },
            readActive: {
                try decode(UniversalAccessRuntimeClient.shared.scrollZoomModifiers())
            },
            write: { value in
                guard case let .choice(id) = value, let raw = values[id] else {
                    throw SystemSettingAdapterError.unreadable
                }
                try UniversalAccessRuntimeClient.shared.setScrollZoomModifiers(raw)
            }
        )
    }

    static func fullKeyboardAccess() -> UniversalAccessSystemSettingAdapter {
        boolean(
            read: { try UniversalAccessRuntimeClient.shared.fullKeyboardAccessEnabled() },
            write: { try UniversalAccessRuntimeClient.shared.setFullKeyboardAccessEnabled($0) }
        )
    }

    static func stickyKeys() -> UniversalAccessSystemSettingAdapter {
        boolean(
            read: { try UniversalAccessRuntimeClient.shared.stickyKeysEnabled() },
            write: { try UniversalAccessRuntimeClient.shared.setStickyKeysEnabled($0) }
        )
    }

    static func slowKeys() -> UniversalAccessSystemSettingAdapter {
        boolean(
            read: { try UniversalAccessRuntimeClient.shared.slowKeysEnabled() },
            write: { try UniversalAccessRuntimeClient.shared.setSlowKeysEnabled($0) }
        )
    }

    private static func boolean(
        read: @escaping () throws -> Bool,
        write: @escaping (Bool) throws -> Void
    ) -> UniversalAccessSystemSettingAdapter {
        UniversalAccessSystemSettingAdapter(
            read: { .boolean(try read()) },
            write: { value in
                guard case let .boolean(enabled) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                try write(enabled)
            }
        )
    }
}

@MainActor
final class TrackpadSecondaryClickSystemSettingAdapter: SystemSettingAdapter {
    typealias Reader = () throws -> String
    typealias Writer = (String) throws -> Void

    private let readSelection: Reader
    private let writeSelection: Writer

    init(
        read: @escaping Reader,
        write: @escaping Writer
    ) {
        readSelection = read
        writeSelection = write
    }

    convenience init() {
        self.init(
            read: { try TrackpadPreferencesClient.shared.secondaryClickMode().rawValue },
            write: { id in
                guard let mode = TrackpadSecondaryClickMode(rawValue: id) else {
                    throw SystemSettingAdapterError.invalidValue
                }
                try TrackpadPreferencesClient.shared.setSecondaryClickMode(mode)
            }
        )
    }

    func read() async throws -> SystemSettingValue {
        .choice(id: try readSelection())
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case let .choice(id) = value else {
            throw SystemSettingAdapterError.invalidValue
        }
        try writeSelection(id)
    }
}

@MainActor
final class LiveScrollSpeedSystemSettingAdapter: SystemSettingAdapter {
    typealias Reader = () throws -> Double
    typealias Writer = (Double) throws -> Void

    private let range: ClosedRange<Double>
    private let tolerance: Double
    private let readSpeed: Reader
    private let writeSpeed: Writer

    init(
        range: ClosedRange<Double> = 0 ... 10,
        tolerance: Double = 0.01,
        read: @escaping Reader,
        write: @escaping Writer
    ) {
        self.range = range
        self.tolerance = tolerance
        readSpeed = read
        writeSpeed = write
    }

    static func trackpad() -> LiveScrollSpeedSystemSettingAdapter {
        LiveScrollSpeedSystemSettingAdapter(
            read: { try TrackpadPreferencesClient.shared.scrollSpeed() },
            write: { try TrackpadPreferencesClient.shared.setScrollSpeed($0) }
        )
    }

    static func mouse() -> LiveScrollSpeedSystemSettingAdapter {
        LiveScrollSpeedSystemSettingAdapter(
            read: { try MousePreferencesClient.shared.scrollSpeed() },
            write: { try MousePreferencesClient.shared.setScrollSpeed($0) }
        )
    }

    func read() async throws -> SystemSettingValue {
        .decimal(try readSpeed() * 10)
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case let .decimal(speed) = value,
              speed.isFinite,
              range.contains(speed) else {
            throw SystemSettingAdapterError.invalidValue
        }
        try writeSpeed(speed / 10)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        guard case let .decimal(expected) = expectedValue else {
            throw SystemSettingAdapterError.invalidValue
        }
        let actual = try readSpeed() * 10
        return abs(actual - expected) <= tolerance
            ? .verified(.decimal(actual))
            : .mismatch(actual: .decimal(actual))
    }
}

@MainActor
final class TrackpadBooleanPreferencesSettingAdapter: SystemSettingAdapter {
    private let domain: String
    private let key: String
    private let store: any FinderPreferencesStoring

    init(domain: String, key: String, store: any FinderPreferencesStoring = CoreFoundationFinderPreferencesStore()) {
        self.domain = domain
        self.key = key
        self.store = store
    }

    func read() async throws -> SystemSettingValue { try await snapshot().value }

    func snapshot() async throws -> SystemSettingSnapshot {
        let state = try store.read(keys: [key], domain: domain)
        return .init(value: try value(from: state), restoration: state)
    }

    private func value(from state: [String: SystemSettingStoredPreference]) throws -> SystemSettingValue {
        guard Set(state.keys) == [key] else { throw SystemSettingAdapterError.invalidValue }
        switch state[key] {
        case .missing: return .boolean(false)
        case let .boolean(enabled): return .boolean(enabled)
        case let .integer(value) where value == 0 || value == 1: return .boolean(value != 0)
        default: throw SystemSettingAdapterError.invalidValue
        }
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case let .boolean(enabled) = value else { throw SystemSettingAdapterError.invalidValue }
        try store.write([key: .boolean(enabled)], domain: domain)
    }

    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        guard snapshot.components == nil, let state = snapshot.restoration,
              try value(from: state) == snapshot.value else { throw SystemSettingAdapterError.invalidValue }
        try store.write(state, domain: domain)
        let actual = try await self.snapshot()
        return actual == snapshot ? .verified(actual.value) : .mismatch(actual: actual.value)
    }
}

@MainActor
final class CompositeBooleanSystemSettingAdapter: SystemSettingAdapter {
    private let adapters: [any SystemSettingAdapter]

    init(adapters: [any SystemSettingAdapter]) {
        self.adapters = adapters
    }

    func read() async throws -> SystemSettingValue {
        guard let first = adapters.first else { throw SystemSettingAdapterError.unreadable }
        return try await first.read()
    }

    func snapshot() async throws -> SystemSettingSnapshot {
        var components: [String: SystemSettingSnapshot] = [:]
        for (index, adapter) in adapters.enumerated() {
            components[String(index)] = try await adapter.snapshot()
        }
        guard let first = components["0"] else { throw SystemSettingAdapterError.unreadable }
        return .init(value: first.value, components: components)
    }

    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        guard snapshot.restoration == nil, let components = snapshot.components,
              Set(components.keys) == Set(adapters.indices.map(String.init)),
              components["0"]?.value == snapshot.value,
              components.values.allSatisfy({ if case .boolean = $0.value { return true }; return false }) else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This history entry lacks complete device snapshots and cannot be safely restored."))
        }
        var firstError: Error?
        for (index, adapter) in adapters.enumerated() {
            let original = components[String(index)]!
            do {
                // An unchanged, read-only domain must not prevent recovery of another device.
                if (try? await adapter.snapshot()) == original { continue }
                _ = try await adapter.restore(original)
            } catch {
                firstError = firstError ?? error
            }
        }
        let actual = try await self.snapshot()
        if actual == snapshot { return .verified(actual.value) }
        if let firstError { throw firstError }
        return .mismatch(actual: actual.value)
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case .boolean = value else { throw SystemSettingAdapterError.invalidValue }
        var firstError: Error?
        var writeCount = 0
        for adapter in adapters {
            do {
                try await adapter.apply(value)
                writeCount += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        guard writeCount > 0 else {
            throw firstError ?? SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not save trackpad settings."))
        }
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        var readableValues: [SystemSettingValue] = []
        for adapter in adapters {
            if let value = try? await adapter.read() {
                readableValues.append(value)
            }
        }
        guard let actual = readableValues.first else { return .unavailable }
        return readableValues.allSatisfy { $0 == expectedValue }
            ? .verified(actual)
            : .mismatch(actual: actual)
    }
}

@MainActor
final class LiveTrackpadBooleanSystemSettingAdapter: SystemSettingAdapter {
    private let persistedAdapter: any SystemSettingAdapter
    private let readLiveValue: () throws -> Bool
    private let writeLiveValue: (Bool) throws -> Void

    init(
        persistedAdapter: any SystemSettingAdapter,
        readLiveValue: @escaping () throws -> Bool,
        writeLiveValue: @escaping (Bool) throws -> Void
    ) {
        self.persistedAdapter = persistedAdapter
        self.readLiveValue = readLiveValue
        self.writeLiveValue = writeLiveValue
    }

    convenience init(threeFingerDragPersistedAdapter: any SystemSettingAdapter) {
        self.init(
            persistedAdapter: threeFingerDragPersistedAdapter,
            readLiveValue: { try TrackpadPreferencesClient.shared.threeFingerDrag() },
            writeLiveValue: { try TrackpadPreferencesClient.shared.setThreeFingerDrag($0) }
        )
    }

    convenience init(tapToClickPersistedAdapter: any SystemSettingAdapter) {
        self.init(
            persistedAdapter: tapToClickPersistedAdapter,
            readLiveValue: { try TrackpadPreferencesClient.shared.tapToClick() },
            writeLiveValue: { try TrackpadPreferencesClient.shared.setTapToClick($0) }
        )
    }

    func read() async throws -> SystemSettingValue {
        try await persistedAdapter.read()
    }

    func snapshot() async throws -> SystemSettingSnapshot {
        let persisted = try await persistedAdapter.snapshot()
        return .init(value: persisted.value, components: [
            "persisted": persisted,
            "live": .init(value: .boolean(try readLiveValue())),
        ])
    }

    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        guard snapshot.restoration == nil, let components = snapshot.components,
              Set(components.keys) == ["persisted", "live"],
              let persisted = components["persisted"], persisted.value == snapshot.value,
              let live = components["live"], !live.hasRestorationData,
              case let .boolean(enabled) = live.value else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This history entry lacks device and live-state snapshots and cannot be safely restored."))
        }
        // The runtime setter may write preferences itself. Restore the exact domains afterwards.
        var firstError: Error?
        do {
            if (try? readLiveValue()) != enabled { try writeLiveValue(enabled) }
        } catch { firstError = error }
        do { _ = try await persistedAdapter.restore(persisted) }
        catch { firstError = firstError ?? error }
        let actual = try await self.snapshot()
        if actual == snapshot { return .verified(actual.value) }
        if let firstError { throw firstError }
        return .mismatch(actual: actual.value)
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case let .boolean(enabled) = value else {
            throw SystemSettingAdapterError.invalidValue
        }
        try writeLiveValue(enabled)
        try await persistedAdapter.apply(value)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        guard case let .boolean(expected) = expectedValue else {
            throw SystemSettingAdapterError.invalidValue
        }
        let liveValue = try readLiveValue()
        guard liveValue == expected else {
            return .mismatch(actual: .boolean(liveValue))
        }
        return try await persistedAdapter.verify(expectedValue)
    }
}

@MainActor
final class LiveTrackpadDecimalSystemSettingAdapter: SystemSettingAdapter {
    private let persistedAdapter: any SystemSettingAdapter
    private let tolerance: Double

    init(
        persistedAdapter: any SystemSettingAdapter,
        tolerance: Double = 0.01
    ) {
        self.persistedAdapter = persistedAdapter
        self.tolerance = tolerance
    }

    func read() async throws -> SystemSettingValue {
        try await persistedAdapter.read()
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case let .decimal(speed) = value,
              speed.isFinite,
              (0 ... 3).contains(speed) else {
            throw SystemSettingAdapterError.invalidValue
        }
        try TrackpadPreferencesClient.shared.setTrackingSpeed(speed)
        try await persistedAdapter.apply(value)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        guard case let .decimal(expected) = expectedValue else {
            throw SystemSettingAdapterError.invalidValue
        }
        let liveValue = try TrackpadPreferencesClient.shared.trackingSpeed()
        guard abs(liveValue - expected) <= tolerance else {
            return .mismatch(actual: .decimal(liveValue))
        }
        return try await persistedAdapter.verify(expectedValue)
    }
}

@MainActor
final class ExistingPluginActionSettingAdapter: SystemSettingAdapter {
    private let reader: () async throws -> SystemSettingValue
    private let reference: (SystemSettingValue) throws -> ActionReference
    private let context: () -> PluginActionExecutionHostContext?

    init(
        reader: @escaping () async throws -> SystemSettingValue,
        reference: @escaping (SystemSettingValue) throws -> ActionReference,
        context: @escaping () -> PluginActionExecutionHostContext?
    ) {
        self.reader = reader
        self.reference = reference
        self.context = context
    }

    func read() async throws -> SystemSettingValue {
        let value = try await reader()
        let reference = try reference(value)
        guard let item = context()?.item(for: reference) else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("The required MacTools plugin is unavailable."))
        }
        guard item.availability.isAvailable else {
            throw SystemSettingAdapterError.unsupported(item.availability.reason ?? MacSettingsStrings.text("The required MacTools plugin is currently unavailable."))
        }
        return value
    }

    func apply(_ value: SystemSettingValue) async throws {
        let reference = try reference(value)
        guard let context = context() else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("The required MacTools plugin is unavailable."))
        }
        switch await context.execute(reference, source: .manual) {
        case .succeeded:
            return
        case let .failed(message), let .unavailable(message):
            throw SystemSettingAdapterError.writeFailed(message)
        case .cancelled:
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("The operation was cancelled."))
        }
    }
}

@MainActor
final class UnavailableSystemSettingAdapter: SystemSettingAdapter {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func read() async throws -> SystemSettingValue {
        throw SystemSettingAdapterError.unsupported(message)
    }

    func apply(_ value: SystemSettingValue) async throws {
        throw SystemSettingAdapterError.unsupported(message)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        .unavailable
    }
}

@MainActor
final class DeterministicSystemSettingAdapter: SystemSettingAdapter {
    var value: SystemSettingValue
    var readError: Error?
    var applyError: Error?
    var verificationOverride: SystemSettingVerification?
    var queuedVerificationOverrides: [SystemSettingVerification] = []
    private(set) var appliedValues: [SystemSettingValue] = []
    private(set) var rollbackValues: [SystemSettingValue] = []

    init(value: SystemSettingValue) {
        self.value = value
    }

    func read() async throws -> SystemSettingValue {
        if let readError { throw readError }
        return value
    }

    func apply(_ value: SystemSettingValue) async throws {
        if let applyError { throw applyError }
        appliedValues.append(value)
        self.value = value
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        if !queuedVerificationOverrides.isEmpty {
            return queuedVerificationOverrides.removeFirst()
        }
        return verificationOverride ?? (value == expectedValue ? .verified(value) : .mismatch(actual: value))
    }

    func rollback(to value: SystemSettingValue) async throws {
        rollbackValues.append(value)
        self.value = value
    }
}
