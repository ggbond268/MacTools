import AppKit
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryPanelPlacementTests: XCTestCase {
    private let primary = ClipboardHistoryPanelScreen(
        id: "primary", frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 40, width: 1440, height: 835)
    )
    private let secondary = ClipboardHistoryPanelScreen(
        id: "secondary", frame: NSRect(x: -1920, y: -200, width: 1920, height: 1080),
        visibleFrame: NSRect(x: -1920, y: -160, width: 1920, height: 1015)
    )
    private let size = NSSize(width: 900, height: 620)

    func testPointerSelectsItsDisplayIncludingNegativeCoordinatesAndMenuBar() {
        let screens = [primary, secondary]
        XCTAssertEqual(ClipboardHistoryPanelPlacement.targetScreen(pointer: NSPoint(x: -1800, y: 870), screens: screens), secondary)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.targetScreen(pointer: NSPoint(x: 500, y: 890), screens: screens), primary)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.targetScreen(pointer: NSPoint(x: 8000, y: 8000), screens: screens), primary)
        XCTAssertNil(ClipboardHistoryPanelPlacement.targetScreen(pointer: .zero, screens: []))
    }

    func testUnmovedDisplaysCenterOnEveryPresentationAtTheCurrentWindowSize() {
        let settings = ClipboardHistorySettingsStore(storage: PlacementTestStorage())
        for screen in [primary, secondary, primary] {
            for size in [size, NSSize(width: 1080, height: 720)] {
                let frame = ClipboardHistoryPanelPlacement.frame(
                    size: size, on: screen, savedPosition: settings.panelPosition(for: screen.id)
                )
                XCTAssertEqual(frame.midX, screen.visibleFrame.midX)
                XCTAssertEqual(frame.midY, screen.visibleFrame.midY)
                XCTAssertNil(settings.panelPosition(for: screen.id))
            }
        }
    }

    func testUnmovedPlacementMatchesSnapReferenceAcrossDisplaysAndWindowSizes() {
        for screen in [primary, secondary] {
            for size in [size, NSSize(width: 2500, height: 1600)] {
                XCTAssertEqual(
                    ClipboardHistoryPanelPlacement.frame(size: size, on: screen, savedPosition: nil),
                    WindowSnapGeometry.defaultFrame(contentSize: size, visibleFrame: screen.visibleFrame)
                )
            }
        }
    }

    func testEachDisplayRestoresItsOwnPositionAfterSettingsReload() {
        let storage = PlacementTestStorage()
        let settings = ClipboardHistorySettingsStore(storage: storage)
        let primaryFrame = NSRect(x: 90, y: 100, width: size.width, height: size.height)
        let secondaryFrame = NSRect(x: -1800, y: -100, width: size.width, height: size.height)
        settings.setPanelPosition(ClipboardHistoryPanelPlacement.position(of: primaryFrame, on: primary), for: primary.id)
        XCTAssertNil(settings.panelPosition(for: secondary.id))
        settings.setPanelPosition(ClipboardHistoryPanelPlacement.position(of: secondaryFrame, on: secondary), for: secondary.id)

        let reloaded = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: primary, savedPosition: reloaded.panelPosition(for: primary.id)), primaryFrame)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: secondary, savedPosition: reloaded.panelPosition(for: secondary.id)), secondaryFrame)
    }

    func testDisplayRearrangementPreservesScreenLocalPosition() {
        let frame = NSRect(x: -1800, y: -100, width: size.width, height: size.height)
        let position = ClipboardHistoryPanelPlacement.position(of: frame, on: secondary)
        let rearranged = ClipboardHistoryPanelScreen(
            id: secondary.id, frame: secondary.frame.offsetBy(dx: 3360, dy: 900),
            visibleFrame: secondary.visibleFrame.offsetBy(dx: 3360, dy: 900)
        )
        XCTAssertEqual(
            ClipboardHistoryPanelPlacement.frame(size: size, on: rearranged, savedPosition: position),
            frame.offsetBy(dx: 3360, dy: 900)
        )
    }

    func testRestorationClampsToChangedWorkAreaWithoutOverwritingStoredPosition() {
        let settings = ClipboardHistorySettingsStore(storage: PlacementTestStorage())
        let position = ClipboardHistoryPanelPosition(left: 1300, top: 800)
        settings.setPanelPosition(position, for: primary.id)
        let frame = ClipboardHistoryPanelPlacement.frame(size: size, on: primary, savedPosition: position)
        XCTAssertTrue(primary.visibleFrame.contains(frame))
        XCTAssertEqual(frame.maxX, primary.visibleFrame.maxX)
        XCTAssertEqual(frame.minY, primary.visibleFrame.minY)
        XCTAssertEqual(settings.panelPosition(for: primary.id), position)
    }

    func testOversizedPanelFitsOnSmallerDisplay() {
        let screen = ClipboardHistoryPanelScreen(
            id: "small", frame: NSRect(x: 1440, y: 0, width: 800, height: 600),
            visibleFrame: NSRect(x: 1440, y: 24, width: 800, height: 550)
        )
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: screen, savedPosition: nil), screen.visibleFrame)
    }

    func testCrossDisplayMoveBelongsToTheDisplayContainingMostOfTheWindow() {
        let frame = NSRect(x: -800, y: 100, width: size.width, height: size.height)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.screen(containing: frame, screens: [primary, secondary]), secondary)
        XCTAssertNil(ClipboardHistoryPanelPlacement.screen(containing: frame.offsetBy(dx: 8000, dy: 0), screens: [primary, secondary]))
    }

    func testMissingDisplayFallsBackWithoutReplacingItsRememberedPosition() {
        let settings = ClipboardHistorySettingsStore(storage: PlacementTestStorage())
        let position = ClipboardHistoryPanelPosition(left: 120, top: 80)
        settings.setPanelPosition(position, for: secondary.id)
        let target = ClipboardHistoryPanelPlacement.targetScreen(pointer: NSPoint(x: -1800, y: 100), screens: [primary])
        XCTAssertEqual(target, primary)
        XCTAssertNil(settings.panelPosition(for: primary.id))
        XCTAssertEqual(settings.panelPosition(for: secondary.id), position)
    }

    func testInvalidStoredDataAndNonFiniteOffsetsFallBackToCenter() {
        let storage = PlacementTestStorage()
        storage.set(Data("invalid".utf8), forKey: "history-panel-positions-by-display")
        let settings = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertNil(settings.panelPosition(for: primary.id))
        let invalid = ClipboardHistoryPanelPosition(left: .infinity, top: .nan)
        settings.setPanelPosition(invalid, for: primary.id)
        XCTAssertNil(settings.panelPosition(for: primary.id))
        let frame = ClipboardHistoryPanelPlacement.frame(size: size, on: primary, savedPosition: invalid)
        XCTAssertEqual(frame.midX, primary.visibleFrame.midX)
        XCTAssertEqual(frame.midY, primary.visibleFrame.midY)
    }
}

@MainActor
private final class PlacementTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
