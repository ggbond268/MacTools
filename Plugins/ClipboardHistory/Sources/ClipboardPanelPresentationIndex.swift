import Foundation

/// Display metadata only. Opening a default page reads a bounded prefix; it never
/// loads payloads or reclassifies the history. Ordered arrays trade cheap reads
/// for shifts on insertion/removal, while ordinary metadata updates stay local.
struct ClipboardPanelPresentationIndex: Sendable {
    private struct Key: Hashable, Sendable {
        let id: UUID
        let isSnippet: Bool
    }

    private var records: [Key: ClipboardPanelSearchCandidate] = [:]
    private var order: [ClipboardPanelMode: [Key]] = [:]
    private var typeCounts: [ClipboardHistoryContentFilter: Int] = [:]
    private var semanticCounts: [ClipboardHistorySemanticFilter: Int] = [:]
    private var presentationCount = 0

    init(items: [ClipboardHistoryItem], savedItems: [ClipboardSavedItem]) {
        records.reserveCapacity(items.count + savedItems.count)
        var keys: [Key] = []
        keys.reserveCapacity(items.count + savedItems.count)
        for item in items {
            let key = Key(id: item.id, isSnippet: false)
            if records.updateValue(.init(item: item, isSnippet: false, sortDate: item.capturedAt), forKey: key) == nil {
                keys.append(key)
            }
        }
        for saved in savedItems where saved.isSnippet {
            let key = Key(id: saved.id, isSnippet: true)
            if records.updateValue(.init(item: saved.historyPresentationItem(), isSnippet: true, sortDate: saved.updatedAt), forKey: key) == nil {
                keys.append(key)
            }
        }
        // History normally arrives in capture order. Keep that order when possible, and
        // sort mixed or unordered inputs once before distributing them to every scope.
        // Sorting dictionary keys independently per scope repeated both sorting and lookups.
        var orderedRecords = keys.map { ($0, records[$0]!) }
        if zip(orderedRecords, orderedRecords.dropFirst()).contains(where: { precedes($0.1.1, $0.0.1) }) {
            orderedRecords.sort { precedes($0.1, $1.1) }
        }
        for (key, record) in orderedRecords {
            for scope in scopes(for: record) { order[scope, default: []].append(key) }
            if !key.isSnippet || records[Key(id: key.id, isSnippet: false)] == nil {
                count(record.item, delta: 1)
            }
        }
    }

    var scopeModes: [ClipboardPanelMode] {
        let scopes = [ClipboardPanelMode.history, .saved, .snippets].filter { count(in: $0) > 0 }
        return [.all] + scopes
    }

    var contentFilters: [ClipboardHistoryContentFilter] {
        ClipboardHistoryContentFilter.allCases.filter { $0 != .all && typeCounts[$0, default: 0] > 0 }
    }

    var semanticFilters: [ClipboardHistorySemanticFilter] {
        ClipboardHistorySemanticFilter.allCases.filter { $0 != .any && semanticCounts[$0, default: 0] > 0 }
    }

    var filterFamilies: [ClipboardHistoryFilterFamily] {
        ClipboardHistoryFilterFamily.available(
            totalItemCount: presentationCount,
            scopeCounts: [.history, .saved, .snippets].map { count(in: $0) },
            typeCounts: ClipboardHistoryContentFilter.allCases.filter { $0 != .all }.map { typeCounts[$0, default: 0] },
            contentCounts: ClipboardHistorySemanticFilter.allCases.filter { $0 != .any }.map { semanticCounts[$0, default: 0] }
        )
    }

    func count(in scope: ClipboardPanelMode) -> Int { order[scope]?.count ?? 0 }

    func page(in scope: ClipboardPanelMode, limit: Int) -> [ClipboardPanelSearchCandidate] {
        (order[scope] ?? []).prefix(max(0, limit)).compactMap { records[$0] }
    }

    mutating func update(_ item: ClipboardHistoryItem?, id: UUID) {
        replace(item.map { .init(item: $0, isSnippet: false, sortDate: $0.capturedAt) },
                key: Key(id: id, isSnippet: false))
    }

    mutating func updateSnippet(_ item: ClipboardSavedItem?, id: UUID) {
        replace(item.flatMap { $0.isSnippet ? .init(
            item: $0.historyPresentationItem(), isSnippet: true, sortDate: $0.updatedAt
        ) : nil }, key: Key(id: id, isSnippet: true))
    }

    private mutating func replace(_ record: ClipboardPanelSearchCandidate?, key: Key) {
        let clipKey = Key(id: key.id, isSnippet: false)
        let snippetKey = Key(id: key.id, isSnippet: true)
        if let counted = records[clipKey] ?? records[snippetKey] { count(counted.item, delta: -1) }
        let previous = records[key]
        let oldScopes = previous.map(scopes) ?? []
        let newScopes = record.map(scopes) ?? []
        let reorders = previous?.sortDate != record?.sortDate
        if let previous {
            for scope in oldScopes where reorders || !newScopes.contains(scope) {
                let position = insertionIndex(of: previous, in: scope)
                if order[scope]?.indices.contains(position) == true, order[scope]?[position] == key {
                    order[scope]?.remove(at: position)
                }
            }
        }
        records[key] = record
        if let record {
            for scope in newScopes where reorders || !oldScopes.contains(scope) {
                let position = insertionIndex(of: record, in: scope)
                order[scope, default: []].insert(key, at: position)
            }
        }
        if let counted = records[clipKey] ?? records[snippetKey] { count(counted.item, delta: 1) }
    }

    private func insertionIndex(of record: ClipboardPanelSearchCandidate, in scope: ClipboardPanelMode) -> Int {
        let keys = order[scope] ?? []
        var lower = 0
        var upper = keys.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if precedes(records[keys[middle]]!, record) { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private func precedes(_ lhs: ClipboardPanelSearchCandidate, _ rhs: ClipboardPanelSearchCandidate) -> Bool {
        if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
        if lhs.item.id != rhs.item.id { return lhs.item.id.uuidString < rhs.item.id.uuidString }
        return !lhs.isSnippet && rhs.isSnippet
    }

    private func scopes(for record: ClipboardPanelSearchCandidate) -> [ClipboardPanelMode] {
        if record.isSnippet { return [.all, .snippets] }
        var scopes: [ClipboardPanelMode] = []
        if record.item.isInHistory || record.item.isSaved { scopes.append(.all) }
        if record.item.isInHistory { scopes.append(.history) }
        if record.item.isSaved { scopes.append(.saved) }
        return scopes
    }

    private mutating func count(_ item: ClipboardHistoryItem, delta: Int) {
        presentationCount += delta
        for filter in ClipboardHistoryContentFilter.allCases where filter != .all && filter.matches(item) {
            typeCounts[filter, default: 0] += delta
        }
        for filter in ClipboardHistorySemanticFilter.allCases where filter != .any && filter.matches(item) {
            semanticCounts[filter, default: 0] += delta
        }
    }
}
