import AppKit
import Foundation

final class ClipboardHTMLResourceLoadDenyDelegate: NSObject {
    @objc(webView:resource:willSendRequest:redirectResponse:fromDataSource:)
    func denyResourceLoad(
        _ webView: AnyObject,
        resource identifier: AnyObject,
        willSendRequest request: NSURLRequest,
        redirectResponse: URLResponse?,
        fromDataSource dataSource: AnyObject
    ) -> NSURLRequest? {
        nil
    }
}

enum ClipboardRichText {
    static let webResourceLoadDelegateOption = NSAttributedString.DocumentReadingOptionKey(
        rawValue: "WebResourceLoadDelegate"
    )

    static func attributedString(for payload: ClipboardHistoryPayload) -> NSAttributedString? {
        for representation in payload.representations {
            if let attributedString = attributedString(for: representation) {
                return attributedString
            }
        }
        return nil
    }

    static func attributedString(
        for representation: ClipboardStoredRepresentation
    ) -> NSAttributedString? {
        let documentType: NSAttributedString.DocumentType
        switch representation.typeIdentifier {
        case ClipboardRepresentationType.rtfd:
            documentType = .rtfd
        case ClipboardRepresentationType.rtf:
            documentType = .rtf
        case ClipboardRepresentationType.html:
            documentType = .html
        default:
            return nil
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
        ]
        // AppKit's default HTML importer permits subsidiary resource loads. Clipboard HTML is
        // untrusted and must remain local, so install a delegate that rejects every request.
        if documentType == .html {
            options[webResourceLoadDelegateOption] = ClipboardHTMLResourceLoadDenyDelegate()
        }
        return try? NSAttributedString(
            data: representation.data,
            options: options,
            documentAttributes: nil
        )
    }
}

enum ClipboardRichTextPreviewResult: Sendable {
    case formatted(AttributedString)
    case plainText(String, isSimplified: Bool)
    case unavailable
}

