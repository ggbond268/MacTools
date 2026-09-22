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

    func testDynamicPhaseShortcutDefaultCannotBypassExistingShortcutConflict() async {
        let initial = ShortcutBinding(keyCode: 48, modifiers: [.option])
        let occupied = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let phase = PhaseShortcutTestPlugin(binding: initial)
        let other = MockComponentPanelPlugin(id: "other", shortcutDefinitions: [
            PluginShortcutDefinition(id: "occupied", title: "Occupied", description: "", actionID: "occupied",
                                     scope: .global, defaultBinding: occupied, isRequired: false)
        ])
        let host = makeHost(plugins: [phase, other])
        XCTAssertEqual(phase.shortcutBindingResolver?("cycle"), initial)
        phase.binding = occupied
        phase.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertNil(phase.shortcutBindingResolver?("cycle"))
        XCTAssertNil(phase.latestBinding)
        XCTAssertGreaterThan(phase.notifications, 0)
        XCTAssertNotNil(host.shortcutItems.first { $0.id == "phase-test.shortcut.cycle" }?.errorMessage)
        phase.binding = initial
        phase.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(phase.latestBinding, initial)
        XCTAssertNil(host.shortcutItems.first { $0.id == "phase-test.shortcut.cycle" }?.errorMessage)
    }

    func testWindowSwitcherReverseChordCannotShadowAnotherPlugin() async {
        let base = ShortcutBinding(keyCode: 48, modifiers: [.option])
        let reverse = ShortcutBinding(keyCode: 48, modifiers: [.option, .shift])
        let switcher = PhaseShortcutTestPlugin(binding: base, id: "window-switcher")
        let other = MockComponentPanelPlugin(id: "other", shortcutDefinitions: [
            PluginShortcutDefinition(id: "occupied", title: "Occupied", description: "", actionID: "occupied",
                                     scope: .global, defaultBinding: reverse, isRequired: false)
        ])
        let host = makeHost(plugins: [switcher, other])
        XCTAssertNil(switcher.shortcutBindingResolver?("cycle"))
        XCTAssertNotNil(host.shortcutItems.first { $0.id == "window-switcher.shortcut.cycle" }?.errorMessage)
        host.clearShortcut(for: "other.shortcut.occupied")
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(switcher.shortcutBindingResolver?("cycle"), base)
        XCTAssertNotNil(host.setShortcutBindingAndReturnError(reverse, for: "other.shortcut.occupied"))
    }

    func testWindowSwitcherReverseChordDetectsCanonicalActionAssignment() {
        let base = ShortcutBinding(keyCode: 48, modifiers: [.option])
        let reverse = ShortcutBinding(keyCode: 48, modifiers: [.option, .shift])
        let switcher = PhaseShortcutTestPlugin(binding: base, id: "window-switcher")
        let host = makeHost(plugins: [switcher])
        XCTAssertEqual(switcher.shortcutBindingResolver?("cycle"), base)
        XCTAssertNil(host.setAppShortcutBindingAndReturnError(reverse, for: .openSettings))
        XCTAssertNil(switcher.shortcutBindingResolver?("cycle"))
        XCTAssertNil(switcher.latestBinding)
        host.clearAppShortcut(.openSettings)
        XCTAssertEqual(switcher.shortcutBindingResolver?("cycle"), base)
    }

    func testComponentPanelPluginOnlyAppearsInComponentItems() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["component"])
        XCTAssertEqual(host.availablePanelItems.map(\.kind), [.widget])
    }

    func testOptionalDashboardAndComponentDetailPresentationsRouteThroughHost() throws {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        var presentationRequests: [AppPresentationRequest] = []
        var componentDetailRequests: [(pluginID: String, detailID: String)] = []
        host.appPresentationHandler = { presentationRequests.append($0) }
        host.componentDetailHandlersByPanelID["components"] = { pluginID, detailID in
            componentDetailRequests.append((pluginID, detailID))
        }

        plugin.requestDashboardPresentation?()
        host.setVisibleMenuBarPanel("components")
        _ = host.componentViewItem(for: host.testEntry(pluginID: "component", kind: .widget).id, dismiss: {})
        plugin.receivedContexts.last?.presentDetail("cpu")

        XCTAssertEqual(presentationRequests, [.showDashboard])
        XCTAssertEqual(componentDetailRequests.map(\.pluginID), [host.testEntry(pluginID: "component", kind: .widget).id])
        XCTAssertEqual(componentDetailRequests.map(\.detailID), ["cpu"])

        let content = try XCTUnwrap(
            host.componentDetailContent(placementID: host.testEntry(pluginID: "component", kind: .widget).id, detailID: "cpu", dismiss: {})
        )
        XCTAssertEqual(content.id, "cpu")
        XCTAssertEqual(content.title, "CPU")
        XCTAssertNil(
            host.componentDetailContent(placementID: host.testEntry(pluginID: "component", kind: .widget).id, detailID: "unknown", dismiss: {})
        )
    }

    func testRefreshingLocalizationDiscardsCachedComponentViewsWithoutRefreshingPlugin() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])

        _ = host.componentViewItem(for: host.testEntry(pluginID: "component", kind: .widget).id, dismiss: {})
        let makeViewCallCount = plugin.makeViewCallCount
        let refreshCallCount = plugin.refreshCallCount

        host.refreshLocalization()

        XCTAssertFalse(host.isComponentViewCached(for: host.testEntry(pluginID: "component", kind: .widget).id))
        XCTAssertEqual(plugin.makeViewCallCount, makeViewCallCount)
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertEqual(plugin.localizationRefreshCount, 1)
        XCTAssertTrue(host.componentItems.first?.isActive == false)
    }

    func testComponentOrderUsesDashboardDisplayPreferences() {
        let first = MockComponentPanelPlugin(id: "first", order: 1)
        let second = MockComponentPanelPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.reorderTestItem(pluginID: "second", kind: .widget, toOffset: 0)

        XCTAssertEqual(host.componentItems.map(\.pluginID), ["second", "first"])
        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["second", "first"])
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
            capabilities: .init(panelItems: [.widget], settings: .form),
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
        let navigation = SettingsNavigationPresentationModel(host: host)
        let marketplace = PluginMarketplacePresentationModel(host: host)
        XCTAssertEqual(navigation.configurationItems.map(\.id), ["component"])
        XCTAssertEqual(marketplace.configurationPluginIDs, ["component"])
        var navigationUpdates = 0
        var marketplaceUpdates = 0
        let navigationSubscription = navigation.objectWillChange.sink { navigationUpdates += 1 }
        let marketplaceSubscription = marketplace.objectWillChange.sink { marketplaceUpdates += 1 }

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
        XCTAssertEqual(host.componentItems.first?.isActive, true)

        _ = host.pluginSettingsContentViewItem(for: "component", sectionID: "custom")

        XCTAssertEqual(configurationCounter.callCount, 2)
        XCTAssertEqual(navigationUpdates, 0, "Live plugin changes must not invalidate navigation")
        XCTAssertEqual(marketplaceUpdates, 0, "Live plugin changes must not invalidate the marketplace")
        withExtendedLifetime((navigationSubscription, marketplaceSubscription)) {}
    }

    func testSettingsPresentationTracksPageAvailabilityWithoutSuppressingContentChanges() async {
        let plugin = MutableComponentPanelPlugin(
            id: "component",
            settingsPage: customSettingsPage(counter: SettingsRenderCounter())
        )
        let host = makeHost(plugins: [plugin])
        let navigation = SettingsNavigationPresentationModel(host: host)
        let marketplace = PluginMarketplacePresentationModel(host: host)
        var navigationSnapshots: [[String]] = []
        var marketplaceSnapshots: [Set<String>] = []
        let navigationSubscription = navigation.$configurationItems.sink {
            navigationSnapshots.append($0.map(\.id))
        }
        let marketplaceSubscription = marketplace.$configurationPluginIDs.sink {
            marketplaceSnapshots.append($0)
        }

        plugin.settingsPage = nil
        plugin.triggerStateChange()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertTrue(host.pluginSettingsItems.isEmpty)

        plugin.settingsPage = customSettingsPage(counter: SettingsRenderCounter())
        plugin.triggerStateChange()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(navigationSnapshots, [["component"], [], ["component"]])
        XCTAssertEqual(marketplaceSnapshots, [["component"], [], ["component"]])
        withExtendedLifetime((navigationSubscription, marketplaceSubscription)) {}
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
        XCTAssertEqual(host.componentItems.first?.isActive, true)
    }

    func testComponentViewsAreCachedForFastPanelPresentation() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertFalse(host.isComponentViewCached(for: host.testEntry(pluginID: "component", kind: .widget).id))

        let first = host.componentViewItem(for: host.testEntry(pluginID: "component", kind: .widget).id, dismiss: {})
        let second = host.componentViewItem(for: host.testEntry(pluginID: "component", kind: .widget).id, dismiss: {})

        XCTAssertEqual(first.id, host.testEntry(pluginID: "component", kind: .widget).id)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(componentPanelPlugin.makeViewCallCount, 1)
        XCTAssertTrue(host.isComponentViewCached(for: host.testEntry(pluginID: "component", kind: .widget).id))
    }

    func testComponentSurfaceLifecycleEventsAreSentWhenPanelVisibilityChanges() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel(nil)
        host.setVisibleMenuBarPanel(nil)

        XCTAssertEqual(componentPanelPlugin.surfaceEvents, [
            .visible("widget"),
            .hidden("widget")
        ])
    }

    func testHostClassifiesDashboardFeatureDualAndSettingsOnlyPluginsExactly() {
        let dashboard = MockComponentPanelPlugin(id: "dashboard", order: 1)
        let feature = MockPrimaryPanelPlugin(id: "feature", order: 2)
        let dual = MockCombinedPlugin(id: "dual", order: 3)
        let settingsOnly = MockSettingsOnlyPlugin(id: "settings", order: 4)
        let host = makeHost(plugins: [dashboard, feature, dual, settingsOnly])

        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["dashboard", "dual"])
        XCTAssertEqual(host.panelEntries(in: "features").map(\.pluginID), ["feature", "dual"])
        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["settings"])
        XCTAssertFalse(host.availablePanelItems.contains { $0.key.pluginID == "settings" })
    }

    func testSurfaceOrdersAreIndependentInDerivedPanelItems() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.reorderTestItem(pluginID: "second", kind: .widget, toOffset: 0)

        XCTAssertEqual(host.componentItems.map(\.pluginID), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.pluginID), ["first", "second"])

        host.reorderTestItem(pluginID: "second", kind: .row, toOffset: 0)

        XCTAssertEqual(host.componentItems.map(\.pluginID), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.pluginID), ["second", "first"])
    }

    func testPanelEditorMovePersistsWithoutChangingOtherPanels() throws {
        let host = makeHost(plugins: [
            MockCombinedPlugin(id: "first", order: 1),
            MockCombinedPlugin(id: "removed", order: 2),
            MockCombinedPlugin(id: "last", order: 3)
        ])
        host.removeTestItem(pluginID: "removed", kind: .widget)
        let session = PanelLayoutEditingSession()
        let ids = host.componentItems.map(\.id)
        let last = host.testEntry(pluginID: "last", kind: .widget)
        _ = session.begin(id: last.id, ids: ids)
        session.preview(offset: 0, ids: ids)
        let move = try XCTUnwrap(session.finish(ids: ids))
        host.movePanelEntry(last, panelID: "components", toOffset: move.offset)
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["last", "first"])
        XCTAssertEqual(host.panelItems.map(\.pluginID), ["first", "removed", "last"])
        let reloaded = MenuBarPanelStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.configuration, host.menuBarPanelStore.configuration)
        XCTAssertTrue(host.addPanelItem(.init(pluginID: "removed", itemID: "widget"), to: "components"))
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["last", "first", "removed"])
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
            capabilities: .init(panelItems: [.row]),
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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let shortcutID = "dynamic.shortcut.open"
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: shortcutID
        )

        XCTAssertEqual(host.panelEntries(in: "features").map(\.pluginID), ["dynamic"])
        XCTAssertNotNil(shortcutStore.customizations(for: [shortcutID])[shortcutID])

        try host.uninstallDynamicPlugin(pluginID: "dynamic")

        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)
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
            capabilities: .init(panelItems: [.row], settings: .none),
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

        XCTAssertEqual(host.panelItems.map(\.pluginID), ["dynamic"])
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
        XCTAssertTrue(host.panelEntries(in: "components").isEmpty)
        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)
        XCTAssertTrue(host.componentItems.isEmpty)
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.availablePanelItems.isEmpty)
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
            capabilities: .init(panelItems: [.widget], settings: .workspace),
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
            capabilities: .init(panelItems: [.row, .widget]),
            store: store
        )
        _ = installTestPluginPackage(
            id: "second",
            bundleName: "Second.bundle",
            capabilities: .init(panelItems: [.row, .widget]),
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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )

        XCTAssertTrue(host.panelEntries(in: "components").isEmpty)
        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)

        host.loadDynamicPluginsIfNeeded()

        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["second", "first"])
        XCTAssertEqual(host.panelEntries(in: "features").map(\.pluginID), ["second", "first"])
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.pluginID), ["second", "first"])
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
            capabilities: .init(panelItems: [.row]),
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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.availablePanelItems.contains { $0.key == .init(pluginID: "dynamic", itemID: "control") })
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .installed)
        XCTAssertEqual(loader.receivedRecordIDs, ["dynamic"])

        host.addPanelItem(.init(pluginID: "dynamic", itemID: "control"), to: "features")

        XCTAssertEqual(host.panelItems.map(\.pluginID), ["dynamic"])
    }

    func testDynamicPanelCapabilityMismatchRejectsTheInvalidCatalog() {
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
            capabilities: .init(panelItems: [.widget]),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertTrue(host.panelEntries(in: "components").isEmpty)
        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)
        XCTAssertTrue(host.availablePanelItems.isEmpty)
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
        let entry = host.testEntry(pluginID: "dual", kind: .widget)
        let activations = plugin.activateCallCount
        let deactivations = plugin.deactivateCallCount
        host.setVisibleMenuBarPanel("components")
        XCTAssertTrue(host.addPanelItem(entry.key, to: "components"))
        XCTAssertTrue(host.addPanelItem(entry.key, to: other))
        host.setVisibleMenuBarPanel(other)
        host.setVisibleMenuBarPanel("components")
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget")])
        for copy in host.panelEntries(in: "components") {
            XCTAssertTrue(host.removePanelEntry(copy, from: "components"))
        }
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget"), .hidden("widget")])
        XCTAssertTrue(host.componentItems(in: "components").isEmpty)
        // A hidden copy must not keep foreground work alive, but remains available.
        host.setVisibleMenuBarPanel(other)
        XCTAssertEqual(plugin.surfaceEvents.last, .visible("widget"))
        XCTAssertTrue(host.removePanelEntry(try XCTUnwrap(host.panelEntries(in: other).first), from: other))
        XCTAssertEqual(plugin.surfaceEvents.last, .hidden("widget"))
        XCTAssertTrue(host.availablePanelItems.contains { $0.key == .init(pluginID: "dual", itemID: "widget") })
        XCTAssertEqual(plugin.activateCallCount, activations)
        XCTAssertEqual(plugin.deactivateCallCount, deactivations)
        XCTAssertEqual(host.panelItems(in: "features").map(\.pluginID), ["dual"])
    }

    func testDeletingVisiblePanelKeepsMigratedWidgetForeground() throws {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        let panel = try XCTUnwrap(host.addMenuBarPanel())
        host.moveTestItem(pluginID: "component", kind: .widget, to: panel)
        host.setVisibleMenuBarPanel(panel)
        XCTAssertNil(host.deleteMenuBarPanel(id: panel))
        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["component"])
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget")], "Fallback keeps the same logical consumer alive")
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel(nil)
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget"), .hidden("widget")])
    }

    func testSurfaceSwitchAcquiresNewConsumerBeforeReleasingOldConsumer() {
        let plugin = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [plugin])
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel("features")
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget"), .visible("control"), .hidden("widget")])
    }

    func testLifecycleCallbacksCanRefreshHostWithoutBeingDeliveredTwice() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        plugin.onSurfaceVisible = { [weak host] in host?.refreshAll() }
        host.setVisibleMenuBarPanel("components")
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget")])
        host.setVisibleMenuBarPanel(nil)
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget"), .hidden("widget")])
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
            XCTAssertEqual(plugin.surfaceEvents, [.visible("widget"), .hidden("widget")])
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
        XCTAssertTrue(host.addPanelItem(original.key, to: "components"))
        XCTAssertTrue(host.removePanelEntry(original, from: "components"))
        XCTAssertEqual(entries.map(\.count), [2, 1])
        XCTAssertNotNil(entries.last?.first?.placement.id)
        XCTAssertEqual(settingsUpdates, 0)
        XCTAssertEqual(plugin.refreshCallCount, refreshCount)
        XCTAssertEqual(host.panelLayoutEntries(in: "components").map(\.id), entries.last?.map(\.id))
        withExtendedLifetime((settings, panels)) {}
    }

    func testLibraryPreviewDoesNotAcquirePanelLifecycle() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])
        XCTAssertNotNil(host.componentPreviewView(for: "component:widget"))
        XCTAssertEqual(plugin.receivedPanelVisibilityValues, [false])
        XCTAssertTrue(plugin.surfaceEvents.isEmpty)
    }

    func testCustomPanelMovesOnlyOneEntryAndPreservesCachedComponentView() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let activationCount = dual.activateCallCount
        let deactivationCount = dual.deactivateCallCount
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        _ = host.componentViewItem(for: host.testEntry(pluginID: "dual", kind: .widget).id, dismiss: {})
        host.moveTestItem(pluginID: "dual", kind: .widget, to: panelID)
        XCTAssertTrue(host.componentItems(in: "components").isEmpty)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.pluginID), ["dual"])
        XCTAssertEqual(host.panelItems(in: "features").map(\.pluginID), ["dual"])
        XCTAssertTrue(host.panelItems(in: panelID).isEmpty)
        XCTAssertTrue(host.isComponentViewCached(for: host.testEntry(pluginID: "dual", kind: .widget).id))
        XCTAssertEqual(dual.activateCallCount, activationCount)
        XCTAssertEqual(dual.deactivateCallCount, deactivationCount)
    }

    func testCustomPanelVisibilityOnlyNotifiesAssignedEntries() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.moveTestItem(pluginID: "dual", kind: .widget, to: panelID)
        host.setVisibleMenuBarPanel("features")
        host.setVisibleMenuBarPanel(panelID)
        host.setVisibleMenuBarPanel(panelID)
        host.setVisibleMenuBarPanel(nil)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .visible("control") }.count, 1)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .hidden("control") }.count, 1)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .visible("widget") }.count, 1)
        XCTAssertEqual(dual.surfaceEvents.filter { $0 == .hidden("widget") }.count, 1)
    }

    func testDeletingMixedPanelPreservesRemainingInstancesInFirstVisiblePanel() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "dual")])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.moveTestItem(pluginID: "dual", kind: .widget, to: panelID)
        host.moveTestItem(pluginID: "dual", kind: .row, to: panelID)
        host.removeTestItem(pluginID: "dual", kind: .widget)
        let row = host.testEntry(pluginID: "dual", kind: .row)
        host.deleteMenuBarPanel(id: panelID)
        XCTAssertEqual(host.panelEntries(in: "components"), [row])
        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)
        XCTAssertTrue(host.componentItems.isEmpty)
    }

    func testMixedPanelHasIndependentOrdersAndMovingAppendsEntry() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "one", order: 1), MockCombinedPlugin(id: "two", order: 2)])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        for id in ["one", "two"] {
            for kind in PluginPanelItemKind.allCases { host.moveTestItem(pluginID: id, kind: kind, to: panelID) }
        }
        host.reorderTestItem(pluginID: "two", kind: .widget, toOffset: 0)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.pluginID), ["two", "one"])
        XCTAssertEqual(host.panelItems(in: panelID).map(\.pluginID), ["one", "two"])
        host.moveTestItem(pluginID: "one", kind: .widget, to: "components")
        XCTAssertEqual(host.componentItems(in: "components").map(\.pluginID), ["one"])
        XCTAssertEqual(host.componentItems(in: panelID).map(\.pluginID), ["two"])
    }

    func testRestoreDefaultPanelsResetsLayoutAndRemovesOnlyCustomPanelShortcuts() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let custom = try XCTUnwrap(host.addMenuBarPanel())
        host.moveTestItem(pluginID: "dual", kind: .widget, to: custom)
        host.moveTestItem(pluginID: "dual", kind: .row, to: custom)
        host.removeTestItem(pluginID: "dual", kind: .widget)
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
        XCTAssertEqual(host.menuBarPanelStore.configuration.panels, MenuBarPanelDefinition.defaults)
        XCTAssertNil(host.actionShortcutSettingsItem(for: customReference))
        XCTAssertEqual(host.actionShortcutSettingsItem(for: defaultReference)?.assignment.binding, defaultBinding)
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["dual"])
        XCTAssertEqual(host.panelItems(in: "features").map(\.pluginID), ["dual"])
        XCTAssertEqual(dual.activateCallCount, activationCount)
        XCTAssertEqual(dual.deactivateCallCount, deactivationCount)
        XCTAssertEqual(MenuBarPanelStore(userDefaults: UserDefaults(suiteName: suiteName)!).configuration, host.menuBarPanelStore.configuration)
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
        host.moveTestItem(pluginID: "one", kind: .widget, to: panelID)
        host.moveTestItem(pluginID: "one", kind: .row, to: panelID)
        host.moveTestItem(pluginID: "two", kind: .widget, to: panelID)
        let original = host.panelEntries(in: panelID)
        XCTAssertEqual(original.map(\.kind), [.widget, .row, .widget])
        XCTAssertEqual(host.panelLayoutEntries(in: panelID).map(\.entry), original)
        host.reorderTestItem(pluginID: "two", kind: .widget, toOffset: 0)
        let reordered = [original[2], original[0], original[1]]
        XCTAssertEqual(host.panelEntries(in: panelID), reordered)
        host.removeTestItem(pluginID: "one", kind: .widget)
        XCTAssertEqual(host.panelEntries(in: panelID), [original[2], original[1]])
        host.reorderTestItem(pluginID: "one", kind: .row, toOffset: 0)
        host.addPanelItem(.init(pluginID: "one", itemID: "widget"), to: panelID)
        XCTAssertEqual(host.panelEntries(in: panelID).map(\.key), [original[1].key, original[2].key, original[0].key])
        host.moveTestItem(pluginID: "two", kind: .row, to: panelID)
        XCTAssertEqual(host.panelEntries(in: panelID).last, host.testEntry(pluginID: "two", kind: .row))
    }

    func testInterleavedPlacementKeepsActionsBetweenCardGrids() throws {
        let span = try XCTUnwrap(PluginPanelWidgetSpan(width: 2, height: 12))
        let host = makeHost(plugins: [MockCombinedPlugin(id: "one", order: 1, span: span),
                                     MockCombinedPlugin(id: "two", order: 2, span: span),
                                     MockCombinedPlugin(id: "three", order: 3, span: span)])
        let entries = [host.testEntry(pluginID: "one", kind: .widget),
                       host.testEntry(pluginID: "two", kind: .widget),
                       host.testEntry(pluginID: "one", kind: .row),
                       host.testEntry(pluginID: "three", kind: .widget),
                       host.testEntry(pluginID: "two", kind: .row)]
        let result = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: host.componentItems,
                                                          features: host.panelItems)
        XCTAssertEqual(result.components.map(\.column), [0, 2, 0])
        XCTAssertEqual(result.components[0].yOffset, result.components[1].yOffset)
        let firstAction = try XCTUnwrap(result.featureOffsets[host.testEntry(pluginID: "one", kind: .row).id])
        let secondAction = try XCTUnwrap(result.featureOffsets[host.testEntry(pluginID: "two", kind: .row).id])
        let cardHeight = ComponentPanelLayout.itemHeight(for: span)
        XCTAssertEqual(firstAction, cardHeight + ConfiguredMenuBarPanelLayout.itemSpacing)
        XCTAssertGreaterThan(result.components[2].yOffset, firstAction + MenuBarPanelLayout.rowHeight(for: host.panelItems[0]))
        XCTAssertGreaterThan(secondAction, result.components[2].yOffset + cardHeight)
        XCTAssertEqual(result.height, secondAction + MenuBarPanelLayout.rowHeight(for: host.panelItems[1]))
        XCTAssertEqual(result, ConfiguredMenuBarPanelLayout.placement(entries: entries, components: host.componentItems,
                                                                    features: host.panelItems))
    }

    func testInterleavedCompactWidgetsKeepFiveColumnGeometryAcrossRows() throws {
        let span = try XCTUnwrap(PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact))
        let host = makeHost(plugins: (0..<6).map { MockCombinedPlugin(id: "icon-\($0)", order: $0, span: span) })
        let widgets = (0..<6).map { host.testEntry(pluginID: "icon-\($0)", kind: .widget) }
        let row = host.testEntry(pluginID: "icon-0", kind: .row)
        let entries = Array(widgets.prefix(5)) + [row, widgets[5]]
        let result = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: host.componentItems,
                                                          features: host.panelItems)
        let frames = result.components.map(PanelLayoutDestination.frame)
        XCTAssertEqual(Array(frames.prefix(5)).map(\.minY), Array(repeating: 0, count: 5))
        XCTAssertEqual(frames[4].maxX, ComponentPanelLayout.gridWidth, accuracy: 0.001)
        XCTAssertEqual(result.featureOffsets[row.id], 64 + ConfiguredMenuBarPanelLayout.itemSpacing)
        XCTAssertGreaterThan(frames[5].minY, try XCTUnwrap(result.featureOffsets[row.id]))
        XCTAssertEqual(frames[5].minX, 0)
        XCTAssertEqual(result.height, frames[5].maxY)
    }

    func testRepeatedFeatureRowsKeepTheFullScrollableDocument() async throws {
        let plugin = MockCombinedPlugin(id: "copies", order: 1, span: try XCTUnwrap(PluginPanelWidgetSpan(width: 2, height: 12)))
        let host = makeHost(plugins: [plugin])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        for _ in 0..<12 { XCTAssertTrue(host.addPanelItem(.init(pluginID: "copies", itemID: "control"), to: panelID)) }
        let entries = host.panelEntries(in: panelID)
        let expected = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: [], features: host.panelItems(in: panelID)).height
        let model = MenuBarUnifiedPanelModel(selectedTab: MenuBarPanelTab(id: panelID), contentHeight: 200,
                                            maximumFeatureListHeight: 200, isPanelVisible: true)
        let root = NSHostingView(rootView: ConfiguredMenuBarPanelsContent(
            pluginHost: host, model: model, contentBodyHeight: 200, onDismiss: {}, onOpenSettings: {},
            onPresentDiskCleanConfiguration: {}, onPresentLaunchControlConfiguration: {})
            .environmentObject(MenuBarPanelPresentationModel(host: host, isVisible: true)))
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
        let span = try XCTUnwrap(PluginPanelWidgetSpan(width: 2, height: 12))
        let plugin = MockCombinedPlugin(id: "copies", order: 1, span: span)
        let host = makeHost(plugins: [plugin])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        for kind in PluginPanelItemKind.allCases {
            for _ in 0..<2 { XCTAssertTrue(host.addPanelItem(.init(pluginID: "copies", itemID: kind.testItemID), to: panelID)) }
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
        host.moveTestItem(pluginID: "dual", kind: .widget, to: panelID)
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: panelID)))
        let backup = host.makePreferencesBackup()
        host.deleteMenuBarPanel(id: panelID)
        let result = try host.importPreferences(backup)
        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.pluginID), ["dual"])
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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
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
private final class MockComponentPanelPlugin: MacToolsPlugin, PluginRuntimeLocalizationRefreshing, PluginShortcutBindingChangeHandling, PluginGroupedShortcutSettingsProviding, PluginDashboardPresenting {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    detail: { [weak self] in self?.makePanelDetailContent(detailID: $0, dismiss: $1) },
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    struct ShortcutBindingChange: Equatable {
        let id: String
        let binding: ShortcutBinding?
    }
    enum SurfaceEvent: Equatable {
        case visible(String)
        case hidden(String)
    }

