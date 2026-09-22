import AppKit
import Combine
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PluginMenuBarIconCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var coordinator: PluginMenuBarIconCoordinator!
    private let light = PluginMenuBarIconRenderContext(
        pointSize: CGSize(width: 24, height: 24), displayScale: 2, appearance: .light
    )

    override func setUpWithError() throws {
        suiteName = "PluginMenuBarIconCoordinatorTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        coordinator = PluginMenuBarIconCoordinator(userDefaults: defaults, updateDelay: .milliseconds(10))
    }

    override func tearDownWithError() throws {
        coordinator.deactivateAll(reason: .hostShutdown)
        coordinator = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testExclusiveClaimRejectsCompetitorWithoutChangingPreferencesOrPlacement() throws {
        let first = IconPlugin(id: "first")
        let second = IconPlugin(id: "second")
        coordinator.synchronize(with: [first, second], pendingPluginIDs: [])
        XCTAssertEqual(first.context.placement(for: "status"), .standalone)
        try first.context.requestPlacement(.primary, for: "status").get()
        let stored = defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey)
        let result = second.context.requestPlacement(.primary, for: "status")
        guard case let .failure(.occupied(owner)) = result else { return XCTFail("Expected an occupied slot") }
        XCTAssertEqual(owner.pluginID, "first")
        XCTAssertEqual(owner.pluginTitle, "First")
        XCTAssertEqual(second.context.placement(for: "status"), .standalone)
        XCTAssertEqual(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey), stored)
        let changes = first.placementChanges
        try first.context.requestPlacement(.primary, for: "status").get()
        XCTAssertEqual(first.placementChanges, changes)
        try first.context.requestPlacement(.standalone, for: "status").get()
        XCTAssertNil(coordinator.primaryIconOwner)
        XCTAssertNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
        XCTAssertEqual(second.context.placement(for: "status"), .standalone)
        try second.context.requestPlacement(.primary, for: "status").get()
    }

    func testUninstallRestoresBeforeTeardownAndRevokesOldCapabilities() throws {
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        let oldContext = plugin.context
        let oldCallback = plugin.onMenuBarIconChange
        try oldContext.requestPlacement(.primary, for: "status").get()
        var restored = false
        coordinator.onPrimaryIconChange = { [unowned self] in
            restored = self.coordinator.snapshot(context: self.light) == nil
        }
        plugin.onContextRevoked = { XCTAssertTrue(restored) }
        coordinator.unregister(pluginID: "first", reason: .uninstalling)
        XCTAssertTrue(restored)
        XCTAssertNil(plugin.menuBarIconHostContext)
        XCTAssertNil(plugin.onMenuBarIconChange)
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginID, "first")
        XCTAssertNotNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
        coordinator.synchronize(with: [], pendingPluginIDs: [])
        XCTAssertNil(coordinator.primaryIconOwner)
        XCTAssertNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
        guard case .failure(.unavailable) = oldContext.requestPlacement(.primary, for: "status") else {
            return XCTFail("Revoked contexts must not acquire the slot")
        }
        oldCallback?("status")
        XCTAssertNil(coordinator.snapshot(context: light))
    }

    func testUninstallingNonOwnerDoesNotTouchSelectedIcon() throws {
        let first = IconPlugin(id: "first")
        let second = IconPlugin(id: "second")
        coordinator.synchronize(with: [first, second], pendingPluginIDs: [])
        try first.context.requestPlacement(.primary, for: "status").get()
        coordinator.unregister(pluginID: "second", reason: .uninstalling)
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginID, "first")
        XCTAssertNotNil(coordinator.snapshot(context: light))
    }

    func testRestartReservesStoredOwnerUntilDiscoveryFinishes() throws {
        let first = IconPlugin(id: "first")
        coordinator.synchronize(with: [first], pendingPluginIDs: [])
        try first.context.requestPlacement(.primary, for: "status").get()
        coordinator.deactivateAll(reason: .hostShutdown)
        coordinator = PluginMenuBarIconCoordinator(userDefaults: defaults)
        let second = IconPlugin(id: "second")
        coordinator.synchronize(with: [second], pendingPluginIDs: nil)
        XCTAssertNil(coordinator.snapshot(context: light))
        guard case .failure(.occupied) = second.context.requestPlacement(.primary, for: "status") else {
            return XCTFail("Load order must not steal the stored selection")
        }
        let restored = IconPlugin(id: "first")
        coordinator.synchronize(with: [second, restored], pendingPluginIDs: [])
        XCTAssertEqual(restored.context.placement(for: "status"), .primary)
        XCTAssertNotNil(coordinator.snapshot(context: light))
    }

    func testMissingOrFailedStoredProviderIsReleasedAfterDiscovery() throws {
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        try plugin.context.requestPlacement(.primary, for: "status").get()
        coordinator.deactivateAll(reason: .hostShutdown)
        coordinator = PluginMenuBarIconCoordinator(userDefaults: defaults)
        coordinator.synchronize(with: [], pendingPluginIDs: [])
        XCTAssertNil(coordinator.primaryIconOwner)
        XCTAssertNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
    }

    func testUpdateKeepsReservationAndRejectsStaleInstanceAfterReplacement() throws {
        let old = IconPlugin(id: "first")
        coordinator.synchronize(with: [old], pendingPluginIDs: [])
        let oldContext = old.context
        let oldCallback = old.onMenuBarIconChange
        try oldContext.requestPlacement(.primary, for: "status").get()
        let generation = coordinator.primaryIconGeneration
        coordinator.unregister(pluginID: "first", reason: .updating)
        coordinator.synchronize(with: [], pendingPluginIDs: ["first"])
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginID, "first")
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginTitle, "First")
        XCTAssertEqual(coordinator.primaryIconOwner?.requiresRestart, true)
        XCTAssertNil(coordinator.snapshot(context: light))
        let replacement = IconPlugin(id: "first")
        coordinator.synchronize(with: [replacement], pendingPluginIDs: [])
        XCTAssertNotEqual(coordinator.primaryIconGeneration, generation)
        XCTAssertEqual(replacement.context.placement(for: "status"), .primary)
        XCTAssertEqual(coordinator.primaryIconOwner?.requiresRestart, false)
        guard case .failure(.unavailable) = oldContext.requestPlacement(.standalone, for: "status") else {
            return XCTFail("Old instances must not release a replacement's ownership")
        }
        oldCallback?("status")
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginID, "first")
    }

    func testUninstallClearsPendingUpdateEvenWithoutLoadedProvider() throws {
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        try plugin.context.requestPlacement(.primary, for: "status").get()
        coordinator.unregister(pluginID: "first", reason: .updating)
        coordinator.unregister(pluginID: "first", reason: .uninstalling)
        coordinator.synchronize(with: [], pendingPluginIDs: [])
        XCTAssertNil(coordinator.primaryIconOwner)
        XCTAssertNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
    }

    func testOwnerPublicationTracksPlacementAndMetadataButNotIconFrames() throws {
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        var changes: [PluginMenuBarIconOwner?] = []
        let subscription = coordinator.$primaryIconOwner.dropFirst().sink { changes.append($0) }
        defer { subscription.cancel() }
        try plugin.context.requestPlacement(.primary, for: "status").get()
        XCTAssertEqual(changes.count, 1)
        plugin.revision = 1
        plugin.onMenuBarIconChange?("status")
        _ = coordinator.snapshot(context: light)
        XCTAssertEqual(changes.count, 1)
        coordinator.unregister(pluginID: "first", reason: .updating)
        XCTAssertEqual(changes.count, 2)
        let pending = try XCTUnwrap(changes.last.flatMap { $0 })
        XCTAssertTrue(pending.requiresRestart)
        XCTAssertEqual(pending.pluginTitle, "First")
        coordinator.refreshPrimaryIconOwner(pluginTitle: "Localized First")
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginTitle, "Localized First")
        XCTAssertEqual(coordinator.primaryIconOwner?.requiresRestart, true)
        coordinator.synchronize(with: [], pendingPluginIDs: [])
        XCTAssertNil(coordinator.primaryIconOwner)
    }

    func testInvalidIconAndUnregisteredIdentifiersCannotAcquireSlot() {
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        plugin.invalidImage = true
        guard case .failure(.invalidIcon) = plugin.context.requestPlacement(.primary, for: "status") else {
            return XCTFail("Expected invalid image rejection")
        }
        guard case .failure(.unavailable) = plugin.context.requestPlacement(.primary, for: "foreign") else {
            return XCTFail("Expected unregistered identifier rejection")
        }
        XCTAssertNil(coordinator.primaryIconOwner)
        XCTAssertNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
    }

    func testIconChangePublishesLatestOwnerSnapshot() async throws {
        let plugin = IconPlugin(id: "first")
        let other = IconPlugin(id: "second")
        coordinator.synchronize(with: [plugin, other], pendingPluginIDs: [])
        try plugin.context.requestPlacement(.primary, for: "status").get()
        let updated = expectation(description: "Latest owner icon is available")
        coordinator.onPrimaryIconChange = { [unowned self] in
            guard coordinator.snapshot(context: light)?.revision == 2 else { return }
            coordinator.onPrimaryIconChange = nil
            updated.fulfill()
        }
        defer { coordinator.onPrimaryIconChange = nil }
        for revision in 1...2 {
            plugin.revision = UInt64(revision)
            plugin.onMenuBarIconChange?("status")
            other.onMenuBarIconChange?("status")
        }
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(coordinator.snapshot(context: light)?.revision, 2)
        XCTAssertEqual(coordinator.primaryIconOwner?.pluginID, plugin.metadata.id)
    }

    func testHostShutdownRevokesCapabilitiesButPreservesSelection() throws {
        let plugin = IconPlugin(id: "first")
        let host = PluginHost(
            plugins: [plugin], shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        try plugin.context.requestPlacement(.primary, for: "status").get()
        plugin.onDeactivate = {
            XCTAssertNil(plugin.menuBarIconHostContext)
            XCTAssertNil(host.menuBarIconCoordinator.snapshot(context: self.light))
        }
        host.deactivateAllPlugins()
        plugin.onDeactivate = nil
        XCTAssertNotNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
    }

    func testUninstallCancelsQueuedIconUpdates() async throws {
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        try plugin.context.requestPlacement(.primary, for: "status").get()
        var changes = 0
        coordinator.onPrimaryIconChange = { changes += 1 }
        plugin.onMenuBarIconChange?("status")
        coordinator.unregister(pluginID: "first", reason: .uninstalling)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes, 1)
        XCTAssertNil(coordinator.snapshot(context: light))
    }

    func testReplacementNeverOverwritesCustomFallbackIcon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: CGSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.red.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 14, height: 14)).fill()
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let source = directory.appendingPathComponent("original.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let settings = MenuBarIconSettings(userDefaults: defaults, rootDirectory: directory)
        settings.importIcon(from: source, for: .light)
        XCTAssertNil(settings.lastErrorMessage)
        let original = settings.imagePayload()
        let plugin = IconPlugin(id: "first")
        coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        try plugin.context.requestPlacement(.primary, for: "status").get()
        XCTAssertNotNil(coordinator.snapshot(context: light))
        XCTAssertEqual(settings.imagePayload(), original)
        coordinator.unregister(pluginID: "first", reason: .uninstalling)
        XCTAssertNil(coordinator.snapshot(context: light))
        XCTAssertEqual(settings.imagePayload(), original)
    }
}

