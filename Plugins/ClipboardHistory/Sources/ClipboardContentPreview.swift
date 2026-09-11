import AppKit
import MacToolsPluginKit
import QuickLookThumbnailing
import SwiftUI

struct ClipboardPreviewRequestID<Key: Hashable>: Hashable {
    let key: Key
    var retry: UInt = 0
    var presentation: UInt = 0
    var isActive = true
}

struct ClipboardPreviewUnavailableView: View {
    let localization: PluginLocalization
    var isUnsupported = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Label(
                isUnsupported
                    ? localization.string("panel.preview.unsupported", defaultValue: "此内容没有可用的预览格式。")
                    : localization.string("panel.preview.failed", defaultValue: "无法载入预览"),
                systemImage: isUnsupported ? "eye.slash" : "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if let retry {
                Button(localization.string("panel.preview.retry", defaultValue: "重试"), action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

enum ClipboardFilePreviewResult: @unchecked Sendable {
    case image(NSImage)
    case missing
    case failed
}

/// Quick Look requires the exact request instance to cancel in-flight generation.
/// The request is immutable after construction and this handle only forwards it
/// to Quick Look's cancellation API, so crossing the cancellation-handler boundary
/// is safe without weakening concurrency checks for the entire framework import.
private final class ClipboardQuickLookRequestHandle: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request

    init(_ request: QLThumbnailGenerator.Request) {
        self.request = request
    }

    func cancel() {
        QLThumbnailGenerator.shared.cancel(request)
    }
}

enum ClipboardFilePreviewLoader {
    @MainActor
    static func load(
        url: URL, scale: CGFloat,
        generate: (@MainActor (QLThumbnailGenerator.Request) async throws -> NSImage)? = nil,
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) async -> ClipboardFilePreviewResult {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 900, height: 650), scale: scale,
            representationTypes: .thumbnail
        )
        let requestHandle = ClipboardQuickLookRequestHandle(request)
        return await withTaskCancellationHandler {
            do {
                let image: NSImage
                if let generate { image = try await generate(request) }
                else { image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage }
                guard !Task.isCancelled else { return .failed }
                return .image(image)
            } catch {
                guard !Task.isCancelled else { return .failed }
                let exists = await Task.detached(priority: .utility) {
                    fileExists(url)
                }.value
                guard !Task.isCancelled else { return .failed }
                return exists ? .failed : .missing
            }
        } onCancel: {
            requestHandle.cancel()
        }
    }
}

/// A bounded page of the original text. The initial page uses metadata, while
/// explicit navigation loads on a worker and releases the reloadable payload.
struct ClipboardTextPreviewPage: Sendable, Equatable {
    static let characterLimit = ClipboardHistoryItem.maximumSearchableCharacterCount
    let text: String
    let number: Int
    let hasMore: Bool

    static func initial(for item: ClipboardHistoryItem) -> Self {
        .init(text: item.text, number: 0, hasMore: item.isSearchTextTruncated)
    }

    static func load(item: ClipboardHistoryItem, number: Int) async throws -> Self {
        guard number >= 0, number <= Int.max / characterLimit else { throw CocoaError(.validationMissingMandatoryProperty) }
        if number == 0 { return initial(for: item) }
        let worker = Task.detached(priority: .userInitiated) {
            defer { item.discardCachedPayloadIfReloadable() }
            try Task.checkCancellation()
            let payload = try item.loadPayload()
            try Task.checkCancellation()
            let text = payload.searchableText
            let start = text.index(text.startIndex, offsetBy: number * characterLimit, limitedBy: text.endIndex) ?? text.endIndex
            let end = text.index(start, offsetBy: characterLimit, limitedBy: text.endIndex) ?? text.endIndex
            try Task.checkCancellation()
            return Self(text: String(text[start..<end]), number: number, hasMore: end < text.endIndex)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

struct ClipboardTextPreviewView: View {
    let item: ClipboardHistoryItem
    let localization: PluginLocalization
    var resetID: UInt = 0
    var isActive = true
    @State private var page: ClipboardTextPreviewPage?
    @State private var presentationID: ClipboardPreviewRequestID<ClipboardEmbeddedPreviewKey>?
    @State private var requestedPage = 0
    @State private var retryID: UInt = 0
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        let displayed = page ?? .initial(for: item)
        VStack(alignment: .leading, spacing: 10) {
            if item.isSearchTextTruncated {
                Label(localization.string("panel.preview.shortened", defaultValue: "预览已缩短，原始内容保持完整。"), systemImage: "text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(localization.string("panel.preview.previous", defaultValue: "上一页")) {
                        requestedPage = displayed.number - 1
                    }.disabled(isLoading || displayed.number == 0)
                    Text(localization.format("panel.preview.page.format", defaultValue: "第 %d 页", displayed.number + 1))
                        .monospacedDigit()
                    Button(localization.string("panel.preview.more", defaultValue: "查看更多")) {
                        requestedPage = displayed.number + 1
                    }.disabled(isLoading || !displayed.hasMore)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if isLoading {
                ProgressView(localization.string("panel.preview.loading", defaultValue: "正在载入预览…"))
                    .controlSize(.small)
            }
            if failed {
                ClipboardPreviewUnavailableView(localization: localization, retry: { retryID &+= 1 })
            }
            ScrollView {
                Text(displayed.text)
                    .font(item.kind == .plainText ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(displayed.number)
        }
        .task(id: TextPageRequest(key: ClipboardEmbeddedPreviewKey(item), page: requestedPage,
                                  retry: retryID, presentation: resetID, isActive: isActive)) {
            let identity = ClipboardPreviewRequestID(key: ClipboardEmbeddedPreviewKey(item),
                                                      presentation: resetID, isActive: isActive)
            let startsPresentation = presentationID != identity
            if startsPresentation {
                presentationID = identity
                page = nil
                requestedPage = 0
                failed = false
                isLoading = false
            }
            guard isActive else { return }
            let number = startsPresentation ? 0 : requestedPage
            failed = false
            isLoading = number != 0
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let loaded = try await ClipboardTextPreviewPage.load(item: item, number: number)
                guard !Task.isCancelled else { return }
                page = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    private struct TextPageRequest: Hashable {
        let key: ClipboardEmbeddedPreviewKey
        let page: Int
        let retry: UInt
        let presentation: UInt
        let isActive: Bool
    }
}
