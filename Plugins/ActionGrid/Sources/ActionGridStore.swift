import Combine
import Foundation
import MacToolsPluginKit

struct ActionGridEntry: Codable, Equatable, Identifiable, Sendable {
    static let maximumCustomTitleByteCount = 80

    let id: UUID
    var reference: ActionReference
    var customTitle: String?
    var folder: ActionGridFolder?
    /// Zero-based position in the containing 3×3 grid. Optional only so
    /// layouts written before format version 3 can be decoded and migrated.
    var slot: Int?

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        customTitle: String? = nil,
        folder: ActionGridFolder? = nil,
        slot: Int? = nil
    ) {
        self.id = id
        self.reference = reference
        self.customTitle = customTitle
        self.folder = folder
        self.slot = slot
    }

    static func folder(
        id: UUID = UUID(),
        title: String,
        systemImage: String = "folder.fill",
        slot: Int? = nil
    ) -> ActionGridEntry {
        ActionGridEntry(
            id: id,
            reference: ActionReference(
                key: ActionKey(
                    providerID: ActionGridStore.folderProviderID,
                    actionID: id.uuidString.lowercased()
                )
            ),
            customTitle: title,
            folder: ActionGridFolder(systemImage: systemImage),
            slot: slot
        )
    }

    var presentationEntry: ActionGridPresentationEntry {
        if let folder {
            return ActionGridPresentationEntry(
                id: id.uuidString.lowercased(),
                folderTitle: customTitle ?? "Folder",
                systemImage: folder.systemImage,
                children: folder.entries.map(\.presentationEntry),
                slotIndex: slot
            )
        }
        return ActionGridPresentationEntry(
            id: id.uuidString.lowercased(),
            reference: reference,
            customTitle: customTitle,
            slotIndex: slot
        )
    }
}

struct ActionGridFolder: Codable, Equatable, Sendable {
    var systemImage: String
    var entries: [ActionGridEntry]

    init(systemImage: String = "folder.fill", entries: [ActionGridEntry] = []) {
        self.systemImage = systemImage
        self.entries = entries
    }
}

@MainActor
final class ActionGridStore: ObservableObject {
    private struct Envelope: Codable {
        let formatVersion: Int
        let entries: [ActionGridEntry]
    }

    static let currentFormatVersion = 3
    static let maximumEntryCount = 9
    static let maximumFolderDepth = 3
    static let maximumTotalEntryCount = 128
    static let maximumPayloadByteCount = 64 * 1_024
    nonisolated static let folderProviderID = "action-grid.folder"
    private static let storageKey = "layout.v1"

