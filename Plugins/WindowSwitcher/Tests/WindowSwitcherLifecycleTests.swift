import AppKit
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

private final class ControlledSwitcherTap: WindowSwitcherShortcutListening {
    var onShortcutPressed: @MainActor @Sendable (Bool, Bool, Bool) -> Void = { _, _, _ in }
    var onShortcutReleased: @MainActor @Sendable () -> Void = {}
    var onEscape: @MainActor @Sendable () -> Void = {}
    var onAccessibilityRevoked: @MainActor @Sendable () -> Void = {}
    var isRunning = false
    var isEditing = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    var allBinding: ShortcutBinding?
    var currentAppBinding: ShortcutBinding?
    func configure(allBinding: ShortcutBinding?, currentAppBinding: ShortcutBinding?) {
        self.allBinding = allBinding; self.currentAppBinding = currentAppBinding
    }
    func setEditing(_ value: Bool) { isEditing = value }
    func setSessionActive(_ value: Bool) {}
}

@MainActor
private final class ControlledSwitcherCatalog: WindowSwitcherCatalog {
    var onChange: (() -> Void)?
    var focusedWindowID: String? = "a"
    var isInitialDiscoveryComplete = true
    var windows: [WindowSwitcherAppEntry] = []
    var activated: [String] = []
    var activationResult: WindowSwitcherActionResult = .succeeded
    var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func refresh() {}
    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry] { windows }
    func activate(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult {
        activated.append(entry.id)
        return activationResult
    }
    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult { .requested }
    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult { .requested }
}

