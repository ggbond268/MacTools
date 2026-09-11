import AppKit
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryShareCoordinatorTests: XCTestCase {
    func testCancelledPreparationDoesNotReportShareFailure() async throws {
        let hud = ShareCoordinatorTestHUD()
        let coordinator = ClipboardHistoryShareCoordinator(
            historyController: makeController(),
            localization: PluginLocalization(bundle: Bundle(for: Self.self)),
            hudPresenter: hud
        )
        let item = ClipboardSavedItem(
            title: "Synthetic",
            savedKind: .snippet,
            payload: .plainText("synthetic text"),
            templateText: "synthetic text"
        )

        coordinator.share(savedItem: item, from: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(hud.failures.isEmpty)
    }

    func testPreparingMultiURLItemPreservesEveryURLInOrder() async throws {
        let urls = [
            try XCTUnwrap(URL(string: "https://example.com/one")),
            try XCTUnwrap(URL(string: "https://example.com/two")),
        ]
        let payload = ClipboardHistoryPayload(pasteboardItems: urls.map { url in
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.url,
                    data: Data(url.absoluteString.utf8)
                ),
            ])
        })
        let item = ClipboardHistoryItem(
            id: UUID(), payload: payload, capturedAt: Date(), sourceApplication: nil,
            isPinned: false, lastUsedAt: nil
        )

        let prepared = await ClipboardHistoryShareCoordinator.prepareSingleShare(for: item)

        XCTAssertEqual(prepared, .URLs(urls))
    }

    private func makeController() -> ClipboardHistoryController {
        ClipboardHistoryController(
            settings: ClipboardHistorySettingsStore(storage: ShareCoordinatorTestStorage()),
            pasteboard: ShareCoordinatorTestPasteboard(),
            sourceContext: ShareCoordinatorTestSource(),
            persistence: UnavailableClipboardHistoryStore()
        )
    }
}

@MainActor
private final class ShareCoordinatorTestHUD: ClipboardPrivacyHUDPresenting {
    private(set) var failures: [String] = []
    func handleSuppressionEvent(_ event: ClipboardCaptureSuppressionEvent) {}
    func showSuccess(_ message: String) {}
    func showFailure(_ message: String) { failures.append(message) }
    func dismiss() {}
}

@MainActor
private final class ShareCoordinatorTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

@MainActor
private final class ShareCoordinatorTestPasteboard: ClipboardPasteboardAccess {
    var changeCount: Int { 0 }
    var typeNames: Set<String> { [] }
    func readPlainText() -> String? { nil }
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult { .empty }
    func writePlainText(_ text: String) -> Bool { false }
    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool { false }
}

@MainActor
private final class ShareCoordinatorTestSource: ClipboardSourceContextProviding {
    func frontmostApplication() -> ClipboardSourceApplication? { nil }
}
