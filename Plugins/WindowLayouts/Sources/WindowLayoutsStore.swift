import CoreGraphics
import Foundation
import MacToolsPluginKit

@MainActor
final class WindowLayoutsStore {
    private enum StorageKey {
        static let gap = "gap"
        static let cyclesHalves = "cycles-halves"
        static let respectsStageManager = "respects-stage-manager"
        static let showsCommandFeedback = "shows-command-feedback"
        static let shortcutPreset = "shortcut-preset"
        static let library = "library.v1"
        static let quarantinedLibrary = "library.v1.quarantined"
    }

    private struct LibraryEnvelope: Codable {
        let formatVersion: Int
        let customCommands: [WindowCustomCommand]
    }

    static let gapRange: ClosedRange<Double> = 0...40
    static let defaultGap: Double = 0
    static let maximumCustomCommandCount = 32
    private static let maximumCustomCommandNameLength = 80
    private static let pointDimensionRange: ClosedRange<CGFloat> = 100...3_000
    private static let fractionDimensionRange: ClosedRange<CGFloat> = 0.05...1
    private static let offsetRange: ClosedRange<CGFloat> = -500...500

    private let storage: PluginStorage
    private(set) var gap: Double
    private(set) var cyclesHalves: Bool
    private(set) var respectsStageManager: Bool
    private(set) var showsCommandFeedback: Bool
    private(set) var shortcutPreset: WindowShortcutPreset
    private(set) var customCommands: [WindowCustomCommand] = []
    private(set) var revision: UInt64 = 0
    var onMutation: (() -> Void)?

    init(storage: PluginStorage) {
        self.storage = storage
        let storedGap = (storage.object(forKey: StorageKey.gap) as? NSNumber)?.doubleValue
            ?? Self.defaultGap
        self.gap = Self.clampedGap(storedGap)
        self.cyclesHalves = (storage.object(forKey: StorageKey.cyclesHalves) as? NSNumber)?.boolValue ?? false
        self.respectsStageManager = (storage.object(forKey: StorageKey.respectsStageManager) as? NSNumber)?.boolValue ?? true
        self.showsCommandFeedback = (storage.object(forKey: StorageKey.showsCommandFeedback) as? NSNumber)?.boolValue ?? false
        let storedShortcutPreset = storage.string(forKey: StorageKey.shortcutPreset)
        self.shortcutPreset = WindowShortcutPreset(storedValue: storedShortcutPreset)
        if storedShortcutPreset == "raycast" || storedShortcutPreset == "rectangle" {
            storage.set(shortcutPreset.rawValue, forKey: StorageKey.shortcutPreset)
        }
        reloadLibrary()
    }

    func setGap(_ gap: Double) {
        let gap = Self.clampedGap(gap)
        self.gap = gap
        storage.set(gap, forKey: StorageKey.gap)
        recordMutation()
    }

    func setCyclesHalves(_ enabled: Bool) {
        cyclesHalves = enabled
        storage.set(enabled, forKey: StorageKey.cyclesHalves)
        recordMutation()
    }

    func setRespectsStageManager(_ enabled: Bool) {
        respectsStageManager = enabled
        storage.set(enabled, forKey: StorageKey.respectsStageManager)
        recordMutation()
    }

    func setShowsCommandFeedback(_ enabled: Bool) {
        showsCommandFeedback = enabled
        storage.set(enabled, forKey: StorageKey.showsCommandFeedback)
        recordMutation()
    }

    func setShortcutPreset(_ preset: WindowShortcutPreset) {
        shortcutPreset = preset
        storage.set(preset.rawValue, forKey: StorageKey.shortcutPreset)
        recordMutation()
    }

    func reset() {
        gap = Self.defaultGap
        cyclesHalves = false
        respectsStageManager = true
        showsCommandFeedback = false
        storage.removeObject(forKey: StorageKey.gap)
        storage.removeObject(forKey: StorageKey.cyclesHalves)
        storage.removeObject(forKey: StorageKey.respectsStageManager)
        storage.removeObject(forKey: StorageKey.showsCommandFeedback)
        recordMutation()
    }

    @discardableResult
    func addCustomCommand(name: String) -> WindowCustomCommand? {
        guard customCommands.count < Self.maximumCustomCommandCount else { return nil }
        let command = WindowCustomCommand(name: normalizedName(name, fallback: "Custom Layout"))
        var updated = customCommands
        updated.append(command)
        guard persist(customCommands: updated) else { return nil }
        customCommands = updated
        recordMutation()
        return command
    }

    @discardableResult
    func updateCustomCommand(_ command: WindowCustomCommand) -> Bool {
        guard let index = customCommands.firstIndex(where: { $0.id == command.id })
        else { return false }
        guard let normalized = normalizedCommand(command) else { return false }
        var updated = customCommands
        updated[index] = normalized
        guard persist(customCommands: updated) else { return false }
        customCommands = updated
        recordMutation()
        return true
    }

