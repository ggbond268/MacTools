import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class ClipboardHistoryShareCoordinator {
    enum PreparedShare: Equatable, Sendable {
        case URLs([URL])
        case text(String)
        case image(Data, typeIdentifier: String)
        case PDF(Data)
        case unavailable
    }
    private let historyController: ClipboardHistoryController
    private let localization: PluginLocalization
    private weak var hudPresenter: (any ClipboardPrivacyHUDPresenting)?
    private var picker: NSSharingServicePicker?
    private var task: Task<Void, Never>?

    init(
        historyController: ClipboardHistoryController,
        localization: PluginLocalization,
        hudPresenter: any ClipboardPrivacyHUDPresenting
    ) {
        self.historyController = historyController
        self.localization = localization
        self.hudPresenter = hudPresenter
    }

    func cancel() {
        task?.cancel()
        task = nil
        picker = nil
    }

    func share(itemIDs: [UUID], from anchorView: NSView?) {
        guard let anchorView, !itemIDs.isEmpty else { return }
        task?.cancel()
        let itemsByID = Dictionary(uniqueKeysWithValues: historyController.items.map { ($0.id, $0) })
        let items = itemIDs.compactMap { itemsByID[$0] }
        guard !items.isEmpty, items.count == itemIDs.count else { return }

        task = Task { @MainActor [weak self, weak anchorView] in
            guard let self, let anchorView else { return }
            let preparedShare: PreparedShare
            if items.count > 1 {
                preparedShare = await self.historyController.combinedPlainText(ids: itemIDs)
                    .map(PreparedShare.text) ?? .unavailable
            } else {
                preparedShare = await Self.prepareSingleShare(for: items[0])
            }
            let sharingItems = Self.sharingItems(from: preparedShare)
            guard !Task.isCancelled else { return }
            guard !sharingItems.isEmpty else {
                self.hudPresenter?.showFailure(self.localization.string(
                    "share.unavailable",
                    defaultValue: "This clipboard item can’t be shared"
                ))
                return
            }
            let picker = NSSharingServicePicker(items: sharingItems)
            self.picker = picker
            PluginPresentationSafety.prepareForWindowOrdering(anchorView.window)
            picker.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: .maxY
            )
        }
    }

    func share(savedItem: ClipboardSavedItem, from anchorView: NSView?) {
        guard let anchorView else { return }
        task?.cancel()
        let presentation = savedItem.historyPresentationItem()
        task = Task { @MainActor [weak self, weak anchorView] in
            guard let self, let anchorView else { return }
            let preparedShare = await Self.prepareSingleShare(for: presentation)
            let sharingItems = Self.sharingItems(from: preparedShare)
            guard !Task.isCancelled else { return }
            guard !sharingItems.isEmpty else {
                self.hudPresenter?.showFailure(self.localization.string(
                    "share.unavailable",
                    defaultValue: "This clipboard item can’t be shared"
                ))
                return
            }
            let picker = NSSharingServicePicker(items: sharingItems)
            self.picker = picker
            PluginPresentationSafety.prepareForWindowOrdering(anchorView.window)
            picker.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: .maxY
            )
        }
    }

    func share(text: String, from anchorView: NSView?) {
        guard let anchorView, !text.isEmpty else { return }
        task?.cancel()
        task = nil
        picker = NSSharingServicePicker(items: [text])
        PluginPresentationSafety.prepareForWindowOrdering(anchorView.window)
        picker?.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    nonisolated static func prepareSingleShare(
        for item: ClipboardHistoryItem
    ) async -> PreparedShare {
        guard let payload = try? await item.loadPayloadAsync() else {
            return .unavailable
        }
        defer { item.discardCachedPayloadIfReloadable() }
        if !payload.fileURLs.isEmpty { return .URLs(payload.fileURLs) }
        if !payload.linkURLs.isEmpty { return .URLs(payload.linkURLs) }
        if item.kind == .pdf,
           let pdf = payload.representations.first(where: {
               $0.typeIdentifier == ClipboardRepresentationType.pdf
           }) {
            return .PDF(pdf.data)
        }
        if let representation = payload.representations.first(where: {
            ClipboardRepresentationType.isImage($0.typeIdentifier)
        }) {
            return .image(representation.data, typeIdentifier: representation.typeIdentifier)
        }
        if let text = ClipboardPlainTextConversion.text(for: item) { return .text(text) }
        if let pdf = payload.representations.first(where: {
            $0.typeIdentifier == ClipboardRepresentationType.pdf
        }) {
            return .PDF(pdf.data)
        }
        return .unavailable
    }

    private static func sharingItems(from preparedShare: PreparedShare) -> [Any] {
        switch preparedShare {
        case let .URLs(urls): return urls
        case let .text(text): return [text]
        case let .image(data, typeIdentifier):
            let item = NSPasteboardItem()
            return item.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
                ? [item]
                : []
        case let .PDF(data): return [data as NSData]
        case .unavailable: return []
        }
    }
}
