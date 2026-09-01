import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacSettingsPlugin

@MainActor
final class MacSettingsLocalizationTests: XCTestCase {
    private var originalPreference: String?
    private var fixtureURL: URL!
    private var fixtureBundle: Bundle!

    private var pluginRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        originalPreference = UserDefaults.standard.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey)
        PluginRuntimeLocalization.source.setPreference("en")
        fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.mactools.localization.\(UUID().uuidString)", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: fixtureURL.appendingPathComponent("Info.plist"))
        let strings = try catalogStrings()
        for language in ["en", "zh-Hans"] {
            let directory = fixtureURL.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = strings.mapValues { entry in
                let localizations = entry["localizations"] as! [String: [String: Any]]
                let unit = localizations[language]!["stringUnit"] as! [String: String]
                return unit["value"]!
            }
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
                .write(to: directory.appendingPathComponent("MacSettings.strings"))
        }
        fixtureBundle = try XCTUnwrap(Bundle(url: fixtureURL))
    }

    override func tearDownWithError() throws {
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        if let fixtureURL { try FileManager.default.removeItem(at: fixtureURL) }
    }

    func testExistingCatalogAndChoicesFollowRuntimeLanguageWithoutRecreatingAdapters() throws {
        try MacSettingsStrings.$bundleOverride.withValue(fixtureBundle) {
            let catalog = try MacSettingsCatalogFactory.make { nil }
            let pointer = try XCTUnwrap(catalog["accessibility.pointer-size"])
            let appearance = try XCTUnwrap(catalog["appearance.dark-mode"])
            XCTAssertEqual(pointer.definition.title, "Pointer Size")
            XCTAssertEqual(appearance.definition.displayDescription(for: .choice(id: "auto")), "Auto")

            PluginRuntimeLocalization.source.setPreference("zh-Hans")
            XCTAssertEqual(pointer.definition.title, "指针大小")
            XCTAssertEqual(pointer.definition.category.title, "辅助功能")
            XCTAssertEqual(appearance.definition.displayDescription(for: .choice(id: "auto")), "自动")
            XCTAssertEqual(catalog.search("pointer size").first?.id, pointer.id)

            PluginRuntimeLocalization.source.setPreference("en")
            XCTAssertEqual(pointer.definition.title, "Pointer Size")
            XCTAssertEqual(catalog.search("大光标").first?.id, pointer.id)
            XCTAssertEqual(catalog.search("指针大小").first?.id, pointer.id)
            XCTAssertEqual(appearance.definition.displayDescription(for: .choice(id: "auto")), "Auto")
        }
    }

    func testUnsupportedTranslationFallsBackToEnglishAndFormatsArguments() {
        MacSettingsStrings.$bundleOverride.withValue(fixtureBundle) {
            PluginRuntimeLocalization.source.setPreference("fr")
            XCTAssertEqual(MacSettingsStrings.text("Pin to Top"), "Pin to Top")
            XCTAssertEqual(MacSettingsStrings.format("Processed %@ of %@", "2", "5"), "Processed 2 of 5")
            PluginRuntimeLocalization.source.setPreference("zh-Hans")
            XCTAssertEqual(MacSettingsStrings.format("Processed %@ of %@", "2", "5"), "已处理 2 / 5 项")
            XCTAssertEqual(SystemSettingAdapterError.unreadable.localizedDescription, "无法读取当前值。")
            PluginRuntimeLocalization.source.setPreference("en")
            XCTAssertEqual(SystemSettingAdapterError.unreadable.localizedDescription, "Could not read the current value.")
        }
    }

    func testProfileNamesPathsIDsAndDesiredValuesAreNeverTranslated() throws {
        try MacSettingsStrings.$bundleOverride.withValue(fixtureBundle) {
            let catalog = try MacSettingsCatalogFactory.make { nil }
            let profile = SystemSettingsProfile(name: "我的配置 – Personal", profileDescription: "Keep my words", entries: [
                .init(settingID: "appearance.dark-mode", desiredValue: .choice(id: "auto"), category: .appearance),
            ])
            let encoded = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
            PluginRuntimeLocalization.source.setPreference("zh-Hans")
            let decoded = try SystemSettingsProfileCodec.decode(encoded, catalog: catalog).0
            XCTAssertEqual(decoded.name, profile.name)
            XCTAssertEqual(decoded.entries, profile.entries)
            let path = URL(fileURLWithPath: "/private/tmp/我的配置/Auto")
            XCTAssertEqual(SystemSettingValue.url(path).conciseDescription, path.path)
        }
    }

    func testEveryResourceHasEnglishAndChineseWithMatchingPlaceholders() throws {
        let strings = try catalogStrings()
        XCTAssertGreaterThanOrEqual(strings.count, 400)
        for (key, entry) in strings {
            let locales = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
            for language in ["en", "zh-Hans"] {
                let unit = try XCTUnwrap(locales[language]?["stringUnit"] as? [String: String])
                let value = try XCTUnwrap(unit["value"])
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, key)
                if language == "en" { XCTAssertEqual(value, key) }
            }
        }
    }

    func testChineseSourceLiteralsAreOnlySearchAliases() throws {
        let directory = pluginRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let chinese = try NSRegularExpression(pattern: "[\\p{Han}]")
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.components(separatedBy: .newlines) {
                guard chinese.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                XCTAssertTrue(line.contains("searchTerms:") || line.contains("keywords:"), "Unlocalized text in \(file.lastPathComponent): \(line)")
            }
        }
    }

    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: pluginRoot.appendingPathComponent("Resources/MacSettings.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }
}
