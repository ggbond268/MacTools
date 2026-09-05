import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryMutationPerformanceTests: XCTestCase {
    func testEdgeOptimizedDiffMatchesReferenceForReordersInsertionsDeletionsAndMetadata() {
        let original = (0..<5).map(makeItem)
        let inserted = makeItem(9)
        var changedFirst = original[0]
        changedFirst.lastUsedAt = Date(timeIntervalSince1970: 999)
        var changedLast = original[4]
        changedLast.lastUsedAt = changedFirst.lastUsedAt
        let variants: [[ClipboardHistoryItem]] = [
            original, [], [inserted] + original, original + [inserted],
            Array(original.dropFirst()), Array(original.dropLast()),
            [original[0], original[2], original[4]],
            [original[4], original[1], original[0], original[2], original[3]],
            [changedFirst, original[1], inserted, original[2], original[3], changedLast],
            [changedFirst, original[1], original[2], original[3], changedLast],
        ]
        for previous in [original, []] {
            for next in variants {
                let expected = referenceDiff(previous, next)
                let actual = ClipboardHistoryMutation.between(previous, next)
                XCTAssertEqual(actual.changes.map(\.id), expected.changes.map(\.id))
                XCTAssertEqual(actual.changes.map(\.before), expected.changes.map(\.before))
                XCTAssertEqual(actual.changes.map(\.after), expected.changes.map(\.after))
                XCTAssertEqual(actual.applying(to: previous), referenceApply(actual, to: previous))
            }
        }
    }

    func testSmallMutationRetainsSequentialChangesForSameID() {
        let original = (0..<3).map(makeItem)
        var used = original[1]
        used.lastUsedAt = Date(timeIntervalSince1970: 999)
        let removed = ClipboardHistoryMutation.Change(id: used.id, before: used, after: nil)
        let inserted = ClipboardHistoryMutation.Change(id: used.id, before: nil, after: used)
        let stale = ClipboardHistoryMutation.Change(id: used.id, before: original[1], after: used)
        for changes in [[stale, removed], [removed, stale], [removed, inserted, stale], [stale, inserted, removed]] {
            let mutation = ClipboardHistoryMutation(changes: changes)
            XCTAssertEqual(mutation.applying(to: original), referenceApply(mutation, to: original))
            XCTAssertEqual(mutation.applying(to: []), referenceApply(mutation, to: []))
        }
    }

    func testSmallMutationOnFiftyThousandItemsStaysWithinBudget() {
        let original = (0..<50_000).map(makeItem)
        var used = original[0]
        used.lastUsedAt = Date(timeIntervalSince1970: 999)
        let mutation = ClipboardHistoryMutation(changes: [.init(id: used.id, before: original[0], after: used)])
        let started = ContinuousClock.now
        for _ in 0..<10 {
            let result = mutation.applying(to: original)
            XCTAssertEqual(result.count, original.count)
            XCTAssertEqual(result.first?.lastUsedAt, used.lastUsedAt)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    private func makeItem(_ index: Int) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), text: "Item \(index)",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }

    private func referenceDiff(_ previous: [ClipboardHistoryItem], _ next: [ClipboardHistoryItem]) -> ClipboardHistoryMutation {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let nextIDs = Set(next.map(\.id))
        let deleted = previous.filter { !nextIDs.contains($0.id) }.map {
            ClipboardHistoryMutation.Change(id: $0.id, before: $0, after: nil)
        }
        let updated = next.compactMap { item -> ClipboardHistoryMutation.Change? in
            old[item.id] == item ? nil : .init(id: item.id, before: old[item.id], after: item)
        }
        return ClipboardHistoryMutation(changes: deleted + updated)
    }

    private func referenceApply(_ mutation: ClipboardHistoryMutation, to items: [ClipboardHistoryItem]) -> [ClipboardHistoryItem] {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var reorders = false
        for change in mutation.changes {
            if let after = change.after, byID[change.id] == nil || byID[change.id]?.capturedAt != after.capturedAt {
                reorders = true
            }
            byID[change.id] = change.applying(to: byID[change.id])
        }
        guard reorders else { return items.compactMap { byID[$0.id] } }
        return byID.values.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt > $1.capturedAt
        }
    }
}
