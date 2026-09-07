import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardBackupViewTests: XCTestCase {
    func testDefaultScopeExcludesHistory() {
        let scope = ClipboardBackupScope()
        XCTAssertTrue(scope.saved)
        XCTAssertTrue(scope.snippets)
        XCTAssertFalse(scope.history)
        XCTAssertFalse(scope.isComplete)
    }

    func testPresentationCancellationWaitsForWorkerBeforeResuming() async throws {
        let model = ClipboardBackupPresentation()
        let entered = expectation(description: "worker entered")
        let resumed = expectation(description: "resume after cancellation")
        model.run(operation: { _ in
            entered.fulfill()
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            throw CancellationError()
        }, completion: { (_: Bool) in XCTFail("Cancelled work cannot complete") })
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.isBusy)
        model.close { restored in
            XCTAssertFalse(restored)
            XCTAssertFalse(model.isBusy)
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertNil(model.error)
    }

    func testBackupSheetRendersWithSyntheticData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ClipboardBackupService(databaseURL: directory.appendingPathComponent("clipboard.sqlite3"),
            keyStore: InMemoryClipboardHistoryKeyStore(), access: ClipboardDatabaseAccessCoordinator(), maximumItemBytes: 5 * 1_024 * 1_024)
        let sheet = ClipboardBackupSheet(action: .backup, service: service,
            localization: PluginLocalization(bundle: .main), historyCount: 42, historyBytes: 16 * 1_024 * 1_024,
            suspend: {}, resume: { _ in })
        let host = NSHostingView(rootView: sheet.frame(width: 600, height: 650).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 650)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
        attachment.name = "Clipboard backup scope and password sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Only a synthetic view is captured; no installed app or real clipboard is accessed.
        try image.write(to: URL(fileURLWithPath: "/tmp/mactools-clipboard-backup-sheet.png"))
    }
}
