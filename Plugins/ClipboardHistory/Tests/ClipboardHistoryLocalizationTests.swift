import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryLocalizationTests: XCTestCase {
    func testBuiltInAppleExclusionsUseCatalogBackedFallbackNames() {
        XCTAssertEqual(
            ClipboardExcludedApplicationDisplayName.fallbackLocalizationKey(
                for: "com.apple.Passwords"
            ),
            "excludedApplication.passwords"
        )
        XCTAssertEqual(
            ClipboardExcludedApplicationDisplayName.fallbackLocalizationKey(
                for: "com.apple.keychainaccess"
            ),
            "excludedApplication.keychainAccess"
        )
        XCTAssertNil(
            ClipboardExcludedApplicationDisplayName.fallbackLocalizationKey(
                for: "com.1password.1password"
            )
        )

        let passwords = ClipboardHistorySettings.defaults.excludedApplications[0]
        XCTAssertEqual(
            ClipboardExcludedApplicationDisplayName.resolve(
                application: passwords,
                installedLocalizedName: nil,
                localizedFallback: { key in
                    key == "excludedApplication.passwords" ? "パスワード" : nil
                }
            ),
            "パスワード"
        )
    }

    func testRuntimeCatalogCoversEveryReferencedKeyAndManifestLocale() throws {
        let pluginDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try jsonObject(at: pluginDirectory.appendingPathComponent("plugin.json"))
        let localizedMetadata = try XCTUnwrap(manifest["localizedMetadata"] as? [String: Any])
        let expectedLocales = Set(localizedMetadata.keys)

        let catalog = try jsonObject(
            at: pluginDirectory.appendingPathComponent("Resources/Localizable.xcstrings")
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertEqual(Set(strings.keys), try referencedLocalizationKeys(in: pluginDirectory))

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), expectedLocales, key)

            let sourceValue = try localizedValue(
                key: key,
                locale: "zh-Hans",
                localizations: localizations
            )
            let sourcePlaceholders = placeholders(in: sourceValue)
            for locale in expectedLocales {
                let value = try localizedValue(
                    key: key,
                    locale: locale,
                    localizations: localizations
                )
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(placeholders(in: value), sourcePlaceholders, "\(key) [\(locale)]")
            }
        }
    }

    private func referencedLocalizationKeys(in pluginDirectory: URL) throws -> Set<String> {
        let sourcesDirectory = pluginDirectory.appendingPathComponent("Sources", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourcesDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let expression = try NSRegularExpression(
            pattern: #"localization\.(?:string|format)\(\s*\"([^\"]+)\""#
        )
        var keys: Set<String> = []
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        return keys
    }

    private func localizedValue(
        key: String,
        locale: String,
        localizations: [String: Any]
    ) throws -> String {
        let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "\(key) [\(locale)]")
        let stringUnit = try XCTUnwrap(
            localization["stringUnit"] as? [String: Any],
            "\(key) [\(locale)]"
        )
        XCTAssertEqual(stringUnit["state"] as? String, "translated", "\(key) [\(locale)]")
        return try XCTUnwrap(stringUnit["value"] as? String, "\(key) [\(locale)]")
    }

    private func placeholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:d|@)"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange]).replacingOccurrences(
                of: #"\d+\$"#,
                with: "",
                options: .regularExpression
            )
        }.sorted()
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
