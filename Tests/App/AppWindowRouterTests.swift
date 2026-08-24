import AppKit
import Carbon
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class AppWindowRouterTests: XCTestCase {
    func testDashboardTargetInvokesOnlyDashboardAction() {
        var dashboardCallCount = 0
        var featurePanelCallCount = 0
        let actions = SettingsPanelPresentationActions(
            showDashboard: { dashboardCallCount += 1 },
            showFeaturePanel: { featurePanelCallCount += 1 }
        )

        actions.present(.dashboard)

        XCTAssertEqual(dashboardCallCount, 1)
        XCTAssertEqual(featurePanelCallCount, 0)
    }

    func testFeaturePanelTargetInvokesOnlyFeaturePanelAction() {
        var dashboardCallCount = 0
        var featurePanelCallCount = 0
        let actions = SettingsPanelPresentationActions(
            showDashboard: { dashboardCallCount += 1 },
            showFeaturePanel: { featurePanelCallCount += 1 }
        )

        actions.present(.featurePanel)

        XCTAssertEqual(dashboardCallCount, 0)
        XCTAssertEqual(featurePanelCallCount, 1)
    }

    func testSettingsWindowKeepsItsWidthAcrossDestinations() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()

        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<SettingsView>)
        await settleWindowLayout(window)
        let initialWidth = window.frame.width
        let initialToolbarItemCount = window.toolbar?.items.count
        let toolbarItemIdentifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        let sidebarToggleIndex = toolbarItemIdentifiers.firstIndex {
            $0.contains("toggleSidebar")
        }

        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertNil(
            sidebarToggleIndex,
            "Expected the settings sidebar toggle to be removed, got \(toolbarItemIdentifiers)"
        )
        XCTAssertGreaterThanOrEqual(
            toolbarItemIdentifiers.count,
            2,
            "Expected history and title toolbar items, got \(toolbarItemIdentifiers)"
        )
        XCTAssertEqual(hostingView.sizingOptions, [])
        XCTAssertEqual(
            hostingView.frame.width,
            SettingsWindowLayout.defaultContentSize.width,
            accuracy: 0.5
        )

        window.setContentSize(NSSize(width: 940, height: 640))
        await settleWindowLayout(window)
        let resizedWidth = window.frame.width
        XCTAssertLessThan(resizedWidth, initialWidth)

        for destination in [
            SettingsNavigationDestination.plugins(.marketplace),
            .about,
            .general
        ] {
            coordinator.navigate(to: destination)
            await settleWindowLayout(window)
            let currentToolbarItemIdentifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            XCTAssertEqual(window.frame.width, resizedWidth, accuracy: 0.5)
            XCTAssertFalse(
                currentToolbarItemIdentifiers.contains { $0.contains("toggleSidebar") },
                "Expected the settings sidebar toggle to remain removed, got \(currentToolbarItemIdentifiers)"
            )
            XCTAssertEqual(
                window.toolbar?.items.count,
                initialToolbarItemCount,
                "Expected a stable toolbar after navigating to \(destination), got \(currentToolbarItemIdentifiers)"
            )
        }

        window.close()
    }

    func testSettingsAndStandalonePalettesShareRecentActionStore() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let settingsHostingView = try XCTUnwrap(
            router.settingsWindow?.contentView as? NSHostingView<SettingsView>
        )

        router.toggleCommandPalette()
        let paletteHostingView = try XCTUnwrap(
            router.commandPalettePanel?.contentView
                as? NSHostingView<StandaloneCommandPaletteRootView>
        )

        XCTAssertTrue(
            settingsHostingView.rootView.commandPaletteRecentStore
                === router.commandPaletteRecentStore
        )
        XCTAssertTrue(
            paletteHostingView.rootView.commandPaletteRecentStore
                === router.commandPaletteRecentStore
        )

        router.commandPalettePanel?.close()
        router.settingsWindow?.close()
    }

    func testSettingsWindowUsesSidebarAsInitialFocus() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()

        let window = try XCTUnwrap(router.settingsWindow)
        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<SettingsView>)
        for _ in 0..<5 {
            await settleWindowLayout(window)
        }

        let sidebarScrollView = try XCTUnwrap(settingsSidebarScrollView(in: hostingView))
        let sidebarListView = try XCTUnwrap(sidebarScrollView.documentView as? NSTableView)
        XCTAssertTrue(
            window.firstResponder === sidebarListView,
            "Expected the settings sidebar to own initial focus, got \(String(describing: window.firstResponder))"
        )

        window.close()
    }

    func testUnifiedSearchOverlayPreservesSidebarScrollGeometry() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()

        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<SettingsView>)
        await settleWindowLayout(window)
        let sidebarScrollView = try XCTUnwrap(settingsSidebarScrollView(in: hostingView))
        let initialBoundsOrigin = sidebarScrollView.contentView.bounds.origin
        let initialContentInsets = sidebarScrollView.contentInsets
        let initialFrame = sidebarScrollView.convert(sidebarScrollView.bounds, to: hostingView)

        coordinator.presentUnifiedSearch(origin: .settingsSidebar)
        await settleWindowLayout(window)

        XCTAssertTrue(settingsSidebarScrollView(in: hostingView) === sidebarScrollView)
        XCTAssertEqual(sidebarScrollView.contentView.bounds.origin.x, initialBoundsOrigin.x, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentView.bounds.origin.y, initialBoundsOrigin.y, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentInsets.top, initialContentInsets.top, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentInsets.bottom, initialContentInsets.bottom, accuracy: 0.5)
        assertEqual(
            sidebarScrollView.convert(sidebarScrollView.bounds, to: hostingView),
            initialFrame
        )

        coordinator.dismissUnifiedSearch()
        await settleWindowLayout(window)

        XCTAssertTrue(settingsSidebarScrollView(in: hostingView) === sidebarScrollView)
        XCTAssertEqual(sidebarScrollView.contentView.bounds.origin.x, initialBoundsOrigin.x, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentView.bounds.origin.y, initialBoundsOrigin.y, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentInsets.top, initialContentInsets.top, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentInsets.bottom, initialContentInsets.bottom, accuracy: 0.5)
        assertEqual(
            sidebarScrollView.convert(sidebarScrollView.bounds, to: hostingView),
            initialFrame
        )

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_K),
                    characters: "k",
                    windowNumber: window.windowNumber
                )
            )
        )
        await settleWindowLayout(window)

        XCTAssertTrue(settingsSidebarScrollView(in: hostingView) === sidebarScrollView)
        XCTAssertEqual(sidebarScrollView.contentView.bounds.origin.x, initialBoundsOrigin.x, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentView.bounds.origin.y, initialBoundsOrigin.y, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentInsets.top, initialContentInsets.top, accuracy: 0.5)
        XCTAssertEqual(sidebarScrollView.contentInsets.bottom, initialContentInsets.bottom, accuracy: 0.5)
        assertEqual(
            sidebarScrollView.convert(sidebarScrollView.bounds, to: hostingView),
            initialFrame
        )

        window.close()
    }

    func testFeatureSettingsPresentationRoutesToRequestedPage() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.presentSettings(.feature(.actionsAndShortcuts))
        XCTAssertEqual(
            router.settingsNavigationCoordinator?.destination,
            .plugins(.actionsAndShortcuts)
        )

        router.presentSettings(.feature(.automation))
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .plugins(.automation))
        router.settingsWindow?.close()
    }

    func testWorkflowPresentationRoutesToTheExactAutomationEditor() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var createdWorkflow: WorkflowDefinition?
        let router = makeRouter(defaults: defaults) { host in
            createdWorkflow = host.automationController.createWorkflow()
        }
        let workflow = try XCTUnwrap(createdWorkflow)

        router.presentSettings(.automationWorkflow(workflow.id))

        XCTAssertEqual(
            router.settingsNavigationCoordinator?.destination,
            .plugins(.automation)
        )
        XCTAssertNil(
            router.settingsNavigationCoordinator?.searchRevealRequest,
            "The visible Automation editor should consume the exact workflow reveal request."
        )
        router.settingsWindow?.close()
    }

    private func settleWindowLayout(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        window.layoutIfNeeded()
    }

    private func settingsSidebarScrollView(in rootView: NSView) -> NSScrollView? {
        descendantViews(of: rootView)
            .compactMap { $0 as? NSScrollView }
            .filter { scrollView in
                let frame = scrollView.convert(scrollView.bounds, to: rootView)
                return frame.minX < 320 && frame.width < 320 && frame.height > 200
            }
            .max { lhs, rhs in
                lhs.bounds.height < rhs.bounds.height
            }
    }

    private func descendantViews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { subview in
            [subview] + descendantViews(of: subview)
        }
    }

    private func assertEqual(
        _ actual: NSRect,
        _ expected: NSRect,
        accuracy: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    func testSettingsWindowConstrainsLiveResizeToMinimumContentSize() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()

        let window = try XCTUnwrap(router.settingsWindow)
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: SettingsWindowLayout.minimumContentSize
            )
        ).size

        XCTAssertEqual(
            router.windowWillResize(window, to: NSSize(width: 400, height: 300)),
            minimumFrameSize
        )

        let largerSize = NSSize(width: 1200, height: 800)
        XCTAssertEqual(router.windowWillResize(window, to: largerSize), largerSize)

        window.close()
    }

    func testClosingSettingsWindowDiscardsNavigationHistory() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let router = AppWindowRouter(
            pluginHost: host,
            appUpdater: AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults
        )

        router.presentSettings(.pluginMarketplace)
        let firstCoordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertEqual(firstCoordinator.destination, .plugins(.marketplace))
        firstCoordinator.navigate(to: .about)

        try XCTUnwrap(router.settingsWindow).close()
        XCTAssertNil(router.settingsNavigationCoordinator)

        router.showSettings()
        let reopenedCoordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertEqual(reopenedCoordinator.history, [.general])
        XCTAssertFalse(reopenedCoordinator.canGoBack)

        try XCTUnwrap(router.settingsWindow).close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testInitializationDoesNotReplaceExistingAppPresentationHandler() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        var receivedRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { request in
            receivedRequests.append(request)
        }

        let router = AppWindowRouter(
            pluginHost: host,
            appUpdater: AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults
        )

        host.presentPluginMarketplace()

        XCTAssertEqual(receivedRequests, [.settings(.pluginMarketplace)])
        XCTAssertNil(router.settingsWindow)
    }

    func testLocalCommandMatcherRecognizesSettingsAndSearchKeyEquivalents() {
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(keyCode: UInt16(kVK_ANSI_Semicolon), characters: ",")
            ),
            .showSettings
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "F",
                    modifiers: [.command, .capsLock]
                )
            ),
            .focusSearch
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_K),
                    characters: "K",
                    modifiers: [.command, .capsLock]
                )
            ),
            .showUnifiedSearch
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(keyCode: UInt16(kVK_ANSI_LeftBracket), characters: "[")
            ),
            .goBack
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(keyCode: UInt16(kVK_ANSI_RightBracket), characters: "]")
            ),
            .goForward
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_UpArrow),
                    characters: "",
                    modifiers: [.control, .command]
                )
            ),
            .moveSidebarSelection(.previous)
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_DownArrow),
                    characters: "",
                    modifiers: [.control, .command]
                )
            ),
            .moveSidebarSelection(.next)
        )
    }

    func testLocalCommandMatcherLeavesCloseQuitAndUnsupportedModifiersUntouched() {
        for keyCode in [kVK_ANSI_W, kVK_ANSI_Q] {
            XCTAssertNil(
                MacToolsLocalKeyboardCommand.resolve(
                    for: keyEvent(keyCode: UInt16(keyCode), characters: "")
                )
            )
        }

        XCTAssertNil(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "f",
                    modifiers: [.command, .shift]
                )
            )
        )
    }

    func testWindowPresentationDeminiaturizesBeforeOrderingFront() {
        var events: [String] = []

        AppWindowPresentation.perform(
            isMiniaturized: true,
            activate: { events.append("activate") },
            deminiaturize: { events.append("deminiaturize") },
            orderFront: { events.append("orderFront") }
        )

        XCTAssertEqual(events, ["activate", "deminiaturize", "orderFront"])
    }

    func testDockVisibilityPolicyUsesRegularActivationOnlyForVisibleSettings() {
        XCTAssertEqual(
            AppDockVisibilityPolicy.activationPolicy(hasVisibleSettingsWindow: true),
            .regular
        )
        XCTAssertEqual(
            AppDockVisibilityPolicy.activationPolicy(hasVisibleSettingsWindow: false),
            .accessory
        )
    }

    func testDockVisibilityControllerDoesNotMutateApplicationPolicyDuringTests() {
        var requestedPolicies = [NSApplication.ActivationPolicy]()
        let setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool = { policy in
            requestedPolicies.append(policy)
            return true
        }

        AppDockVisibilityController.update(
            hasVisibleSettingsWindow: true,
            isRunningTests: true,
            setActivationPolicy: setActivationPolicy
        )
        XCTAssertTrue(requestedPolicies.isEmpty)

        AppDockVisibilityController.update(
            hasVisibleSettingsWindow: true,
            isRunningTests: false,
            setActivationPolicy: setActivationPolicy
        )
        XCTAssertEqual(requestedPolicies, [.regular])
    }

    func testSettingsPaletteVisibilityPolicyRejectsMiniaturizedAndInactiveSpaceWindows() {
        XCTAssertTrue(
            CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: true,
                isWindowMiniaturized: true,
                isWindowOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOnActiveSpace: false
            )
        )
    }

    func testStandalonePalettePlacementSelectsPointerScreenAndClampsToVisibleFrame() {
        let first = NSRect(x: 0, y: 0, width: 800, height: 600)
        let second = NSRect(x: 800, y: 100, width: 500, height: 400)

        let frame = StandaloneCommandPaletteLayout.frame(
            contentSize: NSSize(width: 720, height: 660),
            pointerLocation: NSPoint(x: 900, y: 200),
            visibleFrames: [first, second]
        )

        XCTAssertEqual(frame.size, second.size)
        XCTAssertTrue(second.contains(frame))
    }

    func testStandalonePaletteContentPreservesOuterPaddingOnCompactFrames() {
        let availableWidth: CGFloat = 500

        XCTAssertEqual(
            UnifiedSearchPaletteLayout.width(for: availableWidth)
                + UnifiedSearchPaletteLayout.outerHorizontalPadding,
            availableWidth
        )
    }

    func testUnifiedPaletteViewportFitsCompleteNavigationRowsWhenSpaceAllows() {
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.resultListHeight(for: 710),
            UnifiedSearchPaletteLayout.maximumResultListHeight
        )
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.resultListHeight(for: 600),
            398
        )
        XCTAssertGreaterThanOrEqual(
            StandaloneCommandPaletteLayout.contentSize.height,
            UnifiedSearchPaletteLayout.maximumResultListHeight
                + UnifiedSearchPaletteLayout.verticalChromeHeight
        )
    }

    func testStandalonePaletteUsesStoredAppearanceOnItsPanelAndContent() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAppearancePreference.light.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        let router = makeRouter(defaults: defaults)

        router.toggleCommandPalette()
        let panel = try XCTUnwrap(router.commandPalettePanel)

        XCTAssertEqual(panel.appearance?.name, .aqua)
        XCTAssertEqual(panel.contentView?.appearance?.name, .aqua)
        router.dismissCommandPalette()
    }

    func testDismissingStandalonePaletteRestoresThePreviousApplication() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var restorationCount = 0
        let focusRestoration = StandaloneCommandPaletteFocusRestoration(
            captureRestoration: { { restorationCount += 1 } },
            canRestore: { true }
        )
        let router = makeRouter(
            defaults: defaults,
            commandPaletteFocusRestoration: focusRestoration
        )

        router.toggleCommandPalette()
        router.dismissCommandPalette()

        XCTAssertEqual(restorationCount, 1)
    }

    func testSuccessfulStandalonePaletteActionRestoresOnlyWhilePaletteOwnsFocus() {
        XCTAssertTrue(
            StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
                .shouldRestorePreviousApplication(
                    paletteIsKey: true,
                    applicationIsActive: true
                )
        )
        XCTAssertFalse(
            StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
                .shouldRestorePreviousApplication(
                    paletteIsKey: false,
                    applicationIsActive: true
                )
        )
        XCTAssertFalse(
            StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
                .shouldRestorePreviousApplication(
                    paletteIsKey: true,
                    applicationIsActive: false
                )
        )
    }

    func testOpeningSettingsFromStandalonePaletteDoesNotRestoreThePreviousApplication() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var restorationCount = 0
        let focusRestoration = StandaloneCommandPaletteFocusRestoration(
            captureRestoration: { { restorationCount += 1 } },
            canRestore: { true }
        )
        let router = makeRouter(
            defaults: defaults,
            commandPaletteFocusRestoration: focusRestoration
        )

        router.toggleCommandPalette()
        router.presentSettings(.general)

        XCTAssertEqual(restorationCount, 0)
        router.settingsWindow?.close()
    }

    func testStandalonePaletteUsesRightToLeftLayoutForArabicLocale() {
        XCTAssertEqual(
            StandaloneCommandPaletteRootView.layoutDirection(for: Locale(identifier: "ar")),
            .rightToLeft
        )
        XCTAssertEqual(
            StandaloneCommandPaletteRootView.layoutDirection(for: Locale(identifier: "en")),
            .leftToRight
        )
    }

    func testStandalonePaletteStateResetsAndRefocusesForEveryPresentation() {
        let state = StandaloneCommandPaletteState()
        state.prepareForPresentation(shortcutLabel: "⌥⌘P")
        let firstResetRequestID = state.resetRequestID
        let firstFocusRequestID = state.focusRequestID
        XCTAssertTrue(state.requestQuickSelection(number: 2))

        state.prepareForPresentation(shortcutLabel: "⌃⌥P")

        XCTAssertGreaterThan(state.resetRequestID, firstResetRequestID)
        XCTAssertGreaterThan(state.focusRequestID, firstFocusRequestID)
        XCTAssertNil(state.quickSelectionRequest)
        XCTAssertEqual(state.presentationOrigin, .globalShortcut("⌃⌥P"))
        XCTAssertEqual(state.shortcutHint, "⌃⌥P")
    }

    func testStandalonePaletteDismissalExplicitlyCancelsOnlyPendingSurfaceWork() {
        let state = StandaloneCommandPaletteState()
        var cancellationCount = 0
        state.setPendingExecutionCancellation { cancellationCount += 1 }

        state.prepareForDismissal()
        state.prepareForDismissal()

        XCTAssertEqual(cancellationCount, 1)
    }

    func testAppDeactivationDismissesStandalonePalette() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.toggleCommandPalette()
        let panel = try XCTUnwrap(router.commandPalettePanel)
        XCTAssertTrue(panel.isVisible)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApplication.shared
        )
        await Task.yield()

        XCTAssertFalse(panel.isVisible)
    }

    func testPhysicalCommandNumbersSelectSettingsPagesInVisualOrder() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_2),
                    characters: "@",
                    windowNumber: window.windowNumber
                )
            )
        )
        XCTAssertEqual(coordinator.destination, .plugins(.automation))

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_4),
                    characters: "$",
                    windowNumber: window.windowNumber
                )
            )
        )
        XCTAssertEqual(coordinator.destination, .plugins(.actionsAndShortcuts))

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_LeftBracket),
                    characters: "[",
                    windowNumber: window.windowNumber
                )
            )
        )
        XCTAssertEqual(coordinator.destination, .plugins(.automation))

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_DownArrow),
                    characters: "",
                    modifiers: [.control, .command],
                    windowNumber: window.windowNumber
                )
            )
        )
        XCTAssertEqual(coordinator.destination, .about)

        window.close()
    }

    func testNavigationShortcutsDoNotMoveBehindUnifiedSearch() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        coordinator.navigate(to: .plugins(.automation))
        coordinator.navigate(to: .about)
        coordinator.goBack()
        XCTAssertTrue(coordinator.canGoBack)
        XCTAssertTrue(coordinator.canGoForward)
        let expectedDestination = coordinator.destination
        let expectedHistoryIndex = coordinator.historyIndex

        coordinator.presentUnifiedSearch(origin: .keyboard)

        for event in [
            keyEvent(
                keyCode: UInt16(kVK_ANSI_LeftBracket),
                characters: "[",
                windowNumber: window.windowNumber
            ),
            keyEvent(
                keyCode: UInt16(kVK_ANSI_RightBracket),
                characters: "]",
                windowNumber: window.windowNumber
            ),
            keyEvent(
                keyCode: UInt16(kVK_DownArrow),
                characters: "",
                modifiers: [.control, .command],
                windowNumber: window.windowNumber
            )
        ] {
            _ = window.performKeyEquivalent(with: event)
            XCTAssertEqual(coordinator.destination, expectedDestination)
            XCTAssertEqual(coordinator.historyIndex, expectedHistoryIndex)
        }

        window.close()
    }

    func testCommandFFallsBackToUnifiedSettingsSearch() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "f",
                    windowNumber: window.windowNumber
                )
            )
        )
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.unifiedSearchPresentationOrigin, .keyboard)

        window.close()
    }

    func testAppUpdateRequestNavigatesDirectlyToAbout() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = AppUpdater(startingUpdater: false)
        updater.setAvailableUpdateVersionForTests("1.2.3")
        let router = makeRouter(defaults: defaults, appUpdater: updater)

        router.presentSettings(.appUpdate)

        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .about)
        router.settingsWindow?.close()
    }

    func testExplicitGeneralAndAboutRequestsSelectTheirSettingsDestinations() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.presentSettings(.about)
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .about)

        router.presentSettings(.general)
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .general)

        router.settingsWindow?.close()
    }

    func testExplicitSettingsRequestsDismissUnifiedSearchInArrivalOrder() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showUnifiedSearch()
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)

        router.presentSettings(.general)
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)

        router.showUnifiedSearch()
        router.presentSettings(.settings)
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)

        router.settingsWindow?.close()
    }

    func testSettingsWindowLayoutTargetRequiresVisibleKeyWindowWithoutUnifiedSearch() {
        XCTAssertTrue(
            AppWindowRouter.isEligibleFocusedWindowLayoutTarget(
                isKeyWindow: true,
                isVisible: true,
                isUnifiedSearchPresented: false
            )
        )
        XCTAssertFalse(
            AppWindowRouter.isEligibleFocusedWindowLayoutTarget(
                isKeyWindow: false,
                isVisible: true,
                isUnifiedSearchPresented: false
            )
        )
        XCTAssertFalse(
            AppWindowRouter.isEligibleFocusedWindowLayoutTarget(
                isKeyWindow: true,
                isVisible: false,
                isUnifiedSearchPresented: false
            )
        )
        XCTAssertFalse(
            AppWindowRouter.isEligibleFocusedWindowLayoutTarget(
                isKeyWindow: true,
                isVisible: true,
                isUnifiedSearchPresented: true
            )
        )
    }

    func testGlobalSearchRefreshesOnlyAppleShortcutsActions() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appleShortcuts = RefreshCountingPlugin(id: "apple-shortcuts")
        let unrelatedPlugin = RefreshCountingPlugin(id: "unrelated")
        let host = PluginHost(
            plugins: [appleShortcuts, unrelatedPlugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let router = AppWindowRouter(
            pluginHost: host,
            appUpdater: AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults
        )
        let appleShortcutsRefreshCount = appleShortcuts.refreshCount
        let unrelatedRefreshCount = unrelatedPlugin.refreshCount

        router.showUnifiedSearch()

        XCTAssertEqual(appleShortcuts.refreshCount, appleShortcutsRefreshCount + 1)
        XCTAssertEqual(unrelatedPlugin.refreshCount, unrelatedRefreshCount)
        router.settingsWindow?.close()
    }

    private func makeRouter(
        defaults: UserDefaults,
        appUpdater: AppUpdater? = nil,
        commandPaletteFocusRestoration: StandaloneCommandPaletteFocusRestoration? = nil,
        configureHost: (PluginHost) -> Void = { _ in }
    ) -> AppWindowRouter {
        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        configureHost(host)
        return AppWindowRouter(
            pluginHost: host,
            appUpdater: appUpdater ?? AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults,
            commandPaletteFocusRestoration: commandPaletteFocusRestoration ?? .init()
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

@MainActor
private final class RefreshCountingPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var refreshCount = 0

    init(id: String) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "bolt",
            iconTint: .accentColor,
            order: 0,
            defaultDescription: id
        )
    }

    func refresh() {
        refreshCount += 1
    }
}

@MainActor
private final class AppWindowRouterFakeLaunchAtLoginService: LaunchAtLoginServicing {
    private var registered = false

    var isRegistered: Bool { registered }

    func register() throws {
        registered = true
    }

    func unregister() throws {
        registered = false
    }
}
