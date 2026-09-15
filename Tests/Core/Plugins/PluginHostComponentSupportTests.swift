import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
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

    func testPermissionPresentationUsesStableCapabilityIDsForLegacyPluginKitKinds() {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "full-disk-access",
                    kind: .automation,
                    title: "完全磁盘访问权限",
                    description: "需要完全磁盘访问权限。"
                ),
                PluginPermissionRequirement(
                    id: "finder-extension",
                    kind: .automation,
                    title: "Finder 扩展",
                    description: "需要启用 Finder 扩展。"
                )
            ]
        )

        let cards = makeHost(plugins: [plugin]).permissionCards

        XCTAssertEqual(cards.map(\.permissionID), ["full-disk-access", "finder-extension"])
        XCTAssertEqual(cards.map(\.iconSystemImage), [
            "externaldrive.badge.checkmark",
            "puzzlepiece.extension"
        ])
    }

    func testPermissionRefreshClearsSettingsGuidanceAfterGrant() throws {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [.init(
                id: "input-monitoring",
                kind: .inputMonitoring,
                title: "Input Monitoring",
                description: "Read input events."
            )],
            settingsPage: .form(description: "Component settings", sections: []),
            isPermissionGranted: false
        )
        let host = makeHost(plugins: [plugin])
        let refreshCallCount = plugin.refreshCallCount
        XCTAssertEqual(host.pluginSettingsItems.first?.missingPermissionCards.count, 1)

        plugin.isPermissionGranted = true
        host.permissionCoordinator.refresh()

        XCTAssertEqual(host.permissionCoordinator.items.first?.status, .granted)
        XCTAssertEqual(host.permissionCards.first?.statusTone, .positive)
        let settings = try XCTUnwrap(host.pluginSettingsItems.first)
        XCTAssertEqual(settings.permissionCards.first?.statusTone, .positive)
        XCTAssertTrue(settings.missingPermissionCards.isEmpty)
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertTrue(plugin.handledPermissionIDs.isEmpty)
    }

    func testPermissionRefreshAddsSettingsGuidanceAfterRevocation() throws {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [.init(
                id: "input-monitoring",
                kind: .inputMonitoring,
                title: "Input Monitoring",
                description: "Read input events."
            )]
        )
        let host = makeHost(plugins: [plugin])
        let refreshCallCount = plugin.refreshCallCount
        XCTAssertTrue(host.pluginSettingsItems.isEmpty)

        plugin.isPermissionGranted = false
        host.permissionCoordinator.refresh()

        XCTAssertEqual(host.permissionCoordinator.items.first?.status, .attention)
        let settings = try XCTUnwrap(host.pluginSettingsItems.first)
        XCTAssertEqual(settings.missingPermissionCards.map(\.permissionID), ["input-monitoring"])
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertTrue(plugin.handledPermissionIDs.isEmpty)
    }

    func testPermissionRecheckPublishesSynchronousPluginRefreshChanges() throws {
        let plugins = ["first", "second"].map { id in
            MockComponentPanelPlugin(
                id: id,
                isActive: true,
                permissionRequirements: [.init(
                    id: "input-monitoring",
                    kind: .inputMonitoring,
                    title: "Input Monitoring",
                    description: "Read input events."
                )]
            )
        }
        let host = makeHost(plugins: plugins)
        let refreshCallCounts = plugins.map(\.refreshCallCount)
        XCTAssertTrue(host.componentItems.allSatisfy(\.isActive))
        XCTAssertTrue(host.pluginSettingsItems.isEmpty)
        for plugin in plugins {
            plugin.onRefresh = { [weak plugin] in
                plugin?.isPermissionGranted = false
                plugin?.isActive = false
                plugin?.onStateChange?()
            }
        }

        let permission = try XCTUnwrap(host.permissionCoordinator.items.first)
        host.permissionCoordinator.performAction(for: permission)

        XCTAssertEqual(plugins.map(\.refreshCallCount), refreshCallCounts.map { $0 + 1 })
        XCTAssertEqual(host.permissionCoordinator.items.first?.status, .attention)
        XCTAssertEqual(host.pluginSettingsItems.count, 2)
        XCTAssertTrue(host.pluginSettingsItems.allSatisfy {
            $0.missingPermissionCards.map(\.permissionID) == ["input-monitoring"]
        })
        XCTAssertTrue(host.componentItems.allSatisfy { !$0.isActive })
    }

    func testPluginSettingsExposeOnlyMissingPermissionsForTopGuidance() throws {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "accessibility",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ],
            isPermissionGranted: false
        )

        let item = try XCTUnwrap(makeHost(plugins: [plugin]).pluginSettingsItems.first)

        XCTAssertEqual(item.permissionCards.map(\.permissionID), ["accessibility"])
        XCTAssertEqual(item.missingPermissionCards.map(\.permissionID), ["accessibility"])
    }

    func testNativeFinderExtensionPermissionUsesExtensionPresentation() {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "native-extension",
                    kind: .finderExtension,
                    title: "Finder Extension",
                    description: "Enable the Finder extension."
                )
            ]
        )
        let cards = makeHost(plugins: [plugin]).permissionCards
        XCTAssertEqual(cards.first?.iconSystemImage, "puzzlepiece.extension")
    }

    func testPermissionGuidanceRequestDoesNotChangeSettingsPage() {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "accessibility",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ],
            isPermissionGranted: false
        )
        let host = makeHost(plugins: [plugin])
        var presentationRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { presentationRequests.append($0) }

        plugin.requestPermissionGuidance?("accessibility")

        XCTAssertTrue(presentationRequests.isEmpty)
        XCTAssertEqual(
            host.pluginSettingsItems.first?.missingPermissionCards.map(\.permissionID),
            ["accessibility"]
        )
    }

    func testExplicitAutomationPermissionButtonUsesCoordinatorWithoutPassiveGuidance() {
        let plugin = MockComponentPanelPlugin(
            id: "automation",
            permissionRequirements: [.init(
                id: "automation", kind: .automation, title: "Automation", description: "Allow System Events"
            )],
            isPermissionGranted: false
        )
        var guidedKinds: [HostPermissionKind] = []
        let host = makeHost(
            plugins: [plugin],
            permissionGuidanceHandler: { kind, _ in guidedKinds.append(kind) }
        )
        plugin.requestPermissionGuidance?("automation")
        XCTAssertTrue(guidedKinds.isEmpty)
        host.performPermissionAction(pluginID: "automation", permissionID: "automation")
        XCTAssertEqual(guidedKinds, [.automation])
    }

    func testLegacyFullDiskAccessUsesCoordinatorGuidanceWithSourceFrame() {
        let plugin = MockComponentPanelPlugin(
            id: "disk",
            permissionRequirements: [.init(
                id: "full-disk-access", kind: .automation, title: "Full Disk Access", description: "Protected files"
            )],
            isPermissionGranted: false
        )
        var guidedKinds: [HostPermissionKind] = []
        var sourceFrames: [CGRect?] = []
        let host = makeHost(
            plugins: [plugin],
            permissionGuidanceHandler: { kind, sourceFrame in
                guidedKinds.append(kind)
                sourceFrames.append(sourceFrame)
            }
        )
        let sourceFrame = CGRect(x: 10, y: 20, width: 32, height: 32)

        host.performPermissionAction(
            pluginID: "disk",
            permissionID: "full-disk-access",
            sourceFrame: sourceFrame
        )

        XCTAssertEqual(guidedKinds, [.fullDiskAccess])
        XCTAssertEqual(sourceFrames, [sourceFrame])
        XCTAssertTrue(plugin.handledPermissionIDs.isEmpty)
    }

    func testFinderExtensionPermissionStillUsesPluginAdapterThroughCoordinator() {
        let plugin = MockComponentPanelPlugin(
            id: "finder",
            permissionRequirements: [.init(
                id: "native-extension",
                kind: .finderExtension,
                title: "Finder Extension",
                description: "Enable the Finder extension."
            )],
            isPermissionGranted: false
        )
        var guidedKinds: [HostPermissionKind] = []
        let host = makeHost(
            plugins: [plugin],
            permissionGuidanceHandler: { kind, _ in guidedKinds.append(kind) }
        )

        host.performPermissionAction(pluginID: "finder", permissionID: "native-extension")

        XCTAssertTrue(guidedKinds.isEmpty)
        XCTAssertEqual(plugin.handledPermissionIDs, ["native-extension"])
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

    func testEmbeddedMixedShortcutGroupIsNotRenderedAgainByHost() {
        let queueGroup = PluginShortcutSettingsGroupConfiguration(
            id: "queue",
            title: "Queue",
            actionIDs: ["previous"],
            shortcutDefinitionIDs: ["paste-next"],
            placementAfterSectionID: "queue-settings"
        )
        let generalGroup = PluginShortcutSettingsGroupConfiguration(
            id: "general",
            title: "General",
            actionIDs: [],
            shortcutDefinitionIDs: ["open"]
        )
        func item(isVisible: Bool) -> PluginSettingsPageItem {
            PluginSettingsPageItem(
                id: "component", pluginID: "component", title: "Component",
                description: "", iconName: "clipboard", iconTint: .blue,
                installedAt: nil,
                page: .form(sections: [
                    PluginSettingsSection(
                        id: "queue-settings", isVisible: isVisible,
                        embeddedShortcutGroupIDs: ["queue"]
                    ) { _ in EmptyView() },
                ]),
                permissionCards: [], missingPermissionCardIDs: [], shortcutItems: [],
                actionShortcutSettingsConfiguration: nil,
                shortcutSettingsGroups: [queueGroup, generalGroup],
                shortcutDefinitionFirstSettingsGroupIDs: [],
                collapsibleShortcutSettingsGroupIDs: [],
                collapsibleActionSettingsGroupIDs: []
            )
        }
        XCTAssertEqual(item(isVisible: true).standaloneShortcutSettingsGroups.map(\.id), ["general"])
        XCTAssertEqual(item(isVisible: false).standaloneShortcutSettingsGroups.map(\.id), ["queue", "general"])
        XCTAssertEqual(item(isVisible: true).shortcutSettingsGroups.map(\.id), ["queue", "general"])
    }

    func testEmbeddedActionOnlyShortcutGroupRetainsThePluginSettingsPage() throws {
        let group = PluginShortcutSettingsGroupConfiguration(
            id: "advanced", title: "Advanced", actionIDs: ["pause"]
        )
        let plugin = MockComponentPanelPlugin(
            id: "component",
            settingsPage: .form(sections: [
                PluginSettingsSection(id: "shortcuts", embeddedShortcutGroupIDs: ["advanced"]) { _ in
                    Text("Advanced controls")
                },
            ]),
            shortcutSettingsGroups: [group]
        )
        let host = makeHost(plugins: [plugin])
        let item = try XCTUnwrap(host.pluginSettingsItems.first)
        XCTAssertNotNil(item.page)
        XCTAssertEqual(item.sections.map(\.id), ["shortcuts"])
        XCTAssertEqual(item.integratedShortcutGroupIDs, ["advanced"])
        XCTAssertTrue(item.standaloneShortcutSettingsGroups.isEmpty)
        XCTAssertTrue(item.shortcutItems.isEmpty, "Action-only groups do not require plugin shortcut definitions")
    }

    func testEmbeddingAnUndeclaredShortcutGroupStillRejectsThePage() throws {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            settingsPage: .form(sections: [
                PluginSettingsSection(id: "shortcuts", embeddedShortcutGroupIDs: ["missing"]) { _ in
                    Text("Invalid")
                },
            ]),
            shortcutDefinitions: [shortcutDefinition(id: "open", groupID: "general")]
        )
        let host = makeHost(plugins: [plugin])
        XCTAssertNil(try XCTUnwrap(host.pluginSettingsItems.first).page)
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

    func testPanelEditorMovePersistsAndPreservesHiddenSlotsAndIndependentSurfaces() throws {
        let host = makeHost(plugins: [
            MockCombinedPlugin(id: "first", order: 1),
            MockCombinedPlugin(id: "hidden", order: 2),
            MockCombinedPlugin(id: "last", order: 3)
        ])
        host.setPluginVisible(false, id: "hidden", on: .dashboard)
        let session = PanelLayoutEditingSession()
        let ids = host.componentItems.map(\.id)
        _ = session.begin(id: "last", ids: ids)
        session.preview(offset: 0, ids: ids)
        XCTAssertEqual(host.componentItems.map(\.id), ["first", "last"])
        let move = try XCTUnwrap(session.finish(ids: ids))
        host.movePlugin(id: move.id, toOffset: move.offset, on: .dashboard)
        XCTAssertEqual(host.componentItems.map(\.id), ["last", "first"])
        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["last", "first"])
        XCTAssertEqual(host.dashboardHiddenLayoutItems.map(\.id), ["hidden"])
        XCTAssertEqual(host.panelItems.map(\.id), ["first", "hidden", "last"])

        let reloaded = PluginDisplayPreferencesStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["first", "hidden", "last"]),
                       ["last", "hidden", "first"])
        XCTAssertEqual(reloaded.visiblePluginIDs(for: .dashboard, defaultPluginIDs: ["first", "hidden", "last"]),
                       ["last", "first"])
        host.setPluginVisible(true, id: "hidden", on: .dashboard)
        XCTAssertEqual(host.componentItems.map(\.id), ["last", "hidden", "first"])
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

    func testCopiesShareLifecycleAndRemovingLastCopyDoesNotDeactivatePlugin() throws {
        let plugin = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [plugin])
        let other = try XCTUnwrap(host.addMenuBarPanel())
        let entry = MenuBarPanelEntry(pluginID: "dual", surface: .dashboard)
        let activations = plugin.activateCallCount
        let deactivations = plugin.deactivateCallCount
        host.setVisibleMenuBarPanel("components")
        XCTAssertTrue(host.addPanelEntry(entry, to: "components"))
        XCTAssertTrue(host.addPanelEntry(entry, to: other))
        host.setVisibleMenuBarPanel(other)
        host.setVisibleMenuBarPanel("components")
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component)])
        for copy in host.panelEntries(in: "components") {
            XCTAssertTrue(host.removePanelEntry(copy, from: "components"))
        }
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component), .hidden(.component)])
        XCTAssertTrue(host.componentItems(in: "components").isEmpty)
        // A hidden copy must not keep foreground work alive, but remains available.
        host.setVisibleMenuBarPanel(other)
        XCTAssertEqual(plugin.surfaceEvents.last, .visible(.component))
        XCTAssertTrue(host.removePanelEntry(try XCTUnwrap(host.panelEntries(in: other).first), from: other))
        XCTAssertEqual(plugin.surfaceEvents.last, .hidden(.component))
        XCTAssertTrue(host.availableComponentItems.contains { $0.id == "dual" })
        XCTAssertEqual(plugin.activateCallCount, activations)
        XCTAssertEqual(plugin.deactivateCallCount, deactivations)
        XCTAssertEqual(host.panelItems(in: "features").map(\.id), ["dual"])
    }

    func testDeletingVisiblePanelKeepsMigratedWidgetForeground() throws {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        let panel = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "component", surface: .dashboard, to: panel)
        host.setVisibleMenuBarPanel(panel)
        XCTAssertNil(host.deleteMenuBarPanel(id: panel))
        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["component"])
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component)], "Fallback keeps the same logical consumer alive")
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel(nil)
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component), .hidden(.component)])
    }

    func testSurfaceSwitchAcquiresNewConsumerBeforeReleasingOldConsumer() {
        let plugin = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [plugin])
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel("features")
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component), .visible(.primary), .hidden(.component)])
    }

    func testLifecycleCallbacksCanRefreshHostWithoutBeingDeliveredTwice() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        plugin.onSurfaceVisible = { [weak host] in host?.refreshAll() }
        host.setVisibleMenuBarPanel("components")
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component)])
        host.setVisibleMenuBarPanel(nil)
        XCTAssertEqual(plugin.surfaceEvents, [.visible(.component), .hidden(.component)])
    }

    func testReentrantPanelCloseNeverHidesAConsumerThatWasNotShown() {
        let plugins = [MockComponentPanelPlugin(id: "one"), MockComponentPanelPlugin(id: "two")]
        let host = makeHost(plugins: plugins)
        for plugin in plugins {
            plugin.onSurfaceVisible = { [weak host] in host?.setVisibleMenuBarPanel(nil) }
        }
        host.setVisibleMenuBarPanel("components")
        XCTAssertEqual(plugins.filter { !$0.surfaceEvents.isEmpty }.count, 1)
        for plugin in plugins where !plugin.surfaceEvents.isEmpty {
            XCTAssertEqual(plugin.surfaceEvents, [.visible(.component), .hidden(.component)])
        }
    }

    func testLayoutOnlyChangesPublishOneCompleteSnapshotWithoutRebuildingSettings() throws {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        var settingsUpdates = 0
        var entries: [[MenuBarPanelEntry]] = []
        let settings = host.$pluginSettingsItems.dropFirst().sink { _ in settingsUpdates += 1 }
        let panels = host.menuBarPanelContentDidChange.sink { entries.append(host.panelEntries(in: "components")) }
        let refreshCount = plugin.refreshCallCount
        let original = try XCTUnwrap(host.panelEntries(in: "components").first)
        XCTAssertTrue(host.addPanelEntry(original, to: "components"))
        XCTAssertTrue(host.removePanelEntry(original, from: "components"))
        XCTAssertEqual(entries.map(\.count), [2, 1])
        XCTAssertNotNil(entries.last?.first?.instanceID)
        XCTAssertEqual(settingsUpdates, 0)
        XCTAssertEqual(plugin.refreshCallCount, refreshCount)
        XCTAssertEqual(host.panelLayoutEntries(in: "components").map(\.id), entries.last?.map(\.id))
        withExtendedLifetime((settings, panels)) {}
    }

    func testLibraryPreviewDoesNotAcquirePanelLifecycle() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        XCTAssertNotNil(host.componentPreviewView(for: "component"))
        XCTAssertEqual(plugin.receivedPanelVisibilityValues, [false])
        XCTAssertTrue(plugin.surfaceEvents.isEmpty)
    }

    func testCustomPanelMovesOnlyOneEntryAndPreservesCachedComponentView() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let activationCount = dual.activateCallCount
        let deactivationCount = dual.deactivateCallCount
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        _ = host.componentViewItem(for: "dual", dismiss: {})
        host.assignPanelEntry(pluginID: "dual", surface: .dashboard, to: panelID)
        XCTAssertTrue(host.componentItems(in: "components").isEmpty)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.id), ["dual"])
        XCTAssertEqual(host.panelItems(in: "features").map(\.id), ["dual"])
        XCTAssertTrue(host.panelItems(in: panelID).isEmpty)
        XCTAssertTrue(host.isComponentViewCached(for: "dual"))
        XCTAssertEqual(dual.activateCallCount, activationCount)
        XCTAssertEqual(dual.deactivateCallCount, deactivationCount)
    }

    func testCustomPanelVisibilityOnlyNotifiesAssignedEntries() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "dual", surface: .dashboard, to: panelID)
        host.setVisibleMenuBarPanel("features")
        host.setVisibleMenuBarPanel(panelID)
        host.setVisibleMenuBarPanel(panelID)
        host.setVisibleMenuBarPanel(nil)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .visible(.primary) }.count, 1)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .hidden(.primary) }.count, 1)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .visible(.component) }.count, 1)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .hidden(.component) }.count, 1)
    }

    func testDeletingMixedPanelReturnsHiddenAndVisibleEntriesToDefaults() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "dual")])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "dual", surface: .dashboard, to: panelID)
        host.assignPanelEntry(pluginID: "dual", surface: .featurePanel, to: panelID)
        host.setPluginVisible(false, id: "dual", on: .dashboard)
        host.deleteMenuBarPanel(id: panelID)
        XCTAssertEqual(host.panelItems(in: "features").map(\.id), ["dual"])
        XCTAssertTrue(host.componentItems(in: "components").isEmpty)
        XCTAssertEqual(host.panelLayoutItems(in: "components", surface: .dashboard, hidden: true).map(\.id), ["dual"])
    }

    func testMixedPanelHasIndependentOrdersAndMovingAppendsEntry() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "one", order: 1), MockCombinedPlugin(id: "two", order: 2)])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        for id in ["one", "two"] {
            for surface in PluginDisplaySurface.allCases { host.assignPanelEntry(pluginID: id, surface: surface, to: panelID) }
        }
        host.movePanelEntry(pluginID: "two", surface: .dashboard, panelID: panelID, toOffset: 0)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.id), ["two", "one"])
        XCTAssertEqual(host.panelItems(in: panelID).map(\.id), ["one", "two"])
        host.assignPanelEntry(pluginID: "one", surface: .dashboard, to: "components")
        XCTAssertEqual(host.componentItems(in: "components").map(\.id), ["one"])
        XCTAssertEqual(host.componentItems(in: panelID).map(\.id), ["two"])
    }

    func testRestoreDefaultPanelsResetsLayoutAndRemovesOnlyCustomPanelShortcuts() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let custom = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "dual", surface: .dashboard, to: custom)
        host.assignPanelEntry(pluginID: "dual", surface: .featurePanel, to: custom)
        host.setPluginVisible(false, id: "dual", on: .dashboard)
        var original = host.menuBarPanels[0]
        original.name = "Renamed"
        original.systemImage = "heart"
        original.isHidden = true
        host.updateMenuBarPanel(original)
        host.moveMenuBarPanel(id: custom, toOffset: 0)
        let customReference = host.panelActionReference(id: custom)
        let defaultReference = host.panelActionReference(id: "features")
        let customBinding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        let defaultBinding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(customBinding, for: customReference))
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(defaultBinding, for: defaultReference))
        let activationCount = dual.activateCallCount
        let deactivationCount = dual.deactivateCallCount

        XCTAssertNil(host.restoreDefaultMenuBarPanelLayout())
        XCTAssertEqual(host.menuBarPanels, MenuBarPanelConfiguration().displayPanels)
        XCTAssertEqual(host.menuBarPanelStore.configuration, MenuBarPanelConfiguration())
        XCTAssertNil(host.actionShortcutSettingsItem(for: customReference))
        XCTAssertEqual(host.actionShortcutSettingsItem(for: defaultReference)?.assignment.binding, defaultBinding)
        XCTAssertEqual(host.panelLayoutEntries(in: "components", hidden: true).map { $0.item.id }, ["dual"])
        XCTAssertEqual(host.panelItems(in: "features").map(\.id), ["dual"])
        XCTAssertEqual(dual.activateCallCount, activationCount)
        XCTAssertEqual(dual.deactivateCallCount, deactivationCount)
        XCTAssertEqual(MenuBarPanelStore(userDefaults: UserDefaults(suiteName: suiteName)!).configuration, MenuBarPanelConfiguration())
    }

    func testCustomPanelShortcutsUseRegistryAndRejectConflicts() throws {
        let host = makeHost()
        let first = try XCTUnwrap(host.addMenuBarPanel())
        let second = try XCTUnwrap(host.addMenuBarPanel())
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: first)))
        XCTAssertNotNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: second)))
        host.deleteMenuBarPanel(id: first)
        XCTAssertNil(host.actionShortcutSettingsItem(for: host.panelActionReference(id: first)))
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: second)))
    }

    func testMixedPanelSharesOneOrderAcrossSettingsAndRendering() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "one", order: 1), MockCombinedPlugin(id: "two", order: 2)])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "one", surface: .dashboard, to: panelID)
        host.assignPanelEntry(pluginID: "one", surface: .featurePanel, to: panelID)
        host.assignPanelEntry(pluginID: "two", surface: .dashboard, to: panelID)
        let original = host.panelEntries(in: panelID)
        XCTAssertEqual(original.map(\.surface), [.dashboard, .featurePanel, .dashboard])
        XCTAssertEqual(host.panelLayoutEntries(in: panelID).map(\.entry), original)
        host.movePanelEntry(pluginID: "two", surface: .dashboard, panelID: panelID, toOffset: 0)
        let reordered = [original[2], original[0], original[1]]
        XCTAssertEqual(host.panelEntries(in: panelID), reordered)
        host.setPluginVisible(false, id: "one", on: .dashboard)
        XCTAssertEqual(host.panelEntries(in: panelID), [original[2], original[1]])
        XCTAssertEqual(host.panelLayoutEntries(in: panelID, hidden: true).map(\.entry), [original[0]])
        host.movePanelEntry(pluginID: "one", surface: .featurePanel, panelID: panelID, toOffset: 0)
        host.setPluginVisible(true, id: "one", on: .dashboard)
        XCTAssertEqual(host.panelEntries(in: panelID), [original[1], original[0], original[2]])
        host.assignPanelEntry(pluginID: "two", surface: .featurePanel, to: panelID)
        XCTAssertEqual(host.panelEntries(in: panelID).last, MenuBarPanelEntry(pluginID: "two", surface: .featurePanel))
    }

    func testInterleavedPlacementKeepsActionsBetweenCardGrids() throws {
        let span = try XCTUnwrap(PluginComponentSpan(width: 2, height: 12))
        let host = makeHost(plugins: [MockCombinedPlugin(id: "one", order: 1, span: span),
                                     MockCombinedPlugin(id: "two", order: 2, span: span),
                                     MockCombinedPlugin(id: "three", order: 3, span: span)])
        let entries = [MenuBarPanelEntry(pluginID: "one", surface: .dashboard),
                       MenuBarPanelEntry(pluginID: "two", surface: .dashboard),
                       MenuBarPanelEntry(pluginID: "one", surface: .featurePanel),
                       MenuBarPanelEntry(pluginID: "three", surface: .dashboard),
                       MenuBarPanelEntry(pluginID: "two", surface: .featurePanel)]
        let result = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: host.componentItems,
                                                          features: host.panelItems)
        XCTAssertEqual(result.components.map(\.column), [0, 2, 0])
        XCTAssertEqual(result.components[0].yOffset, result.components[1].yOffset)
        let firstAction = try XCTUnwrap(result.featureOffsets["one"])
        let secondAction = try XCTUnwrap(result.featureOffsets["two"])
        let cardHeight = ComponentPanelLayout.itemHeight(for: span)
        XCTAssertEqual(firstAction, cardHeight + ConfiguredMenuBarPanelLayout.itemSpacing)
        XCTAssertGreaterThan(result.components[2].yOffset, firstAction + MenuBarPanelLayout.rowHeight(for: host.panelItems[0]))
        XCTAssertGreaterThan(secondAction, result.components[2].yOffset + cardHeight)
        XCTAssertEqual(result.height, secondAction + MenuBarPanelLayout.rowHeight(for: host.panelItems[1]))
        XCTAssertEqual(result, ConfiguredMenuBarPanelLayout.placement(entries: entries, components: host.componentItems,
                                                                    features: host.panelItems))
    }

    func testRepeatedFeatureRowsKeepTheFullScrollableDocument() async throws {
        let plugin = MockCombinedPlugin(id: "copies", order: 1, span: try XCTUnwrap(PluginComponentSpan(width: 2, height: 12)))
        let host = makeHost(plugins: [plugin])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        for _ in 0..<12 { XCTAssertTrue(host.addPanelEntry(.init(pluginID: "copies", surface: .featurePanel), to: panelID)) }
        let entries = host.panelEntries(in: panelID)
        let expected = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: [], features: host.panelItems).height
        let model = MenuBarUnifiedPanelModel(selectedTab: MenuBarPanelTab(id: panelID), contentHeight: 200,
                                            maximumFeatureListHeight: 200, isPanelVisible: true)
        let root = NSHostingView(rootView: ConfiguredMenuBarPanelsContent(
            pluginHost: host, model: model, contentBodyHeight: 200, onDismiss: {}, onOpenSettings: {},
            onPresentDiskCleanConfiguration: {}, onPresentLaunchControlConfiguration: {}))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 304, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(expected, 200)
        XCTAssertEqual(document.bounds.height, expected, accuracy: 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
    }

    func testDuplicateCardsAndActionsKeepIndependentLayoutEntries() throws {
        let span = try XCTUnwrap(PluginComponentSpan(width: 2, height: 12))
        let plugin = MockCombinedPlugin(id: "copies", order: 1, span: span)
        let host = makeHost(plugins: [plugin])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        for surface in PluginDisplaySurface.allCases {
            for _ in 0..<2 { XCTAssertTrue(host.addPanelEntry(.init(pluginID: "copies", surface: surface), to: panelID)) }
        }
        let entries = host.panelEntries(in: panelID)
        let placement = ConfiguredMenuBarPanelLayout.placement(entries: entries,
            components: host.componentItems(in: panelID), features: host.panelItems(in: panelID))
        XCTAssertEqual(placement.components.count, 2)
        XCTAssertEqual(placement.featureOffsets.count, 2)
        let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(Set(frames.map(\.id)), Set(entries.map(\.id)))
    }

    func testPanelBackupRestoresLayoutAndCustomShortcutTogether() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "dual")])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.assignPanelEntry(pluginID: "dual", surface: .dashboard, to: panelID)
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: panelID)))
        let backup = host.makePreferencesBackup()
        host.deleteMenuBarPanel(id: panelID)
        let result = try host.importPreferences(backup)
        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.id), ["dual"])
        XCTAssertEqual(host.actionShortcutSettingsItem(for: host.panelActionReference(id: panelID))?.assignment.binding, binding)
    }

    private func makeHost(
        plugins: [any MacToolsPlugin] = [],
        dynamicPluginManager: DynamicPluginManager? = nil,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80),
        openPermissionSettings: @escaping (URL) -> Void = { _ in },
        permissionGuidanceHandler: @escaping PermissionCoordinator.GuidanceHandler = { _, _ in }
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
            pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay,
            openPermissionSettings: openPermissionSettings,
            permissionGuidanceHandler: permissionGuidanceHandler
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
    PluginShortcutBindingChangeHandling, PluginGroupedShortcutSettingsProviding,
    PluginDashboardPresenting, PluginComponentDetailPresenting {
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
    let shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestDashboardPresentation: (() -> Void)?
    var requestComponentDetailPresentation: ((String) -> Void)?
    var isActive: Bool
    private(set) var makeViewCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var localizationRefreshCount = 0
    private(set) var receivedPanelVisibilityValues: [Bool] = []
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var shortcutBindingChanges: [ShortcutBindingChange] = []
    var isPermissionGranted: Bool
    var onRefresh: (() -> Void)?
    private(set) var handledPermissionIDs: [String] = []

    var onSurfaceVisible: (() -> Void)?

    init(
        id: String,
        order: Int = 1,
        span: PluginComponentSpan = .oneByOne,
        isActive: Bool = false,
        permissionRequirements: [PluginPermissionRequirement] = [],
        settingsPage: PluginSettingsPage? = nil,
        shortcutDefinitions: [PluginShortcutDefinition] = [],
        shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] = [],
        isPermissionGranted: Bool = true
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
        self.shortcutSettingsGroups = shortcutSettingsGroups
        self.isPermissionGranted = isPermissionGranted
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
        onSurfaceVisible?()
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.hidden(surface))
    }

    func refresh() {
        refreshCallCount += 1
        onRefresh?()
    }

    func refreshLocalization() {
        localizationRefreshCount += 1
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: isPermissionGranted, footnote: nil)
    }

    func handlePermissionAction(id: String) { handledPermissionIDs.append(id) }
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
    let descriptor: PluginComponentDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    init(id: String, order: Int = 1, span: PluginComponentSpan = .oneByOne) {
        descriptor = PluginComponentDescriptor(span: span)
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
        AnyView(
            VStack(spacing: 8) {
                Image(systemName: metadata.iconName).font(.title2)
                Text(context.pluginID).font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(metadata.iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        )
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
