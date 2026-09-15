import AppKit
import Carbon
import Combine
import MacToolsPluginKit
import SwiftUI
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

    func testEditingBlocksExplicitNativeAndRepeatedStatusItemDismissalUntilDone() async throws {
        var closeCount = 0
        let fixture = try await makePresentedFixture(onClosed: { closeCount += 1 })
        defer { fixture.close() }
        let presenter = fixture.presenter
        let popover = presenter.debugPopoverForTests
        let model = presenter.debugPanelModelForTests
        model.beginLayoutEditing(visibleItemCount: 0)
        try await Task.sleep(for: .milliseconds(150))
        var feedbackCount = 0
        var panelUpdates = 0
        let feedbackSubscription = model.editingFeedback.requests.sink { feedbackCount += 1 }
        let panelSubscription = model.objectWillChange.sink { panelUpdates += 1 }
        defer { feedbackSubscription.cancel(); panelSubscription.cancel() }
        let editingSize = popover.contentSize

        presenter.dismissPanels()
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(feedbackCount, 1)
        popover.performClose(nil)
        XCTAssertTrue(popover.isShown)
        presenter.toggleComponentPanel(relativeTo: fixture.button)
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(feedbackCount, 1, "Repeated close requests must not stack feedback animations")
        XCTAssertEqual(panelUpdates, 0, "Feedback must not publish a panel content or layout change")

        // Cooldown timing is covered by PanelLayoutToolbarTests; each close path
        // below should independently deliver feedback without wall-clock waits.
        model.editingFeedback.reset()
        popover.performClose(nil)
        XCTAssertEqual(feedbackCount, 2, "Native close requests must signal the Done button")
        model.editingFeedback.reset()
        presenter.toggleComponentPanel(relativeTo: fixture.button)
        XCTAssertEqual(feedbackCount, 3, "The status-item toggle must signal the Done button")
        model.editingFeedback.reset()
        let mainWindow = try XCTUnwrap(popover.contentViewController?.view.window)
        NSApp.postEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mainWindow.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: UInt16(kVK_Escape))), atStart: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(feedbackCount, 4, "Main-panel Escape must signal Done instead of ending editing")
        presenter.performKeyboardAction(.dismissPanel)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(popover.contentSize, editingSize)
        XCTAssertEqual(panelUpdates, 0)

        presenter.toggleFeaturePanel(relativeTo: fixture.button)
        XCTAssertEqual(model.selectedTab, .features)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertEqual(closeCount, 0)

        try await Task.sleep(for: .milliseconds(150))
        try clickHeaderButton(in: XCTUnwrap(popover.contentViewController?.view), leading: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isEditingLayout, "Done explicitly ends editing")
        XCTAssertTrue(popover.isShown)
        presenter.dismissPanels()
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(closeCount, 1)
    }

    func testRemovingWidgetUpdatesPopoverHeightInTheSameTransaction() async throws {
        let fixture = try await makePresentedFixture(plugins: [PresenterLayoutPlugin("a"), PresenterLayoutPlugin("b")])
        defer { fixture.close() }
        let model = fixture.presenter.debugPanelModelForTests
        model.beginLayoutEditing(visibleItemCount: 2)
        try await Task.sleep(for: .milliseconds(100))
        var updates = 0
        let observer = model.objectWillChange.sink { updates += 1 }
        let entry = try XCTUnwrap(fixture.host.panelEntries(in: "components").last)
        let oldHeight = model.contentHeight
        XCTAssertTrue(fixture.host.removePanelEntry(entry, from: "components"))
        XCTAssertLessThan(model.contentHeight, oldHeight)
        XCTAssertEqual(updates, 1, "Content and native height must settle without queued intermediate layouts")
        let finalSize = fixture.presenter.debugPopoverForTests.contentSize
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(fixture.presenter.debugPopoverForTests.contentSize, finalSize)
        withExtendedLifetime(observer) {}
    }

    private func clickTab(_ id: String, in view: NSView) throws {
        let tab = try XCTUnwrap(descendants(view).compactMap { $0 as? MenuBarPanelIconControl }.first {
            $0.accessibilityIdentifier() == "menuBarPanel.tab.\(id)"
        })
        let window = try XCTUnwrap(tab.window)
        let point = tab.convert(CGPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    func testDeletingSelectedPanelPublishesOneFinalSizeAndKeepsRemainingTabsUsable() async throws {
        let fixture = try await makePresentedFixture(plugins: [
            PresenterLayoutPlugin("one"), PresenterLayoutPlugin("two"), PresenterLayoutPlugin("three"),
        ])
        defer { fixture.close() }
        let presenter = fixture.presenter
        let model = presenter.debugPanelModelForTests
        let popover = presenter.debugPopoverForTests
        let customID = try XCTUnwrap(fixture.host.addMenuBarPanel())
        fixture.host.assignPanelEntry(pluginID: "one", surface: .dashboard, to: customID)
        presenter.showPanel(id: customID, toggle: false, relativeTo: fixture.button)
        model.beginLayoutEditing(visibleItemCount: 1)
        try await Task.sleep(for: .milliseconds(250))
        let oldHeight = popover.contentSize.height
        let mainView = try XCTUnwrap(popover.contentViewController?.view)
        let retiredTab = try XCTUnwrap(descendants(mainView).compactMap { $0 as? MenuBarPanelIconControl }.first {
            $0.accessibilityIdentifier() == "menuBarPanel.tab.\(customID)"
        })
        mainView.window?.makeFirstResponder(retiredTab)
        var sizes: [NSSize] = []
        let observation = popover.observe(\.contentSize, options: .new) { _, change in
            MainActor.assumeIsolated { if let size = change.newValue { sizes.append(size) } }
        }
        XCTAssertNil(model.deletePanel(id: customID))
        XCTAssertEqual(model.selectedTab, .components, "Selection must recover in the deletion transaction")
        XCTAssertEqual(fixture.host.panelID(pluginID: "one", surface: .dashboard), "components")
        let finalSize = popover.contentSize
        XCTAssertGreaterThan(finalSize.height, oldHeight)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(popover.contentSize, finalSize)
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertTrue(sizes.allSatisfy { $0 == finalSize }, "Deletion must not resize through an empty intermediate panel")
        observation.invalidate()
        XCTAssertNil(retiredTab.window)
        XCTAssertFalse(mainView.window?.firstResponder === retiredTab)
        try clickTab("features", in: mainView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedTab, .features)
        try clickTab("components", in: mainView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedTab, .components)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertTrue(popover.isShown)

        let otherID = try XCTUnwrap(fixture.host.addMenuBarPanel())
        XCTAssertNil(model.deletePanel(id: otherID))
        XCTAssertEqual(model.selectedTab, .components, "Deleting another panel preserves selection")
        XCTAssertEqual(popover.contentSize, finalSize)
    }

    private func clickHeaderButton(in root: NSView, leading: Bool) throws {
        let window = try XCTUnwrap(root.window)
        window.makeKey()
        let inset = MenuBarPanelLayout.panelTopPadding + MenuBarPanelLayout.headerHeight / 2
        let contentBounds = root.safeAreaLayoutGuide.frame
        let local = CGPoint(x: leading ? contentBounds.minX + 28 : contentBounds.maxX - 28,
                            y: root.isFlipped ? contentBounds.minY + inset : contentBounds.maxY - inset)
        let point = root.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private struct PresentedFixture {
        let presenter: MenuBarPanelPresenter
        let host: PluginHost
        let anchorWindow: NSWindow
        let button: NSStatusBarButton
        let defaults: UserDefaults
        let suite: String

        func close() {
            presenter.debugPanelModelForTests.endLayoutEditing()
            presenter.dismissPanels()
            anchorWindow.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makePresentedFixture(plugins: [any MacToolsPlugin] = [], onClosed: @escaping () -> Void = {}) async throws -> PresentedFixture {
        let suite = "MenuBarPanelPresenterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let host = PluginHost(plugins: plugins, shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager())
        let presenter = MenuBarPanelPresenter(pluginHost: host, appUpdater: AppUpdater(startingUpdater: false),
            menuBarPanelThemeStore: MenuBarPanelThemeStore(userDefaults: defaults),
            onDismiss: {}, onOpenUpdate: {}, onOpenSettings: {}, onOpenUnifiedSearch: {},
            onPresentDiskCleanConfiguration: {}, onPresentLaunchControlConfiguration: {},
            onAllPanelsClosed: onClosed)
        // A dedicated anchor avoids depending on available menu-bar space and
        // asynchronous status-item placement in the user's desktop session.
        let screen = try XCTUnwrap(NSScreen.main)
        let anchorWindow = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 180,
            y: screen.visibleFrame.maxY - 100, width: 80, height: 40),
            styleMask: [.titled], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let button = NSStatusBarButton(frame: CGRect(x: 24, y: 8, width: 28, height: 24))
        button.image = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)
        anchorWindow.contentView?.addSubview(button)
        anchorWindow.makeKeyAndOrderFront(nil)
        anchorWindow.contentView?.layoutSubtreeIfNeeded()
        presenter.showDashboard(relativeTo: button)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(presenter.isAnyPanelShown)
        return PresentedFixture(presenter: presenter, host: host, anchorWindow: anchorWindow,
                                button: button, defaults: defaults, suite: suite)
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

@MainActor
private final class PresenterLayoutPlugin: MacToolsPlugin, PluginComponentPanel {
    let metadata: PluginMetadata
    let descriptor = PluginComponentDescriptor(span: PluginComponentSpan(width: 4, height: 24)!)
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(_ id: String) {
        metadata = PluginMetadata(id: id, title: id, iconName: "square", iconTint: .blue,
                                  order: 0, defaultDescription: id)
    }

    var componentPanelState: PluginComponentState {
        .init(subtitle: "", isActive: true, isEnabled: true, isVisible: true, errorMessage: nil)
    }

    func makeView(context: PluginComponentContext) -> AnyView { AnyView(Text(metadata.title)) }
}
