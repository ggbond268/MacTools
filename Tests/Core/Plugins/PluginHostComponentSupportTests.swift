import AppKit
import SwiftUI
import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostComponentSupportTests: XCTestCase {
    private let suiteName = "PluginHostComponentSupportTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testComponentPanelPluginOnlyAppearsInComponentItems() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.id), ["component"])
        XCTAssertEqual(host.featureManagementItems.map(\.presentation), [.componentPanel])
    }

    func testOptionalDashboardAndComponentDetailPresentationsRouteThroughHost() throws {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        var presentationRequests: [AppPresentationRequest] = []
        var componentDetailRequests: [(pluginID: String, detailID: String)] = []
        host.appPresentationHandler = { presentationRequests.append($0) }
        host.componentDetailPresentationHandler = { pluginID, detailID in
            componentDetailRequests.append((pluginID, detailID))
        }

        plugin.requestDashboardPresentation?()
        plugin.requestComponentDetailPresentation?("cpu")

        XCTAssertEqual(presentationRequests, [.showDashboard])
        XCTAssertEqual(componentDetailRequests.map(\.pluginID), ["component"])
        XCTAssertEqual(componentDetailRequests.map(\.detailID), ["cpu"])

        let content = try XCTUnwrap(
            host.componentDetailContent(pluginID: "component", detailID: "cpu", dismiss: {})
        )
        XCTAssertEqual(content.id, "cpu")
        XCTAssertEqual(content.title, "CPU")
        XCTAssertNil(
            host.componentDetailContent(pluginID: "component", detailID: "unknown", dismiss: {})
        )
    }

    func testRefreshingLocalizationDiscardsCachedComponentViewsWithoutRefreshingPlugin() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])

        _ = host.componentViewItem(for: "component", dismiss: {})
        let makeViewCallCount = plugin.makeViewCallCount
        let refreshCallCount = plugin.refreshCallCount

        host.refreshLocalization()

        XCTAssertFalse(host.isComponentViewCached(for: "component"))
        XCTAssertEqual(plugin.makeViewCallCount, makeViewCallCount)
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertEqual(plugin.localizationRefreshCount, 1)
        XCTAssertTrue(host.componentItems.first?.isActive == false)
    }

    func testComponentOrderUsesDashboardDisplayPreferences() {
        let first = MockComponentPanelPlugin(id: "first", order: 1)
        let second = MockComponentPanelPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.movePlugin(id: "second", toOffset: 0, on: .dashboard)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["second", "first"])
    }

    func testComponentOnlyPluginContributesSettingsPermissionsAndShortcuts() {
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "accessibility",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ],
            settingsPage: .form(
                description: "组件设置说明。",
                sections: [
                    PluginSettingsSection(
                        id: "settings",
                        title: "组件设置",
                        rows: [
                            PluginSettingsRow(
                                id: "settings-action",
                                title: "组件状态",
                                control: .status(
                                    text: "正常",
                                    systemImage: "checkmark",
                                    tone: .positive,
                                    actionTitle: "执行"
                                )
                            )
                        ]
                    )
                ]
            ),
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "shortcut",
                    title: "组件快捷键",
                    description: "触发组件动作。",
                    actionID: "shortcut-action",
                    scope: .whilePluginActive,
                    defaultBinding: nil,
                    isRequired: false
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertEqual(host.permissionCards.map(\.pluginID), ["component"])
        XCTAssertEqual(host.permissionCards.map(\.iconSystemImage), ["accessibility"])
        XCTAssertEqual(host.permissionCards.map(\.iconVisualScale), [1.0])
        XCTAssertEqual(host.shortcutItems.map(\.pluginID), ["component"])
        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["component"])
        XCTAssertEqual(host.pluginSettingsItems.first?.sections.map(\.id), ["settings"])
        XCTAssertEqual(host.pluginSettingsItems.first?.permissionCards.map(\.permissionID), ["accessibility"])
        XCTAssertEqual(host.pluginSettingsItems.first?.shortcutItems.map(\.pluginID), ["component"])
    }

    func testShortcutsInSameSharedBindingGroupCanUseSameBinding() {
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "first",
                    title: "第一个",
                    description: "第一个动作。",
                    actionID: "first",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                ),
                PluginShortcutDefinition(
                    id: "second",
                    title: "第二个",
                    description: "第二个动作。",
                    actionID: "second",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setShortcutBinding(binding, for: "component.shortcut.first")
        host.setShortcutBinding(binding, for: "component.shortcut.second")

        XCTAssertNil(host.shortcutItems.first { $0.id == "component.shortcut.second" }?.errorMessage)
    }

    func testShortcutsInDifferentSharedBindingGroupsStillRejectDuplicateBindings() {
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "first",
                    title: "第一个",
                    description: "第一个动作。",
                    actionID: "first",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                ),
                PluginShortcutDefinition(
                    id: "second",
                    title: "第二个",
                    description: "第二个动作。",
                    actionID: "second",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.up"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setShortcutBinding(binding, for: "component.shortcut.first")
        host.setShortcutBinding(binding, for: "component.shortcut.second")

        XCTAssertNotNil(host.shortcutItems.first { $0.id == "component.shortcut.second" }?.errorMessage)
    }

    func testOpenSettingsShortcutCanBeConfiguredAndCleared() {
        let host = makeHost(plugins: [])
        let binding = ShortcutBinding(keyCode: 1, modifiers: [.command, .option])

        XCTAssertNil(host.setAppShortcutBindingAndReturnError(binding, for: .openSettings))
        XCTAssertEqual(
            host.appShortcutItems.first { $0.action == .openSettings }?.bindingText,
            ShortcutFormatter.displayString(for: binding)
        )
        XCTAssertTrue(host.appShortcutItems.first { $0.action == .openSettings }?.canClear == true)
        XCTAssertNil(host.appShortcutItems.first { $0.action == .openSettings }?.errorMessage)

        host.clearAppShortcut(.openSettings)

        XCTAssertEqual(
            host.appShortcutItems.first { $0.action == .openSettings }?.bindingText,
            ShortcutFormatter.displayString(for: nil)
        )
        XCTAssertFalse(host.appShortcutItems.first { $0.action == .openSettings }?.canClear == true)
    }

    func testPluginsWithoutConfigurationSurfaceAreHiddenFromConfigurationList() {
        let primaryPanelPlugin = MockPrimaryPanelPlugin(id: "feature")
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(
            plugins: [primaryPanelPlugin, componentPanelPlugin]
        )

        XCTAssertTrue(host.pluginSettingsItems.isEmpty)
        XCTAssertFalse(host.hasPluginSettings(pluginID: "component"))
    }

    func testCustomPluginConfigurationContributesConfigurationItemAndCachesView() {
        let configurationCounter = SettingsRenderCounter()
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            settingsPage: customSettingsPage(counter: configurationCounter)
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["component"])
        XCTAssertEqual(host.pluginSettingsItems.first?.description, "自定义配置")
        XCTAssertEqual(host.pluginSettingsItems.first?.hasPluginContent, true)

        _ = host.pluginSettingsContentViewItem(for: "component", sectionID: "custom")
        _ = host.pluginSettingsContentViewItem(for: "component", sectionID: "custom")

        XCTAssertEqual(configurationCounter.callCount, 1)
    }

    func testEmbeddedShortcutSectionKeepsAllShortcutsInContextAndSearchModel() throws {
        let renderCounter = SettingsRenderCounter()
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "devices",
                    embeddedShortcutGroupIDs: ["devices"]
                ) { context in
                    renderCounter.makeView(context: context)
                }
            ]
        )
        let plugin = MockComponentPanelPlugin(
            id: "component",
            settingsPage: page,
            shortcutDefinitions: [
                shortcutDefinition(id: "device", groupID: "devices"),
                shortcutDefinition(id: "general", groupID: "general")
            ]
        )
        let host = makeHost(plugins: [plugin])
        let item = try XCTUnwrap(host.pluginSettingsItems.first)

        XCTAssertEqual(item.shortcutItems.map(\.id), [
            "component.shortcut.device",
            "component.shortcut.general"
        ])
        XCTAssertEqual(item.remainingShortcutItems.map(\.id), ["component.shortcut.general"])

        _ = host.pluginSettingsContentViewItem(for: "component", sectionID: "devices")

        XCTAssertEqual(renderCounter.lastContext?.shortcutItems.count, 2)
    }

    func testDynamicSettingsLayoutMismatchKeepsHostShortcutSurfaceButHidesPluginPage() throws {
        let plugin = MockComponentPanelPlugin(
            id: "dynamic",
            settingsPage: .workspace { _ in Text("Workspace") },
            shortcutDefinitions: [shortcutDefinition(id: "open", groupID: nil)]
        )
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(componentPanel: true, settings: .form),
            store: store
        )
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { records in
                records.map { DynamicPluginLoadResult(record: $0, plugins: [plugin], errorMessage: nil) }
            }
        )
        let host = makeHost(plugins: [], dynamicPluginManager: manager)
        let item = try XCTUnwrap(host.pluginSettingsItems.first)

        XCTAssertNil(item.page)
        XCTAssertEqual(item.shortcutItems.map(\.id), ["dynamic.shortcut.open"])
    }

    func testPluginStateChangesAreCoalescedAndInvalidateDirtyConfigurationViewCache() async {
        let configurationCounter = SettingsRenderCounter()
        let componentPanelPlugin = MutableComponentPanelPlugin(
            id: "component",
            settingsPage: customSettingsPage(counter: configurationCounter)
        )
        let host = makeHost(
            plugins: [componentPanelPlugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )

        _ = host.pluginSettingsContentViewItem(for: "component", sectionID: "custom")
        XCTAssertEqual(configurationCounter.callCount, 1)
        XCTAssertEqual(componentPanelPlugin.componentStateReadCount, 1)

        componentPanelPlugin.isActive = true
        componentPanelPlugin.triggerStateChange()
        componentPanelPlugin.triggerStateChange()
        componentPanelPlugin.triggerStateChange()

        XCTAssertEqual(componentPanelPlugin.componentStateReadCount, 1)

        for _ in 0..<20 where componentPanelPlugin.componentStateReadCount < 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(componentPanelPlugin.componentStateReadCount, 2)
        XCTAssertEqual(host.featureManagementItems.first?.isActive, true)

        _ = host.pluginSettingsContentViewItem(for: "component", sectionID: "custom")

        XCTAssertEqual(configurationCounter.callCount, 2)
    }

    func testPluginStateChangesOnlyReadDirtyPanelState() async throws {
        let changingPlugin = CountingPrimaryPanelPlugin(id: "changing", order: 1)
        let stablePlugin = CountingPrimaryPanelPlugin(id: "stable", order: 2)
        let host = makeHost(
            plugins: [changingPlugin, stablePlugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )
        changingPlugin.panelStateReadCount = 0
        stablePlugin.panelStateReadCount = 0

        changingPlugin.primarySubtitle = "changed"
        changingPlugin.onStateChange?()
        changingPlugin.primarySubtitle = "changed again"
        changingPlugin.onStateChange?()
        changingPlugin.onStateChange?()

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(changingPlugin.panelStateReadCount, 1)
        XCTAssertEqual(stablePlugin.panelStateReadCount, 0)
        XCTAssertEqual(host.panelItems.map(\.description), ["changed again", "Feature stable"])
    }

    func testComponentActiveStateContributesToHasActivePlugin() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component", isActive: true)
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertTrue(host.hasActivePlugin)
        XCTAssertEqual(host.featureManagementItems.first?.isActive, true)
    }

    func testComponentViewsAreCachedForFastPanelPresentation() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertFalse(host.isComponentViewCached(for: "component"))

        let first = host.componentViewItem(for: "component", dismiss: {})
        let second = host.componentViewItem(for: "component", dismiss: {})

        XCTAssertEqual(first.id, "component")
        XCTAssertEqual(second.id, "component")
        XCTAssertEqual(componentPanelPlugin.makeViewCallCount, 1)
        XCTAssertTrue(host.isComponentViewCached(for: "component"))
    }

    func testComponentSurfaceLifecycleEventsAreSentWhenPanelVisibilityChanges() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setPanelSurface(.component, visible: true)
        host.setPanelSurface(.component, visible: true)
        host.setPanelSurface(.component, visible: false)
        host.setPanelSurface(.component, visible: false)

        XCTAssertEqual(componentPanelPlugin.surfaceEvents, [
            .visible(.component),
            .hidden(.component)
        ])
    }

    func testHostClassifiesDashboardFeatureDualAndSettingsOnlyPluginsExactly() {
        let dashboard = MockComponentPanelPlugin(id: "dashboard", order: 1)
        let feature = MockPrimaryPanelPlugin(id: "feature", order: 2)
        let dual = MockCombinedPlugin(id: "dual", order: 3)
        let settingsOnly = MockSettingsOnlyPlugin(id: "settings", order: 4)
        let host = makeHost(plugins: [dashboard, feature, dual, settingsOnly])

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["dashboard", "dual"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["feature", "dual"])
        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["settings"])
        XCTAssertFalse(host.featureManagementItems.contains { $0.id == "settings" })
    }

    func testSurfaceOrdersAreIndependentInDerivedPanelItems() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.movePlugin(id: "second", toOffset: 0, on: .dashboard)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.id), ["first", "second"])

        host.movePlugin(id: "second", toOffset: 0, on: .featurePanel)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.id), ["second", "first"])
    }

    func testUninstallingDynamicPluginRemovesLayoutAndShortcutReferences() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let packageStore = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true),
            store: packageStore
        )
        let shortcutDefinition = PluginShortcutDefinition(
            id: "open",
            title: "Open",
            description: "Open the dynamic plugin.",
            actionID: "open",
            scope: .global,
            defaultBinding: nil,
            isRequired: false
        )
        let plugin = MockPrimaryPanelPlugin(
            id: "dynamic",
            shortcutDefinitions: [shortcutDefinition]
        )
        let manager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: StubDynamicPluginLoader { records in
                records.map { record in
                    DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
                }
            }
        )
        let shortcutStore = ShortcutStore(userDefaults: defaults)
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: shortcutStore,
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let shortcutID = "dynamic.shortcut.open"
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: shortcutID
        )

        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["dynamic"])
        XCTAssertNotNil(shortcutStore.customizations(for: [shortcutID])[shortcutID])

        try host.uninstallDynamicPlugin(pluginID: "dynamic")

        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.shortcutItems.isEmpty)
        XCTAssertTrue(shortcutStore.customizations(for: [shortcutID]).isEmpty)
        XCTAssertTrue(packageStore.installedRecords().isEmpty)
    }

    func testDynamicPluginConfigurationGetterIsNotReadWhenManifestDoesNotDeclareConfiguration() {
        let plugin = ConfigurationTrapPlugin(id: "dynamic")
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true, settings: .none),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: loader
        )
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.panelItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.pluginSettingsItems.isEmpty)
        XCTAssertEqual(plugin.settingsPageReadCount, 0)
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testDynamicSettingsOnlyPluginAppearsOnlyInConfigurationList() {
        let plugin = MockSettingsOnlyPlugin(id: "settings-only", order: 1)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "settings-only",
            bundleName: "SettingsOnly.bundle",
            capabilities: .init(settings: .workspace),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["settings-only"])
        XCTAssertTrue(host.dashboardLayoutItems.isEmpty)
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
        XCTAssertTrue(host.componentItems.isEmpty)
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.featureManagementItems.isEmpty)
    }

    func testDynamicPluginConfigurationUsesLocalizedManifestSummaryForDefaultDescription() {
        let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
        let previousPreference = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set("zh-Hans", forKey: preferenceKey)
        defer {
            if let previousPreference {
                UserDefaults.standard.set(previousPreference, forKey: preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
        }

        let plugin = MockComponentPanelPlugin(
            id: "localized",
            settingsPage: .workspace { _ in
                Text("Settings")
            }
        )
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "localized",
            bundleName: "Localized.bundle",
            capabilities: .init(componentPanel: true, settings: .workspace),
            localizedMetadata: [
                "zh-Hans": PluginLocalizedMetadata(
                    displayName: "本地化插件",
                    summary: "本地化说明"
                ),
            ],
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.pluginSettingsItems.first?.title, "本地化插件")
        XCTAssertEqual(host.pluginSettingsItems.first?.description, "本地化说明")
    }

    func testDeferredDynamicLoadingMigratesLegacyOrderIntoBothSurfaces() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "first",
            bundleName: "First.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        _ = installTestPluginPackage(
            id: "second",
            bundleName: "Second.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [record.id == "first" ? first : second],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let legacyData = try JSONEncoder().encode(
            LegacyDisplayPreferencesFixture(
                orderedPluginIDs: ["second", "first"],
                hiddenPluginIDs: []
            )
        )
        defaults.set(legacyData, forKey: "plugin.display.preferences")
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )

        XCTAssertTrue(host.dashboardLayoutItems.isEmpty)
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)

        host.loadDynamicPluginsIfNeeded()

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.id), ["second", "first"])
    }

    func testLegacyGlobalHiddenPreferenceKeepsDynamicPluginLoadedButHidesItsSurface() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true),
            store: store
        )
        let plugin = MockPrimaryPanelPlugin(id: "dynamic")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let legacyData = try JSONEncoder().encode(
            LegacyDisplayPreferencesFixture(
                orderedPluginIDs: ["dynamic"],
                hiddenPluginIDs: ["dynamic"]
            )
        )
        defaults.set(legacyData, forKey: "plugin.display.preferences")
        defaults.set(["dynamic"], forKey: "plugins.dynamic.disabledPluginIDs")
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.featurePanelHiddenLayoutItems.map(\.id), ["dynamic"])
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .installed)
        XCTAssertEqual(loader.receivedRecordIDs, ["dynamic"])

        host.setPluginVisible(true, id: "dynamic", on: .featurePanel)

        XCTAssertEqual(host.panelItems.map(\.id), ["dynamic"])
    }

    func testDynamicPanelCapabilityMismatchExposesOnlyManifestAndRuntimeIntersection() {
        let plugin = MockCombinedPlugin(id: "dynamic")
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: false, componentPanel: true),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(
            host.dashboardLayoutItems.first?.capabilities,
            PluginHostCapabilities(
                supportsDashboard: true,
                supportsFeaturePanel: false,
                settingsLayout: nil
            )
        )
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private func customSettingsPage(counter: SettingsRenderCounter) -> PluginSettingsPage {
        .form(
            description: "自定义配置",
            sections: [
                PluginSettingsSection(id: "custom") { context in
                    counter.makeView(context: context)
                }
            ]
        )
    }

    private func shortcutDefinition(id: String, groupID: String?) -> PluginShortcutDefinition {
        PluginShortcutDefinition(
            id: id,
            title: id,
            description: id,
            actionID: id,
            scope: .global,
            defaultBinding: nil,
            isRequired: false,
            settingsGroupID: groupID
        )
    }

    private func makeHost(
        plugins: [any MacToolsPlugin] = [],
        dynamicPluginManager: DynamicPluginManager? = nil,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80)
    ) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: plugins,
            dynamicPluginManager: dynamicPluginManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: displayConfigurationObserver,
            displayTopologyRefreshDelay: displayTopologyRefreshDelay,
            pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay
        )
    }

    private func installTestPluginPackage(
        id: String,
        bundleName: String,
        capabilities: PluginPackageManifest.Capabilities = .init(),
        localizedMetadata: [String: PluginLocalizedMetadata]? = nil,
        store: PluginPackageStore
    ) -> PluginPackageRecord {
        let sourceURL = store.rootDirectory
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = sourceURL.appendingPathComponent(bundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: id,
            version: "1.0.0",
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleName,
            capabilities: capabilities,
            localizedMetadata: localizedMetadata
        )
        let data = try? JSONEncoder().encode(manifest)
        try? data?.write(to: sourceURL.appendingPathComponent("plugin.json"))

        return try! store.installPackage(from: sourceURL)
    }
}

