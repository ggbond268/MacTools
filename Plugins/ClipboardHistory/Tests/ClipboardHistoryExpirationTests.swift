import Combine
import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryExpirationTests: XCTestCase {
    func testExpirationUsesLatestActivityAndFallsBackToCaptureForUnusedItems() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let day: TimeInterval = 24 * 60 * 60
        var settings = ClipboardHistorySettings.defaults
        settings.expiration = .oneDay
        var reused = item("reused", capturedAt: now.addingTimeInterval(-3 * day))
        reused.lastUsedAt = now.addingTimeInterval(-day + 1)
        var idle = item("idle", capturedAt: now.addingTimeInterval(-3 * day))
        idle.lastUsedAt = now.addingTimeInterval(-day - 1)
        let unused = item("unused", capturedAt: now.addingTimeInterval(-day + 1))
        let oldUnused = item("old unused", capturedAt: now.addingTimeInterval(-day - 1))
        var recaptured = item("recaptured", capturedAt: now)
        recaptured.lastUsedAt = now.addingTimeInterval(-2 * day)

        let retained = ClipboardRetentionPolicy.prune(
            [reused, idle, unused, oldUnused, recaptured], settings: settings, now: now
        )

        XCTAssertEqual(Set(retained.map(\.id)), Set([reused.id, unused.id, recaptured.id]))
        XCTAssertEqual(retained.first(where: { $0.id == reused.id })?.capturedAt, reused.capturedAt)
        XCTAssertEqual(
            ClipboardRetentionPolicy.prune(retained, settings: settings, now: now.addingTimeInterval(2)).map(\.id),
            [recaptured.id]
        )
    }

    func testLoadingKeepsOldHistoryThatWasRecentlyUsed() async throws {
        let expiration = try XCTUnwrap(ClipboardHistorySettings.defaults.expiration.interval)
        let now = Date()
        var reused = item("reused", capturedAt: now.addingTimeInterval(-expiration - 60))
        reused.lastUsedAt = now.addingTimeInterval(-60)
        let unused = item("unused", capturedAt: reused.capturedAt)
        let (controller, _) = makeController(items: [reused, unused])
        defer { controller.stop() }
        controller.start()
        let loaded = await waitUntil { controller.isLoaded }
        XCTAssertTrue(loaded)

        XCTAssertEqual(controller.items.map(\.id), [reused.id])
        controller.processRetentionExpiration(now: now)
        XCTAssertEqual(controller.items.map(\.id), [reused.id])
    }

    func testSingleAndCombinedReuseExtendExpirationWithoutExtendingOtherItems() async throws {
        let expiration = try XCTUnwrap(ClipboardHistorySettings.defaults.expiration.interval)
        for combined in [false, true] {
            let referenceDate = Date()
            let capturedAt = referenceDate.addingTimeInterval(-expiration + 60)
            let reused = item("reuse me", capturedAt: capturedAt)
            let unused = item("leave idle", capturedAt: capturedAt.addingTimeInterval(1))
            let (controller, persistence) = makeController(items: [unused, reused])
            defer { controller.stop() }
            controller.start()
            let loaded = await waitUntil { controller.isLoaded }
            XCTAssertTrue(loaded)
            let model = ClipboardHistoryPanelModel()
            model.prepareForPresentation(items: controller.items)
            await model.waitForSearchForTesting()
            let subscription = controller.itemUpdates.sink { update in
                model.updateItems(update.items, revision: update.revision, changedIDs: update.changedIDs)
            }
            let didCopy = if combined {
                await controller.copyCombinedItemsAsPlainText(ids: [reused.id])
            } else {
                await controller.copyItem(id: reused.id)
            }
            XCTAssertTrue(didCopy)
            let usedAt = try XCTUnwrap(controller.items.first(where: { $0.id == reused.id })?.lastUsedAt)
            XCTAssertEqual(model.visibleItems.first?.id, reused.id)
            XCTAssertFalse(model.isSearching)

            // A previously scheduled deadline must recheck activity before removing items.
            controller.processRetentionExpiration(now: referenceDate.addingTimeInterval(120))
            XCTAssertEqual(controller.items.map(\.id), [reused.id])
            XCTAssertEqual(controller.items.first?.capturedAt, capturedAt)
            let persistedRenewal = await waitUntil {
                persistence.savedItems.count == 1 && persistence.savedItems.first?.lastUsedAt == usedAt
            }
            XCTAssertTrue(persistedRenewal)

            controller.processRetentionExpiration(now: usedAt.addingTimeInterval(expiration + 1))
            XCTAssertTrue(controller.items.isEmpty)
            withExtendedLifetime(subscription) {}
        }
    }

    func testExpiredSavedAndProtectedItemsKeepTheirExistingProtection() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.expiration = .oneDay
        let oldDate = now.addingTimeInterval(-3 * 24 * 60 * 60)
        var saved = item("saved", capturedAt: oldDate)
        saved.setSavedMetadata(.init(title: "Saved", savedAt: oldDate))
        let queued = item("queued", capturedAt: oldDate)
        let shortcut = item("shortcut", capturedAt: oldDate)
        let items = [saved, queued, shortcut]

        let retained = ClipboardRetentionPolicy.prune(
            items, settings: settings, now: now,
            protectedItemIDs: [queued.id], shortcutRetainedItemIDs: [shortcut.id]
        )
        XCTAssertEqual(Set(retained.filter(\.isInHistory).map(\.id)), Set([queued.id, shortcut.id]))
        XCTAssertTrue(retained.first(where: { $0.id == saved.id })?.isSaved == true)
        XCTAssertFalse(retained.first(where: { $0.id == saved.id })?.isInHistory == true)
        XCTAssertEqual(ClipboardRetentionPolicy.prune(retained, settings: settings, now: now).map(\.id), [saved.id])

        settings.expiration = .never
        XCTAssertEqual(Set(ClipboardRetentionPolicy.prune(items, settings: settings, now: now).map(\.id)), Set(items.map(\.id)))
    }

    private func item(_ text: String, capturedAt: Date) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), text: text, capturedAt: capturedAt,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }

    private func makeController(items: [ClipboardHistoryItem]) -> (ClipboardHistoryController, ExpirationHistoryStore) {
        let suite = "ClipboardHistoryExpirationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardHistorySettingsStore(
            storage: UserDefaultsPluginStorage(pluginID: "clipboard-expiration-tests", userDefaults: defaults)
        )
        settings.setPaused(false)
        settings.excludedApplications = []
        let persistence = ExpirationHistoryStore(items: items)
        let controller = ClipboardHistoryController(settings: settings,
            pasteboard: ExpirationPasteboard(), sourceContext: ExpirationSourceContext(),
            persistence: persistence, monitoringInterval: 60)
        return (controller, persistence)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class ExpirationPasteboard: ClipboardPasteboardAccess {
    var changeCount = 0
    var typeNames: Set<String> { [] }
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult { .empty }
    func writePlainText(_ text: String) -> Bool { writePayload(.plainText(text)) }
    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool {
        changeCount += 1
        return true
    }
}

@MainActor
private final class ExpirationSourceContext: ClipboardSourceContextProviding {
    func frontmostApplication() -> ClipboardSourceApplication? { nil }
}

private final class ExpirationHistoryStore: ClipboardHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardHistoryItem]
    init(items: [ClipboardHistoryItem]) { self.items = items }
    var savedItems: [ClipboardHistoryItem] { lock.withLock { items } }
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { savedItems }
    func save(_ items: [ClipboardHistoryItem]) throws { lock.withLock { self.items = items } }
    func reset() throws { lock.withLock { items = [] } }
    func removeAll() throws { try reset() }
}
