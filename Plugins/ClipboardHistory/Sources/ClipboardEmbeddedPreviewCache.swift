import AppKit
import SwiftUI

struct ClipboardEmbeddedPreviewKey: Hashable {
    let itemID: UUID
    let payloadDigest: Data

    init(_ item: ClipboardHistoryItem) {
        itemID = item.id
        payloadDigest = item.payloadDigest
    }
}

/// Window-scoped, bounded decoded thumbnails. Never retains source clipboard payloads.
@MainActor
final class ClipboardEmbeddedPreviewCache {
    private struct Entry {
        let image: NSImage
        let cost: Int
        var access: UInt64
    }
    private struct Flight {
        let id: UUID
        let task: Task<ClipboardEmbeddedPreviewResult, Never>
        var consumers: Set<UUID>
    }

    private let maximumCost: Int
    private let maximumCount: Int
    private let loader: @MainActor (ClipboardHistoryItem) async -> NSImage?
    private var entries: [ClipboardEmbeddedPreviewKey: Entry] = [:]
    private var flights: [ClipboardEmbeddedPreviewKey: Flight] = [:]
    private var access: UInt64 = 0
    private(set) var totalCost = 0
    var count: Int { entries.count }

    init(maximumCost: Int = 32 * 1_024 * 1_024, maximumCount: Int = 8,
         loader: @escaping @MainActor (ClipboardHistoryItem) async -> NSImage? = { await ClipboardEmbeddedPreviewLoader.load(for: $0) }) {
        self.maximumCost = max(0, maximumCost)
        self.maximumCount = max(0, maximumCount)
        self.loader = loader
    }

    func cachedImage(for item: ClipboardHistoryItem) -> NSImage? {
        let key = ClipboardEmbeddedPreviewKey(item)
        guard var entry = entries[key] else { return nil }
        access &+= 1
        entry.access = access
        entries[key] = entry
        return entry.image
    }

    func image(for item: ClipboardHistoryItem) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedImage(for: item) { return cached }
        let key = ClipboardEmbeddedPreviewKey(item)
        let consumer = UUID()
        let flight: Flight
        if var existing = flights[key] {
            existing.consumers.insert(consumer)
            flights[key] = existing
            flight = existing
        } else {
            let loader = loader
            flight = Flight(id: UUID(), task: Task {
                ClipboardEmbeddedPreviewResult(image: await loader(item))
            }, consumers: [consumer])
            flights[key] = flight
        }
        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(consumer: consumer, key: key, flightID: flight.id) }
        }
        guard !Task.isCancelled else {
            cancel(consumer: consumer, key: key, flightID: flight.id)
            return nil
        }
        // Keep the flight until every consumer has resumed, including images too
        // large to cache. Invalidation removes it and rejects all late results.
        guard var active = flights[key], active.id == flight.id else { return nil }
        active.consumers.remove(consumer)
        if active.consumers.isEmpty { flights.removeValue(forKey: key) }
        else { flights[key] = active }
        if entries[key] == nil, let image = result.image { insert(image, for: key) }
        return result.image
    }

    func retain(where isValid: (ClipboardEmbeddedPreviewKey) -> Bool) {
        for key in Array(entries.keys) where !isValid(key) {
            totalCost -= entries.removeValue(forKey: key)?.cost ?? 0
        }
        for key in Array(flights.keys) where !isValid(key) {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    func removeAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        entries.removeAll()
        totalCost = 0
    }

    private func cancel(consumer: UUID, key: ClipboardEmbeddedPreviewKey, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private func insert(_ image: NSImage, for key: ClipboardEmbeddedPreviewKey) {
        let width = image.representations.map { Double($0.pixelsWide) }.max() ?? Double(image.size.width)
        let height = image.representations.map { Double($0.pixelsHigh) }.max() ?? Double(image.size.height)
        // Conservatively budget eight bytes per pixel, including high-bit-depth images.
        let cost = width * height * 8
        guard maximumCount > 0, width > 0, height > 0,
              cost.isFinite, cost > 0, cost < Double(Int.max), cost <= Double(maximumCost) else { return }
        if let previous = entries.removeValue(forKey: key) { totalCost -= previous.cost }
        while entries.count >= maximumCount || totalCost + Int(cost) > maximumCost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            totalCost -= entries.removeValue(forKey: oldest)?.cost ?? 0
        }
        access &+= 1
        entries[key] = Entry(image: image, cost: Int(cost), access: access)
        totalCost += Int(cost)
    }
}

/// Async preview state belongs to the preview leaf, not the whole list/toolbar/footer.
struct ClipboardEmbeddedPreviewView<Content: View, Unavailable: View>: View {
    let item: ClipboardHistoryItem
    let cache: ClipboardEmbeddedPreviewCache
    var resetID: UInt = 0
    var isActive = true
    @ViewBuilder let content: (NSImage) -> Content
    @ViewBuilder let unavailable: () -> Unavailable
    @State private var image: NSImage?
    @State private var displayedKey: ClipboardEmbeddedPreviewKey?
    @State private var requestedKey: ClipboardEmbeddedPreviewKey?
    @State private var isLoading = false
    @State private var showsLoadingIndicator = false

    var body: some View {
        Group {
            if let image {
                content(image)
                    .opacity(displayedKey == requestedKey ? 1 : 0.58)
                    .overlay {
                        if showsLoadingIndicator {
                            ProgressView().controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
            } else if showsLoadingIndicator {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                unavailable()
            }
        }
        .task(id: ClipboardEmbeddedPreviewRequestID(
            key: ClipboardEmbeddedPreviewKey(item),
            resetID: resetID
        )) {
            guard isActive else {
                requestedKey = nil
                displayedKey = nil
                image = nil
                isLoading = false
                showsLoadingIndicator = false
                return
            }
            await load()
        }
        .onChange(of: isActive) { _, active in
            guard !active else { return }
            requestedKey = nil
            displayedKey = nil
            image = nil
            isLoading = false
            showsLoadingIndicator = false
        }
    }

    private func load() async {
        guard isActive else { return }
        let key = ClipboardEmbeddedPreviewKey(item)
        requestedKey = key
        if let cached = cache.cachedImage(for: item) {
            displayedKey = key
            image = cached
            isLoading = false
            showsLoadingIndicator = false
            return
        }
        isLoading = true
        showsLoadingIndicator = false
        let progressTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, requestedKey == key, isLoading else { return }
            showsLoadingIndicator = true
        }
        let loaded = await cache.image(for: item)
        progressTask.cancel()
        guard !Task.isCancelled, requestedKey == key else { return }
        image = loaded
        displayedKey = loaded == nil ? nil : key
        isLoading = false
        showsLoadingIndicator = false
    }
}

private struct ClipboardEmbeddedPreviewRequestID: Hashable {
    let key: ClipboardEmbeddedPreviewKey
    let resetID: UInt
}
