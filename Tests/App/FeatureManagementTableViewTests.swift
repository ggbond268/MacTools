import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class FeatureManagementTableViewTests: XCTestCase {
    func testSettingsPageReadableWidthExpandsBeforeCapping() {
        XCTAssertEqual(SettingsPageLayout.readableContentWidth(for: 560), 520)
        XCTAssertEqual(SettingsPageLayout.readableContentWidth(for: 800), 760)
        XCTAssertEqual(SettingsPageLayout.readableContentWidth(for: 1_200), 960)
    }

    func testGeneralSettingsUsesACompactReadableColumn() {
        XCTAssertEqual(
            SettingsPageLayout.readableContentWidth(for: 560, policy: .general),
            520
        )
        XCTAssertEqual(
            SettingsPageLayout.readableContentWidth(for: 800, policy: .general),
            720
        )
        XCTAssertEqual(
            SettingsPageLayout.readableContentWidth(for: 1_200, policy: .general),
            720
        )
        XCTAssertEqual(
            SettingsPageLayout.groupedSectionLayoutWidth(
                for: 1_200,
                policy: .general
            ),
            700
        )
    }

    func testGroupedSectionWidthPreservesNativeCardChrome() {
        XCTAssertEqual(SettingsPageLayout.groupedSectionLayoutWidth(for: 560), 500)
        XCTAssertEqual(SettingsPageLayout.groupedSectionLayoutWidth(for: 800), 740)
        XCTAssertEqual(SettingsPageLayout.groupedSectionLayoutWidth(for: 1_200), 940)
    }

    func testGroupedSectionCardAndHeaderShareTheReadableOuterGuide() {
        for viewportWidth in [560.0, 800.0, 1_200.0] {
            let readableWidth = SettingsPageLayout.readableContentWidth(
                for: viewportWidth
            )
            let sectionLayoutWidth = SettingsPageLayout.groupedSectionLayoutWidth(
                for: viewportWidth
            )

            XCTAssertEqual(
                sectionLayoutWidth + SettingsPageLayout.groupedSectionHorizontalChrome,
                readableWidth
            )
        }
    }

    func testUpdatePolicySkipsUnchangedItems() {
        let items = [
            makeItem(id: "activity-bar", isActive: false)
        ]

        XCTAssertFalse(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: items,
            currentItems: items,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480.2,
            currentContentWidth: 480.4
        ))
    }

    func testUpdatePolicyRefreshesWhenRowStateChanges() {
        let previousItems = [
            makeItem(id: "activity-bar", isActive: false)
        ]
        let currentItems = [
            makeItem(id: "activity-bar", isActive: false, canUninstall: true)
        ]

        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: previousItems,
            currentItems: currentItems,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480,
            currentContentWidth: 480
        ))
    }

    func testCapabilitySummaryCoversEverySurfaceCombination() {
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: true, featurePanel: true)),
            AppL10n.plugins("plugin.capability.both", defaultValue: "仪表盘与功能面板")
        )
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: true, featurePanel: false)),
            AppL10n.plugins("plugin.capability.dashboard", defaultValue: "仪表盘")
        )
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: false, featurePanel: true)),
            AppL10n.plugins("plugin.capability.featurePanel", defaultValue: "功能面板")
        )
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: false, featurePanel: false)),
            AppL10n.plugins("plugin.capability.settingsOnly", defaultValue: "仅设置")
        )
    }

    func testSurfaceDescriptionsStayFocusedOnLayout() {
        let item = makeItem(
            id: "activity-bar",
            isActive: false
        )

        XCTAssertEqual(
            featureManagementDescription(for: item, mode: .surface(.dashboard)),
            item.description
        )
        XCTAssertEqual(
            featureManagementDescription(for: item, mode: .surface(.featurePanel)),
            item.description
        )
    }

    func testVisibilityPresentationMatchesTheMetricRowConvention() {
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.symbolName(isVisible: true),
            "eye"
        )
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.tintColor(isVisible: true),
            .systemBlue
        )
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.symbolName(isVisible: false),
            "eye.slash"
        )
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.tintColor(isVisible: false),
            .tertiaryLabelColor
        )
    }

    func testRapidVisibilityActionsAlternateTheCellCachedValue() {
        var isVisible = true

        XCTAssertFalse(
            FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        )
        XCTAssertTrue(
            FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        )
        XCTAssertFalse(
            FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        )
    }

    func testReorderPolicyRejectsDisabledReordering() {
        let items = [
            makeItem(id: "first", isActive: false),
            makeItem(id: "second", isActive: false)
        ]

        XCTAssertNil(FeatureManagementReorderPolicy.targetOffset(
            for: "first",
            proposedRow: 1,
            items: items,
            mode: .surface(.dashboard),
            isReorderEnabled: false
        ))
    }

    func testReorderPolicyUsesSurfaceLocalRowsAndClampsOffsets() {
        let surfaceItems = [
            makeItem(id: "visible-first", isActive: false),
            makeItem(id: "visible-second", isActive: false)
        ]

        XCTAssertEqual(FeatureManagementReorderPolicy.targetOffset(
            for: "visible-first",
            proposedRow: -4,
            items: surfaceItems,
            mode: .surface(.dashboard),
            isReorderEnabled: true
        ), 0)
        XCTAssertEqual(FeatureManagementReorderPolicy.targetOffset(
            for: "visible-first",
            proposedRow: 20,
            items: surfaceItems,
            mode: .surface(.dashboard),
            isReorderEnabled: true
        ), surfaceItems.count)
        XCTAssertNil(FeatureManagementReorderPolicy.targetOffset(
            for: "not-on-surface",
            proposedRow: 1,
            items: surfaceItems,
            mode: .surface(.dashboard),
            isReorderEnabled: true
        ))
    }

    func testContextMenuPolicyGroupsVisibleDynamicPluginActionsInExpectedOrder() {
        let item = makeItem(
            id: "dynamic",
            isActive: false,
            canUninstall: true,
            hasSettings: true
        )

        XCTAssertEqual(
            FeatureManagementContextMenuPolicy.actionGroups(
                for: item,
                row: 1,
                itemCount: 3,
                mode: .surface(.dashboard),
                isReorderEnabled: true
            ),
            [
                [.openSettings, .viewMarketplace],
                [
                    .moveToTop(isEnabled: true),
                    .moveToBottom(isEnabled: true),
                    .setVisible(false),
                ],
                [.uninstall],
            ]
        )
    }

    func testContextMenuPolicyDisablesMoveActionsAtVisibleListBoundaries() {
        let item = makeItem(id: "built-in", isActive: false)

        XCTAssertEqual(
            FeatureManagementContextMenuPolicy.actionGroups(
                for: item,
                row: 0,
                itemCount: 3,
                mode: .surface(.featurePanel),
                isReorderEnabled: true
            ),
            [[
                .moveToTop(isEnabled: false),
                .moveToBottom(isEnabled: true),
                .setVisible(false),
            ]]
        )
        XCTAssertEqual(
            FeatureManagementContextMenuPolicy.actionGroups(
                for: item,
                row: 2,
                itemCount: 3,
                mode: .surface(.featurePanel),
                isReorderEnabled: true
            ),
            [[
                .moveToTop(isEnabled: true),
                .moveToBottom(isEnabled: false),
                .setVisible(false),
            ]]
        )
    }

    func testContextMenuPolicyKeepsBuiltInRowsActionableOnBothSurfaces() {
        let item = makeItem(id: "built-in", isActive: false)

        for mode in [
            FeatureManagementTableMode.surface(.dashboard),
            .surface(.featurePanel),
        ] {
            XCTAssertEqual(
                FeatureManagementContextMenuPolicy.actionGroups(
                    for: item,
                    row: 0,
                    itemCount: 1,
                    mode: mode,
                    isReorderEnabled: true
                ),
                [[
                    .moveToTop(isEnabled: false),
                    .moveToBottom(isEnabled: false),
                    .setVisible(false),
                ]]
            )
        }
    }

    func testContextMenuPolicyOmitsMoveActionsForHiddenRows() {
        let item = makeItem(
            id: "hidden",
            isActive: false,
            isVisible: false,
            canUninstall: true,
            hasSettings: true
        )

        for mode in [
            FeatureManagementTableMode.surface(.dashboard),
            .surface(.featurePanel),
        ] {
            XCTAssertEqual(
                FeatureManagementContextMenuPolicy.actionGroups(
                    for: item,
                    row: 0,
                    itemCount: 1,
                    mode: mode,
                    isReorderEnabled: false
                ),
                [
                    [.openSettings, .viewMarketplace],
                    [.setVisible(true)],
                    [.uninstall],
                ]
            )
        }
    }

    @MainActor
    func testContextMenuActionsRemainBoundToOriginalPluginAfterCellReuse() {
        let originalItem = makeItem(
            id: "original",
            isActive: false,
            canUninstall: true,
            hasSettings: true
        )
        let replacementItem = makeItem(
            id: "replacement",
            isActive: false,
            canUninstall: true,
            hasSettings: true
        )

        XCTAssertEqual(
            FeatureManagementTableCellInspection.contextMenuEventsAfterReconfiguringCell(
                originalItem: originalItem,
                replacementItem: replacementItem,
                mode: .surface(.featurePanel)
            ),
            [
                "settings:original",
                "marketplace:original",
                "move-top:original",
                "move-bottom:original",
                "visibility:original:false",
                "uninstall:original",
            ]
        )
    }

    private func makeItem(
        id: String,
        isActive: Bool,
        isVisible: Bool = true,
        canUninstall: Bool = false,
        hasSettings: Bool = false,
        capabilities: PluginHostCapabilities? = nil,
        releaseChannel: String? = nil
    ) -> FeatureManagementTableItem {
        FeatureManagementTableItem(surfaceItem: makeSurfaceItem(
            id: id,
            isActive: isActive,
            isVisible: isVisible,
            canUninstall: canUninstall,
            capabilities: capabilities,
            releaseChannel: releaseChannel
        ), hasSettings: hasSettings)
    }

    private func makeSurfaceItem(
        id: String,
        isActive: Bool = false,
        isVisible: Bool = true,
        canUninstall: Bool = false,
        capabilities: PluginHostCapabilities? = nil,
        releaseChannel: String? = nil
    ) -> PluginSurfaceLayoutItem {
        PluginSurfaceLayoutItem(
            id: id,
            title: "活动统计",
            description: "统计输入与活动",
            iconName: "chart.bar.xaxis",
            iconTint: Color(nsColor: .systemGreen),
            capabilities: capabilities ?? self.capabilities(dashboard: true, featurePanel: true),
            isVisible: isVisible,
            isActive: isActive,
            canUninstall: canUninstall,
            removesDataOnUninstall: false,
            category: nil,
            releaseChannel: releaseChannel
        )
    }

    private func capabilities(
        dashboard: Bool,
        featurePanel: Bool
    ) -> PluginHostCapabilities {
        PluginHostCapabilities(
            supportsDashboard: dashboard,
            supportsFeaturePanel: featurePanel,
            settingsLayout: nil
        )
    }

    func testEveryLayoutSurfaceCanReorder() {
        XCTAssertTrue(FeatureManagementTableMode.surface(.dashboard).supportsReordering)
        XCTAssertTrue(FeatureManagementTableMode.surface(.featurePanel).supportsReordering)
        XCTAssertFalse(FeatureManagementReorderPolicy.canReorder(
            mode: .surface(.dashboard),
            isReorderEnabled: false
        ))
    }
}
