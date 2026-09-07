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
        XCTAssertFalse(model.completed)
        XCTAssertTrue(model.showsCancel)
    }

    func testSuccessfulBackupReplacesCancelWithDone() async {
        let model = ClipboardBackupPresentation()
        let completed = expectation(description: "backup completed")
        XCTAssertTrue(model.showsCancel)
        model.run(operation: { _ in true }) { _ in
            model.completed = true
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.showsCancel)
        XCTAssertFalse(model.didRestore)
    }

    func testSuccessfulRestoreRetainsReportAndResumesWithRestoredData() async {
        let model = ClipboardBackupPresentation()
        let summary = ClipboardBackupSummary(added: 2, conflicts: 1, missingFileReferences: 1)
        let completed = expectation(description: "restore completed")
        model.run(operation: { _ in summary }) {
            model.restored($0)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(model.showsCancel)
        XCTAssertEqual(model.result, summary)
        let resumed = expectation(description: "resume with restored data")
        model.close { restored in
            XCTAssertTrue(restored)
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 2)
    }

    func testFailureDoesNotPresentCompletion() async {
        let model = ClipboardBackupPresentation()
        let resumed = expectation(description: "failed work drained")
        model.run(operation: { _ in throw ClipboardBackupError.storage }) { (_: Bool) in
            XCTFail("Failed work must not complete")
        }
        model.close { _ in resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.completed)
        XCTAssertTrue(model.showsCancel)
    }

    func testSettingsBackupActionsRenderWithIsolatedStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "clipboard-backup-layout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = InMemoryClipboardHistoryKeyStore()
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let persistence = IncrementalEncryptedClipboardHistoryStore(databaseURL: databaseURL, keyStore: keyStore)
        let service = ClipboardBackupService(databaseURL: databaseURL, keyStore: keyStore,
            access: ClipboardDatabaseAccessCoordinator(), maximumItemBytes: 1_024)
        try Data().write(to: service.rollbackURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controller = ClipboardHistoryController(
            settings: ClipboardHistorySettingsStore(storage: UserDefaultsPluginStorage(pluginID: "test", userDefaults: defaults)),
            pasteboard: GeneralClipboardPasteboard(pasteboard: pasteboard), persistence: persistence)
        let region = ClipboardBackupRegion(localization: PluginLocalization(bundle: .main), controller: controller,
            makeService: { service }, suspend: {}, resume: { _ in })
        let host = NSHostingView(rootView: region.pluginSettingsCardBackground(.standard).padding(20)
            .frame(width: 680).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/tmp/mactools-clipboard-backup-settings.png"))
        let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
        attachment.name = "Clipboard backup settings actions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBackupSheetRendersWithSyntheticData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ClipboardBackupService(databaseURL: directory.appendingPathComponent("clipboard.sqlite3"),
            keyStore: InMemoryClipboardHistoryKeyStore(), access: ClipboardDatabaseAccessCoordinator(), maximumItemBytes: 5 * 1_024 * 1_024)
        let completed = ClipboardBackupPresentation()
        completed.restored(ClipboardBackupSummary(added: 12, merged: 3))
        let states: [(String, ClipboardBackupRegion.Action, URL?, ClipboardBackupPresentation)] = [
            ("backup-password", .backup, directory.appendingPathComponent("Clipboard.mactoolsclipboard"), ClipboardBackupPresentation()),
            ("restore-select-file", .restore, nil, ClipboardBackupPresentation()),
            ("restore-password", .restore, directory.appendingPathComponent("Clipboard.mactoolsclipboard"), ClipboardBackupPresentation()),
            ("restore-completed", .restore, nil, completed),
        ]
        let originalPreference = UserDefaults.standard.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey)
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        var bundleDirectory = Bundle(for: Self.self).bundleURL
        while bundleDirectory.path != "/",
              !FileManager.default.fileExists(atPath: bundleDirectory.appendingPathComponent("ClipboardHistory.bundle").path) {
            bundleDirectory.deleteLastPathComponent()
        }
        let bundle = try XCTUnwrap(Bundle(url: bundleDirectory.appendingPathComponent("ClipboardHistory.bundle")))
        let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let locales = ["ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh-Hans", "zh-Hant"]
        for locale in locales {
            PluginRuntimeLocalization.source.setPreference(locale)
            let localization = PluginLocalization(bundle: bundle)
            for (key, entry) in strings where key.hasPrefix("backup.") {
                let translations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
                let unit = try XCTUnwrap(translations[locale]?["stringUnit"] as? [String: String])
                XCTAssertEqual(localization.string(key, defaultValue: "MISSING"), unit["value"], "\(locale): \(key)")
            }
            for (name, action, url, model) in states {
                let sheet = ClipboardBackupSheet(action: action, service: service,
                    localization: localization, historyCount: 42, historyBytes: 16 * 1_024 * 1_024,
                    suspend: {}, resume: { _ in }, initialFileURL: url, presentation: model)
                let host = NSHostingView(rootView: sheet.background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, PluginRuntimeLocalization.locale)
                    .environment(\.layoutDirection, locale == "ar" ? .rightToLeft : .leftToRight))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
                attachment.name = "Clipboard " + name + " (" + locale + ")"
                attachment.lifetime = .keepAlways
                add(attachment)
                // Only synthetic views are captured; no installed app or real clipboard is accessed.
                try image.write(to: URL(fileURLWithPath: "/tmp/mactools-clipboard-\(name)-\(locale).png"))
            }
        }
    }
}
