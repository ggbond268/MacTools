import Foundation
import UniformTypeIdentifiers

enum ClipboardHistoryExportPlanner {
    static func options(for item: ClipboardHistoryItem) -> [ClipboardExportOption] {
        switch item.kind {
        case .plainText:
            [option(.plainText, isDefault: true)]
        case .richText:
            [
                option(.html, isDefault: true),
                option(.pdf),
                option(.markdown),
                option(.plainText),
            ] + (hasOriginalRichRepresentation(item) ? [option(.original)] : [])
        case .image:
            [
                option(.png, isDefault: true),
                option(.original),
                option(.jpeg),
                option(.tiff),
                option(.recognizedText),
            ]
        case .pdf:
            [option(.original, isDefault: true)]
        case .files:
            []
        case .link:
            [option(.webLocation, isDefault: true), option(.plainText)]
        case .color:
            [option(.plainText, isDefault: true)]
        case .media:
            item.representationTypeIdentifiers.contains(where: { identifier in
                exportableMediaType(for: identifier) != nil
            }) ? [option(.original, isDefault: true)] : []
        }
    }

    static func defaultFormat(for item: ClipboardHistoryItem) -> ClipboardExportFormat? {
        options(for: item).first?.format
    }

    static func makePlan(
        item: ClipboardHistoryItem,
        payload: ClipboardHistoryPayload,
        format: ClipboardExportFormat,
        baseName: String,
        markdownAttachmentDirectorySuffix: String = "assets",
        markdownAttachmentBaseName: String = "Attachment"
    ) throws -> ClipboardExportPlan {
        guard options(for: item).contains(where: { $0.format == format }) else {
            throw ClipboardExportError.unsupportedRepresentation
        }
        let count = try expectedArtifactCount(payload: payload, format: format)
        guard count > 0 else { throw ClipboardExportError.unavailable }
        let fileExtension = try preferredExtension(payload: payload, format: format)
        let suggestedName = ClipboardHistoryExportNaming.fileName(
            baseName: baseName,
            extension: fileExtension
        )
        return ClipboardExportPlan(
            itemID: item.id,
            format: format,
            destination: count == 1 ? .file : .folder,
            suggestedName: suggestedName,
            contentTypeIdentifier: contentTypeIdentifier(payload: payload, format: format),
            expectedArtifactCount: count,
            markdownAttachmentDirectorySuffix: markdownAttachmentDirectorySuffix,
            markdownAttachmentBaseName: markdownAttachmentBaseName
        )
    }

    private static func option(
        _ format: ClipboardExportFormat,
        isDefault: Bool = false
    ) -> ClipboardExportOption {
        ClipboardExportOption(format: format, isDefault: isDefault)
    }

    private static func hasOriginalRichRepresentation(_ item: ClipboardHistoryItem) -> Bool {
        item.representationTypeIdentifiers.contains(ClipboardRepresentationType.rtf)
            || item.representationTypeIdentifiers.contains(ClipboardRepresentationType.rtfd)
    }

    private static func expectedArtifactCount(
        payload: ClipboardHistoryPayload,
        format: ClipboardExportFormat
    ) throws -> Int {
        switch format {
        case .html, .plainText, .webLocation, .recognizedText:
            return 1
        case .markdown:
            return 1 + ClipboardRichDocumentExporter.attachmentCount(in: payload)
        case .pdf:
            return payload.kind == .richText
                ? 1
                : matchingItems(in: payload, where: { $0.typeIdentifier == ClipboardRepresentationType.pdf }).count
        case .png, .jpeg, .tiff:
            return matchingItems(in: payload, where: {
                ClipboardRepresentationType.isImage($0.typeIdentifier)
            }).count
        case .original:
            switch payload.kind {
            case .richText:
                return 1
            case .image:
                return matchingItems(in: payload, where: {
                    ClipboardRepresentationType.isImage($0.typeIdentifier)
                }).count
            case .pdf:
                return matchingItems(in: payload, where: {
                    $0.typeIdentifier == ClipboardRepresentationType.pdf
                }).count
            case .media:
                return matchingItems(in: payload, where: {
                    exportableMediaType(for: $0.typeIdentifier) != nil
                }).count
            default:
                throw ClipboardExportError.unsupportedRepresentation
            }
        }
    }

    private static func preferredExtension(
        payload: ClipboardHistoryPayload,
        format: ClipboardExportFormat
    ) throws -> String {
        switch format {
        case .plainText, .recognizedText: return "txt"
        case .html: return "html"
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .webLocation: return "webloc"
        case .original:
            guard let representation = originalRepresentation(in: payload) else {
                throw ClipboardExportError.unsupportedRepresentation
            }
            if representation.typeIdentifier == ClipboardRepresentationType.rtfd {
                return "rtfd"
            }
            guard let type = UTType(representation.typeIdentifier),
                  let fileExtension = type.preferredFilenameExtension else {
                throw ClipboardExportError.unsupportedRepresentation
            }
            return fileExtension
        }
    }

    private static func contentTypeIdentifier(
        payload: ClipboardHistoryPayload,
        format: ClipboardExportFormat
    ) -> String? {
        switch format {
        case .plainText, .recognizedText: UTType.plainText.identifier
        case .html: UTType.html.identifier
        case .pdf: UTType.pdf.identifier
        case .markdown: UTType(filenameExtension: "md")?.identifier ?? "net.daringfireball.markdown"
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .tiff: UTType.tiff.identifier
        case .webLocation: "com.apple.web-internet-location"
        case .original: originalRepresentation(in: payload)?.typeIdentifier
        }
    }

    static func originalRepresentation(in payload: ClipboardHistoryPayload) -> ClipboardStoredRepresentation? {
        switch payload.kind {
        case .richText:
            return payload.representations.first {
                $0.typeIdentifier == ClipboardRepresentationType.rtfd
            } ?? payload.representations.first {
                $0.typeIdentifier == ClipboardRepresentationType.rtf
            }
        case .image:
            return payload.representations.first { ClipboardRepresentationType.isImage($0.typeIdentifier) }
        case .pdf:
            return payload.representations.first { $0.typeIdentifier == ClipboardRepresentationType.pdf }
        case .media:
            return payload.representations.first {
                exportableMediaType(for: $0.typeIdentifier) != nil
            }
        default:
            return nil
        }
    }

    static func matchingItems(
        in payload: ClipboardHistoryPayload,
        where predicate: (ClipboardStoredRepresentation) -> Bool
    ) -> [ClipboardStoredPasteboardItem] {
        payload.pasteboardItems.filter { item in item.representations.contains(where: predicate) }
    }

    static func exportableMediaType(for typeIdentifier: String) -> UTType? {
        guard ClipboardRepresentationType.isMedia(typeIdentifier),
              let type = UTType(typeIdentifier),
              type.preferredFilenameExtension?.isEmpty == false else {
            return nil
        }
        return type
    }
}
