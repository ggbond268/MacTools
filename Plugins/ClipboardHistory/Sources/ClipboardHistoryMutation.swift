import Foundation

/// An ordered set of item/field changes, not a replacement collection. Applying a later OCR or
/// usage update must never restore saved metadata from the snapshot in which that work began.
struct ClipboardHistoryMutation: Sendable {
    struct Change: Sendable {
        let id: UUID
        let before: ClipboardHistoryItem?
        let after: ClipboardHistoryItem?

        func applying(to current: ClipboardHistoryItem?) -> ClipboardHistoryItem? {
            guard let after else { return nil }
            guard let before else { return after }
            // A genuine recopy is new history even if an earlier delete just committed. Late
            // OCR/usage updates cannot recreate it or restore an inherited bookmark.
            guard let current else {
                guard before.capturedAt != after.capturedAt else { return nil }
                var recaptured = after
                if before.savedMetadata == after.savedMetadata { recaptured.setSavedMetadata(nil) }
                return recaptured
            }
            let replacesContent = before.payloadDigest != after.payloadDigest
                || before.capturedAt != after.capturedAt
                || before.sourceApplication != after.sourceApplication
            var result = replacesContent ? after : current
            let savedMetadata = before.savedMetadata == after.savedMetadata
                ? current.savedMetadata : after.savedMetadata
            if result.savedMetadata != savedMetadata { result.setSavedMetadata(savedMetadata) }
            result.isInHistory = before.isInHistory == after.isInHistory
                ? current.isInHistory : after.isInHistory
            result.lastUsedAt = before.lastUsedAt == after.lastUsedAt
                ? current.lastUsedAt : after.lastUsedAt
            if before.imageSearchText != after.imageSearchText
                || before.hasCompletedImageTextIndexing != after.hasCompletedImageTextIndexing {
                if result.payloadDigest == after.payloadDigest {
                    if result.imageSearchText != after.imageSearchText { result.setImageSearchText(after.imageSearchText) }
                    result.hasCompletedImageTextIndexing = after.hasCompletedImageTextIndexing
                }
            } else if replacesContent, current.payloadDigest == after.payloadDigest {
                if result.imageSearchText != current.imageSearchText { result.setImageSearchText(current.imageSearchText) }
                result.hasCompletedImageTextIndexing = current.hasCompletedImageTextIndexing
            }
            return result.isInHistory || result.isSaved ? result : nil
        }
    }

    let changes: [Change]
    var changedIDs: Set<UUID> { Set(changes.map(\.id)) }

    static func between(_ previous: [ClipboardHistoryItem], _ next: [ClipboardHistoryItem]) -> Self {
        // Metadata edits retain order; capture/retention usually only change an edge.
        // Keep the shared prefix/suffix out of the lookup tables entirely.
        var prefix = 0
        var leadingChanges: [Change] = []
        while prefix < min(previous.count, next.count), previous[prefix].id == next[prefix].id {
            if previous[prefix] != next[prefix] {
                leadingChanges.append(Change(id: next[prefix].id, before: previous[prefix], after: next[prefix]))
            }
            prefix += 1
        }
        var suffix = 0
        var trailingChanges: [Change] = []
        while suffix < min(previous.count, next.count) - prefix {
            let before = previous[previous.count - suffix - 1]
            let after = next[next.count - suffix - 1]
            guard before.id == after.id else { break }
            if before != after { trailingChanges.append(Change(id: after.id, before: before, after: after)) }
            suffix += 1
        }
        let oldMiddle = previous[prefix..<(previous.count - suffix)]
        let newMiddle = next[prefix..<(next.count - suffix)]
        let oldByID = Dictionary(uniqueKeysWithValues: oldMiddle.map { ($0.id, $0) })
        let nextIDs = Set(newMiddle.map(\.id))
        var changes = oldMiddle.filter { !nextIDs.contains($0.id) }.map {
            Change(id: $0.id, before: $0, after: nil)
        }
        changes += leadingChanges
        changes += newMiddle.compactMap { item in
            guard oldByID[item.id] != item else { return nil }
            return Change(id: item.id, before: oldByID[item.id], after: item)
        }
        changes += trailingChanges.reversed()
        return Self(changes: changes)
    }

    func applying(to items: [ClipboardHistoryItem]) -> [ClipboardHistoryItem] {
        guard !changes.isEmpty else { return items }
        // The common save/OCR/usage acknowledgement touches only a few IDs. Copy the
        // array once, but do not hash and retain every unchanged item in a dictionary.
        if changes.count <= 32 { return applyingSmallMutation(to: items) }
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var changesOrdering = false
        for change in changes {
            if let after = change.after,
               byID[change.id] == nil || byID[change.id]?.capturedAt != after.capturedAt {
                changesOrdering = true
            }
            byID[change.id] = change.applying(to: byID[change.id])
        }
        guard changesOrdering else { return items.compactMap { byID[$0.id] } }
        return byID.values.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func applyingSmallMutation(to items: [ClipboardHistoryItem]) -> [ClipboardHistoryItem] {
        var changesByID = Dictionary(grouping: changes, by: \.id)
        var result = items
        var removedIndices: [Int] = []
        var changesOrdering = false

        func apply(_ changes: [Change], to item: ClipboardHistoryItem?) -> ClipboardHistoryItem? {
            var current = item
            for change in changes {
                if let after = change.after, current == nil || current?.capturedAt != after.capturedAt {
                    changesOrdering = true
                }
                current = change.applying(to: current)
            }
            return current
        }

        for index in items.indices {
            guard let itemChanges = changesByID.removeValue(forKey: items[index].id) else { continue }
            if let updated = apply(itemChanges, to: items[index]) {
                result[index] = updated
            } else {
                removedIndices.append(index)
            }
            if changesByID.isEmpty { break }
        }
        for index in removedIndices.reversed() { result.remove(at: index) }
        for itemChanges in changesByID.values {
            if let inserted = apply(itemChanges, to: nil) { result.append(inserted) }
        }
        if changesOrdering {
            result.sort {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return result
    }
}