@MainActor
private final class IconPlugin: MacToolsPlugin, PluginMenuBarIconProviding, PluginMenuBarIconHostContextConsuming {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var onMenuBarIconChange: ((String) -> Void)?
    var menuBarIconHostContext: PluginMenuBarIconHostContext? {
        didSet { if menuBarIconHostContext == nil { onContextRevoked?() } }
    }
    var onContextRevoked: (() -> Void)?
    var onDeactivate: (() -> Void)?
    var placementChanges = 0
    var revision: UInt64 = 0
    var invalidImage = false
    var context: PluginMenuBarIconHostContext { menuBarIconHostContext! }
    var menuBarIconDescriptors: [PluginMenuBarIconDescriptor] { [.init(id: "status", title: metadata.title)] }

    init(id: String) {
        metadata = PluginMetadata(id: id, title: id.capitalized, iconName: "circle", iconTint: .green, order: 0, defaultDescription: "Test")
    }

    func deactivate(reason: PluginDeactivationReason) { onDeactivate?() }
    func menuBarIconPlacementDidChange() { placementChanges += 1 }

    func menuBarIcon(for iconID: String, context: PluginMenuBarIconRenderContext) -> PluginMenuBarIconSnapshot? {
        let image = NSImage(size: invalidImage ? .zero : context.pointSize, flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return true
        }
        return .init(revision: revision, image: image, isTemplate: true, tooltip: "Status", accessibilityDescription: "Status")
    }
}