@MainActor
final class WindowSwitcherLifecycleTests: XCTestCase {
    private final class PermissionFixture {
        var granted = true
    }
    private func entry(_ id: String) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 100, bundleIdentifier: "org.example.test", appName: "Fixture",
                               windowTitle: id, icon: nil, windowElement: nil, isMinimized: false, shortcutToken: nil)
    }
    private func plugin(catalog: ControlledSwitcherCatalog, tap: ControlledSwitcherTap,
                        overlay: WindowSwitcherOverlayController? = nil,
                        trusted: @escaping @MainActor @Sendable () -> Bool = { true }) -> WindowSwitcherPlugin {
        let plugin = WindowSwitcherPlugin(context: PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID,
            storage: WindowSwitcherMemoryStorage()), appCatalog: catalog, overlayController: overlay ?? WindowSwitcherOverlayController(), shortcutTap: tap,
            discoveryTimeout: .milliseconds(30), accessibilityTrusted: trusted)
        // Most lifecycle scenarios below exercise release-to-activate cycling.
        // Search and legacy scenarios opt into their respective mode explicitly.
        plugin.store.setMode(.directCycle)
        plugin.shortcutBindingResolver = { id in
            id == WindowSwitcherConstants.shortcutDefinitionID
                ? WindowSwitcherShortcutBindingStore.defaultBinding : WindowSwitcherShortcutBindingStore.currentAppBinding
        }
        return plugin
    }
    private func eventually(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testLegacySessionRestoresSavedKeyAndKeepsItWhenCatalogRefreshes() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        catalog.windows[0].windowNumber = 1
        catalog.windows[1].windowNumber = 2
        let overlay = WindowSwitcherOverlayController()
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.keyWindow)
        _ = plugin.store.setManualShortcut("cmd+w", for: "a", in: catalog.windows)
        tap.onShortcutPressed(false, false, false)
        await eventually { overlay.isVisible }
        XCTAssertEqual(plugin.session?.usesDirectKeys, true)
        XCTAssertEqual(plugin.session?.entries.first(where: { $0.id == "a" })?.shortcutToken, "cmd+w")
        catalog.windows.reverse()
        catalog.onChange?()
        XCTAssertEqual(plugin.session?.entries.first(where: { $0.id == "a" })?.shortcutToken, "cmd+w")
        tap.onShortcutReleased()
        XCTAssertTrue(overlay.isVisible)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        XCTAssertTrue(overlay.handleChooserShortcut(event))
        await eventually { catalog.activated == ["a"] }
        XCTAssertFalse(overlay.isVisible)
    }

    func testRecentUseSearchStartsAtNextWindowAndFailureDoesNotReopen() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        catalog.activationResult = .failed
        let overlay = WindowSwitcherOverlayController()
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        plugin.store.setSortMode(.recentUse)
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.selectedID, "b")
        await eventually { overlay.isVisible }
        overlay.onSelect?(catalog.windows[1])
        await eventually { catalog.activated == ["b"] }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(plugin.session)
        XCTAssertFalse(overlay.isVisible)
    }

    func testHostResolvedNilAndCustomBindingsAreAuthoritative() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let custom = ShortcutBinding(keyCode: 48, modifiers: [.control, .option])
        plugin.shortcutBindingResolver = { id in id == WindowSwitcherConstants.shortcutDefinitionID ? custom : nil }
        XCTAssertEqual(tap.allBinding, custom)
        XCTAssertNil(tap.currentAppBinding)
        plugin.shortcutBindingResolver = { _ in nil }
        plugin.shortcutBindingDidChange(id: WindowSwitcherConstants.shortcutDefinitionID, binding: nil)
        XCTAssertNil(tap.allBinding)
        XCTAssertNil(tap.currentAppBinding)
    }

    func testExplicitPresetsReplaceCustomBindingAndNotifyRunningTap() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        var binding = ShortcutBinding(keyCode: 40, modifiers: [.control, .option])
        var reject = false
        let itemID = "\(WindowSwitcherConstants.pluginID).shortcut.\(WindowSwitcherConstants.shortcutDefinitionID)"
        plugin.shortcutBindingResolver = { _ in binding }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: WindowSwitcherConstants.pluginID,
                shortcutItems: [ShortcutSettingsItem(id: itemID, pluginID: WindowSwitcherConstants.pluginID,
                    pluginTitle: "Window Switcher", title: "All windows", description: "", bindingText: "",
                    isRequired: true, canClear: false, usesDefaultValue: false, errorMessage: nil)],
                recordShortcut: { id, requested in
                    XCTAssertEqual(id, itemID)
                    if reject { return "Conflict" }
                    binding = requested
                    return nil
                })
        }
        plugin.handleSettingsAction(.setSelection(controlID: "switching-shortcut", optionID: "command-tab"))
        XCTAssertEqual(binding, WindowSwitcherShortcutBindingStore.legacyBinding)
        XCTAssertEqual(tap.allBinding, binding)
        plugin.handleSettingsAction(.setSelection(controlID: "switching-shortcut", optionID: "option-tab"))
        XCTAssertEqual(binding, WindowSwitcherShortcutBindingStore.defaultBinding)
        XCTAssertEqual(tap.allBinding, binding)
        XCTAssertTrue(plugin.store.configuration.usesCompanionDefaults)
        reject = true
        plugin.handleSettingsAction(.setSelection(controlID: "switching-shortcut", optionID: "command-tab"))
        XCTAssertEqual(binding, WindowSwitcherShortcutBindingStore.defaultBinding)
        XCTAssertEqual(tap.allBinding, binding)
    }

    func testCycleReleaseDuringContextMenuDoesNotActivateWindow() async throws {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let overlay = WindowSwitcherOverlayController()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        // Exercise the menu lifecycle in one actor turn. Waiting for the delayed
        // presentation lets unrelated parallel test apps steal focus before the
        // simulated menu opens, which cancels the session for an unrelated reason.
        overlay.show(try XCTUnwrap(plugin.session), currentPID: nil, showsPreview: false)
        XCTAssertTrue(overlay.isVisible)
        let menu = try XCTUnwrap(overlay.contextMenu(forRow: 0))
        overlay.menuWillOpen(menu)
        XCTAssertTrue(tap.isEditing, "Escape must reach native menu tracking")
        tap.onShortcutReleased()
        XCTAssertNotNil(plugin.session)
        XCTAssertTrue(catalog.activated.isEmpty)
        overlay.menuDidClose(menu)
        await eventually { plugin.session == nil }
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testCustomShortcutsNarrowHighlightedAppAndReturnToAllWindows() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let overlay = WindowSwitcherOverlayController()
        let first = entry("original")
        func browser(_ id: String, _ number: UInt32) -> WindowSwitcherAppEntry {
            WindowSwitcherAppEntry(id: id, processIdentifier: 200, bundleIdentifier: "org.example.browser", appName: "Browser", windowTitle: id, icon: nil, windowElement: nil, isMinimized: false, windowNumber: number, shortcutToken: nil)
        }
        catalog.windows = [first, browser("browser-1", 1), browser("browser-2", 2)]
        catalog.focusedWindowID = first.id
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        plugin.shortcutBindingResolver = { id in
            ShortcutBinding(keyCode: id == WindowSwitcherConstants.shortcutDefinitionID ? 40 : 38, modifiers: [.control, .option])
        }
        tap.onShortcutPressed(false, false, false)
        await eventually { overlay.isVisible }
        XCTAssertEqual(plugin.session?.selectedID, "browser-1")
        tap.onShortcutPressed(false, false, true)
        XCTAssertEqual(plugin.session?.scope, .currentApplication(200))
        XCTAssertEqual(plugin.session?.selectedID, "browser-1")
        tap.onShortcutPressed(false, false, true)
        XCTAssertEqual(plugin.session?.selectedID, "browser-2")
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.scope, .all)
        XCTAssertEqual(plugin.session?.selectedID, "browser-2")
        tap.onShortcutReleased()
        XCTAssertTrue(plugin.session?.isPersistent == true)
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testPersistentSessionCyclesWithRepeatedTabWithoutClosing() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b"), entry("c")]
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        plugin.shortcutBindingResolver = { _ in WindowSwitcherShortcutBindingStore.legacyBinding }
        tap.onShortcutPressed(false, false, false)
        XCTAssertTrue(plugin.session?.isPersistent == true)
        let first = plugin.session?.selectedID
        tap.onShortcutPressed(false, false, false)
        XCTAssertNotEqual(plugin.session?.selectedID, first)
        tap.onShortcutPressed(true, false, false)
        XCTAssertEqual(plugin.session?.selectedID, first)
        tap.onShortcutReleased()
        XCTAssertNotNil(plugin.session)
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testPersistentSessionCyclesWithRepeatedGraveWithoutClosing() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b"), entry("c")]
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        plugin.shortcutBindingResolver = { _ in WindowSwitcherShortcutBindingStore.currentAppBinding }
        tap.onShortcutPressed(false, false, false)
        XCTAssertTrue(plugin.session?.isPersistent == true)
        let first = plugin.session?.selectedID
        tap.onShortcutPressed(false, false, false)
        XCTAssertNotEqual(plugin.session?.selectedID, first)
        tap.onShortcutPressed(true, false, false)
        XCTAssertEqual(plugin.session?.selectedID, first)
        tap.onShortcutReleased()
        XCTAssertNotNil(plugin.session)
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testPresetSelectionFollowsActualBindingIncludingCustomAndClearedState() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.shortcutBindingResolver = { _ in WindowSwitcherShortcutBindingStore.legacyBinding }
        XCTAssertEqual(plugin.switchingShortcutSelection, "command-tab")
        plugin.shortcutBindingResolver = { _ in WindowSwitcherShortcutBindingStore.defaultBinding }
        XCTAssertEqual(plugin.switchingShortcutSelection, "option-tab")
        plugin.shortcutBindingResolver = { _ in ShortcutBinding(keyCode: 40, modifiers: [.control, .option]) }
        XCTAssertEqual(plugin.switchingShortcutSelection, "custom")
        plugin.shortcutBindingResolver = { _ in nil }
        XCTAssertEqual(plugin.switchingShortcutSelection, "custom")
    }

    func testColdInvocationWaitsForInitialProcessesInsteadOfFirstFastApp() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.isInitialDiscoveryComplete = false
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        catalog.windows = [entry("other")]
        catalog.onChange?()
        XCTAssertNil(plugin.session)
        XCTAssertNotNil(plugin.pendingInvocation)
        catalog.windows = [entry("a"), entry("b"), entry("other")]
        catalog.isInitialDiscoveryComplete = true
        catalog.onChange?()
        XCTAssertEqual(plugin.session?.selectedID, "b")
    }

    func testCanonicalActionReportsDiscoveryTimeoutInsteadOfSuccess() async throws {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let handle = try plugin.beginAction(ActionInvocation(reference: ActionReference(key: plugin.actionDefinitions[0].key),
                                                             source: .test, mode: .foreground))
        let result = await handle.result()
        guard case .failed = result else { return XCTFail("Empty discovery must not report presentation success") }
        XCTAssertNil(plugin.pendingInvocation)
        XCTAssertNil(plugin.session)
    }

    func testCanonicalCurrentAppUsesHostTargetBeforePalette() async throws {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let application = NSRunningApplication.current
        catalog.windows = [WindowSwitcherAppEntry(id: "target", processIdentifier: application.processIdentifier,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "Target", icon: nil,
            windowElement: nil, isMinimized: false, shortcutToken: nil), entry("other")]
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.focusedWindowTargetProvider = { PluginFocusedWindowTarget(application: application, preferredWindowNumber: 42) }
        let handle = try plugin.beginAction(ActionInvocation(reference: ActionReference(key: ActionKey(
            providerID: WindowSwitcherConstants.pluginID, actionID: WindowSwitcherConstants.currentAppActionID)),
            source: .test, mode: .foreground))
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertNil(plugin.session, "One current-app window must not open a chooser")
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testColdStartTimeoutResetsEditingAndAllowsNextInvocation() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        tap.onShortcutPressed(false, false, false)
        XCTAssertFalse(tap.isEditing)
        XCTAssertNotNil(plugin.pendingInvocation)
        await eventually { plugin.pendingInvocation == nil }
        XCTAssertFalse(tap.isEditing)
        catalog.windows = [entry("a"), entry("b")]
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.selectedID, "b")
    }

    func testQuickReleaseDuringDiscoveryCommitsExactlyOnceWhenSnapshotArrives() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutReleased()
        XCTAssertTrue(catalog.activated.isEmpty)
        catalog.windows = [entry("a"), entry("b")]
        catalog.onChange?()
        await eventually { catalog.activated == ["b"] }
        tap.onShortcutReleased()
        XCTAssertEqual(catalog.activated, ["b"])
    }

    func testUnknownForegroundTargetStartsAtMostRecentWindow() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        catalog.focusedWindowID = nil
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.selectedID, "a")
    }

    func testColdDiscoveryPreservesRepeatedForwardAndReverseSteps() async {
        for directions in [[false, false], [false, false, true], [true, true]] {
            let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
            let plugin = plugin(catalog: catalog, tap: tap)
            for reversed in directions { tap.onShortcutPressed(reversed, false, false) }
            tap.onShortcutReleased()
            catalog.windows = [entry("a"), entry("b"), entry("c"), entry("d")]
            catalog.onChange?()
            let step = directions.reduce(0) { $0 + ($1 ? -1 : 1) }
            let expected = ["a", "b", "c", "d"][(step % 4 + 4) % 4]
            await eventually { catalog.activated == [expected] }
            plugin.deactivate(reason: .hostShutdown)
        }
    }

    func testCancelledColdNavigationDoesNotLeakIntoNextInvocation() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutPressed(false, false, false)
        tap.onEscape()
        tap.onShortcutPressed(false, false, false)
        catalog.windows = [entry("a"), entry("b"), entry("c")]
        catalog.onChange?()
        XCTAssertEqual(plugin.session?.selectedID, "b")
        XCTAssertEqual(plugin.session?.invocationModifiers, .option)
    }

    func testCancelWhileDiscoveringCannotActivateLateResult() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutReleased()
        tap.onEscape()
        catalog.windows = [entry("a"), entry("b")]
        catalog.onChange?()
        await Task.yield()
        XCTAssertNil(plugin.session)
        XCTAssertNil(plugin.pendingInvocation)
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testModifierReleaseAfterEnteringSearchDoesNotCommit() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let overlay = WindowSwitcherOverlayController()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        var session = plugin.session!
        session.beginSearch()
        overlay.onSessionChange?(session)
        tap.onShortcutReleased()
        await Task.yield()
        XCTAssertTrue(catalog.activated.isEmpty)
        XCTAssertTrue(plugin.session?.isPersistent == true)
        XCTAssertFalse(tap.isEditing, "Persistent result navigation must still accept custom scope shortcuts")
    }

    func testPermissionRevocationCancelsOpenSessionAndStopsWorkers() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let permission = PermissionFixture()
        let plugin = plugin(catalog: catalog, tap: tap, trusted: { permission.granted })
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        XCTAssertNotNil(plugin.session)
        permission.granted = false
        catalog.onChange?()
        XCTAssertNil(plugin.session)
        XCTAssertFalse(catalog.isRunning)
        XCTAssertFalse(tap.isRunning)
        tap.onShortcutReleased()
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testNewGestureAfterColdReleaseDoesNotInheritOldStepsOrCommitEarly() async {
        for reversed in [false, true] {
            let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
            let plugin = plugin(catalog: catalog, tap: tap)
            tap.onShortcutPressed(false, false, false)
            tap.onShortcutPressed(false, true, false)
            tap.onShortcutReleased()
            tap.onShortcutPressed(reversed, false, false)
            catalog.windows = [entry("a"), entry("b"), entry("c")]
            catalog.onChange?()
            XCTAssertTrue(catalog.activated.isEmpty)
            XCTAssertEqual(plugin.session?.selectedID, reversed ? "c" : "b")
            tap.onShortcutReleased()
            await eventually { catalog.activated == [reversed ? "c" : "b"] }
            plugin.deactivate(reason: .hostShutdown)
        }
    }

    func testReleaseRechecksPermissionBeforeAnyCatalogNotification() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let permission = PermissionFixture()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap, trusted: { permission.granted })
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        permission.granted = false
        tap.onShortcutReleased()
        await Task.yield()
        XCTAssertTrue(catalog.activated.isEmpty)
        XCTAssertNil(plugin.session)
        XCTAssertFalse(tap.isRunning)
    }

    func testReverseCycleAnchorsToExactWindowWithinSameApplication() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b"), entry("c")]
        catalog.focusedWindowID = "b"
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(true, false, false)
        XCTAssertEqual(plugin.session?.selectedID, "a")
        tap.onShortcutReleased()
        await eventually { catalog.activated == ["a"] }
    }
    func testScopeAndPreviewKeyboardCommandsPreservePersistentSelection() {
        let overlay = WindowSwitcherOverlayController()
        defer { overlay.hide() }
        let windows = [entry("a"), entry("b")].enumerated().map { index, entry in var value = entry; value.windowNumber = UInt32(index + 1); return value }
        let session = WindowSwitcherSession(entries: windows, selectedID: "a", isPersistent: true, originalWindowID: "a")
        overlay.show(session, currentPID: 100, showsPreview: false)
        func command(_ key: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: ["1", "2"].contains(key) ? [.command, .shift] : .command, timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0)!
        }
        XCTAssertTrue(overlay.handleChooserShortcut(command("2")))
        XCTAssertEqual(overlay.session?.scope, .currentApplication(100))
        XCTAssertTrue(overlay.handleChooserShortcut(command("1")))
        XCTAssertEqual(overlay.session?.scope, .all)
        var preview: Bool?
        overlay.onPreviewChange = { preview = $0 }
        XCTAssertTrue(overlay.handleChooserShortcut(command("p")))
        XCTAssertEqual(preview, true)
        XCTAssertTrue(overlay.handleChooserShortcut(command("p")))
        XCTAssertEqual(preview, false)
        XCTAssertTrue(overlay.session?.isPersistent == true)
    }

    func testShortcutSettingsClearlyLabelBothScopes() {
        let plugin = plugin(catalog: ControlledSwitcherCatalog(), tap: ControlledSwitcherTap())
        defer { plugin.deactivate(reason: .hostShutdown) }
        let definitions = plugin.shortcutDefinitions
        XCTAssertEqual(definitions.count, 2)
        XCTAssertTrue(definitions.allSatisfy { $0.settingsControlTitle?.isEmpty == false })
        XCTAssertNotEqual(definitions[0].settingsControlTitle, definitions[1].settingsControlTitle)
    }

}
