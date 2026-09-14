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

        try await Task.sleep(for: .milliseconds(650))
        popover.performClose(nil)
        XCTAssertEqual(feedbackCount, 2, "Native close requests must signal the Done button")
        try await Task.sleep(for: .milliseconds(650))
        presenter.toggleComponentPanel(relativeTo: fixture.button)
        XCTAssertEqual(feedbackCount, 3, "The status-item toggle must signal the Done button")
        try await Task.sleep(for: .milliseconds(650))
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

    func testWidgetLibraryKeepsEditingAndRevealsAppendedEntriesAfterPanelResizes() async throws {
        let fixture = try await makePresentedFixture(plugins: ["a", "b", "c", "d", "e", "f", "g"].map(PresenterLayoutPlugin.init))
        defer { fixture.close() }
        let presenter = fixture.presenter
        let host = fixture.host
        for id in ["a", "b"] { XCTAssertTrue(host.removePanelEntry(.init(pluginID: id, surface: .dashboard), from: "components")) }
        presenter.debugPanelModelForTests.beginLayoutEditing(visibleItemCount: 5)
        try await Task.sleep(for: .milliseconds(250))
        let mainWindow = try XCTUnwrap(presenter.debugPopoverForTests.contentViewController?.view.window)
        let mainContent = try XCTUnwrap(mainWindow.contentView)
        let bitmap = try XCTUnwrap(mainContent.bitmapImageRepForCachingDisplay(in: mainContent.bounds))
        mainContent.cacheDisplay(in: mainContent.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: "/private/tmp/mactools-widget-editor-footer.png"))
        for id in ["a", "b"] {
            try clickFooterButton(in: mainWindow, trailingOffset: mainWindow.contentView!.bounds.width - 64)
            try await Task.sleep(for: .milliseconds(350))
            let library = try XCTUnwrap(NSApp.windows.first {
                $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0)
            })
            XCTAssertTrue(presenter.containsPresentedWindow(library))
            presenter.dismissPanels()
            XCTAssertTrue(presenter.debugPopoverForTests.isShown)
            XCTAssertTrue(presenter.debugPanelModelForTests.isEditingLayout)
            if id == "b" {
                let list = try XCTUnwrap(descendants(library.contentView!).compactMap { $0 as? NSTableView }.first)
                list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(200))
            }
            library.makeKey()
            let point = CGPoint(x: 310, y: try XCTUnwrap(library.contentView).bounds.height - 170)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                library.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: library.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(library.isVisible, "A successful addition closes only the widget library")
            XCTAssertEqual(host.panelEntries(in: "components").last?.pluginID, id)
            let root = try XCTUnwrap(presenter.debugPopoverForTests.contentViewController?.view)
            let canvas = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "panel.layout.canvas" })
            let scroll = try XCTUnwrap(canvas.enclosingScrollView)
            XCTAssertEqual(scroll.contentView.bounds.maxY, try XCTUnwrap(scroll.documentView).bounds.maxY, accuracy: 1)
            XCTAssertTrue(presenter.debugPopoverForTests.isShown)
            XCTAssertTrue(presenter.debugPanelModelForTests.isEditingLayout)
        }
    }

    func testWidgetRemovalConfirmationCanToggleRepeatedlyWithoutClosingTheEditor() async throws {
        let fixture = try await makePresentedFixture(plugins: [PresenterLayoutPlugin("one")])
        defer { fixture.close() }
        let presenter = fixture.presenter
        let model = presenter.debugPanelModelForTests
        model.beginLayoutEditing(visibleItemCount: 1)
        try await Task.sleep(for: .milliseconds(250))
        let root = try XCTUnwrap(presenter.debugPopoverForTests.contentViewController?.view)
        let window = try XCTUnwrap(root.window)
        let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }.first)
        for index in 0..<6 {
            let metrics = PanelLayoutItemControlsLayout(size: source.bounds.size)
            let point = source.convert(CGPoint(x: source.menuFrame.minX + metrics.buttonSide / 2,
                                              y: source.menuFrame.midY), to: nil)
            source.hover?.trackingView?.pointerLocationInWindow = { _ in point }
            source.hover?.trackingView?.refresh()
            try await Task.sleep(for: .milliseconds(150))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: false)
            }
            try await Task.sleep(for: .milliseconds(300))
            let confirmation = NSApp.windows.first { $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0) }
            XCTAssertEqual(confirmation != nil, index.isMultiple(of: 2),
                           "Click \(index + 1), parent key: \(window.isKeyWindow), target: \(point)")
            if let confirmation {
                confirmation.makeKey()
                confirmation.selectNextKeyView(nil)
                source.hover?.trackingView?.pointerLocationInWindow = { _ in CGPoint(x: -100, y: -100) }
                source.hover?.trackingView?.refresh()
                try await Task.sleep(for: .milliseconds(150))
            }
            XCTAssertTrue(model.isEditingLayout)
            XCTAssertTrue(presenter.debugPopoverForTests.isShown)
            XCTAssertEqual(fixture.host.panelEntries(in: "components").count, 1)
        }
    }

    func testDeleteConfirmationCancelEscapeAndDeleteKeepMainPopoverEditing() async throws {
        let fixture = try await makePresentedFixture()
        defer { fixture.close() }
        let presenter = fixture.presenter
        let model = presenter.debugPanelModelForTests
        let customID = try XCTUnwrap(fixture.host.addMenuBarPanel())
        presenter.showPanel(id: customID, toggle: false, relativeTo: fixture.button)
        model.beginLayoutEditing(visibleItemCount: 0)
        try await Task.sleep(for: .milliseconds(200))
        let mainView = try XCTUnwrap(presenter.debugPopoverForTests.contentViewController?.view)
        try clickTab("features", in: mainView)
        try await Task.sleep(for: .milliseconds(100))
        try clickTab(customID, in: mainView)
        try await Task.sleep(for: .milliseconds(100))
        try clickFooterButton(in: XCTUnwrap(mainView.window), trailingOffset: 140)
        try await Task.sleep(for: .milliseconds(300))

        let confirmation = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0)
        })
        XCTAssertFalse(confirmation === mainView.window)
        XCTAssertTrue(presenter.containsPresentedWindow(confirmation))
        XCTAssertTrue(presenter.debugPopoverForTests.isShown)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertTrue(fixture.host.menuBarPanels.contains { $0.id == customID })
        XCTAssertNil(NSApp.modalWindow, "Confirmation must not create a modal alert")

        let content = try XCTUnwrap(confirmation.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/mactools-panel-delete-confirmation.png"))

        if CGPreflightScreenCaptureAccess() {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(confirmation.windowNumber),
                                 "/private/tmp/mactools-panel-delete-confirmation-window.png"]
            try capture.run()
            capture.waitUntilExit()
        }

        presenter.dismissPanels() // The outside-click coordinator may request dismissal first.
        XCTAssertTrue(presenter.debugPopoverForTests.isShown)
        try clickFooterButton(in: confirmation, trailingOffset: 130)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(confirmation.isVisible)
        XCTAssertTrue(presenter.debugPopoverForTests.isShown)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertTrue(fixture.host.menuBarPanels.contains { $0.id == customID })

        try clickFooterButton(in: XCTUnwrap(mainView.window), trailingOffset: 140)
        try await Task.sleep(for: .milliseconds(250))
        let escapeConfirmation = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0)
        })
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: escapeConfirmation.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)))
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(escapeConfirmation.isVisible)
        XCTAssertTrue(presenter.debugPopoverForTests.isShown)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertTrue(fixture.host.menuBarPanels.contains { $0.id == customID })

        try clickFooterButton(in: XCTUnwrap(mainView.window), trailingOffset: 140)
        try await Task.sleep(for: .milliseconds(250))
        let deleteConfirmation = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0)
        })
        deleteConfirmation.makeKey()
        let confirm = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: deleteConfirmation.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(deleteConfirmation.performKeyEquivalent(with: confirm))
        try await Task.sleep(for: .milliseconds(300))
        if deleteConfirmation.isVisible, let content = deleteConfirmation.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/private/tmp/mactools-panel-delete-after-click.png"))
        }
        XCTAssertFalse(deleteConfirmation.isVisible)
        XCTAssertFalse(fixture.host.menuBarPanels.contains { $0.id == customID })
        XCTAssertTrue(presenter.debugPopoverForTests.isShown)
        XCTAssertTrue(model.isEditingLayout)
        XCTAssertTrue(fixture.host.menuBarPanels.contains { $0.id == model.selectedTab.id })
        try clickTab("features", in: mainView)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.selectedTab.id, "features")
        try clickFooterButton(in: XCTUnwrap(mainView.window), trailingOffset: 140)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0) },
                       "Default panels keep the footer's Delete Panel action disabled")
        try clickTab("features", in: mainView)
        try await Task.sleep(for: .milliseconds(200))
        let iconPicker = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0)
        })
        XCTAssertTrue(presenter.debugPopoverForTests.isShown)
        NSApp.postEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: iconPicker.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: UInt16(kVK_Escape))), atStart: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(iconPicker.isVisible)
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

    private func clickFooterButton(in window: NSWindow, trailingOffset: CGFloat) throws {
        window.makeKey()
        let bounds = try XCTUnwrap(window.contentView).bounds
        let point = CGPoint(x: bounds.maxX - trailingOffset, y: bounds.minY + 38)
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
