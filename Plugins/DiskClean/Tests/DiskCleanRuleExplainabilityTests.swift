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