private struct LegacyDisplayPreferencesFixture: Codable {
    let orderedPluginIDs: [String]
    let hiddenPluginIDs: Set<String>
}

@MainActor
private final class StubDynamicPluginLoader: DynamicPluginLoading {
    private let handler: ([PluginPackageRecord]) -> [DynamicPluginLoadResult]
    private(set) var receivedRecordIDs: [String] = []

    init(handler: @escaping ([PluginPackageRecord]) -> [DynamicPluginLoadResult]) {
        self.handler = handler
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDs = records.map(\.id)
        return handler(records)
    }
}

@MainActor
private final class MockComponentPanelPlugin: MacToolsPlugin, PluginComponentPanel,
    PluginPanelSurfaceLifecycleHandling, PluginRuntimeLocalizationRefreshing,
    PluginShortcutBindingChangeHandling, PluginDashboardPresenting,
    PluginComponentDetailPresenting {
    struct ShortcutBindingChange: Equatable {
        let id: String
        let binding: ShortcutBinding?
    }
    enum SurfaceEvent: Equatable {
        case visible(PluginPanelSurface)
        case hidden(PluginPanelSurface)
    }

    let metadata: PluginMetadata
    let descriptor: PluginComponentDescriptor
    let permissionRequirements: [PluginPermissionRequirement]
    let shortcutDefinitions: [PluginShortcutDefinition]
    let settingsPage: PluginSettingsPage?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestDashboardPresentation: (() -> Void)?
    var requestComponentDetailPresentation: ((String) -> Void)?
    private let isActive: Bool
    private(set) var makeViewCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var localizationRefreshCount = 0
    private(set) var receivedPanelVisibilityValues: [Bool] = []
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var shortcutBindingChanges: [ShortcutBindingChange] = []

    init(
        id: String,
        order: Int = 1,
        span: PluginComponentSpan = .oneByOne,
        isActive: Bool = false,
        permissionRequirements: [PluginPermissionRequirement] = [],
        settingsPage: PluginSettingsPage? = nil,
        shortcutDefinitions: [PluginShortcutDefinition] = []
    ) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Component \(id)"
        )
        self.descriptor = PluginComponentDescriptor(span: span)
        self.isActive = isActive
        self.permissionRequirements = permissionRequirements
        self.shortcutDefinitions = shortcutDefinitions
        self.settingsPage = settingsPage
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        makeViewCallCount += 1
        receivedPanelVisibilityValues.append(context.isPanelVisible)
        return AnyView(Text(context.pluginID))
    }

    func makeComponentDetailContent(
        detailID: String,
        dismiss: @escaping () -> Void
    ) -> PluginComponentDetailContent? {
        guard detailID == "cpu" else {
            return nil
        }
        return PluginComponentDetailContent(
            id: detailID,
            title: "CPU",
            content: AnyView(Text("CPU detail"))
        )
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.visible(surface))
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.hidden(surface))
    }

    func refresh() {
        refreshCallCount += 1
    }

    func refreshLocalization() {
        localizationRefreshCount += 1
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        shortcutBindingChanges.append(.init(id: id, binding: binding))
    }
}