    @discardableResult
    func duplicateCustomCommand(id: UUID, copySuffix: String) -> WindowCustomCommand? {
        guard let source = customCommands.first(where: { $0.id == id }),
              customCommands.count < Self.maximumCustomCommandCount
        else { return nil }
        let copy = WindowCustomCommand(
            name: duplicateName(source.name, copySuffix: copySuffix),
            width: source.width,
            height: source.height,
            anchor: source.anchor,
            offsetX: source.offsetX,
            offsetY: source.offsetY,
            allowExternalInvocation: source.allowExternalInvocation
        )
        var updated = customCommands
        updated.append(copy)
        guard persist(customCommands: updated) else { return nil }
        customCommands = updated
        recordMutation()
        return copy
    }

    @discardableResult
    func removeCustomCommand(id: UUID) -> Bool {
        var updated = customCommands
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
        updated.remove(at: index)
        guard persist(customCommands: updated) else { return false }
        customCommands = updated
        recordMutation()
        return true
    }

    func customCommand(actionID: String) -> WindowCustomCommand? {
        customCommands.first { $0.actionID == actionID }
    }

    func customCommand(id: UUID) -> WindowCustomCommand? {
        customCommands.first { $0.id == id }
    }

    private func reloadLibrary() {
        guard let data = storage.data(forKey: StorageKey.library) else { return }
        guard data.count <= 2 * 1_024 * 1_024,
              let envelope = try? JSONDecoder().decode(LibraryEnvelope.self, from: data),
              envelope.formatVersion == 1,
              envelope.customCommands.count <= Self.maximumCustomCommandCount,
              let normalizedCommands = normalizedCommands(envelope.customCommands)
        else {
            quarantine(data)
            return
        }
        if normalizedCommands != envelope.customCommands,
           !persist(customCommands: normalizedCommands) {
            quarantine(data)
            return
        }
        customCommands = normalizedCommands
    }

    private func persist(customCommands: [WindowCustomCommand]) -> Bool {
        guard customCommands.count <= Self.maximumCustomCommandCount,
              let normalizedCommands = normalizedCommands(customCommands),
              normalizedCommands == customCommands,
              let data = try? JSONEncoder().encode(LibraryEnvelope(
            formatVersion: 1,
            customCommands: customCommands
        )), data.count <= 2 * 1_024 * 1_024 else {
            return false
        }
        storage.set(data, forKey: StorageKey.library)
        return storage.data(forKey: StorageKey.library) == data
    }

    private func normalizedCommands(
        _ commands: [WindowCustomCommand]
    ) -> [WindowCustomCommand]? {
        var seenIDs: Set<UUID> = []
        var result: [WindowCustomCommand] = []
        result.reserveCapacity(commands.count)
        for command in commands {
            guard seenIDs.insert(command.id).inserted,
                  let normalized = normalizedCommand(command)
            else {
                return nil
            }
            result.append(normalized)
        }
        return result
    }

    private func normalizedCommand(_ command: WindowCustomCommand) -> WindowCustomCommand? {
        guard let width = normalizedDimension(command.width),
              let height = normalizedDimension(command.height),
              command.offsetX.isFinite,
              command.offsetY.isFinite
        else {
            return nil
        }
        var normalized = command
        normalized.name = normalizedName(command.name, fallback: "Custom Layout")
        normalized.width = width
        normalized.height = height
        normalized.offsetX = min(max(command.offsetX, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        normalized.offsetY = min(max(command.offsetY, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        return normalized
    }

    private func normalizedDimension(
        _ dimension: WindowLayoutDimension
    ) -> WindowLayoutDimension? {
        switch dimension {
        case .current:
            return .current
        case let .points(value):
            guard value.isFinite else { return nil }
            return .points(min(max(value, Self.pointDimensionRange.lowerBound), Self.pointDimensionRange.upperBound))
        case let .fraction(value):
            guard value.isFinite else { return nil }
            return .fraction(min(max(value, Self.fractionDimensionRange.lowerBound), Self.fractionDimensionRange.upperBound))
        }
    }

    private func quarantine(_ data: Data) {
        storage.set(data, forKey: StorageKey.quarantinedLibrary)
        storage.removeObject(forKey: StorageKey.library)
    }

    private func normalizedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(Self.maximumCustomCommandNameLength))
    }

    private func duplicateName(_ sourceName: String, copySuffix: String) -> String {
        let trimmedSuffix = copySuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuffix.isEmpty else {
            return normalizedName(sourceName, fallback: "Custom Layout")
        }
        let boundedSuffix = String(trimmedSuffix.prefix(Self.maximumCustomCommandNameLength - 2))
        let suffix = " \(boundedSuffix)"
        let sourceLength = max(1, Self.maximumCustomCommandNameLength - suffix.count)
        let source = String(sourceName.prefix(sourceLength))
        return normalizedName(source + suffix, fallback: "Custom Layout")
    }

    private func recordMutation() {
        revision &+= 1
        onMutation?()
    }

    private static func clampedGap(_ gap: Double) -> Double {
        guard gap.isFinite else { return defaultGap }
        return min(max(gap, gapRange.lowerBound), gapRange.upperBound)
    }
}
