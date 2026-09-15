import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanRuleExplainabilityTests: XCTestCase {
    func testConfidenceCodableAndValues() throws {
        for conf in [DiskCleanConfidence.high, .medium, .low] {
            let encoded = try JSONEncoder().encode(conf)
            let decoded = try JSONDecoder().decode(DiskCleanConfidence.self, from: encoded)
            XCTAssertEqual(decoded, conf)
        }
        XCTAssertEqual(DiskCleanConfidence.high.rawValue, "high")
        XCTAssertEqual(DiskCleanConfidence.medium.rawValue, "medium")
        XCTAssertEqual(DiskCleanConfidence.low.rawValue, "low")
    }

    func testSafetyTierCodableAndTitles() throws {
        let fakeLocalization = PluginLocalization(bundle: .main)

        for tier in [DiskCleanSafetyTier.safe, .moderate, .sensitive] {
            let encoded = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(DiskCleanSafetyTier.self, from: encoded)
            XCTAssertEqual(decoded, tier)
            XCTAssertFalse(tier.title(localization: fakeLocalization).isEmpty)
        }
        XCTAssertEqual(DiskCleanSafetyTier.safe.rawValue, "safe")
        XCTAssertEqual(DiskCleanSafetyTier.moderate.rawValue, "moderate")
        XCTAssertEqual(DiskCleanSafetyTier.sensitive.rawValue, "sensitive")
    }

    func testDataClassCodable() throws {
        let classes: [DiskCleanDataClass] = [
            .cache, .log, .diagnostic, .downloadedResource,
            .generatedDependency, .buildArtifact, .installer, .temporaryState
        ]
        for dataClass in classes {
            let encoded = try JSONEncoder().encode(dataClass)
            let decoded = try JSONDecoder().decode(DiskCleanDataClass.self, from: encoded)
            XCTAssertEqual(decoded, dataClass)
        }
    }

    func testRuleExplanationRoundTrip() throws {
        let explanation = DiskCleanRuleExplanation(
            whyMatched: "Matches Xcode DerivedData build intermediate files.",
            consequence: "Xcode will rebuild indexing and module caches on next build.",
            safetyTier: .safe,
            requiresFullDiskAccess: false,
            confidence: .high,
            title: "DerivedData",
            summary: "Xcode caches",
            dataClass: .buildArtifact,
            owner: "Xcode",
            discoveryMethod: .knownPathPattern,
            defaultSelectionReason: "Safe to clean",
            regeneration: "Automatically regenerated during next compilation.",
            provenance: .macOSDocumentedLocation
        )

        let encoded = try JSONEncoder().encode(explanation)
        let decoded = try JSONDecoder().decode(DiskCleanRuleExplanation.self, from: encoded)

        XCTAssertEqual(decoded.whyMatched, explanation.whyMatched)
        XCTAssertEqual(decoded.consequence, explanation.consequence)
        XCTAssertEqual(decoded.regeneration, explanation.regeneration)
        XCTAssertEqual(decoded.safetyTier, .safe)
        XCTAssertEqual(decoded.dataClass, .buildArtifact)
        XCTAssertEqual(decoded.confidence, .high)
        XCTAssertEqual(decoded.requiresFullDiskAccess, false)
        XCTAssertEqual(decoded.provenance, .macOSDocumentedLocation)
    }

    func testResolvedExplanationUsesExplicitWhenAvailable() {
        let explanation = DiskCleanRuleExplanation(
            whyMatched: "Explicit reason",
            consequence: "Explicit consequence",
            safetyTier: .safe,
            confidence: .high
        )
        let target = DiskCleanRuleTarget(
            id: "test.target",
            legacyRuleID: "cache.test",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: ["~/Library/Caches/Test/*"]),
            reservedRootPaths: ["~/Library/Caches/Test"],
            explanation: explanation
        )

        XCTAssertEqual(target.resolvedExplanation.whyMatched, "Explicit reason")
        XCTAssertEqual(target.resolvedExplanation.consequence, "Explicit consequence")
        XCTAssertEqual(target.resolvedExplanation.safetyTier, .safe)
        XCTAssertEqual(target.resolvedExplanation.confidence, .high)
    }

    func testResolvedExplanationGeneratesFallbackWhenNil() {
        let lowTarget = DiskCleanRuleTarget(
            id: "test.low",
            legacyRuleID: "cache.test",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: ["~/Library/Caches/Test/*"]),
            reservedRootPaths: ["~/Library/Caches/Test"]
        )
        XCTAssertEqual(lowTarget.resolvedExplanation.safetyTier, .safe)
        XCTAssertFalse(lowTarget.resolvedExplanation.whyMatched.isEmpty)
        XCTAssertFalse(lowTarget.resolvedExplanation.consequence.isEmpty)

        let mediumTarget = DiskCleanRuleTarget(
            id: "test.medium",
            legacyRuleID: "developer.test",
            category: .developer,
            risk: .medium,
            kind: .path(globs: ["~/Test/*"]),
            reservedRootPaths: ["~/Test"]
        )
        XCTAssertEqual(mediumTarget.resolvedExplanation.safetyTier, .moderate)

        let highTarget = DiskCleanRuleTarget(
            id: "test.high",
            legacyRuleID: "system.test",
            category: .logs,
            risk: .high,
            kind: .path(globs: ["/var/log/test/*"]),
            reservedRootPaths: ["/var/log/test"]
        )
        XCTAssertEqual(highTarget.resolvedExplanation.safetyTier, .sensitive)
    }

    func testCandidateCarriesExplanation() {
        let explanation = DiskCleanRuleExplanation(
            whyMatched: "CocoaPods cache files",
            consequence: "CocoaPods will redownload pods when needed",
            safetyTier: .safe,
            confidence: .high
        )
        let candidate = DiskCleanCandidate(
            id: "cocoapods-1",
            targetID: "developer.mobile-caches",
            legacyRuleID: "developer.mobile-caches",
            category: .developer,
            path: "/Users/tester/Library/Caches/CocoaPods/Pods",
            risk: .low,
            safety: .allowed,
            explanation: explanation
        )

        XCTAssertEqual(candidate.explanation?.whyMatched, "CocoaPods cache files")
        XCTAssertEqual(candidate.explanation?.consequence, "CocoaPods will redownload pods when needed")
        XCTAssertEqual(candidate.explanation?.safetyTier, .safe)
        XCTAssertEqual(candidate.explanation?.confidence, .high)
    }
}


