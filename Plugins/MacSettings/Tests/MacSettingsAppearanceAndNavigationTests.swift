import XCTest
import MacToolsPluginKit
@testable import MacSettingsPlugin
@testable import AppearancePlugin

@MainActor
final class MacSettingsAppearanceAndNavigationTests: XCTestCase {
    private final class AppearanceController: SystemAppearanceControlling {
        var snapshot = SystemAppearanceSnapshot(mode: .auto, isDark: true)
        var writes: [SystemAppearanceMode] = []
        var fails = false

        func read() throws -> SystemAppearanceSnapshot { snapshot }
        func setMode(_ mode: SystemAppearanceMode) throws {
            if fails { throw SystemAppearanceError.unavailable }
            writes.append(mode)
            snapshot = .init(mode: mode, isDark: mode == .auto ? snapshot.isDark : mode == .dark)
        }
    }

    private func reference(_ mode: String) throws -> ActionReference {
        .init(key: .init(providerID: "appearance", actionID: "set-mode"),
              parameters: try .init(["mode": .string(mode)]))
    }

    func testCanonicalProviderSupportsModeReadApplyAndUndoToAutomatic() async throws {
        let native = AppearanceController()
        let plugin = AppearancePlugin(appearanceController: native)
        let context = PluginActionExecutionHostContext(item: { reference in
            guard let entry = plugin.actionCatalogEntries.first(where: { $0.reference == reference }) else { return nil }
            return ActionSurfaceCatalogItem(reference: reference, title: entry.title, subtitle: nil,
                ownerTitle: "Appearance", systemImage: "circle.lefthalf.filled",
                availability: plugin.actionAvailability(for: reference), isSafe: true,
                presentationState: entry.presentationState)
        }, execute: { reference, _ in
            do {
                let result = await (try plugin.beginAction(.init(reference: reference, source: .test, mode: .background))).result()
                switch result {
                case .succeeded: return .succeeded(message: nil)
                case let .failed(message): return .failed(message: message)
                case .cancelled: return .cancelled
                }
            } catch { return .failed(message: error.localizedDescription) }
        })
        let catalog = try MacSettingsCatalogFactory.make { context }
        let record = try XCTUnwrap(catalog["appearance.dark-mode"])
        XCTAssertTrue(record.definition.isProfileEligible)
        XCTAssertFalse(record.definition.schema.accepts(.boolean(true)))
        let snapshot = try await record.adapter.snapshot()
        XCTAssertEqual(snapshot.value, .choice(id: "auto"))
        try await record.adapter.apply(.choice(id: "light"))
        let current = try await record.adapter.read()
        XCTAssertEqual(current, .choice(id: "light"))
        _ = try await record.adapter.restore(snapshot)
        let restored = try await record.adapter.read()
        XCTAssertEqual(restored, .choice(id: "auto"))
        XCTAssertEqual(native.writes, [.light, .auto])
        XCTAssertTrue(plugin.permissionRequirementIDs(for: try reference("auto").key).isEmpty)
    }

    func testInvalidCancelledAndFailedActionsDoNotPublishAFalseMode() async throws {
        let native = AppearanceController()
        let plugin = AppearancePlugin(appearanceController: native)
        XCTAssertFalse(plugin.actionAvailability(for: try reference("unknown")).isAvailable)
        let cancelled = try plugin.beginAction(.init(reference: try reference("dark"), source: .test, mode: .background))
        cancelled.cancel()
        _ = await cancelled.result()
        XCTAssertTrue(native.writes.isEmpty)
        native.fails = true
        let failed = try plugin.beginAction(.init(reference: try reference("dark"), source: .test, mode: .background))
        let result = await failed.result()
        guard case .failed = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(plugin.actionCatalogEntries.filter { $0.reference.key.actionID == "set-mode" && $0.presentationState == .active }.map(\.reference), [try reference("auto")])
    }

    func testAppearanceProfileRoundTripsAndLegacyBooleanKeepsExplicitIntent() throws {
        for (value, expected) in [(SystemSettingValue.boolean(true), "dark"), (.boolean(false), "light"), (.choice(id: "auto"), "auto")] {
            let entry = SystemSettingsProfileEntry(settingID: "appearance.dark-mode", desiredValue: value, category: .appearance)
            let decoded = try JSONDecoder().decode(SystemSettingsProfileEntry.self, from: JSONEncoder().encode(entry))
            XCTAssertEqual(decoded.desiredValue, .choice(id: expected))
        }
        let entry = SystemSettingsProfileEntry(settingID: "finder.show-path-bar", desiredValue: .boolean(true), category: .finder)
        XCTAssertEqual(try JSONDecoder().decode(SystemSettingsProfileEntry.self, from: JSONEncoder().encode(entry)), entry)
    }

