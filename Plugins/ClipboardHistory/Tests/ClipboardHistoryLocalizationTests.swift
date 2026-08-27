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

    func testEnglishCatalogDescribesHistoryAndSavedLibraryWithoutPinnedTerminology() throws {
        let pluginDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try jsonObject(
            at: pluginDirectory.appendingPathComponent("Resources/Localizable.xcstrings")
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let expectedValues = [
            "settings.snippets.clear": "Delete Snippets",
            "clear.all.message": "Clears History. Saved clips and snippets are kept. This cannot be undone.",
            "settings.saved.clear.message": "Removes Saved status from clips in History and permanently deletes Saved-only clips. History and snippets are kept. This cannot be undone.",
            "settings.snippets.clear.message": "Permanently deletes all snippets and their keywords. History and Saved clips are kept. This cannot be undone.",
            "metadata.title": "Clipboard",
            "metadata.description": "Search encrypted History and manage reusable snippets and Saved items",
            "panel.status.count": "%d history items · %d saved",
            "settings.retention.maximum.description": "When the item limit is reached, the oldest History items are removed automatically. Saved items are unaffected.",
            "settings.retention.expiration.description": "Never disables age-based expiration; capacity limits may still remove the oldest History items. Saved items are unaffected.",
            "settings.retention.storageLimit.description": "When the storage limit is reached, the oldest History items are removed. Saved items are unaffected; actual storage remains subject to available disk space.",
        ]

        for (key, expectedValue) in expectedValues {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let value = try localizedValue(key: key, locale: "en", localizations: localizations)
            XCTAssertEqual(value, expectedValue, key)
            XCTAssertFalse(value.lowercased().contains("pin"), key)
        }

        for key in [
            "saved.editDetails",
            "saved.error.invalidDateFormat",
            "saved.error.multipleCursorMarkers",
            "saved.error.unknownMacro",
        ] {
            XCTAssertNotNil(strings[key], key)
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
