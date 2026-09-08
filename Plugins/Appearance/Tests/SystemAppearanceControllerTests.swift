import XCTest
@testable import AppearancePlugin

@MainActor
final class SystemAppearanceControllerTests: XCTestCase {
    private final class Flags {
        var dark = false
        var automatic = false
        var writes: [String] = []
        var rejectedMode: SystemAppearanceMode?

        var access: SystemAppearanceController.Access {
            .init(readDark: { self.dark }, readAutomatic: { self.automatic },
                  writeDark: { self.writes.append("dark=\($0)"); self.dark = $0 },
                  writeAutomatic: { self.writes.append("auto=\($0)"); self.automatic = $0 },
                  persistedModeMatches: { $0 != self.rejectedMode })
        }
    }

    func testAutomaticPolicyIsIndependentOfRenderedTheme() throws {
        let flags = Flags()
        flags.automatic = true
        let controller = SystemAppearanceController(access: flags.access)
        XCTAssertEqual(try controller.read(), .init(mode: .auto, isDark: false))
        flags.dark = true
        XCTAssertEqual(try controller.read(), .init(mode: .auto, isDark: true))
    }

    func testManualModeDisablesAutomaticBeforeChangingTheme() throws {
        let flags = Flags()
        flags.automatic = true
        let controller = SystemAppearanceController(access: flags.access)
        try controller.setMode(.dark)
        XCTAssertEqual(flags.writes, ["auto=false", "dark=true"])
        XCTAssertEqual(try controller.read(), .init(mode: .dark, isDark: true))
        try controller.setMode(.light)
        XCTAssertEqual(try controller.read(), .init(mode: .light, isDark: false))
    }

    func testAutomaticModeDoesNotForceTheCurrentThemeAndRepeatedSelectionDoesNotWrite() throws {
        let flags = Flags()
        flags.dark = true
        let controller = SystemAppearanceController(access: flags.access)
        try controller.setMode(.auto)
        try controller.setMode(.auto)
        XCTAssertEqual(flags.writes, ["auto=true"])
        XCTAssertEqual(try controller.read(), .init(mode: .auto, isDark: true))
    }

    func testPersistenceMismatchRestoresPreviousMode() throws {
        let flags = Flags()
        flags.automatic = true
        flags.rejectedMode = .dark
        let controller = SystemAppearanceController(access: flags.access)
        XCTAssertThrowsError(try controller.setMode(.dark)) {
            guard case SystemAppearanceError.verificationFailed(restored: true) = $0 else {
                return XCTFail("Expected a verified rollback")
            }
        }
        XCTAssertEqual(try controller.read().mode, .auto)
        XCTAssertEqual(flags.writes, ["auto=false", "dark=true", "auto=true"])
    }

    func testIgnoredNativeWriteCannotReportSuccess() throws {
        let controller = SystemAppearanceController(access: .init(
            readDark: { false }, readAutomatic: { false }, writeDark: { _ in },
            writeAutomatic: { _ in }, persistedModeMatches: { _ in true }
        ))
        XCTAssertThrowsError(try controller.setMode(.dark))
        XCTAssertEqual(try controller.read().mode, .light)
    }

    func testUnavailableRuntimeFailsClosed() {
        let controller = SystemAppearanceController(access: nil)
        XCTAssertThrowsError(try controller.read())
        XCTAssertThrowsError(try controller.setMode(.auto))
    }
}
