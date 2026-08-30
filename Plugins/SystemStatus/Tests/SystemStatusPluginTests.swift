import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import SystemStatusPlugin

@MainActor
final class SystemStatusPluginTests: XCTestCase {
    private let suiteName = "SystemStatusPluginTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSystemStatusLayoutHeightFollowsVisibleMetricRows() {
        XCTAssertEqual(SystemStatusComponentLayout.contentHeight(for: []), 96)
        XCTAssertEqual(SystemStatusComponentLayout.contentHeight(for: [.cpu]), 82)
        XCTAssertEqual(SystemStatusComponentLayout.contentHeight(for: [.cpu, .gpu, .topProcesses]), 184)
    }

    func testForegroundSamplingIsOwnedByEachVisibleSurface() {
        let viewModel = SystemStatusViewModel(sampler: StubSystemStatusSampler(), historyStore: StubSystemStatusHistoryStore())
        defer { viewModel.stop() }
        viewModel.startMenuBar(requiresSlowSampling: false)
        XCTAssertFalse(viewModel.isSamplingForeground)
        viewModel.startForeground(for: .menuBarPopover)
        viewModel.startForeground(for: .menuBarPopover)
        XCTAssertEqual(viewModel.foregroundConsumers, [.menuBarPopover])
        XCTAssertTrue(viewModel.isSamplingForeground)
        viewModel.startForeground(for: .dashboard)
        viewModel.returnToBackground(from: .menuBarPopover)
        XCTAssertTrue(viewModel.isSamplingForeground)
        viewModel.returnToBackground(from: .menuBarPopover)
        XCTAssertEqual(viewModel.foregroundConsumers, [.dashboard])
        viewModel.returnToBackground(from: .dashboard)
        XCTAssertFalse(viewModel.isSamplingForeground)
        viewModel.startForeground(for: .menuBarPopover)
        viewModel.startForeground(for: .dashboard)
        viewModel.returnToBackground(from: .dashboard)
        XCTAssertTrue(viewModel.isSamplingForeground)
        viewModel.stop()
        XCTAssertTrue(viewModel.foregroundConsumers.isEmpty)
        XCTAssertFalse(viewModel.isSamplingForeground)
    }

    func testExpandedMetricRowHeightAccommodatesWrappedValues() {
        let options = [SystemStatusMenuBarValueKind.level, .power, .timeRemaining, .temperature, .state].map {
            SystemStatusMenuBarValueOption(kind: $0, title: $0.rawValue, liveValue: "100%")
        }
        let item = makeMetricPreferenceTableItem(
            valueOptions: options, selectedValues: [.level, .power],
            secondaryValueNoneTitle: "No Second Value", reorderAccessibilityTitle: "Drag to reorder"
        )
        let row = SystemStatusMenuBarMetricEditorRow(
            item: item, isExpanded: true, selectedSlot: .constant(.primary),
            onToggleExpansion: {}, onVisibilityChange: { _ in }, onValuesChange: { _ in },
            onStyleChange: { _ in }, onValueArrangementChange: { _ in }
        )
        for width: CGFloat in [500, 640, 740, 960] {
            let allocatedHeight = SystemStatusMenuBarEditorLayout.expandedHeight(width: width, valueCount: options.count)
            let host = NSHostingView(rootView: row.frame(width: width))
            XCTAssertLessThanOrEqual(host.fittingSize.height, allocatedHeight, "Row overflow at width \(width)")
            XCTAssertEqual(allocatedHeight, width < 740 ? 227 : 192)

            let table = SystemStatusMenuBarMetricEditorTableView(
                items: [item], expandedKind: .battery, selectedSlots: .constant([:]),
                onToggleExpansion: { _ in }, onVisibilityChange: { _, _ in }, onMove: { _, _ in },
                onValuesChange: { _, _ in }, onStyleChange: { _, _ in }, onValueArrangementChange: { _, _ in }
            )
            let tableHost = NSHostingView(rootView: table.frame(width: width))
            XCTAssertEqual(tableHost.fittingSize.height, allocatedHeight + 12, accuracy: 1)
        }
    }

    func testCompactColumnReservationContainsLocalizedBatteryTimes() {
        let view = SystemStatusMenuBarMetricsView()
        view.menuBarLayout = .vertical
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        for (reservation, value) in [("99Std59Min", "12Std34Min"), ("99時間59分", "12時間34分")] {
            let block = SystemStatusMenuBarMetricBlock(
                kind: .battery, label: "BAT", valueKinds: [.timeRemaining], values: [value],
                widthReservationValues: [reservation], style: .vertical
            )
            view.blocks = [block]
            let cellWidth = view.intrinsicContentSize.width - 8
            let columnWidth = view.compactStackedValueColumnWidth(for: block)
            let valueWidth = NSAttributedString(string: value, attributes: [.font: font, .kern: 0]).size().width
            let contentX = (cellWidth - 13 - columnWidth) / 2
            XCTAssertGreaterThanOrEqual(contentX, 0)
            XCTAssertLessThanOrEqual(contentX + 13 + valueWidth, cellWidth)
        }
    }

    func testEveryLiteralLocalizationKeyExistsInThePluginCatalog() throws {
        let pluginRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: pluginRoot.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let pattern = #"(?:localization\??\.(?:string|format)|localized)\s*\(\s*"([^"]+)""#
        let expression = try NSRegularExpression(pattern: pattern)
        let files = try FileManager.default.contentsOfDirectory(
            at: pluginRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                let key = String(source[range])
                XCTAssertNotNil(strings[key], "Missing \(key) referenced in \(file.lastPathComponent)")
            }
        }
    }

    func testMenuBarMetricPopoverKeepsDetailWindowInsideItsPresentationBoundary() {
        let popoverWindow = NSWindow()
        let detailWindow = NSPanel()
        let unrelatedWindow = NSWindow()

        XCTAssertEqual(
            SystemStatusMenuBarPopoverPresentationPolicy.behavior,
            .applicationDefined
        )
        XCTAssertTrue(
            SystemStatusMenuBarPopoverPresentationPolicy.containsPresentedWindow(
                popoverWindow,
                popoverWindow: popoverWindow,
                detailWindow: detailWindow
            )
        )
        XCTAssertTrue(
            SystemStatusMenuBarPopoverPresentationPolicy.containsPresentedWindow(
                detailWindow,
                popoverWindow: popoverWindow,
                detailWindow: detailWindow
            )
        )
        XCTAssertFalse(
            SystemStatusMenuBarPopoverPresentationPolicy.containsPresentedWindow(
                unrelatedWindow,
                popoverWindow: popoverWindow,
                detailWindow: detailWindow
            )
        )
    }

    func testMenuBarMetricPopoverToggleDismissesWhilePresentationIsTracked() {
        XCTAssertEqual(
            SystemStatusMenuBarPopoverLifecyclePolicy.toggleAction(hasTrackedPopover: false),
            .present
        )
        XCTAssertEqual(
            SystemStatusMenuBarPopoverLifecyclePolicy.toggleAction(hasTrackedPopover: true),
            .dismiss
        )
    }

    func testMenuBarMetricPopoverIgnoresStaleCloseCallbacks() {
        let trackedPopover = NSObject()
        let stalePopover = NSObject()

        XCTAssertTrue(
            SystemStatusMenuBarPopoverLifecyclePolicy.shouldFinishDismissal(
                trackedPopoverIdentifier: ObjectIdentifier(trackedPopover),
                closedPopoverIdentifier: ObjectIdentifier(trackedPopover)
            )
        )
        XCTAssertFalse(
            SystemStatusMenuBarPopoverLifecyclePolicy.shouldFinishDismissal(
                trackedPopoverIdentifier: ObjectIdentifier(trackedPopover),
                closedPopoverIdentifier: ObjectIdentifier(stalePopover)
            )
        )
    }

    func testConfigurationDefaultsShowPanelMetricsAndHideMenuBarMetrics() {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )

        XCTAssertEqual(
            controller.configuration.visiblePanelMetricKinds,
            SystemStatusComponentLayout.defaultPanelMetricKinds
        )
        XCTAssertTrue(controller.configuration.visibleMenuBarMetricKinds.isEmpty)
        XCTAssertEqual(
            controller.configuration.menuBarItems.first { $0.kind == .disk }?.values,
            [.free, .activity]
        )
        XCTAssertTrue(
            controller.configuration.menuBarItems.allSatisfy {
                $0.valueArrangement == .automatic
            }
        )
        XCTAssertTrue(
            controller.configuration.menuBarItems.allSatisfy {
                $0.style == .horizontal
            }
        )
        XCTAssertEqual(controller.configuration.processSort, .cpu)
    }

    func testConfigurationPersistsVisibilityAndOrder() {
        let storage = SystemStatusMemoryPluginStorage()
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )

        controller.setPanelMetric(.gpu, visible: false)
        controller.movePanelMetric(.battery, toOffset: 0)
        controller.setMenuBarMetric(.cpu, visible: true)
        controller.setMenuBarMetric(.memory, visible: true)
        controller.moveMenuBarMetric(.memory, toOffset: 0)
        controller.setMenuBarValues(.memory, values: [.swap, .usage])
        controller.setMenuBarStyle(.memory, style: .minimal)
        controller.setMenuBarValueArrangement(.memory, arrangement: .inline)
        controller.setProcessSort(.memory)

        let restoredController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )

        XCTAssertEqual(restoredController.configuration.panelItems.map(\.kind).first, .battery)
        XCTAssertFalse(restoredController.configuration.panelItems.first { $0.kind == .gpu }?.isVisible ?? true)
        XCTAssertEqual(restoredController.configuration.visibleMenuBarMetricKinds, [.memory, .cpu])
        XCTAssertEqual(restoredController.configuration.menuBarItems.first?.values, [.swap, .usage])
        XCTAssertEqual(
            restoredController.configuration.menuBarItems.first?.valueArrangement,
            .inline
        )
        XCTAssertEqual(restoredController.configuration.menuBarItems.first?.style, .minimal)
        XCTAssertEqual(restoredController.configuration.processSort, .memory)
    }

    func testMenuBarMetricCanMoveToFinalInsertionOffset() throws {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let initialItems = controller.configuration.menuBarItems
        let firstKind = try XCTUnwrap(initialItems.first?.kind)

        controller.moveMenuBarMetric(firstKind, toOffset: initialItems.count)

        XCTAssertEqual(controller.configuration.menuBarItems.last?.kind, firstKind)
    }

    func testPortablePreferencesRoundTripRestoresEveryConfigurationField() throws {
        let sourceController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let sourcePlugin = SystemStatusPlugin(
            settingsController: sourceController,
            storage: SystemStatusMemoryPluginStorage()
        )
        var sourceChangeCount = 0
        sourcePlugin.onPersistentPreferencesChange = { sourceChangeCount += 1 }

        sourceController.setPanelMetric(.gpu, visible: false)
        sourceController.movePanelMetric(.battery, toOffset: 0)
        sourceController.setMenuBarMetric(.cpu, visible: true)
        sourceController.setMenuBarMetric(.memory, visible: true)
        sourceController.moveMenuBarMetric(.memory, toOffset: 0)
        sourceController.setMenuBarValues(.memory, values: [.swap, .usage])
        sourceController.setMenuBarStyle(.memory, style: .vertical)
        sourceController.setMenuBarValueArrangement(.memory, arrangement: .stacked)
        sourceController.setMenuBarStyle(.cpu, style: .minimal)
        sourceController.setProcessSort(.memory)

        XCTAssertGreaterThan(sourceChangeCount, 0)
        let backup = try XCTUnwrap(sourcePlugin.makePortablePreferencesBackup())

        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let destinationPlugin = SystemStatusPlugin(
            settingsController: destinationController,
            storage: SystemStatusMemoryPluginStorage()
        )
        var destinationChangeCount = 0
        destinationPlugin.onPersistentPreferencesChange = { destinationChangeCount += 1 }

        XCTAssertTrue(destinationPlugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(destinationController.configuration, sourceController.configuration)
        XCTAssertEqual(destinationChangeCount, 1)

        XCTAssertTrue(destinationPlugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(destinationChangeCount, 1)
    }

    func testLegacyMenuBarPreferenceDefaultsMissingArrangementToAutomatic() throws {
        let data = try XCTUnwrap(
            """
            {
              "kind": "cpu",
              "isVisible": true,
              "values": ["usage", "temperature"]
            }
            """.data(using: .utf8)
        )

        let preference = try JSONDecoder().decode(
            SystemStatusMenuBarMetricPreference.self,
            from: data
        )

        XCTAssertEqual(preference.valueArrangement, .automatic)
        XCTAssertEqual(preference.style, .horizontal)
    }

    func testLegacyConfigurationCopiesGlobalStyleIntoEveryMetric() throws {
        let data = try XCTUnwrap(
            """
            {
              "panelItems": [],
              "menuBarItems": [
                {
                  "kind": "cpu",
                  "isVisible": true,
                  "values": ["usage", "temperature"]
                },
                {
                  "kind": "network",
                  "isVisible": true,
                  "values": ["download", "upload"]
                }
              ],
              "menuBarLayout": "minimal",
              "processSort": "cpu"
            }
            """.data(using: .utf8)
        )

        let configuration = try JSONDecoder().decode(SystemStatusConfiguration.self, from: data)

        XCTAssertTrue(configuration.menuBarItems.allSatisfy { $0.style == .minimal })
        XCTAssertTrue(configuration.menuBarItems.allSatisfy { $0.valueArrangement == .automatic })
    }

    func testMenuBarValueArrangementAutoFollowsStyleAndHonorsOverrides() {
        XCTAssertEqual(
            SystemStatusMenuBarValueArrangement.automatic.resolved(
                for: .horizontal,
                metric: .cpu
            ),
            .inline
        )
        XCTAssertEqual(
            SystemStatusMenuBarValueArrangement.automatic.resolved(
                for: .vertical,
                metric: .network
            ),
            .stacked
        )
        XCTAssertEqual(
            SystemStatusMenuBarValueArrangement.automatic.resolved(
                for: .minimal,
                metric: .cpu
            ),
            .stacked
        )
        XCTAssertEqual(
            SystemStatusMenuBarValueArrangement.automatic.resolved(
                for: .minimal,
                metric: .network
            ),
            .stacked
        )
        XCTAssertEqual(
            SystemStatusMenuBarValueArrangement.inline.resolved(
                for: .vertical,
                metric: .cpu
            ),
            .inline
        )
        XCTAssertEqual(
            SystemStatusMenuBarValueArrangement.stacked.resolved(
                for: .horizontal,
                metric: .network
            ),
            .stacked
        )
    }

    func testFailedConfigurationSaveDoesNotPublishOrSignalPersistentChange() {
        let storage = SystemStatusMemoryPluginStorage(
            blockedSetKeys: ["settings.configuration.v1"]
        )
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )
        let plugin = SystemStatusPlugin(settingsController: controller, storage: storage)
        var changeCount = 0
        plugin.onPersistentPreferencesChange = { changeCount += 1 }

        controller.setMenuBarMetric(.cpu, visible: true)

        XCTAssertEqual(controller.configuration, .default)
        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(
            SystemStatusPluginStorageConfigurationStore(storage: storage).load(),
            .default
        )
    }

    func testPortableRestoreLeavesExistingConfigurationIntactWhenAtomicWriteFails() throws {
        let sourceController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        sourceController.setMenuBarMetric(.cpu, visible: true)
        sourceController.setMenuBarValues(.cpu, values: [.power, .load])
        let backup = try XCTUnwrap(sourceController.makePortablePreferencesBackup())

        let storage = SystemStatusMemoryPluginStorage()
        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )
        let originalConfiguration = destinationController.configuration
        storage.blockedSetKeys.insert("settings.configuration.v1")

        XCTAssertFalse(destinationController.restorePortablePreferences(from: backup))
        XCTAssertEqual(destinationController.configuration, originalConfiguration)
        XCTAssertEqual(
            SystemStatusPluginStorageConfigurationStore(storage: storage).load(),
            originalConfiguration
        )
    }

    func testPluginDeclaresPortablePreferencesCapabilitiesUsedByTheHost() {
        let plugin: any MacToolsPlugin = SystemStatusPlugin(storage: SystemStatusMemoryPluginStorage())

        XCTAssertNotNil(plugin as? any PluginPortablePreferencesProviding)
        XCTAssertNotNil(plugin as? any PluginPortablePreferencesRestorationReporting)
        XCTAssertNotNil(plugin as? any PluginPersistentPreferencesChangeSignaling)
        XCTAssertNotNil(plugin as? any PluginDashboardPresenting)
        XCTAssertNotNil(plugin as? any PluginComponentDetailPresenting)
    }

    func testPluginProvidesMetricDetailsButNotProcessDetails() throws {
        let plugin = SystemStatusPlugin(storage: SystemStatusMemoryPluginStorage())

        let cpuDetail = try XCTUnwrap(
            plugin.makeComponentDetailContent(detailID: SystemStatusMetricKind.cpu.rawValue, dismiss: {})
        )

        XCTAssertEqual(cpuDetail.id, SystemStatusMetricKind.cpu.rawValue)
        XCTAssertEqual(cpuDetail.title, "CPU")
        XCTAssertNil(
            plugin.makeComponentDetailContent(
                detailID: SystemStatusMetricKind.topProcesses.rawValue,
                dismiss: {}
            )
        )
        XCTAssertNil(plugin.makeComponentDetailContent(detailID: "unknown", dismiss: {}))
    }

    func testPortablePreferencesRejectUnsupportedFormatWithoutChangingConfiguration() throws {
        let sourcePlugin = SystemStatusPlugin(storage: SystemStatusMemoryPluginStorage())
        let backup = try XCTUnwrap(sourcePlugin.makePortablePreferencesBackup())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup) as? [String: Any]
        )
        object["formatVersion"] = 999
        let invalidBackup = try JSONSerialization.data(withJSONObject: object)

        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        destinationController.setMenuBarMetric(.cpu, visible: true)
        let originalConfiguration = destinationController.configuration
        let destinationPlugin = SystemStatusPlugin(
            settingsController: destinationController,
            storage: SystemStatusMemoryPluginStorage()
        )

        XCTAssertFalse(destinationPlugin.restorePortablePreferencesReportingResult(from: invalidBackup))
        XCTAssertEqual(destinationController.configuration, originalConfiguration)
    }

    func testConfigurationMigratesLegacyNetworkLayoutToMenuBarLayout() {
        let storage = SystemStatusMemoryPluginStorage()
        storage.set("vertical", forKey: "settings.menuBar.network.layout")

        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )

        XCTAssertEqual(controller.configuration.menuBarLayout, .vertical)
        XCTAssertTrue(controller.configuration.menuBarItems.allSatisfy { $0.style == .vertical })
        XCTAssertNil(storage.string(forKey: "settings.menuBar.network.layout"))
        XCTAssertEqual(storage.string(forKey: "settings.menuBar.layout"), "vertical")
    }

    func testMenuBarBuilderUsesCustomSettingsSection() throws {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let plugin = SystemStatusPlugin(
            settingsController: controller,
            storage: SystemStatusMemoryPluginStorage()
        )
        let page = try XCTUnwrap(plugin.settingsPage)
        guard case let .form(sections) = page.body else {
            return XCTFail("Expected a form settings page")
        }

        XCTAssertEqual(
            sections.map(\.id),
            ["panel-metrics", "menu-bar-metrics"]
        )

        let builderSection = try XCTUnwrap(sections.last)
        guard case .custom = builderSection.content else {
            return XCTFail("Expected a custom menu-bar builder")
        }

        controller.setMenuBarLayout(.vertical)
        XCTAssertEqual(controller.configuration.menuBarLayout, .vertical)
        XCTAssertTrue(controller.configuration.menuBarItems.allSatisfy { $0.style == .vertical })
    }

    func testMenuBarBatchStyleAndResetActionsHaveClearScopes() {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        controller.setMenuBarMetric(.cpu, visible: true)
        controller.moveMenuBarMetric(.network, toOffset: 0)
        controller.setMenuBarValues(.network, values: [.upload, .download])
        controller.setMenuBarStyle(.network, style: .minimal)
        controller.setMenuBarValueArrangement(.network, arrangement: .inline)

        let customizedKinds = controller.configuration.menuBarItems.map(\.kind)
        let customizedVisibility = controller.configuration.menuBarItems.map(\.isVisible)
        let customizedValues = controller.configuration.menuBarItems.map(\.values)

        controller.applyMenuBarStyleToAll(.vertical)
        XCTAssertTrue(controller.configuration.menuBarItems.allSatisfy { $0.style == .vertical })
        XCTAssertEqual(controller.configuration.menuBarItems.map(\.kind), customizedKinds)
        XCTAssertEqual(controller.configuration.menuBarItems.map(\.values), customizedValues)

        controller.resetMenuBarAppearances()
        XCTAssertTrue(controller.configuration.menuBarItems.allSatisfy { $0.style == .horizontal })
        XCTAssertTrue(controller.configuration.menuBarItems.allSatisfy { $0.valueArrangement == .automatic })
        XCTAssertEqual(controller.configuration.menuBarItems.map(\.kind), customizedKinds)
        XCTAssertEqual(controller.configuration.menuBarItems.map(\.isVisible), customizedVisibility)
        XCTAssertEqual(controller.configuration.menuBarItems.map(\.values), customizedValues)

        controller.resetMenuBarConfiguration()
        XCTAssertEqual(
            controller.configuration.menuBarItems,
            SystemStatusConfiguration.default.menuBarItems
        )
    }

    func testPluginDescriptorShrinksWhenPanelMetricsAreHidden() {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        controller.setPanelMetric(.gpu, visible: false)
        controller.setPanelMetric(.network, visible: false)
        controller.setPanelMetric(.disk, visible: false)
        controller.setPanelMetric(.memory, visible: false)
        controller.setPanelMetric(.battery, visible: false)
        controller.setPanelMetric(.topProcesses, visible: false)

        let plugin = SystemStatusPlugin(
            settingsController: controller,
            storage: SystemStatusMemoryPluginStorage()
        )

        let expectedHeight = PluginComponentPanelLayoutMetrics.default.heightSpan(
            fittingContentHeight: SystemStatusComponentLayout.contentHeight(for: [.cpu])
        )
        XCTAssertEqual(plugin.descriptor.span, PluginComponentSpan(width: 4, height: expectedHeight)!)
    }

    func testMenuBarFormatterUsesSelectedOrder() {
        var snapshot = SystemStatusSnapshot.empty
        snapshot.cpu = SystemStatusCPUSnapshot(
            usage: 0.125,
            loadAverage1Minute: nil,
            temperatureCelsius: 42.4,
            systemPowerWatts: nil,
            isCollecting: false
        )
        snapshot.memory = SystemStatusMemorySnapshot(
            usedBytes: 6_000,
            totalBytes: 10_000,
            swapUsedBytes: nil,
            swapTotalBytes: nil
        )
        snapshot.network = SystemStatusNetworkSnapshot(
            interfaceName: "en0",
            ipAddress: nil,
            publicIPAddress: nil,
            downloadBytesPerSecond: 1_024,
            uploadBytesPerSecond: 2_048,
            isConnected: true,
            isCollecting: false
        )

        XCTAssertEqual(
            SystemStatusMenuBarMetricsFormatter.text(snapshot: snapshot, kinds: [.memory, .cpu, .network]),
            "RAM 60% 5.9K | CPU 13% 42° | NET ↓1K ↑2K"
        )
    }

    func testMenuBarFormatterProvidesReusableValueLinesForVerticalLayout() {
        var snapshot = SystemStatusSnapshot.empty
        snapshot.cpu = SystemStatusCPUSnapshot(
            usage: 0.125,
            loadAverage1Minute: nil,
            temperatureCelsius: 42.4,
            systemPowerWatts: nil,
            isCollecting: false
        )
        snapshot.network = SystemStatusNetworkSnapshot(
            interfaceName: "en0",
            ipAddress: nil,
            publicIPAddress: nil,
            downloadBytesPerSecond: 1_024,
            uploadBytesPerSecond: 2_048,
            isConnected: true,
            isCollecting: false
        )

        XCTAssertEqual(
            SystemStatusMenuBarMetricsFormatter.blocks(
                snapshot: snapshot,
                kinds: [.cpu, .network]
            ),
            [
                SystemStatusMenuBarMetricBlock(
                    kind: .cpu,
                    label: "CPU",
                    values: ["13%", "42°"],
                    style: .horizontal
                ),
                SystemStatusMenuBarMetricBlock(
                    kind: .network,
                    label: "NET",
                    values: ["↓1K", "↑2K"],
                    style: .horizontal
                )
            ]
        )

        XCTAssertEqual(
            SystemStatusMenuBarMetricsFormatter.blocks(snapshot: snapshot, kinds: [.cpu]).first?.symbolName,
            "cpu"
        )

        let metricsView = SystemStatusMenuBarMetricsView()
        metricsView.blocks = SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: snapshot,
            kinds: [.cpu, .network]
        )
        let horizontalWidth = metricsView.intrinsicContentSize.width
        metricsView.blocks = SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: snapshot,
            items: [.cpu, .network].map {
                SystemStatusMenuBarMetricPreference(
                    kind: $0,
                    isVisible: true,
                    values: SystemStatusMenuBarValueKind.defaultValues(for: $0),
                    style: .vertical
                )
            }
        )

        XCTAssertNotEqual(metricsView.intrinsicContentSize.width, horizontalWidth)
    }

    func testVerticalMenuBarMetricsProvideUsefulSecondaryValues() {
        var snapshot = SystemStatusSnapshot.empty
        snapshot.memory = SystemStatusMemorySnapshot(
            usedBytes: 6 * 1_024 * 1_024 * 1_024,
            totalBytes: 10 * 1_024 * 1_024 * 1_024,
            swapUsedBytes: nil,
            swapTotalBytes: nil
        )
        snapshot.disk = SystemStatusDiskSnapshot(
            usedBytes: 60,
            totalBytes: 100,
            readBytesPerSecond: 1 * 1_024 * 1_024,
            writeBytesPerSecond: 2 * 1_024 * 1_024
        )
        snapshot.battery = SystemStatusBatterySnapshot(
            isAvailable: true,
            level: 0.8,
            state: .acPower,
            timeRemainingMinutes: nil,
            adapterWatts: 70,
            batteryPowerWatts: -18.5,
            temperatureCelsius: 31,
            healthPercent: 96,
            cycleCount: 120
        )

        let blocks = SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: snapshot,
            kinds: [.memory, .disk, .battery]
        )

        XCTAssertEqual(blocks.map(\.values), [
            ["60%", "6G"],
            ["40B", "↕3M"],
            ["80%", "+19W"]
        ])
        XCTAssertEqual(blocks.map(\.horizontalValue), ["60% 6G", "40B ↕3M", "80% +19W"])
    }

    func testBatteryPowerSignDistinguishesChargingFromDischarging() {
        func powerValue(_ watts: Double) -> String? {
            var snapshot = SystemStatusSnapshot.empty
            snapshot.battery = SystemStatusBatterySnapshot(
                isAvailable: true,
                level: 0.69,
                state: watts < 0 ? .charging : .unplugged,
                timeRemainingMinutes: nil,
                adapterWatts: nil,
                batteryPowerWatts: watts,
                temperatureCelsius: nil,
                healthPercent: nil,
                cycleCount: nil
            )
            let item = SystemStatusMenuBarMetricPreference(
                kind: .battery,
                isVisible: true,
                values: [.power]
            )
            return SystemStatusMenuBarMetricsFormatter.blocks(
                snapshot: snapshot,
                items: [item]
            ).first?.values.first
        }

        XCTAssertEqual(powerValue(-54), "+54W")
        XCTAssertEqual(powerValue(54), "−54W")
    }

    func testBatteryTimeRemainingUsesPowerStateWhenNoCountdownApplies() {
        func value(state: SystemStatusBatteryState, minutes: Int?) -> String? {
            var snapshot = SystemStatusSnapshot.empty
            snapshot.battery = SystemStatusBatterySnapshot(
                isAvailable: true,
                level: 0.66,
                state: state,
                timeRemainingMinutes: minutes,
                adapterWatts: 70,
                batteryPowerWatts: nil,
                temperatureCelsius: 35.89,
                healthPercent: 100,
                cycleCount: 15
            )
            let item = SystemStatusMenuBarMetricPreference(
                kind: .battery,
                isVisible: true,
                values: [.timeRemaining]
            )
            return SystemStatusMenuBarMetricsFormatter.blocks(
                snapshot: snapshot,
                items: [item]
            ).first?.values.first
        }

        XCTAssertEqual(value(state: .acPower, minutes: nil), "AC")
        XCTAssertEqual(value(state: .charged, minutes: nil), "FULL")
        XCTAssertEqual(value(state: .charging, minutes: nil), "…")
        XCTAssertEqual(value(state: .unplugged, minutes: nil), "…")
        XCTAssertEqual(value(state: .unplugged, minutes: 93), "1h33m")
    }

    func testMenuBarFormatterUsesCustomizedMetricValuesAndOrder() {
        var snapshot = SystemStatusSnapshot.empty
        snapshot.cpu = SystemStatusCPUSnapshot(
            usage: 0.25,
            loadAverage1Minute: 4.25,
            temperatureCelsius: 55,
            systemPowerWatts: 8.5,
            isCollecting: false
        )

        let items = [
            SystemStatusMenuBarMetricPreference(
                kind: .cpu,
                isVisible: true,
                values: [.power, .load]
            )
        ]

        let block = SystemStatusMenuBarMetricsFormatter.blocks(snapshot: snapshot, items: items).first
        XCTAssertEqual(block?.valueKinds, [.power, .load])
        XCTAssertEqual(block?.values, ["8.5W", "L4.2"])
        XCTAssertEqual(block?.horizontalValue, "8.5W L4.2")
    }

    func testCompactDecimalFormattingUsesRequestedLocale() {
        XCTAssertEqual(
            SystemStatusMenuBarMetricsFormatter.localizedDecimal(
                1.5,
                locale: Locale(identifier: "de_DE")
            ),
            "1,5"
        )
    }

    func testActivityMonitorActionUsesSystemApplicationURL() {
        XCTAssertEqual(
            SystemStatusProcessActions.activityMonitorURL.path,
            "/System/Applications/Utilities/Activity Monitor.app"
        )
    }

    func testNewSystemStatusStringsCoverEverySupportedLanguage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Plugins/SystemStatus/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let supportedLanguages = Set(
            AppLanguagePreference.allCases
                .filter { $0 != .system }
                .map(\.rawValue)
        )
        let exactKeys: Set<String> = [
            "disk.availableUnitFormat",
            "chart.range30Minutes",
            "chart.range2Hours",
            "chart.range24Hours",
            "chart.timeline",
            "settings.menuBar.builderDescription",
            "settings.menuBar.preview",
            "settings.menuBar.previewEmpty",
            "settings.menuBar.setAllMetricsTo",
            "settings.menuBar.reset",
            "settings.menuBar.resetStylesAndLayout",
            "settings.menuBar.resetAll",
            "settings.menuBar.resetAll.confirmationTitle",
            "settings.menuBar.resetAll.confirmationMessage",
            "settings.menuBar.resetAll.cancel",
            "settings.menuBar.resetAll.confirm",
            "settings.menuBarLayout.compact",
            "settings.menuBarLayout.detailed",
            "settings.menuBarLayout.minimal",
            "settings.menuBarStyle.title",
            "settings.menuBarStyle.mixed",
            "settings.menuBarValueArrangement.title",
            "settings.menuBarValueArrangement.automatic",
            "settings.menuBarValueArrangement.stacked",
            "settings.menuBarValueArrangement.inline",
            "menuBar.action.openDashboard",
            "menuBar.action.customize",
            "component.metric.openDetailFormat",
            "detail.minimum",
            "detail.average",
            "detail.maximum",
            "detail.back",
            "detail.close",
            "settings.menuBarValue.custom",
            "settings.menuBarValue.first",
            "settings.menuBarValue.secondOptional",
            "settings.metric.reorderAccessibility",
            "topProcesses.openActivityMonitor",
            "topProcesses.sortHelpFormat",
        ]
        let prefixes = [
            "chart.disk.",
            "menuBar.compact.",
            "settings.menuBarValue.",
        ]
        let keys = Set(strings.keys.filter { key in
            exactKeys.contains(key) || prefixes.contains { prefix in key.hasPrefix(prefix) }
        })

        XCTAssertTrue(exactKeys.isSubset(of: keys))
        XCTAssertFalse(keys.isEmpty)
        for key in keys.sorted() {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLanguages, key)

            for language in supportedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "\(key) [\(language)]"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) [\(language)]"
                )
                XCTAssertEqual(stringUnit["state"] as? String, "translated", "\(key) [\(language)]")
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "\(key) [\(language)]"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key) [\(language)]"
                )
            }
        }
    }

    func testSystemStatusStringCatalogHasUniqueTopLevelKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Plugins/SystemStatus/Resources/Localizable.xcstrings")
        let source = try String(contentsOf: catalogURL, encoding: .utf8)
        let keys = source.split(separator: "\n").compactMap { line -> String? in
            let text = String(line)
            guard text.hasPrefix("    \"") else { return nil }
            let remainder = text.dropFirst(5)
            guard let closingQuote = remainder.firstIndex(of: "\"") else { return nil }
            return String(remainder[..<closingQuote])
        }

        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testPanelSettingsCellPreservesLocalizedReorderAccessibility() {
        let panelItem = makeMetricPreferenceTableItem(
            valueOptions: [],
            selectedValues: [],
            secondaryValueNoneTitle: "Aucune deuxième valeur",
            reorderAccessibilityTitle: "Faire glisser pour réorganiser"
        )
        let cell = SystemStatusMetricPreferenceCellView(frame: NSRect(x: 0, y: 0, width: 560, height: 58))
        cell.configure(item: panelItem, onVisibilityChange: { _ in })
        cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(cell.reorderAccessibilityLabel, "Faire glisser pour réorganiser")
    }

    func testMenuBarSlotAssignmentAppendsReplacesSwapsAndClears() {
        XCTAssertEqual(
            SystemStatusMenuBarSlotAssignment.assigning(
                .temperature,
                to: .secondary,
                in: [.usage]
            ),
            [.usage, .temperature]
        )
        XCTAssertEqual(
            SystemStatusMenuBarSlotAssignment.assigning(
                .power,
                to: .primary,
                in: [.usage, .temperature]
            ),
            [.power, .temperature]
        )
        XCTAssertEqual(
            SystemStatusMenuBarSlotAssignment.assigning(
                .temperature,
                to: .primary,
                in: [.usage, .temperature]
            ),
            [.temperature, .usage]
        )
        XCTAssertEqual(
            SystemStatusMenuBarSlotAssignment.clearingSecondary(
                in: [.usage, .temperature]
            ),
            [.usage]
        )
    }

    func testMenuBarEditorDragPayloadKeepsMetricAndValueScopesSeparate() {
        let metricPayload = SystemStatusMenuBarEditorDragPayload.metric(.battery)
        XCTAssertEqual(
            SystemStatusMenuBarEditorDragPayload.metric(from: metricPayload),
            .battery
        )
        XCTAssertNil(
            SystemStatusMenuBarEditorDragPayload.value(from: metricPayload, metric: .battery)
        )

        let valuePayload = SystemStatusMenuBarEditorDragPayload.value(.level, metric: .battery)
        XCTAssertNil(SystemStatusMenuBarEditorDragPayload.metric(from: valuePayload))
        XCTAssertEqual(
            SystemStatusMenuBarEditorDragPayload.value(from: valuePayload, metric: .battery),
            .level
        )
        XCTAssertNil(SystemStatusMenuBarEditorDragPayload.value(from: valuePayload, metric: .cpu))
    }

    func testMenuBarMetricWidthsRemainStableAsValuesChange() {
        let metricsView = SystemStatusMenuBarMetricsView()
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["1%", "9°"]),
            SystemStatusMenuBarMetricBlock(kind: .network, label: "NET", values: ["↓1B", "↑2B"])
        ]
        let compactHorizontalWidth = metricsView.intrinsicContentSize.width

        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["100%", "999°"]),
            SystemStatusMenuBarMetricBlock(kind: .network, label: "NET", values: ["↓9.9M", "↑9.9M"])
        ]
        XCTAssertEqual(
            metricsView.intrinsicContentSize.width,
            compactHorizontalWidth,
            "Horizontal reservations must cover changing live values"
        )

        metricsView.menuBarLayout = .vertical
        let expandedVerticalWidth = metricsView.intrinsicContentSize.width
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["1%", "9°"]),
            SystemStatusMenuBarMetricBlock(kind: .network, label: "NET", values: ["↓1B", "↑2B"])
        ]
        XCTAssertEqual(
            metricsView.intrinsicContentSize.width,
            expandedVerticalWidth,
            "Compact reservations must cover changing live values"
        )

        let verticalMetricWidths = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["1%", "9°"]),
            SystemStatusMenuBarMetricBlock(kind: .gpu, label: "GPU", values: ["2%", "10°"]),
            SystemStatusMenuBarMetricBlock(kind: .memory, label: "RAM", values: ["20%"]),
            SystemStatusMenuBarMetricBlock(kind: .disk, label: "DSK", values: ["30%"]),
            SystemStatusMenuBarMetricBlock(kind: .battery, label: "BAT", values: ["40%", "20°"]),
            SystemStatusMenuBarMetricBlock(kind: .network, label: "NET", values: ["↓1K", "↑2K"])
        ].map { block -> CGFloat in
            metricsView.blocks = [block]
            return metricsView.intrinsicContentSize.width
        }
        XCTAssertTrue(
            verticalMetricWidths.dropFirst().allSatisfy { $0 == verticalMetricWidths[0] },
            "Default compact metric blocks should share a stable width: \(verticalMetricWidths)"
        )

        metricsView.menuBarLayout = .minimal
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["1%", "9°"]),
            SystemStatusMenuBarMetricBlock(kind: .network, label: "NET", values: ["↓1B", "↑2B"])
        ]
        let minimalWidth = metricsView.intrinsicContentSize.width
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["100%", "999°"]),
            SystemStatusMenuBarMetricBlock(kind: .network, label: "NET", values: ["↓9.9M", "↑9.9M"])
        ]
        XCTAssertEqual(
            metricsView.intrinsicContentSize.width,
            minimalWidth,
            "Minimal reservations must cover changing live values"
        )

        metricsView.menuBarLayout = .vertical
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(kind: .cpu, label: "CPU", values: ["1%", "9°"])
        ]
        let compactCPUWidth = metricsView.intrinsicContentSize.width
        metricsView.menuBarLayout = .minimal
        XCTAssertLessThan(metricsView.intrinsicContentSize.width, compactCPUWidth)
    }

    func testPerMetricArrangementChangesWidthWithoutChangingGlobalStyle() {
        let metricsView = SystemStatusMenuBarMetricsView()
        metricsView.menuBarLayout = .minimal
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(
                kind: .cpu,
                label: "CPU",
                values: ["16%", "88°"],
                valueArrangement: .stacked
            )
        ]
        let stackedWidth = metricsView.intrinsicContentSize.width

        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(
                kind: .cpu,
                label: "CPU",
                values: ["16%", "88°"],
                valueArrangement: .inline
            )
        ]

        XCTAssertGreaterThan(metricsView.intrinsicContentSize.width, stackedWidth)
        XCTAssertEqual(metricsView.menuBarLayout, .minimal)
    }

    func testPerMetricStylesRenderIndependentlyOfTheFallbackStyle() {
        let metricsView = SystemStatusMenuBarMetricsView()
        metricsView.menuBarLayout = .horizontal
        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(
                kind: .cpu,
                label: "CPU",
                values: ["16%", "88°"],
                style: .horizontal
            )
        ]
        let detailedWidth = metricsView.intrinsicContentSize.width

        metricsView.blocks = [
            SystemStatusMenuBarMetricBlock(
                kind: .cpu,
                label: "CPU",
                values: ["16%", "88°"],
                style: .minimal
            )
        ]
        let minimalWidth = metricsView.intrinsicContentSize.width

        XCTAssertLessThan(minimalWidth, detailedWidth)
        XCTAssertEqual(metricsView.menuBarLayout, .horizontal)
    }

    func testMinimalMenuBarIdentityOnlyAppearsWhenValuesAreAmbiguous() {
        XCTAssertEqual(
            SystemStatusMenuBarMinimalIdentity.identity(for: .cpu, valueKinds: [.usage, .temperature]),
            "C"
        )
        XCTAssertEqual(
            SystemStatusMenuBarMinimalIdentity.identity(for: .gpu, valueKinds: [.usage, .temperature]),
            "G"
        )
        XCTAssertEqual(
            SystemStatusMenuBarMinimalIdentity.identity(for: .memory, valueKinds: [.usage, .used]),
            "M"
        )
        XCTAssertEqual(
            SystemStatusMenuBarMinimalIdentity.identity(for: .battery, valueKinds: [.level, .power]),
            "B"
        )
        XCTAssertNil(
            SystemStatusMenuBarMinimalIdentity.identity(for: .network, valueKinds: [.download, .upload])
        )
        XCTAssertEqual(
            SystemStatusMenuBarMinimalIdentity.identity(for: .network, valueKinds: [.throughput]),
            "N"
        )
        XCTAssertNil(
            SystemStatusMenuBarMinimalIdentity.identity(for: .disk, valueKinds: [.read, .write])
        )
        XCTAssertEqual(
            SystemStatusMenuBarMinimalIdentity.identity(for: .disk, valueKinds: [.free, .activity]),
            "D"
        )
    }

    func testMetricDetailRangesExposeExpectedIntervals() {
        XCTAssertEqual(SystemStatusMetricDetailRange.thirtyMinutes.interval, 30 * 60)
        XCTAssertEqual(SystemStatusMetricDetailRange.twoHours.interval, 2 * 60 * 60)
        XCTAssertEqual(SystemStatusMetricDetailRange.twentyFourHours.interval, 24 * 60 * 60)
    }

    func testMenuBarNetworkRatesStayWithinCompactWidthReservation() {
        var snapshot = SystemStatusSnapshot.empty
        snapshot.network = SystemStatusNetworkSnapshot(
            interfaceName: "en0",
            ipAddress: nil,
            publicIPAddress: nil,
            downloadBytesPerSecond: 100 * 1_024 * 1_024,
            uploadBytesPerSecond: UInt64.max,
            isConnected: true,
            isCollecting: false
        )

        XCTAssertEqual(
            SystemStatusMenuBarMetricsFormatter.blocks(
                snapshot: snapshot,
                kinds: [.network]
            ).first?.values,
            ["↓0.1G", "↑16E"]
        )
    }

    func testProductionSamplingScheduleBalancesForegroundDetailAndBackgroundCost() {
        let schedule = SystemStatusSamplingSchedule.production

        XCTAssertEqual(schedule.backgroundFastInterval, .seconds(30))
        XCTAssertEqual(schedule.menuBarFastInterval, .seconds(3))
        XCTAssertEqual(schedule.foregroundFastInterval, .seconds(3))
        XCTAssertEqual(schedule.backgroundSlowInterval, 300)
        XCTAssertEqual(schedule.menuBarSlowInterval, 3)
        XCTAssertEqual(schedule.foregroundSlowInterval, 15)
        XCTAssertEqual(schedule.backgroundProcessInterval, 300)
        XCTAssertEqual(schedule.foregroundProcessInterval, 15)
        XCTAssertEqual(schedule.backgroundHistoryInterval, 300)
        XCTAssertEqual(schedule.foregroundHistoryInterval, 60)
    }

    func testViewModelMergesDiskCapacityAndActivitySamples() async throws {
        let viewModel = SystemStatusViewModel(
            sampler: StubSystemStatusSampler(),
            historyStore: StubSystemStatusHistoryStore(),
            schedule: .test
        )

        await viewModel.refreshSnapshotNow(referenceDate: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(viewModel.snapshot.disk.usedBytes, 50)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertEqual(viewModel.snapshot.disk.readBytesPerSecond, 2_048)
        XCTAssertEqual(viewModel.snapshot.disk.writeBytesPerSecond, 1_024)
        XCTAssertEqual(viewModel.snapshot.history.last?.diskReadBytesPerSecond, 2_048)
        XCTAssertEqual(viewModel.snapshot.history.last?.diskWriteBytesPerSecond, 1_024)
    }

    func testDisplayHistoryPruneKeepsTwentyFourHoursWithRecentHighResolution() {
        let points = stride(from: 0, through: 86_400, by: 3).map { timestamp in
            SystemStatusHistoryPoint(
                timestamp: TimeInterval(timestamp),
                cpuUsage: Double(timestamp) / 90_000
            )
        }

        let pruned = SystemStatusViewModel.prunedSortedDisplayHistory(
            points,
            referenceDate: Date(timeIntervalSince1970: 86_400)
        )

        XCTAssertEqual(pruned.count, 2_011)
        XCTAssertEqual(pruned.first?.timestamp, 57)
        XCTAssertEqual(pruned.last?.timestamp, 86_400)
        XCTAssertEqual(pruned.filter { $0.timestamp >= 84_600 }.count, 601)

        let historicalBuckets = pruned
            .filter { $0.timestamp < 84_600 }
            .map { Int($0.timestamp / 60) }
        XCTAssertEqual(Set(historicalBuckets).count, historicalBuckets.count)
    }

    func testPluginReusesViewModelAcrossComponentViews() {
        let viewModel = SystemStatusViewModel(sampler: StubSystemStatusSampler())
        let plugin = SystemStatusPlugin(viewModel: viewModel, storage: SystemStatusMemoryPluginStorage())

        let first = plugin.makeView(
            context: PluginComponentContext(
                pluginID: "system-status",
                dismiss: {},
                isPanelVisible: true
            )
        )
        let second = plugin.makeView(
            context: PluginComponentContext(
                pluginID: "system-status",
                dismiss: {},
                isPanelVisible: true
            )
        )

        XCTAssertFalse(String(describing: first).isEmpty)
        XCTAssertFalse(String(describing: second).isEmpty)
    }

    private func makeMetricPreferenceTableItem(
        valueOptions: [SystemStatusMenuBarValueOption],
        selectedValues: [SystemStatusMenuBarValueKind],
        secondaryValueNoneTitle: String,
        reorderAccessibilityTitle: String
    ) -> SystemStatusMetricPreferenceTableItem {
        SystemStatusMetricPreferenceTableItem(
            kind: .battery,
            title: "Battery",
            description: "Battery status",
            iconName: "battery.100",
            iconTint: .green,
            isVisible: true,
            visibilityActionTitle: "Hide Battery",
            visibilityStateTitle: "Visible",
            valueOptions: valueOptions,
            selectedValues: selectedValues,
            style: .horizontal,
            styleTitle: "Style",
            detailedStyleTitle: "Detailed",
            compactStyleTitle: "Compact",
            minimalStyleTitle: "Minimal",
            valueArrangement: .automatic,
            valueArrangementTitle: "Value Layout",
            automaticArrangementTitle: "Auto",
            stackedArrangementTitle: "Stacked",
            inlineArrangementTitle: "Inline",
            secondaryValueNoneTitle: secondaryValueNoneTitle,
            primaryValueTitle: "First Value",
            secondaryValueTitle: "Second Value (Optional)",
            availableValuesTitle: "Available Values",
            reorderAccessibilityTitle: reorderAccessibilityTitle
        )
    }

}

