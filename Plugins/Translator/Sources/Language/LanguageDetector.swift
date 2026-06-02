import Foundation
import NaturalLanguage

protocol LanguageDetecting: Sendable {
    func detect(_ text: String) -> TranslatorLanguage?
}

struct LanguageDetector: LanguageDetecting {
    func detect(_ text: String) -> TranslatorLanguage? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            return nil
        }

        if Self.isShortHanOnlyText(trimmedText) {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmedText)

        if let language = recognizer.dominantLanguage,
           let translatorLanguage = Self.map(language) {
            return translatorLanguage
        }

        return Self.detectByScript(trimmedText)
    }

    private static func map(_ language: NLLanguage) -> TranslatorLanguage? {
        switch language {
        case .simplifiedChinese:
            return .simplifiedChinese
        case .traditionalChinese:
            return .traditionalChinese
        case .english:
            return .english
        case .japanese:
            return .japanese
        case .korean:
            return .korean
        case .french:
            return .french
        case .german:
            return .german
        case .spanish:
            return .spanish
        case .portuguese:
            return .portuguese
        case .italian:
            return .italian
        case .russian:
            return .russian
        default:
            return nil
        }
    }

    private static func detectByScript(_ text: String) -> TranslatorLanguage? {
        for scalar in text.unicodeScalars {
            if Self.isJapaneseScript(scalar) {
                return .japanese
            }

            if Self.isKoreanScript(scalar) {
                return .korean
            }
        }

        return nil
    }

    private static func isJapaneseScript(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x309F).contains(Int(scalar.value)) ||
            (0x30A0...0x30FF).contains(Int(scalar.value))
    }

    private static func isKoreanScript(_ scalar: UnicodeScalar) -> Bool {
        (0xAC00...0xD7AF).contains(Int(scalar.value)) ||
            (0x1100...0x11FF).contains(Int(scalar.value)) ||
            (0x3130...0x318F).contains(Int(scalar.value))
    }

    private static func isShortHanOnlyText(_ text: String) -> Bool {
        var hanScalarCount = 0

        for scalar in text.unicodeScalars {
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                continue
            }

            guard Self.isHanScript(scalar) else {
                return false
            }

            hanScalarCount += 1
            if hanScalarCount > 3 {
                return false
            }
        }

        return hanScalarCount > 0
    }

    private static func isHanScript(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }
}
