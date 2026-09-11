import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import MacSettingsPlugin
@testable import AppearancePlugin

@MainActor
final class PluginHostActionExecutionContextTests: XCTestCase {
    func testComposedAppearanceUsesSelectedPolicyWithoutAutomationPermission() async throws {
        let native = HostContextAppearanceController()
        let provider = AppearancePlugin(appearanceController: native)
        let box = MacSettingsActionContextBox()
        let record = try XCTUnwrap(MacSettingsCatalogFactory.make { box.context }["appearance.dark-mode"])
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let plugin = MacSettingsPlugin(controller: controller, actionContextBox: box)
        let host = makePluginHostForTests(plugins: [provider, plugin])
        let current = try await record.adapter.read()
        XCTAssertEqual(current, .choice(id: "auto"))
        let succeeded = await controller.applyAndWait(.choice(id: "light"), to: record)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(native.mode, .light)
        XCTAssertEqual(controller.rowStates[record.id]?.value, .choice(id: "light"))
        _ = host
        controller.deactivate()
    }

    func testCachedFavoritesFollowPreparationCompletionAndCancellation() async throws {
        for cancels in [false, true] {
            let adapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
            let record = makeTestRecord(id: "flag", title: "Flag", adapter: adapter)
            let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
            controller.toggleFavorite(record.id)
            let plugin = MacSettingsPlugin(controller: controller)
            let host = makePluginHostForTests(plugins: [plugin])
            host.setDisclosureExpanded(true, for: plugin.metadata.id)
            try await Task.sleep(for: .milliseconds(350))
            controller.cancelRefresh()
            XCTAssertEqual(host.panelItems.first?.detail?.controls.first?.isEnabled, true)
            adapter.suspendNextRead = true
            controller.preparePlan(for: .init(name: "Busy", entries: [
                .init(settingID: record.id, desiredValue: .boolean(true), category: .finder),
            ]))
            while !adapter.firstReadStarted { await Task.yield() }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(host.panelItems.first?.detail?.controls.first?.isEnabled, false)
            if cancels { controller.cancelOperation() }
            adapter.resumeFirstRead(with: .boolean(false))
            while controller.isPreparingPlan { await Task.yield() }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(host.panelItems.first?.detail?.controls.first?.isEnabled, true)
            if cancels { XCTAssertNil(controller.activePlan) }
            controller.deactivate()
        }
    }

    func testComposedTrueToneVerifiesBeforeDebouncedHostRebuild() async throws {
        let provider = HostContextActionProviderPlugin()
        let box = MacSettingsActionContextBox()
        let record = try XCTUnwrap(MacSettingsCatalogFactory.make { box.context }["display.true-tone"])
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let plugin = MacSettingsPlugin(controller: controller, actionContextBox: box)
        let host = makePluginHostForTests(plugins: [provider, plugin])
        let succeeded = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(provider.desiredValues, [true], "Verification must not roll back a successful provider write")
        XCTAssertEqual(controller.rowStates[record.id]?.value, .boolean(true))
        provider.availability = .unavailable("Unsupported display")
        plugin.actionExecutionCatalogDidChange()
        XCTAssertEqual(controller.rowStates[record.id]?.availability, .providerUnavailable("Unsupported display"))
        provider.availability = .available
        plugin.actionExecutionCatalogDidChange()
        XCTAssertEqual(controller.rowStates[record.id]?.availability, .available)
        _ = host
        controller.deactivate()
    }

    func testProviderNavigationUsesHostSettingsAndMarketplaceFallback() throws {
        let provider = HostContextActionProviderPlugin()
        let consumer = HostContextConsumerPlugin()
        let host = makePluginHostForTests(plugins: [provider, consumer])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }
        let context = try XCTUnwrap(consumer.actionExecutionHostContext)
        context.openProviderSettings(providerID: provider.metadata.id)
        context.openProviderSettings(providerID: "not-installed")
        XCTAssertEqual(requests, [
            .settings(.pluginConfiguration(provider.metadata.id)), .settings(.pluginMarketplace),
        ])
    }

    func testConsumerReceivesLiveCatalogAndExecutionUsesProvider() async throws {
        let provider = HostContextActionProviderPlugin()
        let consumer = HostContextConsumerPlugin()
        let host = makePluginHostForTests(plugins: [provider, consumer])
        let context = try XCTUnwrap(consumer.actionExecutionHostContext)
        let reference = ActionReference(
            key: ActionKey(providerID: provider.metadata.id, actionID: "run")
        )

        XCTAssertEqual(context.item(for: reference)?.reference, reference)
        XCTAssertGreaterThan(consumer.catalogChangeCount, 0)
        let result = await context.execute(reference, source: .test)
        XCTAssertEqual(result, .succeeded(message: "done"))
        XCTAssertEqual(provider.executionCount, 1)
        _ = host
    }
}

@MainActor
private final class HostContextAppearanceController: SystemAppearanceControlling {
    var mode = SystemAppearanceMode.auto
    func read() throws -> SystemAppearanceSnapshot { .init(mode: mode, isDark: mode != .light) }
    func setMode(_ mode: SystemAppearanceMode) throws { self.mode = mode }
}

@MainActor
private final class HostContextConsumerPlugin:
    MacToolsPlugin,
    PluginActionExecutionHostContextConsuming
{
    let metadata = PluginMetadata(
        id: "host-context-consumer",
        title: "Consumer",
        iconName: "arrow.triangle.branch",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Consumes actions"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionExecutionHostContext: PluginActionExecutionHostContext?
    private(set) var catalogChangeCount = 0

    func actionExecutionCatalogDidChange() {
        catalogChangeCount += 1
    }

    func refresh() {}
}

@MainActor
private final class HostContextActionProviderPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "display-true-color",
        title: "Provider",
        iconName: "play.circle",
        iconTint: .green,
        order: 2,
        defaultDescription: "Provides an action"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var executionCount = 0
    private(set) var desiredValues: [Bool] = []
    var availability: ActionAvailability = .available
    var settingsPage: PluginSettingsPage? { .form(description: "Provider settings", sections: []) }

    var actionDefinitions: [ActionDefinition] {
        ["run", "toggle", "set-enabled"].map { id in
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: id),
                title: "Run",
                description: "Run provider action",
                systemImage: "play.circle",
                parameters: id == "set-enabled" ? [.init(id: "enabled", title: "Enabled", kind: .boolean)] : [],
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            )
        }
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        ["run", "toggle"].map { id in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: id)
                ),
                title: "Run",
                presentationState: desiredValues.last == true ? .active : .inactive
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability { availability }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            self?.executionCount += 1
            if case let .boolean(enabled)? = invocation.reference.parameters["enabled"] {
                self?.desiredValues.append(enabled)
            }
            self?.onStateChange?()
            return .succeeded(message: "done")
        }
    }

    func refresh() {}
}
