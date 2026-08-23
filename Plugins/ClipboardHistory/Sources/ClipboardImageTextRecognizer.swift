import Foundation
import ImageIO
import Vision

protocol ClipboardImageTextRecognizing: Sendable {
    func recognizeText(in payload: ClipboardHistoryPayload) async -> String?
}

struct VisionClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    private static let maximumIndexedCharacterCount = 20_000

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        guard let imageData = payload.representations.first(where: {
            ClipboardRepresentationType.isImage($0.typeIdentifier)
        })?.data else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return String(text.prefix(Self.maximumIndexedCharacterCount))
        }.value
    }
}
