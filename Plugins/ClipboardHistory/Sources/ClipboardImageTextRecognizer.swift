import Foundation
import ImageIO
import Vision

protocol ClipboardImageTextRecognizing: Sendable {
    func recognizeText(in payload: ClipboardHistoryPayload) async -> String?
}

struct VisionClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    private static let maximumIndexedCharacterCount = 20_000
    static let maximumSourcePixelCount = 64_000_000
    static let maximumSourceDimension = 32_768
    static let maximumOCRDimension = 4_096

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        guard let imageData = payload.representations.first(where: {
            ClipboardRepresentationType.isImage($0.typeIdentifier)
        })?.data else {
            return nil
        }

        return await Self.recognizeText(
            in: imageData,
            maximumCharacterCount: Self.maximumIndexedCharacterCount
        )
    }

    static func recognizeText(
        in imageData: Data,
        maximumCharacterCount: Int?
    ) async -> String? {

        let worker = Task.detached(priority: .utility) { () -> String? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(
                      imageData as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  Self.allowsSourceDimensions(
                      width: width.intValue,
                      height: height.intValue
                  ),
                  !Task.isCancelled,
                  let image = CGImageSourceCreateThumbnailAtIndex(
                      source,
                      0,
                      [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceShouldCacheImmediately: true,
                          kCGImageSourceThumbnailMaxPixelSize: Self.maximumOCRDimension,
                      ] as CFDictionary
                  ) else {
                return nil
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            do {
                guard !Task.isCancelled else { return nil }
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            guard !Task.isCancelled else { return nil }

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let maximumCharacterCount {
                return String(text.prefix(maximumCharacterCount))
            }
            return text
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func allowsSourceDimensions(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension,
              width <= maximumSourcePixelCount / height else {
            return false
        }
        return width * height <= maximumSourcePixelCount
    }
}

struct VisionClipboardImageTextExportRecognizer: ClipboardImageTextRecognizing {
    typealias ImageRecognizer = @Sendable (Data) async -> String?

    private let imageRecognizer: ImageRecognizer

    init() {
        imageRecognizer = { imageData in
            await VisionClipboardImageTextRecognizer.recognizeText(
                in: imageData,
                maximumCharacterCount: nil
            )
        }
    }

    init(imageRecognizer: @escaping ImageRecognizer) {
        self.imageRecognizer = imageRecognizer
    }

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        let images = payload.pasteboardItems.compactMap { item in
            item.representations.first(where: {
                ClipboardRepresentationType.isImage($0.typeIdentifier)
            })?.data
        }
        guard !images.isEmpty else { return nil }

        var recognized: [String] = []
        recognized.reserveCapacity(images.count)
        for image in images {
            guard !Task.isCancelled else { return nil }
            guard let result = await imageRecognizer(image) else { continue }
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            recognized.append(text)
        }
        guard !recognized.isEmpty else { return nil }
        return recognized.joined(separator: "\n\n")
    }
}
