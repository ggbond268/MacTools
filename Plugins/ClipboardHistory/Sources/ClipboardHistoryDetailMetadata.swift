import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardFileReferencePresentation {
    static let maximumVisibleFileCount = 100

    static func visibleURLs(from urls: [URL]) -> ArraySlice<URL> {
        urls.prefix(maximumVisibleFileCount)
    }

    static func remainingCount(for urls: [URL]) -> Int {
        max(0, urls.count - maximumVisibleFileCount)
    }
}

actor ClipboardFileAvailabilityCache {
    static let shared = ClipboardFileAvailabilityCache()

    private static let maximumEntryCount = 512
    private static let freshnessInterval: TimeInterval = 2
    private struct Entry {
        let isAvailable: Bool
        let checkedAt: TimeInterval
    }
    private var availabilityByURL: [URL: Entry] = [:]
    private var insertionOrder: [URL] = []

    func isAvailable(_ url: URL) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = availabilityByURL[url],
           now - cached.checkedAt < Self.freshnessInterval {
            return cached.isAvailable
        }
        let isAvailable = FileManager.default.fileExists(atPath: url.path)
        availabilityByURL[url] = Entry(isAvailable: isAvailable, checkedAt: now)
        if !insertionOrder.contains(url) {
            insertionOrder.append(url)
        }
        if insertionOrder.count > Self.maximumEntryCount {
            let expiredURL = insertionOrder.removeFirst()
            availabilityByURL.removeValue(forKey: expiredURL)
        }
        return isAvailable
    }
}

enum ClipboardHistoryDetailMetadataValue: Equatable, Sendable {
    case format(String)
    case characterCount(Int)
    case lineCount(Int)
    case dimensions(width: Int, height: Int)
    case pageCount(Int)
    case fileCount(Int)
    case byteCount(Int64)
    case durationSeconds(Double)
    case host(String)
}

struct ClipboardHistoryDetailMetadata: Equatable, Sendable {
    let values: [ClipboardHistoryDetailMetadataValue]
}

enum ClipboardHistoryDetailMetadataLoader {
    static func load(for item: ClipboardHistoryItem) async -> ClipboardHistoryDetailMetadata {
        switch item.kind {
        case .plainText, .richText:
            return textMetadata(item)
        case .image:
            return await loadPayload(item).map(embeddedImageMetadata) ?? .init(values: [])
        case .pdf:
            return await loadPayload(item).map(embeddedPDFMetadata) ?? .init(values: [])
        case .files:
            return await fileMetadata(item.fileURLs)
        case .link:
            return linkMetadata(item)
        case .media:
            return await loadPayload(item).map(embeddedMediaMetadata) ?? .init(values: [])
        case .color:
            return ClipboardHistoryDetailMetadata(values: [])
        }
    }

    private static func loadPayload(_ item: ClipboardHistoryItem) async -> ClipboardHistoryPayload? {
        await Task.detached(priority: .utility) {
            defer { item.discardCachedPayloadIfReloadable() }
            return try? item.loadPayload()
        }.value
    }

    private static func textMetadata(_ item: ClipboardHistoryItem) -> ClipboardHistoryDetailMetadata {
        var values: [ClipboardHistoryDetailMetadataValue] = [
            .characterCount(item.textCharacterCount),
        ]
        if item.textLineCount > 1 {
            values.append(.lineCount(item.textLineCount))
        }
        return ClipboardHistoryDetailMetadata(values: values)
    }

    private static func embeddedImageMetadata(
        _ payload: ClipboardHistoryPayload
    ) -> ClipboardHistoryDetailMetadata {
            guard let representation = payload.representations.first(where: {
                ClipboardRepresentationType.isImage($0.typeIdentifier)
            }) else {
                return ClipboardHistoryDetailMetadata(values: [])
            }
            var values: [ClipboardHistoryDetailMetadataValue] = []
            if let format = formatName(typeIdentifier: representation.typeIdentifier) {
                values.append(.format(format))
            }
            if let dimensions = imageDimensions(data: representation.data) {
                values.append(.dimensions(width: dimensions.width, height: dimensions.height))
            }
            values.append(.byteCount(Int64(payload.byteCount)))
            return ClipboardHistoryDetailMetadata(values: values)
    }

