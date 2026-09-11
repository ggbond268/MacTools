import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistorySourceTests: XCTestCase {
    func testDeclaredIdentifierValidationPreservesExplicitUnknown() {
        XCTAssertEqual(ClipboardPasteboardSourceHint.applicationIdentifier(from: Data("com.example.Editor".utf8)),
                       .application("com.example.Editor"))
        for invalid in ["", "com.example.\nEditor", "../Editor", "com..example", ".example", "example.", String(repeating: "a", count: 256)] {
            XCTAssertEqual(ClipboardPasteboardSourceHint.applicationIdentifier(from: Data(invalid.utf8)), .unknown)
        }
        XCTAssertEqual(ClipboardPasteboardSourceHint.applicationIdentifier(from: nil), .unknown)
        XCTAssertEqual(ClipboardPasteboardSourceHint.applicationIdentifier(from: Data([0xFF])), .unknown)
    }

    func testRemoteSourceSurvivesCodingWithoutPretendingToBeAnApplication() throws {
        let item = remoteItem()
        let loaded = try JSONDecoder().decode(ClipboardHistoryItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(loaded.source, .universalClipboard)
        XCTAssertNil(loaded.sourceApplication)
        XCTAssertEqual(loaded, item)
    }

    func testLegacyApplicationAndUnknownSourcesRemainReadable() throws {
        for application in [ClipboardSourceApplication(bundleIdentifier: "com.example.Editor", name: "Editor"), nil] {
            let item = ClipboardHistoryItem(id: UUID(), text: "Legacy", capturedAt: .now,
                sourceApplication: application, isPinned: false, lastUsedAt: nil)
            let data = try JSONEncoder().encode(item)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["source"], "Ordinary app records keep the legacy format")
            let loaded = try JSONDecoder().decode(ClipboardHistoryItem.self, from: data)
            XCTAssertEqual(loaded.sourceApplication, application)
            XCTAssertEqual(loaded.source, ClipboardHistorySource(application: application))
        }
    }

    func testRecaptureRetainsRemoteOriginAndSavedMetadata() throws {
        var existing = remoteItem()
        existing.setSavedMetadata(.init(title: "Keep", savedAt: .now))
        let recaptured = try XCTUnwrap(existing.recaptured(from: remoteItem()))
        XCTAssertEqual(recaptured.source, .universalClipboard)
        XCTAssertEqual(recaptured.savedMetadata?.title, "Keep")
        XCTAssertEqual(recaptured.id, existing.id)
    }

    private func remoteItem() -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), payload: .plainText("Remote content"), capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil, source: .universalClipboard)
    }
}
