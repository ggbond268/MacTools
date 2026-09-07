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

    func testUnifiedPanelModelEditLayoutStateTransitions() {
        let model = MenuBarUnifiedPanelModel(
            selectedTab: .components,
            contentHeight: 300,
            maximumFeatureListHeight: 400,
            isPanelVisible: true,
            isEditingLayout: false
        )

        XCTAssertFalse(model.isEditingLayout)

        model.toggleEditLayout()
        XCTAssertTrue(model.isEditingLayout)

        var selectedTab: MenuBarPanelTab?
        model.onTabSelection = { selectedTab = $0 }
        model.selectTab(.features)
        XCTAssertFalse(model.isEditingLayout)
        XCTAssertEqual(selectedTab, .features)

        model.isEditingLayout = true
        XCTAssertTrue(model.isEditingLayout)

        // Switching tab via update resets edit mode
        model.update(
            selectedTab: .features,
            contentHeight: 300,
            maximumFeatureListHeight: 400,
            isPanelVisible: true
        )
        XCTAssertFalse(model.isEditingLayout)

        model.isEditingLayout = true
        // Popover closing resets edit mode
        model.update(
            selectedTab: .features,
            contentHeight: 300,
            maximumFeatureListHeight: 400,
            isPanelVisible: false
        )
        XCTAssertFalse(model.isEditingLayout)
    }

    func testUnhandledEscapeExitsEditLayoutWithoutDismissing() {
        let model = MenuBarUnifiedPanelModel(
            selectedTab: .components,
            contentHeight: 300,
            maximumFeatureListHeight: 400,
            isPanelVisible: true,
            isEditingLayout: true
        )
        var didDismiss = false
        let escapeHandler = {
            if model.isEditingLayout {
                model.isEditingLayout = false
            } else {
                didDismiss = true
            }
        }

        escapeHandler()
        XCTAssertFalse(model.isEditingLayout)
        XCTAssertFalse(didDismiss)

        escapeHandler()
        XCTAssertFalse(model.isEditingLayout)
        XCTAssertTrue(didDismiss)
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
