import XCTest
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class SystemSettingCatalogTests: XCTestCase {
    func testBuiltInCatalogIsCuratedAndValid() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }

        XCTAssertEqual(catalog.records.count, 44)
        XCTAssertEqual(Set(catalog.records.map(\.id)).count, catalog.records.count)
        XCTAssertTrue(catalog.records.allSatisfy { $0.definition.schema.isValid })
        XCTAssertTrue(catalog.records.allSatisfy { !$0.definition.searchTerms.isEmpty })
        XCTAssertTrue(catalog.records.contains { $0.definition.executionClass == .existingPluginProvider })
        XCTAssertFalse(catalog.records.contains { $0.definition.executionClass == .guidedManual })

        XCTAssertEqual(
            catalog["accessibility.three-finger-drag"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.pointer-size"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.pointer-size"]?.definition.requirements.requiredPermissionID,
            MacSettingsPermission.fullDiskAccess
        )
        XCTAssertEqual(
            catalog["accessibility.keyboard-zoom"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.scroll-zoom"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["accessibility.scroll-zoom-modifier"]?.definition.executionClass,
            .directVerified
        )
        XCTAssertEqual(
            catalog["finder.show-path-bar"]?.definition.executionClass,
            .directRequiresRestart
        )
        XCTAssertEqual(
            catalog["finder.search-scope"]?.definition.executionClass,
            .directAppliesNextUse
        )
        XCTAssertEqual(
            catalog["screenshots.format"]?.definition.executionClass,
            .directAppliesNextUse
        )
        XCTAssertEqual(
            catalog["input.mouse-tracking-speed"]?.definition.executionClass,
            .directRequiresLogout
        )
        XCTAssertEqual(
            catalog["input.scroll-speed"]?.definition.executionClass,
            .hardwareDependent
        )
        XCTAssertEqual(
            catalog["input.mouse-scroll-speed"]?.definition.executionClass,
            .hardwareDependent
        )
        XCTAssertNil(catalog["network.wifi"])
        XCTAssertNil(catalog["power.low-power-mode"])
        XCTAssertEqual(catalog["dock.size"]?.definition.executionClass, .directVerified)
        XCTAssertEqual(catalog["desktop.menu-bar-auto-hide"]?.definition.executionClass, .existingPluginProvider)
        XCTAssertEqual(
            catalog["desktop.menu-bar-auto-hide"]?.definition.schema,
            .choice(options: [
                .init(id: "always", title: "Always"),
                .init(id: "desktop-only", title: "On Desktop Only"),
                .init(id: "full-screen-only", title: "In Full Screen Only"),
                .init(id: "never", title: "Never"),
            ])
        )
        XCTAssertNotNil(catalog["desktop.show-items-on-desktop"])
        XCTAssertNotNil(catalog["desktop.show-items-in-stage-manager"])
        XCTAssertNotNil(catalog["desktop.show-widgets-on-desktop"])
        XCTAssertNotNil(catalog["desktop.show-widgets-in-stage-manager"])
        XCTAssertEqual(
            catalog["finder.warn-empty-trash"]?.definition.executionClass,
            .directAppliesNextUse
        )
        XCTAssertEqual(
            catalog["display.true-tone"]?.definition.executionClass,
            .existingPluginProvider
        )
        XCTAssertEqual(
            Set(catalog.records.map(\.definition.category)),
            Set(SystemSettingCategory.allCases).subtracting([.power, .network])
        )
        XCTAssertTrue(catalog["accessibility.three-finger-drag"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.pointer-size"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.keyboard-zoom"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.scroll-zoom"]?.definition.isProfileEligible == true)
        XCTAssertTrue(catalog["accessibility.scroll-zoom-modifier"]?.definition.isProfileEligible == true)
    }

    func testReleaseScopeRetainsSelectedControlsAndExcludesDeferredSettings() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let deferredIDs: Set<SystemSettingID> = [
            "accessibility.full-keyboard-access", "accessibility.sticky-keys",
            "accessibility.slow-keys", "input.secondary-click", "keyboard.function-keys",
            "screenshots.destination", "display.night-shift",
        ]
        XCTAssertEqual(Set(catalog.deferredDefinitions.keys), deferredIDs)
        for id in deferredIDs {
            XCTAssertNil(catalog[id], "Deferred settings must not expose adapters")
            let definition = try XCTUnwrap(catalog.deferredDefinitions[id])
            XCTAssertFalse(catalog.search(definition.title).contains { $0.id == id })
        }

        let selectedIDs: [SystemSettingID] = [
            "accessibility.three-finger-drag", "accessibility.pointer-size",
            "accessibility.keyboard-zoom", "accessibility.scroll-zoom",
            "accessibility.scroll-zoom-modifier", "input.scroll-speed",
            "input.mouse-scroll-speed", "input.tap-to-click", "input.natural-scrolling",
            "input.mouse-tracking-speed", "input.trackpad-tracking-speed",
            "finder.show-all-extensions", "finder.new-window-target",
        ]
        for id in selectedIDs {
            XCTAssertNotNil(catalog[id], "Selected setting must remain in the initial release: \(id)")
        }
        for profile in BuiltInSystemSettingsProfiles.templates(catalog: catalog) {
            XCTAssertTrue(Set(profile.entries.map(\.settingID)).isDisjoint(with: deferredIDs))
            XCTAssertTrue(SystemSettingsProfileCodec.validate(profile, catalog: catalog).isValid)
        }
    }

    func testMenuBarProviderReadsAndWritesExactFourStateMode() async throws {
        var executedReference: ActionReference?
        let context = PluginActionExecutionHostContext(
            item: { reference in
                guard reference.key.providerID == "auto-hide-menu-bar",
                      reference.parameters["mode"] == .string("desktop-only") else { return nil }
                return ActionSurfaceCatalogItem(
                    reference: reference,
                    title: "On Desktop Only",
                    subtitle: nil,
                    ownerTitle: "Menu Bar",
                    systemImage: "menubar.rectangle",
                    availability: .available,
                    isSafe: true,
                    presentationState: .active
                )
            },
            execute: { reference, _ in
                executedReference = reference
                return .succeeded(message: nil)
            }
        )
        let catalog = try MacSettingsCatalogFactory.make { context }
        let record = try XCTUnwrap(catalog["desktop.menu-bar-auto-hide"])

        let currentValue = try await record.adapter.read()
        XCTAssertEqual(currentValue, .choice(id: "desktop-only"))
        try await record.adapter.apply(.choice(id: "full-screen-only"))
        XCTAssertEqual(executedReference?.key.actionID, "set-mode")
        XCTAssertEqual(executedReference?.parameters["mode"], .string("full-screen-only"))
    }

    func testDisplayProvidersReadLiveActionStateAndWriteExplicitDesiredValue() async throws {
        var executedReference: ActionReference?
        let context = PluginActionExecutionHostContext(
            item: { reference in
                guard reference.key.providerID == "display-true-color" else { return nil }
                return ActionSurfaceCatalogItem(
                    reference: reference,
                    title: "True Tone",
                    subtitle: nil,
                    ownerTitle: "Display",
                    systemImage: "display",
                    availability: .available,
                    isSafe: true,
                    presentationState: .active
                )
            },
            execute: { reference, _ in
                executedReference = reference
                return .succeeded(message: nil)
            }
        )
        let catalog = try MacSettingsCatalogFactory.make { context }
        let record = try XCTUnwrap(catalog["display.true-tone"])

        let currentValue = try await record.adapter.read()
        XCTAssertEqual(currentValue, .boolean(true))
        try await record.adapter.apply(.boolean(false))
        XCTAssertEqual(executedReference?.key.providerID, "display-true-color")
        XCTAssertEqual(executedReference?.key.actionID, "set-enabled")
        XCTAssertEqual(executedReference?.parameters["enabled"], .boolean(false))
    }

    func testNaturalLanguageSearchExamplesRemainDirectResults() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let expectations: [(String, SystemSettingID)] = [
            ("drag window trackpad", "accessibility.three-finger-drag"),
            ("large cursor", "accessibility.pointer-size"),
            ("show extension", "finder.show-all-extensions"),
            ("dock disappear", "dock.auto-hide"),
            ("screenshot jpg", "screenshots.format"),
            ("zoom keyboard", "accessibility.keyboard-zoom"),
            ("scroll gesture zoom", "accessibility.scroll-zoom"),
            ("scroll zoom modifier", "accessibility.scroll-zoom-modifier"),
        ]

        for (query, expectedID) in expectations {
            XCTAssertEqual(catalog.search(query).first?.id, expectedID, "Query: \(query)")
        }
    }

    func testCatalogRejectsDuplicateIDsAndInvalidDefaults() {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let first = makeTestRecord(id: "duplicate", title: "First", adapter: adapter)
        let second = makeTestRecord(id: "duplicate", title: "Second", adapter: adapter)
        XCTAssertThrowsError(try SystemSettingCatalog(records: [first, second])) {
            XCTAssertEqual($0 as? SystemSettingCatalogValidationError, .duplicateID("duplicate"))
        }

        let invalid = makeTestRecord(
            id: "invalid",
            title: "Invalid",
            schema: .boolean,
            defaultValue: .integer(1),
            adapter: adapter
        )
        XCTAssertThrowsError(try SystemSettingCatalog(records: [invalid])) {
            XCTAssertEqual($0 as? SystemSettingCatalogValidationError, .invalidDefaultValue("invalid"))
        }
    }

    func testCompatibilityDistinguishesEveryRequirementState() {
        let environment = SystemSettingEnvironment(
            systemVersion: .init(14),
            availableHardware: [],
            grantedPermissionIDs: [],
            availableProviderIDs: []
        )
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let hardware = makeTestRecord(
            id: "hardware",
            title: "Hardware",
            requirements: .init(requiredHardware: "trackpad"),
            adapter: adapter
        )
        let permission = makeTestRecord(
            id: "permission",
            title: "Permission",
            requirements: .init(requiredPermissionID: "accessibility"),
            adapter: adapter
        )
        let provider = makeTestRecord(
            id: "provider",
            title: "Provider",
            requirements: .init(existingProviderID: "appearance"),
            adapter: adapter
        )
        let managed = makeTestRecord(
            id: "managed",
            title: "Managed",
            executionClass: .managedOnly,
            adapter: adapter
        )

        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: hardware.definition, environment: environment),
            .hardwareUnavailable("trackpad")
        )
        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: permission.definition, environment: environment),
            .permissionMissing("accessibility")
        )
        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: provider.definition, environment: environment),
            .providerUnavailable("appearance")
        )
        XCTAssertEqual(
            SystemSettingCompatibilityEvaluator.availability(for: managed.definition, environment: environment),
            .managedOnly
        )
    }
}
