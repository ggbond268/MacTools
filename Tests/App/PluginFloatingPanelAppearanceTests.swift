import Foundation
import XCTest
@testable import MacToolsPluginKit

final class PluginFloatingPanelAppearanceTests: XCTestCase {
    func testStoredPreferenceDefaultsToSystemAndRejectsUnknownValues() {
        let suiteName = "PluginFloatingPanelAppearanceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PluginFloatingPanelAppearance.stored(in: defaults), .system)

        defaults.set("unknown", forKey: PluginFloatingPanelAppearance.userDefaultsKey)
        XCTAssertEqual(PluginFloatingPanelAppearance.stored(in: defaults), .system)

        PluginFloatingPanelAppearance.solid.store(in: defaults)
        XCTAssertEqual(PluginFloatingPanelAppearance.stored(in: defaults), .solid)
    }

    func testSurfaceResolutionGivesReduceTransparencyHighestPrecedence() {
        XCTAssertEqual(
            PluginFloatingPanelResolvedSurface.resolve(
                appearance: .system,
                reducesTransparency: true,
                supportsNativeGlass: true
            ),
            .solid
        )
        XCTAssertEqual(
            PluginFloatingPanelResolvedSurface.resolve(
                appearance: .solid,
                reducesTransparency: false,
                supportsNativeGlass: true
            ),
            .solid
        )
        XCTAssertEqual(
            PluginFloatingPanelResolvedSurface.resolve(
                appearance: .system,
                reducesTransparency: false,
                supportsNativeGlass: true
            ),
            .nativeGlass
        )
        XCTAssertEqual(
            PluginFloatingPanelResolvedSurface.resolve(
                appearance: .system,
                reducesTransparency: false,
                supportsNativeGlass: false
            ),
            .regularMaterial
        )
    }
}
