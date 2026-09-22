import Foundation

/// Reuses a few bounded previews, including their prepared light and dark colors.
/// Never retains source payloads or failed reads, so Retry always attempts a fresh import.
@MainActor
final class ClipboardRichTextPreviewCache {
    private struct Entry {
        let result: ClipboardRichTextPreviewResult
        var access: UInt64
    }

    private let maximumCount: Int
    private let loader: (ClipboardHistoryItem) async -> ClipboardRichTextPreviewResult
    private var entries: [ClipboardEmbeddedPreviewKey: Entry] = [:]
    private var access: UInt64 = 0
    private var pendingKey: ClipboardEmbeddedPreviewKey?
    private var generation: UInt64 = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(maximumCount: Int = 4, loader: @escaping (ClipboardHistoryItem) async -> ClipboardRichTextPreviewResult = {
        await ClipboardRichTextPreviewLoader.load(for: $0, fallbackText: $0.text)
    }) {
        self.maximumCount = max(0, maximumCount)
        self.loader = loader
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.removeAll() }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit { memoryPressureSource?.cancel() }

    func cachedPreview(for item: ClipboardHistoryItem) -> ClipboardRichTextPreviewResult? {
        let key = ClipboardEmbeddedPreviewKey(item)
        guard var entry = entries[key] else { return nil }
        access &+= 1
        entry.access = access
        entries[key] = entry
        return entry.result
    }

    func preview(for item: ClipboardHistoryItem) async -> ClipboardRichTextPreviewResult {
        guard !Task.isCancelled else { return .unavailable }
        invalidatePendingLoad()
        if let cached = cachedPreview(for: item) { return cached }
        let key = ClipboardEmbeddedPreviewKey(item)
        let request = generation
        pendingKey = key
        let loaded = await loader(item)
        guard !Task.isCancelled, generation == request else { return .unavailable }
        pendingKey = nil
        switch loaded {
        case .formatted, .plainText: insert(loaded, for: key)
        case .fallback, .unavailable: break
        }
        return loaded
    }

    func retain(where isValid: (ClipboardEmbeddedPreviewKey) -> Bool) {
        entries = entries.filter { isValid($0.key) }
        if let pendingKey, !isValid(pendingKey) { invalidatePendingLoad() }
    }

    func invalidatePendingLoad() {
        generation &+= 1
        pendingKey = nil
    }

    func removeAll() {
        invalidatePendingLoad()
        entries.removeAll()
    }

    private func insert(_ result: ClipboardRichTextPreviewResult, for key: ClipboardEmbeddedPreviewKey) {
        guard maximumCount > 0 else { return }
        // Each imported document is already bounded by the rich-text preview policy.
        entries = entries.filter { $0.key.itemID != key.itemID }
        if entries.count >= maximumCount,
           let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
        access &+= 1
        entries[key] = Entry(result: result, access: access)
    }
}
