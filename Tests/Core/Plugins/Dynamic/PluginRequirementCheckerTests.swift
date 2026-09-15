import XCTest
@testable import MacTools

@MainActor
final class PluginRequirementCheckerTests: XCTestCase {
    func testOldOSIsRejectedBeforeLookingForApplications() {
        var lookups = 0
        let checker = PluginRequirementChecker(macOSVersion: { "26.6" }, applicationInstalled: { _ in lookups += 1; return true })
        XCTAssertEqual(checker.failure(for: PluginRequirementTestData.requirements()), .macOS("27.0"))
        XCTAssertEqual(lookups, 0)
    }

    func testApplicationPresenceIsCheckedFreshWithoutPermissionGate() {
        var found = false
        let checker = PluginRequirementChecker(macOSVersion: { "27.0" }, applicationInstalled: { _ in found })
        let requirements = PluginRequirementTestData.requirements()
        XCTAssertEqual(checker.failure(for: requirements), .application("Siri AI"))
        found = true
        XCTAssertNil(checker.failure(for: requirements), "Accessibility is setup guidance, not an install requirement")
        found = false
        XCTAssertEqual(checker.failure(for: requirements), .application("Siri AI"))
    }

    func testXcodeCleanupRemainsAvailableAfterXcodeIsUninstalled() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        struct SourceManifest: Decodable {
            let requirements: PluginProductMetadata.Requirements
        }
        let data = try Data(contentsOf: root.appendingPathComponent("Plugins/XcodeClean/plugin.json"))
        let manifest = try JSONDecoder().decode(SourceManifest.self, from: data)
        let checker = PluginRequirementChecker(macOSVersion: { "27.0" }, applicationInstalled: { _ in false })
        XCTAssertNil(checker.failure(for: manifest.requirements), "Leftover Xcode data can be cleaned without the app installed")
    }

    func testLegacyPackagesWithoutRequirementsRemainCompatible() {
        let checker = PluginRequirementChecker(macOSVersion: { "14.0" }, applicationInstalled: { _ in false })
        XCTAssertNil(checker.failure(for: nil))
    }
}

enum PluginRequirementTestData {
    static func requirements() -> PluginProductMetadata.Requirements {
        .init(minimumMacOSVersion: "27.0", architectures: [], hardware: [],
              applications: [.init(bundleID: "com.example.siri", name: "Siri AI")], executables: [],
              permissionIDs: ["accessibility"], setupComplexity: "simple", requiresRelaunch: false)
    }
}
