import AppKit
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

private final class ControlledSwitcherTap: WindowSwitcherShortcutListening {
    var onShortcutPressed: @MainActor @Sendable (Bool, Bool, Bool) -> Void = { _, _, _ in }
    var onShortcutReleased: @MainActor @Sendable () -> Void = {}
    var onEscape: @MainActor @Sendable () -> Void = {}
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
    var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func refresh() {}
    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry] { windows }
    func activate(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult {
        activated.append(entry.id)
        return .succeeded
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
        XCTAssertEqual(plugin.session?.results.map(\.id), ["target"])
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testColdStartTimeoutResetsEditingAndAllowsNextInvocation() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.keyWindow)
        tap.onShortcutPressed(false, false, false)
        XCTAssertFalse(tap.isEditing)
        XCTAssertNotNil(plugin.pendingInvocation)
        await eventually { plugin.pendingInvocation == nil }
        XCTAssertFalse(tap.isEditing)
        catalog.windows = [entry("a"), entry("b")]
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.selectedID, "a")
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
        XCTAssertTrue(tap.isEditing)
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
        let session = WindowSwitcherSession(entries: [entry("a"), entry("b")], selectedID: "a", isPersistent: true, originalWindowID: "a")
        overlay.show(session, currentPID: 100, showsPreview: false)
        func command(_ key: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
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
