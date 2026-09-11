import AppKit
import SwiftUI
import MacToolsPluginKit
@testable import ClipboardHistoryPlugin

struct PreviewHistoryStore: ClipboardHistoryPersisting {
    let items: [ClipboardHistoryItem]
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { items }
    func save(_ items: [ClipboardHistoryItem]) throws {}
    func reset() throws {}
    func removeAll() throws {}
}
struct PreviewSnippetStore: ClipboardSavedLibraryPersisting {
    let items: [ClipboardSavedItem]
    func prepare() throws {}
    func load() throws -> [ClipboardSavedItem] { items }
    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {}
    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload { .plainText("") }
    func updateLastUsedAt(id: UUID, date: Date) throws {}
    func delete(id: UUID) throws {}
    func removeAll() throws {}
}

@main
struct ClipboardWindowProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        guard let count = Int(CommandLine.arguments.dropFirst().first ?? "1000"),
              (1...ClipboardHistorySettings.maximumSupportedItemCount).contains(count) else {
            fatalError("Pass a record count between 1 and 10000, optionally followed by --cold")
        }
        let now = Date()
        let items = (0..<count).map { index in
            ClipboardHistoryItem(id: UUID(), text: "Sample clipboard text \(index)", capturedAt: now.addingTimeInterval(Double(-index)), sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        }
        let storage = AccessibilityTestStorage()
        storage.set(ClipboardHistorySettings.maximumSupportedItemCount, forKey: "maximum-item-count")
        let settings = ClipboardHistorySettingsStore(storage: storage)
        let pasteboard = AccessibilityTestPasteboard()
        let history = ClipboardHistoryController(settings: settings, pasteboard: pasteboard,
            sourceContext: AccessibilityTestSource(), persistence: PreviewHistoryStore(items: items))
        let library = ClipboardSavedLibraryController(pasteboard: pasteboard, persistence: PreviewSnippetStore(items: []))
        history.start(); library.start()
        for _ in 0..<2000 where !history.isLoaded || !library.isLoaded { try await Task.sleep(for: .milliseconds(5)) }
        precondition(history.isLoaded && library.isLoaded, "Synthetic storage did not become ready")
        let initStart = ContinuousClock.now
        let controller = ClipboardHistoryPanelController(historyController: history, savedLibraryController: library,
            previewPasteboard: pasteboard, localization: PluginLocalization(bundle: .main), onIgnoreNextCopy: {},
            hudPresenter: ClipboardPrivacyHUDController())
        let initTime = ContinuousClock.now - initStart
        // Introspection is confined to this probe; production callers never expose the view model.
        let model = Mirror(reflecting: controller).children.first { $0.label == "model" }!.value as! ClipboardHistoryPanelModel
        if !CommandLine.arguments.contains("--cold") {
            let prepared = ContinuousClock.now
            controller.prepareForNextPresentation()
            await model.waitForPresentationPreparationForTesting()
            await model.waitForSearchForTesting()
            precondition(!controller.isVisible && NSApp.windows.allSatisfy { !($0 is NSPanel) })
            print("Background metadata preparation: \(ContinuousClock.now - prepared)")
        }
        print("Records: \(history.items.count), controller creation: \(initTime)")
        for attempt in 0..<6 {
            let started = ContinuousClock.now
            controller.show()
            let showed = ContinuousClock.now
            let window = NSApp.windows.first { $0.isVisible && $0 is NSPanel && $0.contentView != nil }!
            let laidOut = ContinuousClock.now
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let flushed = ContinuousClock.now
            await model.waitForPresentationPreparationForTesting()
            await model.waitForSearchForTesting()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let ready = ContinuousClock.now
            print("Open \(attempt): show=\(showed-started), lookup=\(laidOut-showed), first flush=\(flushed-laidOut), ready=\(ready-started), rows=\(model.visibleItems.count)")
            try await Task.sleep(for: .milliseconds(300))
            controller.close(restorePreviousApplication: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        history.stop(); library.stop()
        for window in NSApp.windows where window is NSPanel { window.close() }
    }
}
@MainActor
private final class AccessibilityTestStorage: PluginStorage {
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
private final class AccessibilityTestPasteboard: ClipboardPasteboardAccess {
    var changeCount: Int { 0 }
    var typeNames: Set<String> { [] }
    func readPlainText() -> String? { nil }
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult { .empty }
    func writePlainText(_ text: String) -> Bool { false }
    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool { false }
}

@MainActor
private final class AccessibilityTestSource: ClipboardSourceContextProviding {
    func frontmostApplication() -> ClipboardSourceApplication? { nil }
}
