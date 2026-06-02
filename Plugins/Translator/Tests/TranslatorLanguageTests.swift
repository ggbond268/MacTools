import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorLanguageTests: XCTestCase {
    func testSupportedLanguageRawValuesAreExact() {
        XCTAssertEqual(
            TranslatorLanguage.allCases.map(\.rawValue),
            ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "pt", "it", "ru"]
        )
    }

    func testLanguageMetadata() {
        XCTAssertEqual(TranslatorLanguage.simplifiedChinese.displayName, "简体中文")
        XCTAssertEqual(TranslatorLanguage.english.promptName, "English")
        XCTAssertEqual(TranslatorLanguage.japanese.flag, "🇯🇵")
    }

    func testLanguageFromLocaleIdentifierMapsChineseVariants() {
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "zh-Hant"), .traditionalChinese)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "zh-TW"), .traditionalChinese)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "zh-HK"), .traditionalChinese)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "zh-MO"), .traditionalChinese)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "zh-CN"), .simplifiedChinese)
    }

    func testLanguageFromLocaleIdentifierMapsSupportedPrefixes() {
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "en-US"), .english)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "ja-JP"), .japanese)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "ko-KR"), .korean)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "fr-FR"), .french)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "de-DE"), .german)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "es-ES"), .spanish)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "pt-BR"), .portuguese)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "it-IT"), .italian)
        XCTAssertEqual(TranslatorLanguage.from(localeIdentifier: "ru-RU"), .russian)
    }

    func testDefaultPairFallsBackToChineseAndEnglishForUnknownLocales() {
        XCTAssertEqual(
            LanguagePreferenceStore.defaultPair(fromPreferredLanguages: ["ar-SA", "th-TH"]),
            TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
        )
    }

    func testDefaultPairUsesUniquePreferredLanguagesWhenTwoSupportedLocalesExist() {
        XCTAssertEqual(
            LanguagePreferenceStore.defaultPair(fromPreferredLanguages: ["ja-JP", "en-US", "zh-CN"]),
            TranslatorLanguagePair(first: .japanese, second: .english)
        )
    }

    func testDefaultPairFallsBackWhenOnlyOneSupportedLocaleExists() {
        XCTAssertEqual(
            LanguagePreferenceStore.defaultPair(fromPreferredLanguages: ["fr-FR", "fr-CA"]),
            TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
        )
    }

    func testPreferenceStoreSavesAndLoadsPair() {
        let storage = TranslatorInMemoryPluginStorage()
        let store = LanguagePreferenceStore(storage: storage)
        let pair = TranslatorLanguagePair(first: .japanese, second: .english)

        store.savePair(pair)

        XCTAssertEqual(store.loadPair(), pair)
        XCTAssertEqual(storage.string(forKey: "translator.language.first"), "ja")
        XCTAssertEqual(storage.string(forKey: "translator.language.second"), "en")
    }

    func testPreferenceStoreIgnoresIdenticalStoredPair() {
        let storage = TranslatorInMemoryPluginStorage()
        storage.set("en", forKey: "translator.language.first")
        storage.set("en", forKey: "translator.language.second")
        let store = LanguagePreferenceStore(storage: storage)

        XCTAssertEqual(
            store.loadPair(),
            LanguagePreferenceStore.defaultPair(fromPreferredLanguages: Locale.preferredLanguages)
        )
    }

    func testLanguageDetectorDetectsJapaneseKoreanAndEnglish() {
        let detector = LanguageDetector()

        XCTAssertEqual(detector.detect("これは日本語の文章です。"), .japanese)
        XCTAssertEqual(detector.detect("안녕하세요 번역 테스트입니다."), .korean)
        XCTAssertEqual(detector.detect("This is an English sentence."), .english)
    }

    func testLanguageDetectorReturnsNilForEmptyOrUnsupportedText() {
        let detector = LanguageDetector()

        XCTAssertNil(detector.detect(" \n\t "))
        XCTAssertNil(detector.detect("12345 !!!"))
    }

    func testLanguageDetectorReturnsNilForAmbiguousShortHanAndLatinText() {
        let detector = LanguageDetector()

        XCTAssertNil(detector.detect("漢字"))
        XCTAssertNil(detector.detect("qzx"))
    }
}