    private static func embeddedPDFMetadata(
        _ payload: ClipboardHistoryPayload
    ) -> ClipboardHistoryDetailMetadata {
            var values: [ClipboardHistoryDetailMetadataValue] = []
            if let representation = payload.representations.first(where: {
                $0.typeIdentifier == ClipboardRepresentationType.pdf
            }),
               let provider = CGDataProvider(data: representation.data as CFData),
               let document = CGPDFDocument(provider) {
                values.append(.pageCount(document.numberOfPages))
            }
            values.append(.byteCount(Int64(payload.byteCount)))
            return ClipboardHistoryDetailMetadata(values: values)
    }

    private static func fileMetadata(_ urls: [URL]) async -> ClipboardHistoryDetailMetadata {
        guard !urls.isEmpty else {
            return ClipboardHistoryDetailMetadata(values: [])
        }

        let basicValues = await Task.detached(priority: .utility) {
            var values: [ClipboardHistoryDetailMetadataValue] = []
            if urls.count > 1 {
                values.append(.fileCount(urls.count))
            }
            let byteCounts = urls.compactMap { url -> Int64? in
                guard let resourceValues = try? url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                ]), resourceValues.isRegularFile == true,
                      let fileSize = resourceValues.fileSize else {
                    return nil
                }
                return Int64(fileSize)
            }
            if !byteCounts.isEmpty {
                values.append(.byteCount(byteCounts.reduce(0, +)))
            }

            guard urls.count == 1, let url = urls.first else { return values }
            let fileKind = ClipboardFileContentKind(url: url)
            let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fileExtension.isEmpty, fileKind != .pdf {
                values.insert(.format(fileExtension.uppercased()), at: 0)
            }
            switch fileKind {
            case .pdf:
                if let document = CGPDFDocument(url as CFURL) {
                    values.insert(.pageCount(document.numberOfPages), at: min(1, values.count))
                }
            case .image:
                if let dimensions = imageDimensions(url: url) {
                    values.insert(
                        .dimensions(width: dimensions.width, height: dimensions.height),
                        at: min(1, values.count)
                    )
                }
            case .audio, .video, .none:
                break
            }
            return values
        }.value

        guard urls.count == 1,
              let url = urls.first,
              let kind = ClipboardFileContentKind(url: url),
              kind == .audio || kind == .video else {
            return ClipboardHistoryDetailMetadata(values: basicValues)
        }

        var values = basicValues
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                values.insert(.durationSeconds(seconds), at: min(1, values.count))
            }
        }
        if kind == .video,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformedSize = naturalSize.applying(transform)
            let width = Int(abs(transformedSize.width).rounded())
            let height = Int(abs(transformedSize.height).rounded())
            if width > 0, height > 0 {
                values.insert(.dimensions(width: width, height: height), at: min(1, values.count))
            }
        }
        return ClipboardHistoryDetailMetadata(values: values)
    }

    private static func linkMetadata(_ item: ClipboardHistoryItem) -> ClipboardHistoryDetailMetadata {
        let candidates = item.linkURLs.map(\.absoluteString) + [item.text]
        let host = candidates.lazy.compactMap { URL(string: $0)?.host() }.first
        return ClipboardHistoryDetailMetadata(values: host.map { [.host($0)] } ?? [])
    }

    private static func embeddedMediaMetadata(
        _ payload: ClipboardHistoryPayload
    ) -> ClipboardHistoryDetailMetadata {
        guard let representation = payload.representations.first(where: {
            ClipboardRepresentationType.isMedia($0.typeIdentifier)
                || $0.typeIdentifier == ClipboardRepresentationType.sound
        }) else {
            return ClipboardHistoryDetailMetadata(values: [])
        }
        var values: [ClipboardHistoryDetailMetadataValue] = []
        if let format = formatName(typeIdentifier: representation.typeIdentifier) {
            values.append(.format(format))
        }
        values.append(.byteCount(Int64(payload.byteCount)))
        return ClipboardHistoryDetailMetadata(values: values)
    }

    private static func formatName(typeIdentifier: String) -> String? {
        UTType(typeIdentifier)?.preferredFilenameExtension?.uppercased()
    }

    private static func imageDimensions(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return imageDimensions(source: source)
    }

    private static func imageDimensions(url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return imageDimensions(source: source)
    }

    private static func imageDimensions(source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }
}
