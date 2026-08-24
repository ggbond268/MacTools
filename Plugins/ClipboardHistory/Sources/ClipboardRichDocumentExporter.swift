import AppKit
import Foundation
import UniformTypeIdentifiers

struct ClipboardRichDocumentExport: Equatable, Sendable {
    let documentData: Data
    let attachments: [ClipboardExportArtifact]
}

enum ClipboardRichDocumentExporter {
    private static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"

    static func html(for payload: ClipboardHistoryPayload) throws -> Data {
        let attributed = try attributedString(for: payload)
        let range = NSRange(location: 0, length: attributed.length)
        let data = try attributed.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        )
        guard var html = String(data: data, encoding: .utf8) else {
            throw ClipboardExportError.conversionFailed
        }
        html = embedAttachmentImages(in: html, attributedString: attributed)
        html = sanitizeHTML(html)
        if html.range(of: "<head", options: .caseInsensitive) != nil {
            html = html.replacingOccurrences(
                of: #"(?i)<head([^>]*)>"#,
                with: "<head$1><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">",
                options: .regularExpression
            )
        } else {
            html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"></head><body>\(html)</body></html>"
        }
        guard let result = html.data(using: .utf8) else {
            throw ClipboardExportError.conversionFailed
        }
        return result
    }

    static func markdown(
        for payload: ClipboardHistoryPayload,
        documentBaseName: String,
        attachmentDirectorySuffix: String,
        attachmentBaseName: String
    ) throws -> ClipboardRichDocumentExport {
        let attributed = try attributedString(for: payload)
        let attachmentDirectoryName = ClipboardHistoryExportNaming.sanitizedBaseName(documentBaseName)
            + "-"
            + ClipboardHistoryExportNaming.sanitizedBaseName(attachmentDirectorySuffix)
        var attachmentIndex = 0
        var attachments: [ClipboardExportArtifact] = []
        var encounteredUnsupportedAttachment = false
        var output = ""
        let source = attributed.string as NSString
        var paragraphLocation = 0
        while paragraphLocation < attributed.length {
            let paragraphRange = source.paragraphRange(
                for: NSRange(location: paragraphLocation, length: 0)
            )
            let paragraph = attributed.attributedSubstring(from: paragraphRange)
            let paragraphStyle = paragraph.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let prefix = markdownParagraphPrefix(paragraph, paragraphStyle: paragraphStyle)
            var line = ""
            paragraph.enumerateAttributes(
                in: NSRange(location: 0, length: paragraph.length),
                options: []
            ) { attributes, range, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    guard let attachmentData = attachmentData(attachment),
                          let fileExtension = attachmentData.type.preferredFilenameExtension,
                          !fileExtension.isEmpty else {
                        encounteredUnsupportedAttachment = true
                        return
                    }
                    attachmentIndex += 1
                    let fileName = ClipboardHistoryExportNaming.fileName(
                        baseName: attachmentBaseName,
                        extension: fileExtension,
                        index: attachmentIndex
                    )
                    let relativePath = attachmentDirectoryName + "/" + fileName
                    attachments.append(ClipboardExportArtifact(
                        relativePath: relativePath,
                        contentTypeIdentifier: attachmentData.type.identifier,
                        data: attachmentData.data
                    ))
                    let label = markdownEscaped(attachmentData.name ?? attachmentBaseName)
                    let target = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                        ?? relativePath
                    if attachmentData.type.conforms(to: .image) {
                        line += "![\(label)](\(target))"
                    } else {
                        line += "[\(label)](\(target))"
                    }
                    return
                }

                var text = (paragraph.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                guard !text.isEmpty else { return }
                text = markdownEscaped(text)

                if let link = attributes[.link] as? URL {
                    text = "[\(text)](\(link.absoluteString))"
                } else if let link = attributes[.link] as? String, !link.isEmpty {
                    text = "[\(text)](\(link))"
                }
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.italic) { text = "*\(text)*" }
                    if traits.contains(.bold) { text = "**\(text)**" }
                    if traits.contains(.monoSpace) { text = "`\(text.replacingOccurrences(of: "`", with: "\\`"))`" }
                }
                if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
                    text = "~~\(text)~~"
                }
                line += text
            }
            let trimmed = line.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                output += prefix + trimmed + "\n\n"
            }
            paragraphLocation = NSMaxRange(paragraphRange)
        }

        guard !encounteredUnsupportedAttachment else {
            throw ClipboardExportError.unsupportedRepresentation
        }

        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = normalized.data(using: .utf8) else {
            throw ClipboardExportError.conversionFailed
        }
        return ClipboardRichDocumentExport(documentData: data, attachments: attachments)
    }

    static func plainText(for payload: ClipboardHistoryPayload) throws -> Data {
        if let native = payload.plainText, !native.isEmpty,
           let data = native.data(using: .utf8) {
            return data
        }
        let text = try attributedString(for: payload).string
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            throw ClipboardExportError.unavailable
        }
        return data
    }

    static func attachmentCount(in payload: ClipboardHistoryPayload) -> Int {
        guard let attributed = try? attributedString(for: payload), attributed.length > 0 else { return 0 }
        var count = 0
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }

    static func sanitizeHTML(_ html: String) -> String {
        var value = html
        let removedElements = ["script", "iframe", "object", "embed", "form"]
        for element in removedElements {
            value = value.replacingOccurrences(
                of: "(?is)<\(element)\\b[^>]*>.*?</\(element)\\s*>",
                with: "",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: "(?is)<\(element)\\b[^>]*/?>",
                with: "",
                options: .regularExpression
            )
        }
        value = value.replacingOccurrences(
            of: #"(?is)<link\b[^>]*rel\s*=\s*['\"]?stylesheet['\"]?[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?is)<meta\b[^>]*http-equiv\s*=\s*['\"]?refresh['\"]?[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?is)\s+on[a-z0-9_-]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?is)(<img\b[^>]*\s)src\s*=\s*(['\"])(?:https?|file):[^'\"]*\2"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?is)url\(\s*(['\"]?)(?:https?|file):[^)]*\)"#,
            with: "none",
            options: .regularExpression
        )
        return value
    }

    private static func attributedString(for payload: ClipboardHistoryPayload) throws -> NSAttributedString {
        guard let attributed = ClipboardRichText.attributedString(for: payload), attributed.length > 0 else {
            throw ClipboardExportError.invalidPayload
        }
        return attributed
    }

    private static func embedAttachmentImages(
        in html: String,
        attributedString: NSAttributedString
    ) -> String {
        let expression = try? NSRegularExpression(
            pattern: #"(?is)(<img\b[^>]*\bsrc\s*=\s*)(['\"])file:[^'\"]*\2"#
        )
        guard let expression else { return html }

        var value = html
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { candidate, _, _ in
            guard let attachment = candidate as? NSTextAttachment,
                  let attachmentData = attachmentData(attachment),
                  attachmentData.type.conforms(to: .image),
                  let mimeType = attachmentData.type.preferredMIMEType else {
                return
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = expression.firstMatch(in: value, options: [], range: range),
                  let replacementRange = Range(match.range, in: value),
                  let prefixRange = Range(match.range(at: 1), in: value) else {
                return
            }
            let replacement = String(value[prefixRange])
                + "\"data:\(mimeType);base64,\(attachmentData.data.base64EncodedString())\""
            value.replaceSubrange(replacementRange, with: replacement)
        }
        return value
    }

    private static func markdownParagraphPrefix(
        _ paragraph: NSAttributedString,
        paragraphStyle: NSParagraphStyle?
    ) -> String {
        if paragraphStyle?.textLists.isEmpty == false {
            return "- "
        }
        guard paragraph.length > 0,
              let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return ""
        }
        if font.pointSize >= 24 { return "# " }
        if font.pointSize >= 19 { return "## " }
        if font.pointSize >= 16, font.fontDescriptor.symbolicTraits.contains(.bold) { return "### " }
        return ""
    }

    private static func markdownEscaped(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"([\\`*_{}\[\]()#+\-.!|>])"#,
            with: #"\\$1"#,
            options: .regularExpression
        )
    }

    static func attachmentData(
        _ attachment: NSTextAttachment
    ) -> (data: Data, type: UTType, name: String?)? {
        let wrapper = attachment.fileWrapper
        let name = wrapper?.preferredFilename ?? wrapper?.filename
        if let data = wrapper?.regularFileContents {
            guard let name,
                  let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension),
                  type.preferredFilenameExtension?.isEmpty == false else {
                return nil
            }
            return (data, type, name)
        }
        guard let image = attachment.image,
              let data = image.tiffRepresentation else { return nil }
        return (data, .tiff, name)
    }
}
