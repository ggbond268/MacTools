import XCTest
@testable import MacTools
@testable import AppHotkeyPlugin

/// The app-hotkey plugin and the host's global-shortcut manager both install Carbon
/// hot-key handlers on the *same* process-wide event target. This PR makes each handler
/// claim only its own signature and return `eventNotHandledErr` for foreign hot keys, so
/// the other manager still receives them. That pass-through dispatch is only correct
/// while the two signatures never collide — assert the invariant here, since the C event
/// handler itself can't be exercised without a live Carbon event loop.
final class HotkeySignatureDispatchTests: XCTestCase {
    func testManagersUseDistinctSignatures() {
        XCTAssertNotEqual(
            AppHotkeyManager.signature,
            GlobalShortcutManager.signature,
            "Colliding signatures would make each handler swallow the other's hot keys."
        )
    }

    func testSignaturesMatchDocumentedFourCC() {
        // Document the bytes (the signature *is* the FourCC) rather than re-stating hex,
        // so a transposed character is caught here.
        XCTAssertEqual(AppHotkeyManager.signature, Self.fourCharCode("AHKY"))
        XCTAssertEqual(GlobalShortcutManager.signature, Self.fourCharCode("MCTL"))
    }

    /// Packs a 4-char ASCII string into an `OSType` the way Carbon FourCC literals do.
    private static func fourCharCode(_ string: String) -> OSType {
        precondition(string.unicodeScalars.count == 4 && string.unicodeScalars.allSatisfy { $0.isASCII })
        return string.unicodeScalars.reduce(0) { ($0 << 8) + OSType($1.value) }
    }
}