extension DiskCleanRuleExplainabilityTests {
    @MainActor
    func testExistingExplanationsAndHistoryFollowLanguageChangesAtDisplayTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for language in ["en", "zh-Hans"] {
            let lproj = directory.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            var values: [String: String] = [:]
            for (key, entry) in strings {
                let locales = entry["localizations"] as? [String: [String: Any]]
                let unit = locales?[language]?["stringUnit"] as? [String: Any]
                values[key] = unit?["value"] as? String
            }
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
        let info = ["CFBundleIdentifier": "test.disk-clean.localization", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let localization = PluginLocalization(bundle: try XCTUnwrap(Bundle(url: directory)))
        let original = UserDefaults.standard.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey)
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let explicit = try XCTUnwrap(DiskCleanRuleCatalogV2.current.target(id: "cache.user-essentials.caches")).resolvedExplanation
        let fallback = DiskCleanRuleTarget(id: "test.rule", legacyRuleID: "test", category: .appCaches,
            risk: .low, kind: .path(globs: []), reservedRootPaths: []).resolvedExplanation
        let run = DiskCleanRunHistoryEntry(id: "run", timestamp: Date(), isTrash: false,
            status: "cancelled", categoriesCleaned: ["appCaches"], itemsRemoved: 0, bytesRemoved: 0)

        let explanations = ["cache.user-essentials.caches", "cache.user-essentials.logs", "developer.mobile-caches"].compactMap {
            DiskCleanRuleCatalogV2.current.target(id: $0)?.resolvedExplanation
        }
        let decoded = try JSONDecoder().decode(DiskCleanRuleExplanation.self, from: JSONEncoder().encode(explicit))
        XCTAssertEqual(decoded.localizationKeyPrefix, explicit.localizationKeyPrefix)

        PluginRuntimeLocalization.source.setPreference("en")
        XCTAssertEqual(explicit.localizedRegeneration(localization), "Apps rebuild necessary caches when next opened.")
        XCTAssertEqual(run.statusTitle(localization: localization), "Cancelled")
        XCTAssertEqual(fallback.localizedWhyMatched(localization), "Matches cleanup rule test.rule.")
        let englishExplanations = explanations.map {
            [$0.localizedWhyMatched(localization), $0.localizedConsequence(localization), $0.localizedRegeneration(localization) ?? ""]
        }
        let englishConsequence = fallback.localizedConsequence(localization)
        let englishCategories = run.categoryTitles(localization: localization)
        XCTAssertNotEqual(englishCategories, run.categoriesCleaned)

        PluginRuntimeLocalization.source.setPreference("zh-Hans")
        XCTAssertEqual(explicit.localizedRegeneration(localization), "应用下次打开时会重新生成所需缓存。")
        XCTAssertEqual(run.statusTitle(localization: localization), "已取消")
        XCTAssertEqual(fallback.localizedWhyMatched(localization), "匹配清理规则 test.rule。")
        for (explanation, english) in zip(explanations, englishExplanations) {
            let translated = [explanation.localizedWhyMatched(localization), explanation.localizedConsequence(localization), explanation.localizedRegeneration(localization) ?? ""]
            for (value, original) in zip(translated, english) {
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, original)
            }
        }
        XCTAssertNotEqual(fallback.localizedConsequence(localization), englishConsequence)
        XCTAssertNotEqual(run.categoryTitles(localization: localization), englishCategories)
    }
}