    @Published private(set) var entries: [ActionGridEntry] = []
    @Published private(set) var loadError: String?
    private(set) var didPersistPortablePreferencesDuringInitialization = false

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        let initialData = storage.data(forKey: Self.storageKey)
        reload()
        didPersistPortablePreferencesDuringInitialization =
            storage.data(forKey: Self.storageKey) != initialData
    }

    @discardableResult
    func add(reference: ActionReference) -> Bool {
        add(reference: reference, in: nil)
    }

    @discardableResult
    func add(reference: ActionReference, in folderID: UUID?) -> Bool {
        add(reference: reference, in: folderID, at: nil)
    }

    @discardableResult
    func add(reference: ActionReference, in folderID: UUID?, at requestedSlot: Int?) -> Bool {
        add(reference: reference, customTitle: nil, in: folderID, at: requestedSlot)
    }

    @discardableResult
    func add(
        reference: ActionReference,
        customTitle: String?,
        in folderID: UUID?,
        at requestedSlot: Int?
    ) -> Bool {
        guard Self.isValidCustomTitle(customTitle) else {
            return false
        }
        let customTitle = Self.normalizedCustomTitle(customTitle)
        return updateEntries(in: folderID) { entries in
            guard let slot = Self.availableSlot(requestedSlot, in: entries),
                  !entries.contains(where: { $0.folder == nil && $0.reference == reference }) else {
                return false
            }
            var entry = ActionGridEntry(reference: reference, slot: slot)
            entry.customTitle = customTitle
            entries.append(entry)
            Self.sortBySlot(&entries)
            return true
        }
    }

    @discardableResult
    func addFolder(title: String, in folderID: UUID?) -> Bool {
        addFolder(title: title, in: folderID, at: nil)
    }

    @discardableResult
    func addFolder(title: String, in folderID: UUID?, at requestedSlot: Int?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.utf8.count <= ActionGridEntry.maximumCustomTitleByteCount else {
            return false
        }
        return updateEntries(in: folderID) { entries in
            guard let slot = Self.availableSlot(requestedSlot, in: entries) else { return false }
            entries.append(.folder(title: title, slot: slot))
            Self.sortBySlot(&entries)
            return true
        }
    }

    @discardableResult
    func replace(id: UUID, reference: ActionReference) -> Bool {
        return updateContainingEntries(entryID: id) { entries, index in
            guard entries[index].folder == nil,
                  !entries.enumerated().contains(where: {
                      $0.offset != index && $0.element.folder == nil && $0.element.reference == reference
                  }) else {
                return false
            }
            entries[index].reference = reference
            return true
        }
    }

    @discardableResult
    func replace(id: UUID, reference: ActionReference, customTitle: String?) -> Bool {
        guard Self.isValidCustomTitle(customTitle) else {
            return false
        }
        let customTitle = Self.normalizedCustomTitle(customTitle)
        return updateContainingEntries(entryID: id) { entries, index in
            guard entries[index].folder == nil,
                  !entries.enumerated().contains(where: {
                      $0.offset != index && $0.element.folder == nil && $0.element.reference == reference
                  }) else {
                return false
            }
            entries[index].reference = reference
            entries[index].customTitle = customTitle
            return true
        }
    }

    @discardableResult
    func setCustomTitle(id: UUID, title: String?) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.utf8.count ?? 0) <= ActionGridEntry.maximumCustomTitleByteCount else {
            return false
        }
        return updateContainingEntries(entryID: id) { entries, index in
            if entries[index].folder != nil, trimmed?.isEmpty != false {
                return false
            }
            entries[index].customTitle = trimmed?.isEmpty == false ? trimmed : nil
            return true
        }
    }

    private static func isValidCustomTitle(_ title: String?) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.utf8.count ?? 0) <= ActionGridEntry.maximumCustomTitleByteCount
    }

    private static func normalizedCustomTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        updateContainingEntries(entryID: id) { entries, index in
            entries.remove(at: index)
            return true
        }
    }

    @discardableResult
    func move(fromOffsets: IndexSet, toOffset: Int) -> Bool {
        move(fromOffsets: fromOffsets, toOffset: toOffset, in: nil)
    }

    @discardableResult
    func move(fromOffsets: IndexSet, toOffset: Int, in folderID: UUID?) -> Bool {
        updateEntries(in: folderID) { entries in
            guard fromOffsets.allSatisfy(entries.indices.contains),
                  (0 ... entries.count).contains(toOffset) else {
                return false
            }
            let occupiedSlots = entries.compactMap(\.slot).sorted()
            entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
            guard entries.count == occupiedSlots.count else { return false }
            for index in entries.indices {
                entries[index].slot = occupiedSlots[index]
            }
            return true
        }
    }

    @discardableResult
    func move(entryID: UUID, toIndex: Int, in folderID: UUID?) -> Bool {
        updateEntries(in: folderID) { entries in
            guard (0 ..< Self.maximumEntryCount).contains(toIndex),
                  let source = entries.firstIndex(where: { $0.id == entryID }),
                  let sourceSlot = entries[source].slot,
                  sourceSlot != toIndex else {
                return false
            }
            if let destination = entries.firstIndex(where: { $0.slot == toIndex }) {
                entries[destination].slot = sourceSlot
            }
            entries[source].slot = toIndex
            Self.sortBySlot(&entries)
            return true
        }
    }

    func entries(in folderID: UUID?) -> [ActionGridEntry] {
        guard let folderID else { return entries }
        return (folder(with: folderID, in: entries)?.entries ?? [])
            .sorted(by: Self.slotOrder)
    }

    func entry(at slot: Int, in folderID: UUID?) -> ActionGridEntry? {
        entries(in: folderID).first { $0.slot == slot }
    }

    func firstAvailableSlot(in folderID: UUID?) -> Int? {
        Self.availableSlot(nil, in: entries(in: folderID))
    }

    func folderEntry(id: UUID) -> ActionGridEntry? {
        entry(with: id, in: entries)
    }

    @discardableResult
    func reset(to references: [ActionReference]) -> Bool {
        var seen = Set<ActionReference>()
        let entries = references.prefix(Self.maximumEntryCount).enumerated().compactMap { index, reference -> ActionGridEntry? in
            guard seen.insert(reference).inserted else { return nil }
            return ActionGridEntry(reference: reference, slot: index)
        }
        return replace(entries)
    }

    @discardableResult
    func migrate(using context: ActionGridHostContext) -> Bool {
        guard loadError == nil else { return false }
        var updated = entries
        let changed = migrate(entries: &updated, using: context)
        return changed && replace(updated)
    }

    func portableBackup(using context: ActionGridHostContext? = nil) -> Data? {
        let portableEntries = portableEntries(entries, using: context)
        guard validate(portableEntries) else { return nil }
        return try? encoder.encode(
            Envelope(formatVersion: Self.currentFormatVersion, entries: portableEntries)
        )
    }

    func actionReferences(inPortableBackup data: Data) -> [ActionReference]? {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              (1 ... Self.currentFormatVersion).contains(envelope.formatVersion),
              let entries = normalizedEntries(
                  envelope.entries,
                  permitsLegacySlots: envelope.formatVersion < 3
              ) else {
            return nil
        }
        return actionReferences(in: entries)
    }

    @discardableResult
    func restorePortableBackup(_ data: Data, using context: ActionGridHostContext? = nil) -> Bool {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              (1 ... Self.currentFormatVersion).contains(envelope.formatVersion),
              let restoredEntries = normalizedEntries(
                  envelope.entries,
                  permitsLegacySlots: envelope.formatVersion < 3
              ),
              actionReferences(in: restoredEntries).allSatisfy({
                  context?.canRestore($0) ?? true
              }) else {
            return false
        }
        guard restoredEntries != entries else { return true }
        return replace(restoredEntries)
    }

    private func portableEntries(
        _ source: [ActionGridEntry],
        using context: ActionGridHostContext?
    ) -> [ActionGridEntry] {
        source.compactMap { entry in
            guard var folder = entry.folder else {
                return context?.canExport(entry.reference) == false ? nil : entry
            }
            folder.entries = portableEntries(folder.entries, using: context)
            var result = entry
            result.folder = folder
            return result
        }
    }

    private func actionReferences(in source: [ActionGridEntry]) -> [ActionReference] {
        source.flatMap { entry in
            entry.folder.map { actionReferences(in: $0.entries) } ?? [entry.reference]
        }
    }

    @discardableResult
    private func replace(
        _ entries: [ActionGridEntry],
        persistWhenUnchanged: Bool = false
    ) -> Bool {
        guard validate(entries),
              let data = try? encoder.encode(
                Envelope(formatVersion: Self.currentFormatVersion, entries: entries)
              ),
              data.count <= Self.maximumPayloadByteCount else {
            return false
        }
        guard persistWhenUnchanged || entries != self.entries else { return false }
        let previousRawValue = storage.object(forKey: Self.storageKey)
        storage.set(data, forKey: Self.storageKey)
        guard storage.data(forKey: Self.storageKey) == data else {
            if !restore(previousRawValue) {
                reload(performLegacyMigration: false)
            }
            return false
        }
        self.entries = entries
        loadError = nil
        return true
    }

    private func reload(performLegacyMigration: Bool = true) {
        guard let rawValue = storage.object(forKey: Self.storageKey) else {
            entries = []
            loadError = nil
            return
        }
        guard let data = rawValue as? Data else {
            entries = []
            loadError = "invalid-grid-layout"
            return
        }
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              (1 ... Self.currentFormatVersion).contains(envelope.formatVersion),
              let decodedEntries = normalizedEntries(
                  envelope.entries,
                  permitsLegacySlots: envelope.formatVersion < 3
              ) else {
            entries = []
            loadError = "invalid-grid-layout"
            return
        }
        if envelope.formatVersion < Self.currentFormatVersion {
            entries = decodedEntries.sorted(by: Self.slotOrder)
            loadError = nil
            if performLegacyMigration {
                _ = replace(decodedEntries, persistWhenUnchanged: true)
            }
            return
        }
        entries = decodedEntries.sorted(by: Self.slotOrder)
        loadError = nil
    }

    private func restore(_ value: Any?) -> Bool {
        if let value {
            storage.set(value, forKey: Self.storageKey)
        } else {
            storage.removeObject(forKey: Self.storageKey)
        }
        return valuesMatch(storage.object(forKey: Self.storageKey), value)
    }

    private func valuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }

    private func validate(_ entries: [ActionGridEntry]) -> Bool {
        var seenIDs = Set<UUID>()
        var totalCount = 0
        return validate(
            entries,
            depth: 0,
            seenIDs: &seenIDs,
            totalCount: &totalCount
        )
    }

    private func validate(
        _ entries: [ActionGridEntry],
        depth: Int,
        seenIDs: inout Set<UUID>,
        totalCount: inout Int
    ) -> Bool {
        guard depth <= Self.maximumFolderDepth,
              entries.count <= Self.maximumEntryCount else {
            return false
        }
        var occupiedSlots = Set<Int>()
        for entry in entries {
            totalCount += 1
            guard totalCount <= Self.maximumTotalEntryCount,
                  seenIDs.insert(entry.id).inserted,
                  let slot = entry.slot,
                  (0 ..< Self.maximumEntryCount).contains(slot),
                  occupiedSlots.insert(slot).inserted,
                  (entry.customTitle?.utf8.count ?? 0) <= ActionGridEntry.maximumCustomTitleByteCount else {
                return false
            }
            if let folder = entry.folder {
                guard entry.reference.key.providerID == Self.folderProviderID,
                      entry.customTitle?.isEmpty == false,
                      !folder.systemImage.isEmpty,
                      folder.systemImage.utf8.count <= 128,
                      validate(
                          folder.entries,
                          depth: depth + 1,
                          seenIDs: &seenIDs,
                          totalCount: &totalCount
                      ) else {
                    return false
                }
            }
        }
        return true
    }

    private func normalizedEntries(
        _ source: [ActionGridEntry],
        permitsLegacySlots: Bool
    ) -> [ActionGridEntry]? {
        var entries = source
        guard normalizeSlots(&entries, permitsLegacySlots: permitsLegacySlots),
              validate(entries) else {
            return nil
        }
        return entries
    }

    private func normalizeSlots(
        _ entries: inout [ActionGridEntry],
        permitsLegacySlots: Bool
    ) -> Bool {
        guard entries.count <= Self.maximumEntryCount else { return false }
        var occupied = Set<Int>()
        for index in entries.indices {
            let requested = entries[index].slot
            if let requested,
               (0 ..< Self.maximumEntryCount).contains(requested),
               occupied.insert(requested).inserted {
                // Keep a valid explicit slot.
            } else if permitsLegacySlots,
                      let slot = (0 ..< Self.maximumEntryCount).first(where: { !occupied.contains($0) }) {
                entries[index].slot = slot
                occupied.insert(slot)
            } else {
                return false
            }
            if var folder = entries[index].folder {
                guard normalizeSlots(&folder.entries, permitsLegacySlots: permitsLegacySlots) else {
                    return false
                }
                entries[index].folder = folder
            }
        }
        Self.sortBySlot(&entries)
        return true
    }

    private static func availableSlot(
        _ requested: Int?,
        in entries: [ActionGridEntry]
    ) -> Int? {
        guard entries.count < maximumEntryCount else { return nil }
        let occupied = Set(entries.compactMap(\.slot))
        if let requested {
            guard (0 ..< maximumEntryCount).contains(requested),
                  !occupied.contains(requested) else {
                return nil
            }
            return requested
        }
        return (0 ..< maximumEntryCount).first { !occupied.contains($0) }
    }

    private static func sortBySlot(_ entries: inout [ActionGridEntry]) {
        entries.sort(by: slotOrder)
    }

    private static func slotOrder(_ lhs: ActionGridEntry, _ rhs: ActionGridEntry) -> Bool {
        (lhs.slot ?? maximumEntryCount) < (rhs.slot ?? maximumEntryCount)
    }

    @discardableResult
    private func updateEntries(
        in folderID: UUID?,
        _ update: (inout [ActionGridEntry]) -> Bool
    ) -> Bool {
        guard loadError == nil else { return false }
        var updated = entries
        let changed: Bool
        if let folderID {
            changed = updateFolderEntries(folderID: folderID, entries: &updated, update: update)
        } else {
            changed = update(&updated)
        }
        return changed && replace(updated)
    }

    @discardableResult
    private func updateContainingEntries(
        entryID: UUID,
        _ update: (inout [ActionGridEntry], Int) -> Bool
    ) -> Bool {
        guard loadError == nil else { return false }
        var updated = entries
        guard updateContainingEntries(entryID: entryID, entries: &updated, update: update) else {
            return false
        }
        return replace(updated)
    }

    private func updateFolderEntries(
        folderID: UUID,
        entries: inout [ActionGridEntry],
        update: (inout [ActionGridEntry]) -> Bool
    ) -> Bool {
        for index in entries.indices {
            guard var folder = entries[index].folder else { continue }
            if entries[index].id == folderID {
                guard update(&folder.entries) else { return false }
                entries[index].folder = folder
                return true
            }
            if updateFolderEntries(folderID: folderID, entries: &folder.entries, update: update) {
                entries[index].folder = folder
                return true
            }
        }
        return false
    }

    private func updateContainingEntries(
        entryID: UUID,
        entries: inout [ActionGridEntry],
        update: (inout [ActionGridEntry], Int) -> Bool
    ) -> Bool {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            return update(&entries, index)
        }
        for index in entries.indices {
            guard var folder = entries[index].folder else { continue }
            if updateContainingEntries(entryID: entryID, entries: &folder.entries, update: update) {
                entries[index].folder = folder
                return true
            }
        }
        return false
    }

    private func folder(with id: UUID, in entries: [ActionGridEntry]) -> ActionGridFolder? {
        guard let entry = entry(with: id, in: entries) else { return nil }
        return entry.folder
    }

    private func entry(with id: UUID, in entries: [ActionGridEntry]) -> ActionGridEntry? {
        for entry in entries {
            if entry.id == id { return entry }
            if let nested = entry.folder.flatMap({ self.entry(with: id, in: $0.entries) }) {
                return nested
            }
        }
        return nil
    }

    private func migrate(
        entries: inout [ActionGridEntry],
        using context: ActionGridHostContext
    ) -> Bool {
        var changed = false
        for index in entries.indices {
            if var folder = entries[index].folder {
                if migrate(entries: &folder.entries, using: context) {
                    entries[index].folder = folder
                    changed = true
                }
                continue
            }
            guard let migrated = context.migrate(entries[index].reference),
                  migrated != entries[index].reference else {
                continue
            }
            entries[index].reference = migrated
            changed = true
        }
        return changed
    }
}

private extension Array {
    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().map { self[$0] }
        for index in offsets.sorted(by: >) {
            remove(at: index)
        }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        insert(contentsOf: moving, at: destination - removedBeforeDestination)
    }
}