@MainActor
private final class MutableComponentPanelPlugin: MacToolsPlugin, PluginComponentPanel {
    let metadata: PluginMetadata
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    let settingsPage: PluginSettingsPage?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var isActive = false
    var onComponentStateRead: (() -> Void)?
    private(set) var componentStateReadCount = 0

    init(id: String, settingsPage: PluginSettingsPage? = nil) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: 1,
            defaultDescription: "Component \(id)"
        )
        self.settingsPage = settingsPage
    }

    var componentPanelState: PluginComponentState {
        componentStateReadCount += 1
        onComponentStateRead?()
        return PluginComponentState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func triggerStateChange() {
        onStateChange?()
    }
}

@MainActor
private final class SettingsRenderCounter {
    private(set) var callCount = 0
    private(set) var lastContext: PluginSettingsContext?

    func makeView(context: PluginSettingsContext) -> AnyView {
        callCount += 1
        lastContext = context
        return AnyView(Text(context.pluginID))
    }
}

@MainActor
private final class MockPrimaryPanelPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var refreshCallCount = 0
    private let definedShortcuts: [PluginShortcutDefinition]

    init(
        id: String,
        order: Int = 1,
        shortcutDefinitions: [PluginShortcutDefinition] = []
    ) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Feature \(id)"
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.definedShortcuts = shortcutDefinitions
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Feature subtitle",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { definedShortcuts }

    func refresh() {
        refreshCallCount += 1
    }
    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class CountingPrimaryPanelPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var primarySubtitle: String
    var panelStateReadCount = 0

    init(id: String, order: Int) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Feature \(id)"
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.primarySubtitle = ""
    }

    var primaryPanelState: PluginPanelState {
        panelStateReadCount += 1
        return PluginPanelState(
            subtitle: primarySubtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}
    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class ConfigurationTrapPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling,
        buttonTitle: "执行"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var settingsPageReadCount = 0

    init(id: String) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemIndigo),
            order: 1,
            defaultDescription: "Dynamic \(id)"
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Dynamic subtitle",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var settingsPage: PluginSettingsPage? {
        settingsPageReadCount += 1
        return .workspace(description: "Should not be read") { _ in Text("Unexpected") }
    }

    func handleAction(_ action: PluginPanelAction) {}
}

@MainActor
private final class MockCombinedPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel, PluginPanelSurfaceLifecycleHandling {
    enum SurfaceEvent: Equatable {
        case visible(PluginPanelSurface)
        case hidden(PluginPanelSurface)
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    init(id: String, order: Int = 1) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Combined \(id)"
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Combined subtitle",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: "Combined component subtitle",
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func handleAction(_ action: PluginPanelAction) {}

    func activate(context: PluginRuntimeContext) {
        activateCallCount += 1
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivateCallCount += 1
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.visible(surface))
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.hidden(surface))
    }
}

@MainActor
private final class MockSettingsOnlyPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: Color(nsColor: .systemGray),
            order: order,
            defaultDescription: "Settings \(id)"
        )
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: "Settings only") { _ in Text("Settings") }
    }
}
