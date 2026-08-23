import Foundation
import MacToolsPluginKit

enum SidecarConnectionTransport: String, Codable, CaseIterable {
    case automatic
    case wiredOnly
}

enum SidecarShortcutAction: String, Codable, CaseIterable {
    case toggle
    case connect
    case disconnect
}

struct SidecarDevicePreference: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var transport: SidecarConnectionTransport
    var shortcutAction: SidecarShortcutAction
    /// A legacy default binding. New bindings are stored and validated by the host shortcut store.
    var shortcut: ShortcutBinding?
    var hasShortcutConfiguration: Bool

    init(
        id: String,
        name: String,
        transport: SidecarConnectionTransport = .automatic,
        shortcutAction: SidecarShortcutAction = .toggle,
        shortcut: ShortcutBinding? = nil,
        hasShortcutConfiguration: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.shortcutAction = shortcutAction
        self.shortcut = shortcut
        self.hasShortcutConfiguration = hasShortcutConfiguration ?? (shortcut != nil)
    }

    var hasCustomConfiguration: Bool {
        transport != .automatic || shortcutAction != .toggle || shortcut != nil || hasShortcutConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case transport
        case shortcutAction
        case shortcut
        case hasShortcutConfiguration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(SidecarConnectionTransport.self, forKey: .transport)
        shortcutAction = try container.decode(SidecarShortcutAction.self, forKey: .shortcutAction)
        shortcut = try container.decodeIfPresent(ShortcutBinding.self, forKey: .shortcut)
        hasShortcutConfiguration = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasShortcutConfiguration
        ) ?? (shortcut != nil)
    }
}

@MainActor
final class SidecarPreferencesStore: ObservableObject {
    private enum StorageKey {
        static let devices = "savedDevices"
        static let disconnectAllShortcut = "disconnectAllShortcut"
        static let connectFirstAvailableShortcut = "connectFirstAvailableShortcut"
        static let portableRestoreTransaction = "portable-restore-transaction.v1"
    }

    private struct PortablePreferences: Codable, Equatable {
        let devices: [SidecarDevicePreference]
        let disconnectAllShortcut: ShortcutBinding?
        let connectFirstAvailableShortcut: ShortcutBinding?
    }

    private enum PersistenceResult {
        case unchanged
        case persisted
        case failed
    }

    private struct PortableRestoreTransaction: Codable {
        let devices: Data?
        let disconnectAllShortcut: Data?
        let connectFirstAvailableShortcut: Data?
    }