    func testDeepLinksUseNativeOpaqueSchemeAndAnchorTokens() throws {
        let pane = "com.apple.Accessibility-Settings.extension"
        for anchor in ["AX_FEATURE_ZOOM", "AX_CURSOR_SIZE", "AX_FEATURE_POINTERCONTROL", "AX_FEATURE_KEYBOARD"] {
            let url = try XCTUnwrap(SystemSettingSystemDestination(pane: pane, anchor: anchor).url)
            XCTAssertEqual(url.absoluteString, "x-apple.systempreferences:\(pane)?\(anchor)")
            XCTAssertNil(url.host)
        }
        for name in ["Appearance", "Desktop", "Displays", "Keyboard", "Trackpad", "Mouse"] {
            let pane = "com.apple.\(name)-Settings.extension"
            XCTAssertEqual(SystemSettingSystemDestination(pane: pane, anchor: nil).url?.absoluteString,
                           "x-apple.systempreferences:\(pane)")
        }
        XCTAssertNil(SystemSettingSystemDestination(pane: pane, anchor: "Zoom").url)
        XCTAssertNil(SystemSettingSystemDestination(pane: "com.apple.Finder-Settings.extension", anchor: nil).url)
        XCTAssertNil(SystemSettingSystemDestination(pane: "com.apple.ScreenCapture-Settings.extension", anchor: nil).url)
    }

    func testCatalogDoesNotOfferNonexistentFinderOrScreenshotPanes() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        for record in catalog.records where [.finder, .screenshots].contains(record.definition.category) {
            XCTAssertNil(record.definition.destination?.url, "\(record.id)")
        }
    }

    func testWorkspaceNavigationMapsEveryDestinationToAnObviousSection() {
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .all), .settings)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .favorites), .settings)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .recent), .settings)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .attention), .settings)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .category(.finder)), .settings)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .profiles), .profiles)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .importExport), .profiles)
        XCTAssertEqual(MacSettingsWorkspaceSection(destination: .history), .history)
        XCTAssertEqual(MacSettingsWorkspaceSection.allCases, [.settings, .profiles, .history])

        let retainedScope = MacSettingsDestination.category(.finder)
        XCTAssertEqual(
            MacSettingsWorkspaceSection.settings.destination(returningTo: retainedScope),
            retainedScope
        )
        XCTAssertEqual(
            MacSettingsWorkspaceSection.profiles.destination(returningTo: retainedScope),
            .profiles
        )
    }

    func testPaletteRowIdentityChangesWithSectionAndFavoriteState() {
        let settingID: SystemSettingID = "accessibility.three-finger-drag"
        let categoryIdentity = MacSettingsPaletteRowIdentity(
            sectionID: "category.accessibility",
            settingID: settingID,
            isFavorite: false
        )
        let pinnedIdentity = MacSettingsPaletteRowIdentity(
            sectionID: "favorites",
            settingID: settingID,
            isFavorite: true
        )

        XCTAssertNotEqual(categoryIdentity, pinnedIdentity)
        XCTAssertNotEqual(
            categoryIdentity,
            MacSettingsPaletteRowIdentity(
                sectionID: categoryIdentity.sectionID,
                settingID: settingID,
                isFavorite: true
            )
        )
    }

    func testGlobalSearchHidesAndThenRestoresThePreviousSettingsScope() {
        var state = MacSettingsSearchScopeState()

        XCTAssertEqual(
            state.destination(afterChanging: "cursor", from: .favorites),
            .all
        )
        XCTAssertEqual(state.destinationBeforeSearch, .favorites)
        XCTAssertEqual(
            state.destination(afterChanging: "pointer", from: .all),
            .all
        )
        XCTAssertEqual(state.destinationBeforeSearch, .favorites)
        XCTAssertEqual(
            state.destination(afterChanging: "", from: .all),
            .favorites
        )
        XCTAssertNil(state.destinationBeforeSearch)
    }

    func testExportFilenameIsPortableAndNeverEmpty() {
        XCTAssertEqual(MacSettingsProfileFilename.exportName(for: "Work Setup"), "Work Setup.mactoolsprofile")
        XCTAssertEqual(MacSettingsProfileFilename.exportName(for: "Work/Personal: 2026"), "Work-Personal- 2026.mactoolsprofile")
        XCTAssertEqual(MacSettingsProfileFilename.exportName(for: "Work\nSetup"), "Work-Setup.mactoolsprofile")
        XCTAssertEqual(MacSettingsProfileFilename.exportName(for: "  "), "Mac Settings.mactoolsprofile")
    }

    func testProfileDocumentExportsItsExactBytes() throws {
        let data = Data([0x00, 0x41, 0xFF])
        let document = MacSettingsProfileDocument(data: data)
        let wrapper = document.exportedFileWrapper()
        XCTAssertEqual(wrapper.regularFileContents, data)
    }

    func testProfileSelectionAppearanceDistinguishesChoiceCompletionAndUnavailableRows() {
        XCTAssertEqual(
            MacSettingsProfileSelectionAppearance(status: .ready, isSelected: true).systemImage,
            "checkmark.square.fill"
        )
        XCTAssertEqual(
            MacSettingsProfileSelectionAppearance(status: .ready, isSelected: false).systemImage,
            "square"
        )
        XCTAssertEqual(
            MacSettingsProfileSelectionAppearance(status: .alreadyMatches, isSelected: false).systemImage,
            "checkmark.circle.fill"
        )
        XCTAssertEqual(
            MacSettingsProfileSelectionAppearance(
                status: .unavailable(.provider, "Missing"),
                isSelected: false
            ).systemImage,
            "minus.circle"
        )
    }
}
