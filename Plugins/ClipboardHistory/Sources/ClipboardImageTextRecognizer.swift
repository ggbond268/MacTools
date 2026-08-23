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
            return String(text.prefix(Self.maximumIndexedCharacterCount))
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
