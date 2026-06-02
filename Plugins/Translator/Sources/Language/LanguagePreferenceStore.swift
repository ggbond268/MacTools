import Foundation
import MacToolsPluginKit

@MainActor
struct LanguagePreferenceStore {
    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
    }

    func loadPair() -> TranslatorLanguagePair {
        let defaultPair = Self.defaultPair(fromPreferredLanguages: Locale.preferredLanguages)

        guard let firstRawValue = storage.string(forKey: TranslatorConstants.StorageKey.firstPreferredLanguage),
              let secondRawValue = storage.string(forKey: TranslatorConstants.StorageKey.secondPreferredLanguage),
              let first = TranslatorLanguage(rawValue: firstRawValue),
              let second = TranslatorLanguage(rawValue: secondRawValue),
              first != second
        else {
            return defaultPair
        }

        return TranslatorLanguagePair(first: first, second: second)
    }

    func savePair(_ pair: TranslatorLanguagePair) {
        storage.set(pair.first.rawValue, forKey: TranslatorConstants.StorageKey.firstPreferredLanguage)
        storage.set(pair.second.rawValue, forKey: TranslatorConstants.StorageKey.secondPreferredLanguage)
    }

    static func defaultPair(fromPreferredLanguages preferredLanguages: [String]) -> TranslatorLanguagePair {
        var languages: [TranslatorLanguage] = []

        for identifier in preferredLanguages {
            guard let language = TranslatorLanguage.from(localeIdentifier: identifier),
                  !languages.contains(language)
            else {
                continue
            }

            languages.append(language)

            if languages.count == 2 {
                return TranslatorLanguagePair(first: languages[0], second: languages[1])
            }
        }

        return TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
    }
}