enum ClipboardRichTextPreviewLoader {
    static func load(
        for item: ClipboardHistoryItem,
        fallbackText: String
    ) async -> ClipboardRichTextPreviewResult {
        let worker = Task.detached(priority: .userInitiated) {
            defer { item.discardCachedPayloadIfReloadable() }
            guard !Task.isCancelled,
                  let payload = try? item.loadPayload(),
                  !Task.isCancelled else {
                return ClipboardRichTextPreviewResult.unavailable
            }
            return ClipboardRichTextPreviewPolicy.makePreview(
                payload: payload,
                fallbackText: fallbackText
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

enum ClipboardRichTextPreviewPolicy {
    /// Rich document import and SwiftUI text layout can both become expensive. Keep formatted
    /// previews intentionally smaller than the storage limit and fall back to bounded plain text.
    static let maximumFormattedByteCount = 128 * 1_024
    static let maximumFormattedCharacterCount = 12_000

    static func makePreview(
        payload: ClipboardHistoryPayload,
        fallbackText: String
    ) -> ClipboardRichTextPreviewResult {
        guard hasRichRepresentation(in: payload) else { return .unavailable }
        guard allowsFormattedImport(payload) else {
            return simplifiedPreview(for: fallbackText)
        }
        guard let imported = ClipboardRichText.attributedString(for: payload) else {
            return simplifiedPreview(for: fallbackText)
        }
        guard imported.length <= maximumFormattedCharacterCount,
              let formatted = try? AttributedString(imported, including: \.appKit) else {
            return simplifiedPreview(for: fallbackText.isEmpty ? imported.string : fallbackText)
        }
        return .formatted(formatted)
    }

    static func boundedPlainText(_ text: String) -> (text: String, wasTruncated: Bool) {
        let candidate = text.prefix(maximumFormattedCharacterCount + 1)
        guard candidate.count > maximumFormattedCharacterCount else { return (text, false) }
        return (String(candidate.prefix(maximumFormattedCharacterCount)) + "\u{2026}", true)
    }

    static func allowsFormattedImport(_ payload: ClipboardHistoryPayload) -> Bool {
        let richRepresentations = payload.representations.filter {
            isRichRepresentation($0.typeIdentifier)
        }
        return !richRepresentations.isEmpty
            && richRepresentations.allSatisfy { $0.data.count <= maximumFormattedByteCount }
    }

    private static func hasRichRepresentation(in payload: ClipboardHistoryPayload) -> Bool {
        payload.representations.contains { isRichRepresentation($0.typeIdentifier) }
    }

    private static func isRichRepresentation(_ typeIdentifier: String) -> Bool {
        [
            ClipboardRepresentationType.rtfd,
            ClipboardRepresentationType.rtf,
            ClipboardRepresentationType.html,
        ].contains(typeIdentifier)
    }

    private static func simplifiedPreview(for text: String) -> ClipboardRichTextPreviewResult {
        guard !text.isEmpty else { return .unavailable }
        let bounded = boundedPlainText(text)
        return .plainText(bounded.text, isSimplified: true)
    }
}

enum ClipboardPlainTextConversion {
    /// Returns complete visible text from a safe rich representation when possible. Native plain
    /// text remains the fallback for plain-only, oversized, or unreadable rich clipboard content.
    static func visibleText(for payload: ClipboardHistoryPayload) -> String? {
        if ClipboardRichTextPreviewPolicy.allowsFormattedImport(payload),
           let richText = ClipboardRichText.attributedString(for: payload)?.string,
           let text = nonempty(richText) {
            return text
        }
        return nonempty(payload.plainText ?? "")
    }

    static func isAvailable(for item: ClipboardHistoryItem) -> Bool {
        switch item.kind {
        case .richText:
            !item.text.isEmpty
                || item.allowsRichTextImport
        case .image:
            !(item.imageSearchText ?? "").isEmpty
        case .files:
            !item.fileURLs.isEmpty
        case .link:
            !item.linkURLs.isEmpty || !item.text.isEmpty
        case .plainText, .pdf, .color, .media:
            !item.text.isEmpty
        }
    }

    static func text(for item: ClipboardHistoryItem) -> String? {
        let candidate: String
        switch item.kind {
        case .richText:
            let payload = try? item.loadPayload()
            candidate = payload.flatMap(visibleText(for:)) ?? item.text
        case .image:
            candidate = item.imageSearchText ?? ""
        case .files:
            let fileURLs = (try? item.loadPayload())?.fileURLs ?? item.fileURLs
            candidate = fileURLs.map(\.path).joined(separator: "\n")
        case .link:
            let payload = try? item.loadPayload()
            candidate = payload?.plainText
                ?? payload?.linkURLs.first?.absoluteString
                ?? item.linkURLs.first?.absoluteString
                ?? item.text
        case .plainText, .pdf, .color, .media:
            let payload = try? item.loadPayload()
            candidate = payload?.plainText ?? item.text
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : candidate
    }

    /// Produces text only after the item's complete payload has been loaded successfully.
    /// Multi-item operations use this path so a corrupt or unavailable payload cannot be
    /// silently replaced with the bounded metadata kept for search and list presentation.
    static func completeText(for item: ClipboardHistoryItem) throws -> String? {
        if item.kind == .image {
            return nonempty(item.imageSearchText ?? "")
        }

        let payload = try item.loadPayload()
        let candidate: String
        switch item.kind {
        case .richText:
            candidate = visibleText(for: payload) ?? ""
        case .files:
            candidate = payload.fileURLs.map(\.path).joined(separator: "\n")
        case .link:
            candidate = payload.plainText
                ?? payload.linkURLs.first?.absoluteString
                ?? ""
        case .plainText, .pdf, .color, .media:
            candidate = payload.plainText ?? ""
        case .image:
            candidate = ""
        }
        return nonempty(candidate)
    }

    private static func nonempty(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
