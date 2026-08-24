import Foundation

enum ClipboardExportFormat: String, CaseIterable, Equatable, Hashable, Sendable {
    case plainText
    case html
    case pdf
    case markdown
    case original
    case png
    case jpeg
    case tiff
    case webLocation
    case recognizedText
}

struct ClipboardExportOption: Equatable, Hashable, Identifiable, Sendable {
    let format: ClipboardExportFormat
    let isDefault: Bool

    var id: ClipboardExportFormat { format }
}

struct ClipboardExportPlan: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case file
        case folder
    }

    let itemID: UUID
    let format: ClipboardExportFormat
    let destination: Destination
    let suggestedName: String
    let contentTypeIdentifier: String?
    let expectedArtifactCount: Int
    let markdownAttachmentDirectorySuffix: String
    let markdownAttachmentBaseName: String

    init(
        itemID: UUID,
        format: ClipboardExportFormat,
        destination: Destination,
        suggestedName: String,
        contentTypeIdentifier: String?,
        expectedArtifactCount: Int,
        markdownAttachmentDirectorySuffix: String = "assets",
        markdownAttachmentBaseName: String = "Attachment"
    ) {
        self.itemID = itemID
        self.format = format
        self.destination = destination
        self.suggestedName = suggestedName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.expectedArtifactCount = expectedArtifactCount
        self.markdownAttachmentDirectorySuffix = markdownAttachmentDirectorySuffix
        self.markdownAttachmentBaseName = markdownAttachmentBaseName
    }
}

struct ClipboardExportArtifact: Equatable, Sendable {
    let relativePath: String
    let contentTypeIdentifier: String
    let data: Data?
    let sourceURL: URL?

    init(
        relativePath: String,
        contentTypeIdentifier: String,
        data: Data
    ) {
        self.relativePath = relativePath
        self.contentTypeIdentifier = contentTypeIdentifier
        self.data = data
        sourceURL = nil
    }

    init(
        relativePath: String,
        contentTypeIdentifier: String,
        sourceURL: URL
    ) {
        self.relativePath = relativePath
        self.contentTypeIdentifier = contentTypeIdentifier
        data = nil
        self.sourceURL = sourceURL
    }
}

struct ClipboardExportDestinationSnapshot: Equatable, Sendable {
    struct FileIdentity: Equatable, Sendable {
        let systemNumber: UInt64?
        let fileNumber: UInt64?
        let size: UInt64?
        let creationDate: Date?
        let modificationDate: Date?
    }

    let fileIdentity: FileIdentity?

    static let absent = ClipboardExportDestinationSnapshot(fileIdentity: nil)
}

enum ClipboardExportError: Error, Equatable, Sendable {
    case unavailable
    case invalidPayload
    case unsupportedRepresentation
    case missingReferencedFile
    case conversionFailed
    case recognizedTextUnavailable
    case unsafeDestination
}
