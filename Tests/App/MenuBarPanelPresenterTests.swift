import AppKit
import Carbon
import Combine
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelPresenterTests: XCTestCase {
    func testHidingAnAlreadyHiddenSecondaryPanelDoesNotPublishAStateChange() {
        let controller = SecondaryPanelController()
        var updateCount = 0
        let cancellable = controller.objectWillChange.sink {
            updateCount += 1
        }

        controller.hide()
        controller.hide()

        XCTAssertEqual(updateCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testFullSizePopoverPreservesOriginalContentArea() {
        let contentSize = NSSize(width: 316, height: 500)
        let insets = NSEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)

        XCTAssertEqual(
            MenuBarPopoverGeometry.popoverSize(
                preserving: contentSize,
                safeAreaInsets: insets
            ),
            NSSize(width: 342, height: 526)
        )
    }

    func testPopoverGeometryRejectsUnavailableSafeAreaInsets() {
        XCTAssertFalse(MenuBarPopoverGeometry.hasUsableInsets(NSEdgeInsetsZero))
        XCTAssertTrue(
            MenuBarPopoverGeometry.hasUsableInsets(
                NSEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)
            )
        )
    }

    func testPanelCommandResolverAddsSettingsWithoutCapturingSearchCloseOrQuit() {
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: "\u{1B}",
                    keyCode: UInt16(kVK_Escape),
                    modifiers: []
                )
            ),
            .dismissPanel
        )
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: ",",
                    keyCode: UInt16(kVK_ANSI_Comma)
                )
            ),
            .showSettings
        )
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: "k",
                    keyCode: UInt16(kVK_ANSI_K)
                )
            ),
            .showUnifiedSearch
        )
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: "1",
                    keyCode: UInt16(kVK_ANSI_1)
                )
            ),
            .selectTab(.components)
        )

        for keyCode in [kVK_ANSI_F, kVK_ANSI_W, kVK_ANSI_Q] {
            XCTAssertNil(
                MenuBarPanelKeyboardAction.resolve(
                    for: makeCommandKeyEvent(
                        characters: "",
                        keyCode: UInt16(keyCode)
                    )
                )
            )
        }
    }

    func testExplicitPresentationOpensClosedSurface() {
        XCTAssertEqual(
            MenuBarPanelPresentationAction.resolve(
                isPanelShown: false,
                selectedTab: .components,
                requestedTab: .features
            ),
            .open
        )
    }

    func testExplicitPresentationSwitchesOpenSurface() {
        XCTAssertEqual(
            MenuBarPanelPresentationAction.resolve(
                isPanelShown: true,
                selectedTab: .components,
                requestedTab: .features
            ),
            .switchPanel
        )
    }

    func testExplicitPresentationFocusesAlreadyOpenSurfaceWithoutClosing() {
        XCTAssertEqual(
            MenuBarPanelPresentationAction.resolve(
                isPanelShown: true,
                selectedTab: .features,
                requestedTab: .features
            ),
            .focus
        )
    }

    func testTogglePresentationOpensRequestedSurfaceWhenClosed() {
        XCTAssertEqual(
            MenuBarPanelToggleAction.resolve(
                isPanelShown: false,
                selectedTab: .features,
                requestedTab: .components
            ),
            .open
        )
    }

    func testTogglePresentationClosesAlreadyOpenRequestedSurface() {
        XCTAssertEqual(
            MenuBarPanelToggleAction.resolve(
                isPanelShown: true,
                selectedTab: .components,
                requestedTab: .components
            ),
            .close
        )
    }

    func testTogglePresentationSwitchesDirectlyFromOtherOpenSurface() {
        XCTAssertEqual(
            MenuBarPanelToggleAction.resolve(
                isPanelShown: true,
                selectedTab: .features,
                requestedTab: .components
            ),
            .switchPanel
        )
    }

    private func makeCommandKeyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