    @Published private(set) var devices: [SidecarDevicePreference]
    @Published private(set) var disconnectAllShortcut: ShortcutBinding?
    @Published private(set) var connectFirstAvailableShortcut: ShortcutBinding?
    private(set) var didPersistPortablePreferencesDuringInitialization = false

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: PluginStorage) {
        self.storage = storage
        let initialDevicesData = storage.data(forKey: StorageKey.devices)
        let initialDisconnectAllShortcutData = storage.data(
            forKey: StorageKey.disconnectAllShortcut
        )
        let initialConnectFirstAvailableShortcutData = storage.data(
            forKey: StorageKey.connectFirstAvailableShortcut
        )
        _ = Self.recoverInterruptedPortableRestore(
            storage: storage,
            encoder: JSONEncoder(),
            decoder: JSONDecoder()
        )
        let storedDevices: [SidecarDevicePreference]
        if let data = storage.data(forKey: StorageKey.devices),
           let savedDevices = try? decoder.decode([SidecarDevicePreference].self, from: data) {
            storedDevices = savedDevices
        } else {
            storedDevices = []
        }

        let storedDisconnectAllShortcut: ShortcutBinding?
        if let data = storage.data(forKey: StorageKey.disconnectAllShortcut),
           let binding = try? decoder.decode(ShortcutBinding.self, from: data) {
            storedDisconnectAllShortcut = binding
        } else {
            storedDisconnectAllShortcut = nil
        }

        let storedConnectFirstAvailableShortcut: ShortcutBinding?
        if let data = storage.data(forKey: StorageKey.connectFirstAvailableShortcut),
           let binding = try? decoder.decode(ShortcutBinding.self, from: data) {
            storedConnectFirstAvailableShortcut = binding
        } else {
            storedConnectFirstAvailableShortcut = nil
        }

        let normalized = Self.normalizedShortcuts(
            devices: storedDevices,
            disconnectAllShortcut: storedDisconnectAllShortcut,
            connectFirstAvailableShortcut: storedConnectFirstAvailableShortcut
        )
        devices = storedDevices
        disconnectAllShortcut = storedDisconnectAllShortcut
        connectFirstAvailableShortcut = storedConnectFirstAvailableShortcut

        if normalized.devices != storedDevices
            || normalized.disconnectAllShortcut != storedDisconnectAllShortcut
            || normalized.connectFirstAvailableShortcut != storedConnectFirstAvailableShortcut {
            _ = persistPortablePreferences(PortablePreferences(
                devices: normalized.devices,
                disconnectAllShortcut: normalized.disconnectAllShortcut,
                connectFirstAvailableShortcut: normalized.connectFirstAvailableShortcut
            ))
        }
        didPersistPortablePreferencesDuringInitialization =
            storage.data(forKey: StorageKey.devices) != initialDevicesData
            || storage.data(forKey: StorageKey.disconnectAllShortcut)
                != initialDisconnectAllShortcutData
            || storage.data(forKey: StorageKey.connectFirstAvailableShortcut)
                != initialConnectFirstAvailableShortcutData
    }

    @discardableResult
    func reconcile(with reachableDevices: [SidecarDevice]) -> Bool {
        var updated = devices
        var didChange = false

        for device in reachableDevices {
            if let index = updated.firstIndex(where: { $0.id == device.id }) {
                guard updated[index].name != device.name else { continue }
                updated[index].name = device.name
                didChange = true
            } else {
                updated.append(SidecarDevicePreference(id: device.id, name: device.name))
                didChange = true
            }
        }

        guard didChange else { return false }
        return persistPortablePreferences(currentPreferences(replacingDevices: updated)) == .persisted
    }

    func preference(for deviceID: String) -> SidecarDevicePreference? {
        devices.first(where: { $0.id == deviceID })
    }

    @discardableResult
    func updateTransport(_ transport: SidecarConnectionTransport, for deviceID: String) -> Bool {
        update(deviceID: deviceID) { $0.transport = transport }
    }

    @discardableResult
    func updateShortcutAction(_ action: SidecarShortcutAction, for deviceID: String) -> Bool {
        update(deviceID: deviceID) { $0.shortcutAction = action }
    }

    @discardableResult
    func updateShortcut(_ shortcut: ShortcutBinding?, for deviceID: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        guard devices[index].shortcut != shortcut
            || devices[index].hasShortcutConfiguration != (shortcut != nil)
        else {
            return false
        }
        var updated = devices
        updated[index].shortcut = shortcut
        updated[index].hasShortcutConfiguration = shortcut != nil
        return persistPortablePreferences(currentPreferences(replacingDevices: updated)) == .persisted
    }

    @discardableResult
    func updateShortcutConfiguration(_ hasConfiguration: Bool, for deviceID: String) -> Bool {
        update(deviceID: deviceID) { $0.hasShortcutConfiguration = hasConfiguration }
    }

    @discardableResult
    func updateDisconnectAllShortcut(_ shortcut: ShortcutBinding?) -> Bool {
        guard disconnectAllShortcut != shortcut else { return false }
        return persistPortablePreferences(PortablePreferences(
            devices: devices,
            disconnectAllShortcut: shortcut,
            connectFirstAvailableShortcut: connectFirstAvailableShortcut
        )) == .persisted
    }

    @discardableResult
    func updateConnectFirstAvailableShortcut(_ shortcut: ShortcutBinding?) -> Bool {
        guard connectFirstAvailableShortcut != shortcut else { return false }
        return persistPortablePreferences(PortablePreferences(
            devices: devices,
            disconnectAllShortcut: disconnectAllShortcut,
            connectFirstAvailableShortcut: shortcut
        )) == .persisted
    }

    @discardableResult
    func clearLegacyShortcuts() -> Bool {
        var updatedDevices = devices
        for index in updatedDevices.indices {
            updatedDevices[index].shortcut = nil
            updatedDevices[index].hasShortcutConfiguration = false
        }
        return persistPortablePreferences(PortablePreferences(
            devices: updatedDevices,
            disconnectAllShortcut: nil,
            connectFirstAvailableShortcut: nil
        )) == .persisted
    }

    @discardableResult
    func move(deviceID: String, before beforeDeviceID: String?) -> Bool {
        guard let sourceIndex = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        var updated = devices
        let device = updated.remove(at: sourceIndex)
        let destinationIndex = beforeDeviceID.flatMap { targetID in
            updated.firstIndex(where: { $0.id == targetID })
        } ?? updated.endIndex
        updated.insert(device, at: destinationIndex)
        guard updated != devices else { return false }
        return persistPortablePreferences(currentPreferences(replacingDevices: updated)) == .persisted
    }

    func priorityIndex(for deviceID: String) -> Int {
        devices.firstIndex(where: { $0.id == deviceID }) ?? .max
    }

    func portablePreferencesData() -> Data? {
        try? encoder.encode(PortablePreferences(
            devices: devices,
            disconnectAllShortcut: disconnectAllShortcut,
            connectFirstAvailableShortcut: connectFirstAvailableShortcut
        ))
    }

    @discardableResult
    func restorePortablePreferences(from data: Data) -> Bool {
        guard let portablePreferences = try? decoder.decode(PortablePreferences.self, from: data) else {
            return false
        }
        let normalized = Self.normalizedShortcuts(
            devices: portablePreferences.devices,
            disconnectAllShortcut: portablePreferences.disconnectAllShortcut,
            connectFirstAvailableShortcut: portablePreferences.connectFirstAvailableShortcut
        )
        switch persistPortablePreferences(PortablePreferences(
            devices: normalized.devices,
            disconnectAllShortcut: normalized.disconnectAllShortcut,
            connectFirstAvailableShortcut: normalized.connectFirstAvailableShortcut
        )) {
        case .unchanged, .persisted:
            return true
        case .failed:
            return false
        }
    }

    func deviceIDs(inPortablePreferences data: Data) -> [String]? {
        guard let portablePreferences = try? decoder.decode(PortablePreferences.self, from: data)
        else {
            return nil
        }
        return Self.normalizedShortcuts(
            devices: portablePreferences.devices,
            disconnectAllShortcut: portablePreferences.disconnectAllShortcut,
            connectFirstAvailableShortcut: portablePreferences.connectFirstAvailableShortcut
        ).devices.map(\.id)
    }

    private func beginPortableRestoreTransaction() -> Bool {
        guard Self.hasExpectedData(forKey: StorageKey.devices, storage: storage),
              Self.hasExpectedData(forKey: StorageKey.disconnectAllShortcut, storage: storage),
              Self.hasExpectedData(forKey: StorageKey.connectFirstAvailableShortcut, storage: storage)
        else {
            return false
        }
        let transaction = PortableRestoreTransaction(
            devices: storage.data(forKey: StorageKey.devices),
            disconnectAllShortcut: storage.data(forKey: StorageKey.disconnectAllShortcut),
            connectFirstAvailableShortcut: storage.data(forKey: StorageKey.connectFirstAvailableShortcut)
        )
        guard let data = try? encoder.encode(transaction) else { return false }
        storage.set(data, forKey: StorageKey.portableRestoreTransaction)
        return storage.data(forKey: StorageKey.portableRestoreTransaction) == data
    }

    private func recoverInterruptedPortableRestore() -> Bool {
        Self.recoverInterruptedPortableRestore(
            storage: storage,
            encoder: encoder,
            decoder: decoder
        )
    }

    private static func recoverInterruptedPortableRestore(
        storage: PluginStorage,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) -> Bool {
        guard let rawTransaction = storage.object(forKey: StorageKey.portableRestoreTransaction) else {
            return true
        }
        guard let transactionData = rawTransaction as? Data else { return false }
        guard let transaction = try? decoder.decode(
            PortableRestoreTransaction.self,
            from: transactionData
        ), writePortableValues(transaction, storage: storage) else {
            return false
        }
        storage.removeObject(forKey: StorageKey.portableRestoreTransaction)
        return storage.object(forKey: StorageKey.portableRestoreTransaction) == nil
    }

    @discardableResult
    private func rollbackPortableRestoreTransaction() -> Bool {
        recoverInterruptedPortableRestore()
    }

    private func finishPortableRestoreTransaction() -> Bool {
        storage.removeObject(forKey: StorageKey.portableRestoreTransaction)
        return storage.object(forKey: StorageKey.portableRestoreTransaction) == nil
    }

    private func writePortableValues(
        devices: Data?,
        disconnectAllShortcut: Data?,
        connectFirstAvailableShortcut: Data?
    ) -> Bool {
        Self.writePortableValues(
            PortableRestoreTransaction(
                devices: devices,
                disconnectAllShortcut: disconnectAllShortcut,
                connectFirstAvailableShortcut: connectFirstAvailableShortcut
            ),
            storage: storage
        )
    }

    private static func writePortableValues(
        _ values: PortableRestoreTransaction,
        storage: PluginStorage
    ) -> Bool {
        setOptional(values.devices, forKey: StorageKey.devices, storage: storage)
        setOptional(
            values.disconnectAllShortcut,
            forKey: StorageKey.disconnectAllShortcut,
            storage: storage
        )
        setOptional(
            values.connectFirstAvailableShortcut,
            forKey: StorageKey.connectFirstAvailableShortcut,
            storage: storage
        )
        return storage.data(forKey: StorageKey.devices) == values.devices
            && storage.data(forKey: StorageKey.disconnectAllShortcut) == values.disconnectAllShortcut
            && storage.data(forKey: StorageKey.connectFirstAvailableShortcut)
                == values.connectFirstAvailableShortcut
    }

    private static func setOptional(_ value: Any?, forKey key: String, storage: PluginStorage) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private static func hasExpectedData(forKey key: String, storage: PluginStorage) -> Bool {
        guard let rawValue = storage.object(forKey: key) else { return true }
        return rawValue is Data
    }

    private func update(
        deviceID: String,
        _ change: (inout SidecarDevicePreference) -> Void
    ) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        var updatedDevices = devices
        change(&updatedDevices[index])
        guard updatedDevices != devices else { return false }
        return persistPortablePreferences(currentPreferences(replacingDevices: updatedDevices)) == .persisted
    }

    private func currentPreferences(
        replacingDevices replacementDevices: [SidecarDevicePreference]? = nil
    ) -> PortablePreferences {
        PortablePreferences(
            devices: replacementDevices ?? devices,
            disconnectAllShortcut: disconnectAllShortcut,
            connectFirstAvailableShortcut: connectFirstAvailableShortcut
        )
    }

    private func persistPortablePreferences(_ candidate: PortablePreferences) -> PersistenceResult {
        let normalized = Self.normalizedShortcuts(
            devices: candidate.devices,
            disconnectAllShortcut: candidate.disconnectAllShortcut,
            connectFirstAvailableShortcut: candidate.connectFirstAvailableShortcut
        )
        let normalizedCandidate = PortablePreferences(
            devices: normalized.devices,
            disconnectAllShortcut: normalized.disconnectAllShortcut,
            connectFirstAvailableShortcut: normalized.connectFirstAvailableShortcut
        )
        let current = currentPreferences()
        guard normalizedCandidate != current else { return .unchanged }
        guard let devicesData = try? encoder.encode(normalizedCandidate.devices) else {
            return .failed
        }
        let disconnectData: Data?
        if let shortcut = normalizedCandidate.disconnectAllShortcut {
            guard let encoded = try? encoder.encode(shortcut) else { return .failed }
            disconnectData = encoded
        } else {
            disconnectData = nil
        }
        let connectData: Data?
        if let shortcut = normalizedCandidate.connectFirstAvailableShortcut {
            guard let encoded = try? encoder.encode(shortcut) else { return .failed }
            connectData = encoded
        } else {
            connectData = nil
        }
        guard recoverInterruptedPortableRestore(),
              beginPortableRestoreTransaction(),
              writePortableValues(
                  devices: devicesData,
                  disconnectAllShortcut: disconnectData,
                  connectFirstAvailableShortcut: connectData
              ),
              finishPortableRestoreTransaction() else {
            rollbackPortableRestoreTransaction()
            return .failed
        }
        devices = normalizedCandidate.devices
        disconnectAllShortcut = normalizedCandidate.disconnectAllShortcut
        connectFirstAvailableShortcut = normalizedCandidate.connectFirstAvailableShortcut
        return .persisted
    }

    private static func normalizedShortcuts(
        devices candidates: [SidecarDevicePreference],
        disconnectAllShortcut: ShortcutBinding?,
        connectFirstAvailableShortcut: ShortcutBinding?
    ) -> (
        devices: [SidecarDevicePreference],
        disconnectAllShortcut: ShortcutBinding?,
        connectFirstAvailableShortcut: ShortcutBinding?
    ) {
        var usedBindings = Set<ShortcutBinding>()
        func uniqueBinding(_ binding: ShortcutBinding?) -> ShortcutBinding? {
            guard let binding, binding.isValid, usedBindings.insert(binding).inserted else {
                return nil
            }
            return binding
        }

        let normalizedConnectFirstAvailableShortcut = uniqueBinding(connectFirstAvailableShortcut)
        let normalizedDisconnectAllShortcut = uniqueBinding(disconnectAllShortcut)
        var normalizedDevices = uniqueDevices(candidates)
        for index in normalizedDevices.indices {
            normalizedDevices[index].shortcut = uniqueBinding(normalizedDevices[index].shortcut)
        }
        return (
            normalizedDevices,
            normalizedDisconnectAllShortcut,
            normalizedConnectFirstAvailableShortcut
        )
    }

    private static func uniqueDevices(_ candidates: [SidecarDevicePreference]) -> [SidecarDevicePreference] {
        var seenIDs = Set<String>()
        return candidates.filter { seenIDs.insert($0.id).inserted }
    }
}