    let metadata: PluginMetadata
    let descriptor: PluginPanelWidgetDescriptor
    let permissionRequirements: [PluginPermissionRequirement]
    let shortcutDefinitions: [PluginShortcutDefinition]
    let settingsPage: PluginSettingsPage?
    let shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestDashboardPresentation: (() -> Void)?
    var receivedContexts: [PluginPanelWidgetContext] = []
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
        span: PluginPanelWidgetSpan = .oneByOne,
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
        self.descriptor = PluginPanelWidgetDescriptor(span: span)
        self.isActive = isActive
        self.permissionRequirements = permissionRequirements
        self.shortcutDefinitions = shortcutDefinitions
        self.settingsPage = settingsPage
        self.shortcutSettingsGroups = shortcutSettingsGroups
        self.isPermissionGranted = isPermissionGranted
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        makeViewCallCount += 1
        receivedContexts.append(context)
        receivedPanelVisibilityValues.append(!context.isPreview)
        return AnyView(Text(context.pluginID))
    }

    func makePanelDetailContent(
        detailID: String,
        dismiss: @escaping () -> Void
    ) -> PluginPanelDetailContent? {
        guard detailID == "cpu" else {
            return nil
        }
        return PluginPanelDetailContent(
            id: detailID,
            title: "CPU",
            content: AnyView(Text("CPU detail"))
        )
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        surfaceEvents.append(.visible(surface))
        onSurfaceVisible?()
    }

    func panelItemDidBecomeHidden(_ surface: String) {
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
private final class MutableComponentPanelPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    }),
        ]
    }

    let metadata: PluginMetadata
    let descriptor = PluginPanelWidgetDescriptor(span: .oneByOne)
    var settingsPage: PluginSettingsPage?
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

    var widgetState: PluginPanelWidgetState {
        componentStateReadCount += 1
        onComponentStateRead?()
        return PluginPanelWidgetState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
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
private final class MockPrimaryPanelPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor
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
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.definedShortcuts = shortcutDefinitions
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: "Feature subtitle",
            isOn: false,
            isEnabled: true,
            isAvailable: true,
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
private final class CountingPrimaryPanelPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor
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
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.primarySubtitle = ""
    }

    var rowState: PluginPanelRowState {
        panelStateReadCount += 1
        return PluginPanelRowState(
            subtitle: primarySubtitle,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
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
private final class ConfigurationTrapPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor = PluginPanelRowDescriptor(
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

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: "Dynamic subtitle",
            isOn: false,
            isEnabled: true,
            isAvailable: true,
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
private final class MockCombinedPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("control") }
                    else { self?.panelItemDidBecomeHidden("control") }
                },
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    enum SurfaceEvent: Equatable {
        case visible(String)
        case hidden(String)
    }

    let metadata: PluginMetadata
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )
    let descriptor: PluginPanelWidgetDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    init(id: String, order: Int = 1, span: PluginPanelWidgetSpan = .oneByOne) {
        descriptor = PluginPanelWidgetDescriptor(span: span)
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Combined \(id)"
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: "Combined subtitle",
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: "Combined component subtitle",
            isActive: false,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
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

    func panelItemDidBecomeVisible(_ surface: String) {
        surfaceEvents.append(.visible(surface))
    }

    func panelItemDidBecomeHidden(_ surface: String) {
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

@MainActor
private final class PhaseShortcutTestPlugin: MacToolsPlugin, PluginShortcutEventHandling, PluginShortcutBindingChangeHandling {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var binding: ShortcutBinding
    var latestBinding: ShortcutBinding?
    var notifications = 0
    init(binding: ShortcutBinding, id: String = "phase-test") {
        self.binding = binding
        metadata = PluginMetadata(id: id, title: "Phase Test", iconName: "keyboard", iconTint: .blue,
                                  order: 0, defaultDescription: "")
    }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        [PluginShortcutDefinition(id: "cycle", title: "Cycle", description: "", actionID: "cycle",
                                  scope: .whilePluginActive, defaultBinding: binding, isRequired: false)]
    }
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {}
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        latestBinding = binding; notifications += 1
    }
}