private actor StubSystemStatusSampler: SystemStatusSampling {
    private(set) var fastCallCount = 0
    private(set) var slowCallCount = 0
    private(set) var processCallCount = 0
    private(set) var publicIPCallCount = 0

    var callCounts: (fast: Int, slow: Int, processes: Int, publicIP: Int) {
        (fastCallCount, slowCallCount, processCallCount, publicIPCallCount)
    }

    func collectFast(referenceDate: Date) async -> SystemStatusFastSample {
        fastCallCount += 1
        return SystemStatusFastSample(
            cpu: SystemStatusCPUSnapshot(
                usage: min(0.95, 0.20 + Double(fastCallCount) * 0.01),
                loadAverage1Minute: 1.42,
                temperatureCelsius: 42,
                systemPowerWatts: 8.5,
                isCollecting: false
            ),
            memory: SystemStatusMemorySnapshot(
                usedBytes: 4_000,
                totalBytes: 8_000,
                swapUsedBytes: 512,
                swapTotalBytes: 2_048
            ),
            network: SystemStatusNetworkSnapshot(
                interfaceName: "en0",
                ipAddress: "192.168.1.2",
                publicIPAddress: nil,
                downloadBytesPerSecond: 1_024,
                uploadBytesPerSecond: 512,
                isConnected: true,
                isCollecting: false
            ),
            disk: SystemStatusDiskSnapshot(
                usedBytes: nil,
                totalBytes: nil,
                readBytesPerSecond: 2_048,
                writeBytesPerSecond: 1_024
            )
        )
    }

    func collectSlow() async -> SystemStatusSlowSample {
        slowCallCount += 1
        return SystemStatusSlowSample(
            disk: SystemStatusDiskSnapshot(
                usedBytes: 50,
                totalBytes: 100,
                readBytesPerSecond: nil,
                writeBytesPerSecond: nil
            ),
            battery: SystemStatusBatterySnapshot(
                isAvailable: true,
                level: 0.8,
                state: .acPower,
                timeRemainingMinutes: nil,
                adapterWatts: 70,
                batteryPowerWatts: -18.5,
                temperatureCelsius: 31,
                healthPercent: 96,
                cycleCount: 120
            ),
            gpu: SystemStatusGPUSnapshot(
                usage: 0.4,
                name: "M1 Pro",
                temperatureCelsius: 43,
                isAvailable: true,
                isCollecting: false
            ),
            hardware: SystemStatusHardwareSnapshot(
                modelName: "MacBookPro18,3",
                chipName: "Apple M1 Pro",
                macOSVersion: "macOS 15.0",
                uptimeSeconds: 3_600,
                totalMemoryBytes: 16_000
            )
        )
    }

    func collectTopProcesses(limit: Int) async -> [SystemStatusTopProcess] {
        processCallCount += 1
        return [
            SystemStatusTopProcess(
                pid: 1,
                displayName: "launchd",
                command: "/sbin/launchd",
                cpuPercent: 1,
                memoryPercent: 0.1,
                memoryBytes: 12_582_912
            )
        ]
    }

    func collectPublicIPAddress() async -> String? {
        publicIPCallCount += 1
        return "203.0.113.1"
    }
}

