import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardHistoryExportService {
    static func loadPayload(for item: ClipboardHistoryItem) async throws -> ClipboardHistoryPayload {
        try await ClipboardHistoryExportAsyncWork.run {
            return try item.loadPayload()
        }
    }

    static func makeArtifacts(
        item: ClipboardHistoryItem,
        payload: ClipboardHistoryPayload,
        plan: ClipboardExportPlan,
        baseName: String,
        recognizer: any ClipboardImageTextRecognizing = VisionClipboardImageTextExportRecognizer()
    ) async throws -> [ClipboardExportArtifact] {
        if plan.format == .recognizedText {
            let recognizedText = await recognizer.recognizeText(in: payload)
            try Task.checkCancellation()
            guard let text = recognizedText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = text.data(using: .utf8) else {
                throw ClipboardExportError.recognizedTextUnavailable
            }
            return try validatedArtifacts([ClipboardExportArtifact(
                relativePath: ClipboardHistoryExportNaming.fileName(baseName: baseName, extension: "txt"),
                contentTypeIdentifier: UTType.plainText.identifier,
                data: data
            )], for: plan)
        }

        if plan.format == .pdf, item.kind == .richText {
            let htmlData = try await ClipboardHistoryExportAsyncWork.run {
                try ClipboardRichDocumentExporter.html(for: payload)
            }
            guard let html = String(data: htmlData, encoding: .utf8) else {
                throw ClipboardExportError.conversionFailed
            }
            let pdf = try await ClipboardPDFExporter().render(html: html)
            guard isValidPDF(pdf) else { throw ClipboardExportError.conversionFailed }
            return try validatedArtifacts([ClipboardExportArtifact(
                relativePath: ClipboardHistoryExportNaming.fileName(baseName: baseName, extension: "pdf"),
                contentTypeIdentifier: UTType.pdf.identifier,
                data: pdf
            )], for: plan)
        }

        let artifacts = try await ClipboardHistoryExportAsyncWork.run {
            return try makeSynchronousArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: baseName
            )
        }
        return try validatedArtifacts(artifacts, for: plan)
    }

    static func write(
        artifacts: [ClipboardExportArtifact],
        plan: ClipboardExportPlan,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        try Task.checkCancellation()
        let artifacts = try validatedArtifacts(artifacts, for: plan)
        switch plan.destination {
        case .file:
            guard artifacts.count == 1, let artifact = artifacts.first else {
                throw ClipboardExportError.invalidPayload
            }
            try write(artifact: artifact, to: destinationURL, fileManager: fileManager)
            return [destinationURL]
        case .folder:
            let groupName = ClipboardHistoryExportNaming.sanitizedBaseName(
                URL(fileURLWithPath: plan.suggestedName).deletingPathExtension().lastPathComponent
            )
            let exportRoot = try ClipboardHistoryExportNaming.availableDirectoryURL(
                in: destinationURL,
                preferredName: groupName,
                fileManager: fileManager
            )
            try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: false)
            do {
                var written: [URL] = []
                for artifact in artifacts {
                    try Task.checkCancellation()
                    guard let relativePath = ClipboardHistoryExportNaming.safeRelativePath(artifact.relativePath) else {
                        throw ClipboardExportError.unsafeDestination
                    }
                    let target = exportRoot.appendingPathComponent(relativePath, isDirectory: false)
                    let parent = target.deletingLastPathComponent()
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                    guard !fileManager.fileExists(atPath: target.path) else {
                        throw ClipboardExportError.unsafeDestination
                    }
                    try write(artifact: artifact, to: target, fileManager: fileManager)
                    written.append(target)
                }
                try Task.checkCancellation()
                return written
            } catch {
                try? fileManager.removeItem(at: exportRoot)
                throw error
            }
        }
    }

    static func destinationSnapshot(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> ClipboardExportDestinationSnapshot {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return ClipboardExportDestinationSnapshot(fileIdentity: .init(
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            creationDate: attributes[.creationDate] as? Date,
            modificationDate: attributes[.modificationDate] as? Date
        ))
    }

    static func writeExplicitFile(
        artifacts: [ClipboardExportArtifact],
        plan: ClipboardExportPlan,
        destinationURL: URL,
        expectedDestination: ClipboardExportDestinationSnapshot,
        fileManager: FileManager = .default,
        beforeCommit: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [URL] {
        try Task.checkCancellation()
        let artifacts = try validatedArtifacts(artifacts, for: plan)
        guard plan.destination == .file,
              artifacts.count == 1,
              let artifact = artifacts.first else {
            throw ClipboardExportError.invalidPayload
        }

        let parent = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ClipboardExportError.unsafeDestination
        }
        let stageURL = parent.appendingPathComponent(
            ".mactools-export-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stageURL) }

        try write(artifact: artifact, to: stageURL, fileManager: fileManager)
        try beforeCommit()
        guard try destinationSnapshot(at: destinationURL, fileManager: fileManager)
            == expectedDestination else {
            throw ClipboardExportError.unsafeDestination
        }

        if expectedDestination == .absent {
            try fileManager.moveItem(at: stageURL, to: destinationURL)
        } else {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stageURL)
        }
        return [destinationURL]
    }

    private static func validatedArtifacts(
        _ artifacts: [ClipboardExportArtifact],
        for plan: ClipboardExportPlan
    ) throws -> [ClipboardExportArtifact] {
        guard !artifacts.isEmpty else { throw ClipboardExportError.unavailable }
        guard artifacts.count == plan.expectedArtifactCount else {
            throw ClipboardExportError.invalidPayload
        }
        return artifacts
    }

    private static func makeSynchronousArtifacts(
        item: ClipboardHistoryItem,
        payload: ClipboardHistoryPayload,
        plan: ClipboardExportPlan,
        baseName: String
    ) throws -> [ClipboardExportArtifact] {
        switch plan.format {
        case .plainText:
            let data: Data
            if item.kind == .richText {
                data = try ClipboardRichDocumentExporter.plainText(for: payload)
            } else if item.kind == .link,
                      let url = payload.linkURLs.first,
                      let encoded = url.absoluteString.data(using: .utf8) {
                data = encoded
            } else if item.kind == .color {
                data = try colorTextData(payload)
            } else {
                let text = payload.plainTexts.joined(separator: "\n")
                guard !text.isEmpty, let encoded = text.data(using: .utf8) else {
                    throw ClipboardExportError.unavailable
                }
                data = encoded
            }
            return [artifact(baseName: baseName, extension: "txt", type: .plainText, data: data)]
        case .html:
            return [artifact(
                baseName: baseName,
                extension: "html",
                type: .html,
                data: try ClipboardRichDocumentExporter.html(for: payload)
            )]
        case .markdown:
            let result = try ClipboardRichDocumentExporter.markdown(
                for: payload,
                documentBaseName: baseName,
                attachmentDirectorySuffix: plan.markdownAttachmentDirectorySuffix,
                attachmentBaseName: plan.markdownAttachmentBaseName
            )
            let document = artifact(
                baseName: baseName,
                extension: "md",
                typeIdentifier: UTType(filenameExtension: "md")?.identifier ?? "net.daringfireball.markdown",
                data: result.documentData
            )
            return [document] + result.attachments
        case .pdf:
            return try binaryArtifacts(
                payload: payload,
                baseName: baseName,
                typeIdentifier: ClipboardRepresentationType.pdf,
                fileExtension: "pdf",
                validate: isValidPDF
            )
        case .png, .jpeg, .tiff:
            return try imageArtifacts(payload: payload, format: plan.format, baseName: baseName)
        case .webLocation:
            guard let url = payload.linkURLs.first else { throw ClipboardExportError.unavailable }
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["URL": url.absoluteString],
                format: .xml,
                options: 0
            )
            return [artifact(
                baseName: baseName,
                extension: "webloc",
                typeIdentifier: "com.apple.web-internet-location",
                data: data
            )]
        case .original:
            return try originalArtifacts(payload: payload, baseName: baseName)
        case .recognizedText:
            throw ClipboardExportError.invalidPayload
        }
    }

    private static func imageArtifacts(
        payload: ClipboardHistoryPayload,
        format: ClipboardExportFormat,
        baseName: String
    ) throws -> [ClipboardExportArtifact] {
        let items = ClipboardHistoryExportPlanner.matchingItems(in: payload) {
            ClipboardRepresentationType.isImage($0.typeIdentifier)
        }
        guard !items.isEmpty else { throw ClipboardExportError.unavailable }
        return try items.enumerated().map { index, storedItem in
            guard let representation = storedItem.representations.first(where: {
                ClipboardRepresentationType.isImage($0.typeIdentifier)
            }), let source = CGImageSourceCreateWithData(representation.data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ClipboardExportError.invalidPayload
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let output: (NSBitmapImageRep.FileType, [NSBitmapImageRep.PropertyKey: Any], UTType, String)
            switch format {
            case .png:
                output = (.png, [:], .png, "png")
            case .jpeg:
                output = (.jpeg, [.compressionFactor: 0.9], .jpeg, "jpg")
            case .tiff:
                output = (.tiff, [:], .tiff, "tiff")
            default:
                throw ClipboardExportError.invalidPayload
            }
            guard let data = bitmap.representation(using: output.0, properties: output.1) else {
                throw ClipboardExportError.conversionFailed
            }
            return artifact(
                baseName: baseName,
                extension: output.3,
                type: output.2,
                data: data,
                index: items.count > 1 ? index + 1 : nil
            )
        }
    }

    private static func originalArtifacts(
        payload: ClipboardHistoryPayload,
        baseName: String
    ) throws -> [ClipboardExportArtifact] {
        let representations: [ClipboardStoredRepresentation]
        switch payload.kind {
        case .richText:
            representations = [ClipboardHistoryExportPlanner.originalRepresentation(in: payload)].compactMap { $0 }
        case .image:
            representations = ClipboardHistoryExportPlanner.matchingItems(in: payload) {
                ClipboardRepresentationType.isImage($0.typeIdentifier)
            }.compactMap { $0.representations.first(where: {
                ClipboardRepresentationType.isImage($0.typeIdentifier)
            }) }
        case .pdf:
            representations = ClipboardHistoryExportPlanner.matchingItems(in: payload) {
                $0.typeIdentifier == ClipboardRepresentationType.pdf
            }.compactMap { $0.representations.first(where: {
                $0.typeIdentifier == ClipboardRepresentationType.pdf
            }) }
        case .media:
            representations = ClipboardHistoryExportPlanner.matchingItems(in: payload) {
                ClipboardHistoryExportPlanner.exportableMediaType(for: $0.typeIdentifier) != nil
            }.compactMap { $0.representations.first(where: {
                ClipboardHistoryExportPlanner.exportableMediaType(for: $0.typeIdentifier) != nil
            }) }
        default:
            throw ClipboardExportError.unsupportedRepresentation
        }
        guard !representations.isEmpty else { throw ClipboardExportError.unavailable }
        return try representations.enumerated().map { index, representation in
            guard !representation.data.isEmpty else {
                throw ClipboardExportError.invalidPayload
            }
            if representation.typeIdentifier == ClipboardRepresentationType.rtfd {
                guard let attributed = ClipboardRichText.attributedString(for: representation),
                      attributed.length > 0 else {
                    throw ClipboardExportError.invalidPayload
                }
                return artifact(
                    baseName: baseName,
                    extension: "rtfd",
                    typeIdentifier: UTType.flatRTFD.identifier,
                    data: representation.data,
                    index: representations.count > 1 ? index + 1 : nil
                )
            }
            if representation.typeIdentifier == ClipboardRepresentationType.rtf {
                guard let attributed = ClipboardRichText.attributedString(for: representation),
                      attributed.length > 0 else {
                    throw ClipboardExportError.invalidPayload
                }
            }
            guard let type = UTType(representation.typeIdentifier),
                  let fileExtension = type.preferredFilenameExtension else {
                throw ClipboardExportError.invalidPayload
            }
            if type.conforms(to: .image) {
                guard let source = CGImageSourceCreateWithData(representation.data as CFData, nil),
                      CGImageSourceGetCount(source) > 0 else {
                    throw ClipboardExportError.invalidPayload
                }
            } else if type.conforms(to: .pdf), !isValidPDF(representation.data) {
                throw ClipboardExportError.invalidPayload
            } else if !(type.conforms(to: .audio) || type.conforms(to: .movie)
                        || type.conforms(to: .rtf)) {
                throw ClipboardExportError.unsupportedRepresentation
            }
            return artifact(
                baseName: baseName,
                extension: fileExtension,
                typeIdentifier: type.identifier,
                data: representation.data,
                index: representations.count > 1 ? index + 1 : nil
            )
        }
    }

    private static func binaryArtifacts(
        payload: ClipboardHistoryPayload,
        baseName: String,
        typeIdentifier: String,
        fileExtension: String,
        validate: (Data) -> Bool
    ) throws -> [ClipboardExportArtifact] {
        let representations = ClipboardHistoryExportPlanner.matchingItems(in: payload) {
            $0.typeIdentifier == typeIdentifier
        }.compactMap { item in
            item.representations.first { $0.typeIdentifier == typeIdentifier }
        }
        guard !representations.isEmpty else { throw ClipboardExportError.unavailable }
        return try representations.enumerated().map { index, representation in
            guard validate(representation.data) else { throw ClipboardExportError.invalidPayload }
            return artifact(
                baseName: baseName,
                extension: fileExtension,
                typeIdentifier: typeIdentifier,
                data: representation.data,
                index: representations.count > 1 ? index + 1 : nil
            )
        }
    }

    private static func colorTextData(_ payload: ClipboardHistoryPayload) throws -> Data {
        guard let representation = payload.representations.first(where: {
            $0.typeIdentifier == ClipboardRepresentationType.color
        }), let color = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSColor.self,
            from: representation.data
        ), let converted = color.usingColorSpace(.sRGB) else {
            throw ClipboardExportError.invalidPayload
        }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        let alpha = Int((converted.alphaComponent * 255).rounded())
        let value = alpha == 255
            ? String(format: "#%02X%02X%02X", red, green, blue)
            : String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
        guard let data = value.data(using: .utf8) else { throw ClipboardExportError.conversionFailed }
        return data
    }

    private static func isValidPDF(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData) else { return false }
        return CGPDFDocument(provider) != nil
    }

    private static func write(
        artifact: ClipboardExportArtifact,
        to url: URL,
        fileManager: FileManager
    ) throws {
        if let data = artifact.data {
            try data.write(to: url, options: .atomic)
        } else if let sourceURL = artifact.sourceURL,
                  fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.copyItem(at: sourceURL, to: url)
        } else {
            throw ClipboardExportError.missingReferencedFile
        }
    }

    private static func artifact(
        baseName: String,
        extension fileExtension: String,
        type: UTType,
        data: Data,
        index: Int? = nil
    ) -> ClipboardExportArtifact {
        artifact(
            baseName: baseName,
            extension: fileExtension,
            typeIdentifier: type.identifier,
            data: data,
            index: index
        )
    }

    private static func artifact(
        baseName: String,
        extension fileExtension: String,
        typeIdentifier: String,
        data: Data,
        index: Int? = nil
    ) -> ClipboardExportArtifact {
        ClipboardExportArtifact(
            relativePath: ClipboardHistoryExportNaming.fileName(
                baseName: baseName,
                extension: fileExtension,
                index: index
            ),
            contentTypeIdentifier: typeIdentifier,
            data: data
        )
    }
}
