import Foundation

/// Reuses only the last bounded preview, including its prepared light and dark colors.
/// Never retains source payloads or failed reads, so Retry always attempts a fresh import.
@MainActor
final class ClipboardRichTextPreviewCache {
    private let loader: (ClipboardHistoryItem) async -> ClipboardRichTextPreviewResult
    private var key: ClipboardEmbeddedPreviewKey?
    private var result: ClipboardRichTextPreviewResult?
    private var generation: UInt64 = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(loader: @escaping (ClipboardHistoryItem) async -> ClipboardRichTextPreviewResult = {
        await ClipboardRichTextPreviewLoader.load(for: $0, fallbackText: $0.text)
    }) {
        self.loader = loader
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.removeAll() }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit { memoryPressureSource?.cancel() }

    func preview(for item: ClipboardHistoryItem) async -> ClipboardRichTextPreviewResult {
        guard !Task.isCancelled else { return .unavailable }
        let requestedKey = ClipboardEmbeddedPreviewKey(item)
        if key == requestedKey, let result { return result }
        generation &+= 1
        let request = generation
        key = requestedKey
        result = nil
        let loaded = await loader(item)
        guard !Task.isCancelled, generation == request else { return .unavailable }
        switch loaded {
        case .formatted, .plainText: result = loaded
        case .fallback, .unavailable: break
        }
        return loaded
    }

    func retain(where isValid: (ClipboardEmbeddedPreviewKey) -> Bool) {
        if let key, !isValid(key) { removeAll() }
    }

    func invalidatePendingLoad() {
        generation &+= 1
        if result == nil { key = nil }
    }

    func removeAll() {
        invalidatePendingLoad()
        key = nil
        result = nil
    }
}
