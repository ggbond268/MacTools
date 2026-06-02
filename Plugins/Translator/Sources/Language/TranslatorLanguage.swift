import Foundation

enum TranslatorLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        case .english:
            return "英语"
        case .japanese:
            return "日语"
        case .korean:
            return "韩语"
        case .french:
            return "法语"
        case .german:
            return "德语"
        case .spanish:
            return "西班牙语"
        case .portuguese:
            return "葡萄牙语"
        case .italian:
            return "意大利语"
        case .russian:
            return "俄语"
        }
    }

    var promptName: String {
        switch self {
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .traditionalChinese:
            return "Traditional Chinese"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .spanish:
            return "Spanish"
        case .portuguese:
            return "Portuguese"
        case .italian:
            return "Italian"
        case .russian:
            return "Russian"
        }
    }

    var flag: String {
        switch self {
        case .simplifiedChinese:
            return "🇨🇳"
        case .traditionalChinese:
            return "🇨🇳"
        case .english:
            return "🇬🇧"
        case .japanese:
            return "🇯🇵"
        case .korean:
            return "🇰🇷"
        case .french:
            return "🇫🇷"
        case .german:
            return "🇩🇪"
        case .spanish:
            return "🇪🇸"
        case .portuguese:
            return "🇵🇹"
        case .italian:
            return "🇮🇹"
        case .russian:
            return "🇷🇺"
        }
    }

    static func from(localeIdentifier: String) -> TranslatorLanguage? {
        let normalized = localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == "zh-hant" ||
            normalized.hasPrefix("zh-hant-") ||
            normalized == "zh-tw" ||
            normalized.hasPrefix("zh-tw-") ||
            normalized == "zh-hk" ||
            normalized.hasPrefix("zh-hk-") ||
            normalized == "zh-mo" ||
            normalized.hasPrefix("zh-mo-") {
            return .traditionalChinese
        }

        if normalized == "zh" || normalized.hasPrefix("zh-") {
            return .simplifiedChinese
        }

        return allCases.first { language in
            normalized == language.rawValue.lowercased() ||
                normalized.hasPrefix("\(language.rawValue.lowercased())-")
        }
    }
}

struct TranslatorLanguagePair: Equatable, Codable, Sendable {
    var first: TranslatorLanguage
    var second: TranslatorLanguage
}