private actor StubSystemStatusHistoryStore: SystemStatusHistoryStoring {
    private(set) var appendedCount = 0
    private var points: [SystemStatusHistoryPoint] = []

    func load(referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        points
    }

    func append(_ point: SystemStatusHistoryPoint, referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        appendedCount += 1
        points.append(point)
        return points
    }
}

@MainActor
private final class SystemStatusMemoryPluginStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String>

    init(blockedSetKeys: Set<String> = []) {
        self.blockedSetKeys = blockedSetKeys
    }

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else {
            return
        }
        guard let value else {
            removeObject(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

private extension SystemStatusSamplingSchedule {
    static let test = SystemStatusSamplingSchedule(
        backgroundFastInterval: .milliseconds(20),
        menuBarFastInterval: .milliseconds(20),
        foregroundFastInterval: .milliseconds(20),
        backgroundSlowInterval: 0,
        menuBarSlowInterval: 0,
        foregroundSlowInterval: 0,
        backgroundProcessInterval: 0,
        foregroundProcessInterval: 0,
        backgroundHistoryInterval: 0,
        foregroundHistoryInterval: 0
    )

    static let foregroundRestart = SystemStatusSamplingSchedule(
        backgroundFastInterval: .seconds(30),
        menuBarFastInterval: .milliseconds(20),
        foregroundFastInterval: .milliseconds(20),
        backgroundSlowInterval: 30,
        menuBarSlowInterval: 30,
        foregroundSlowInterval: 30,
        backgroundProcessInterval: 30,
        foregroundProcessInterval: 30,
        backgroundHistoryInterval: 30,
        foregroundHistoryInterval: 30
    )
}
