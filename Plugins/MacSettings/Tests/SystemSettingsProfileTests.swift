import XCTest
@testable import MacSettingsPlugin

@MainActor
final class SystemSettingsProfileTests: XCTestCase {
    func testZenTemplateUsesOnlyVerifiedDistractionFreeSettings() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let templates = BuiltInSystemSettingsProfiles.templates(catalog: catalog)
        let zen = try XCTUnwrap(templates.first { $0.id == UUID(uuidString: "3DE73F6D-2B52-4641-92D7-3FE6FA22B701") })

        XCTAssertEqual(templates.count, 3)
        XCTAssertEqual(zen.name, "Zen")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: zen.entries.map { ($0.settingID, $0.desiredValue) }),
            [
                "dock.auto-hide": .boolean(true),
                "dock.show-recents": .boolean(false),
                "desktop.menu-bar-auto-hide": .choice(id: "always"),
                "desktop.show-items-on-desktop": .boolean(false),
                "desktop.show-items-in-stage-manager": .boolean(false),
                "desktop.show-widgets-on-desktop": .boolean(false),
                "desktop.show-widgets-in-stage-manager": .boolean(false),
            ]
        )
        XCTAssertFalse(zen.entries.contains { $0.settingID == "desktop.stage-manager" })
        XCTAssertTrue(SystemSettingsProfileCodec.validate(zen, catalog: catalog).isValid)
        XCTAssertTrue(zen.entries.allSatisfy { catalog[$0.settingID]?.definition.isProfileEligible == true })
    }

    func testFinderProfileRechecksPairedPathEvenWhenTargetStillMatches() async throws {
        let store = InMemoryFinderPreferencesStore()
        let adapter = FinderWindowDestinationSystemSettingAdapter(store: store, validateDirectory: { _ in })
        let record = makeTestRecord(
            id: "finder.new-window-target", title: "Destination",
            schema: .directoryChoice(options: FinderWindowDestination.options),
            defaultValue: .choice(id: "PfAF"), adapter: adapter
        )
        let catalog = makeTestCatalog([record])
        let controller = MacSettingsController(catalog: catalog, storage: MacSettingsTestStorage())
        try await adapter.apply(.choice(id: "PfDe"))
        let profile = SystemSettingsProfile(name: "Desktop", entries: [
            .init(settingID: record.id, desiredValue: .choice(id: "PfDe"), category: .finder),
        ])
        let matchingPlan = try await controller.makePlan(for: profile)
        XCTAssertEqual(matchingPlan.items.first?.status, .alreadyMatches)
        store.domains["com.apple.finder"]?["NewWindowTargetPath"] = .string("file:///tmp/elsewhere/")
        let writeCount = store.writes.count
        let staleReport = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: matchingPlan)
        XCTAssertEqual(staleReport.results.first?.kind, .previewChanged)
        XCTAssertEqual(store.writes.count, writeCount)
        let freshPlan = try await controller.makePlan(for: profile)
        XCTAssertEqual(freshPlan.items.first?.status, .ready)
        XCTAssertEqual(freshPlan.items.first?.currentValue, .choice(id: "PfDe"))
        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: freshPlan)
        XCTAssertEqual(report.results.first?.kind, .appliedAndVerified)
        XCTAssertEqual(report.rollbackPoint.entries.count, 1)
    }

    func testFinderProfileAllowsNamedLocationsButRejectsLocalPathsAndUnknownTargets() async throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        for option in FinderWindowDestination.options {
            let profile = SystemSettingsProfile(name: "Named", entries: [
                .init(settingID: "finder.new-window-target", desiredValue: .choice(id: option.id), category: .finder),
            ])
            let data = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("file:"))
            XCTAssertEqual(try SystemSettingsProfileCodec.decode(data, catalog: catalog).0.entries, profile.entries)
        }
        for value in [SystemSettingValue.url(URL(filePath: "/private/tmp/private-project")), .choice(id: "PfXX")] {
            let profile = SystemSettingsProfile(name: "Local", entries: [
                .init(settingID: "finder.new-window-target", desiredValue: value, category: .finder),
            ])
            XCTAssertThrowsError(try SystemSettingsProfileCodec.encode(profile, catalog: catalog))
            let forcedPlan = SystemSettingsProfileApplyPlan(profileID: profile.id, profileName: profile.name, items: [
                .init(settingID: "finder.new-window-target", title: "Destination", currentValue: nil,
                      desiredValue: value, status: .ready, isSelected: true),
            ])
            let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: forcedPlan)
            XCTAssertEqual(report.results.first?.kind, .unsupported)
        }
    }

    func testFinderProfileRollbackRestoresCustomAndAbsentDestinationKeys() async throws {
        let originals: [[String: SystemSettingStoredPreference]] = [
            [:],
            ["NewWindowTarget": .string("PfLo"), "NewWindowTargetPath": .string("file:///tmp/original%20path/")],
        ]
        for original in originals {
            let store = InMemoryFinderPreferencesStore(domains: ["com.apple.finder": original])
            let adapter = FinderWindowDestinationSystemSettingAdapter(store: store, validateDirectory: { _ in })
            let record = makeTestRecord(
                id: "finder.new-window-target", title: "Destination",
                schema: .directoryChoice(options: FinderWindowDestination.options),
                defaultValue: .choice(id: "PfAF"), adapter: adapter
            )
            let catalog = makeTestCatalog([record])
            let plan = SystemSettingsProfileApplyPlan(profileID: UUID(), profileName: "Named destination", items: [
                .init(settingID: record.id, title: "Destination", currentValue: nil,
                      desiredValue: .choice(id: "PfDe"), status: .ready, isSelected: true),
            ])
            let coordinator = SystemSettingsProfileApplyCoordinator(catalog: catalog)
            let report = await coordinator.apply(plan: plan)
            XCTAssertEqual(report.results.first?.kind, .appliedAndVerified)
            let point = try JSONDecoder().decode(SystemSettingRollbackPoint.self, from: JSONEncoder().encode(report.rollbackPoint))
            let results = await coordinator.rollback(point)
            XCTAssertEqual(results.first?.kind, .appliedAndVerified)
            XCTAssertEqual(store.domains["com.apple.finder"], original)
        }
    }

    func testDeferredProfileValuesSurviveImportAndEditingButCannotExecute() async throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let entries = catalog.deferredDefinitions.values
            .filter(\.isProfileEligible)
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { SystemSettingsProfileEntry(
                settingID: $0.id, desiredValue: $0.defaultValue!, category: $0.category
            ) }
        let profile = SystemSettingsProfile(name: "Earlier preview", entries: entries)
        let data = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
        let (decoded, validation) = try SystemSettingsProfileCodec.decode(data, catalog: catalog)
        XCTAssertEqual(decoded.entries, entries)
        XCTAssertEqual(validation.warnings, entries.map { .unknownSetting($0.settingID) })

        let store = InMemorySystemSettingsProfileStore(profiles: [decoded])
        let controller = MacSettingsController(
            catalog: catalog, storage: MacSettingsTestStorage(), profileStore: store
        )
        let draft = controller.makeDraft(from: decoded)
        XCTAssertTrue(controller.saveDraft(draft, replacing: decoded))
        XCTAssertEqual(store.load().first?.entries, entries)
        let plan = try await controller.makePlan(for: decoded)
        XCTAssertTrue(plan.items.allSatisfy { $0.status == .unknownSetting && !$0.isSelected })

        // Execution must also refuse deferred IDs if handed an old or forged plan.
        let forcedPlan = SystemSettingsProfileApplyPlan(
            profileID: profile.id, profileName: profile.name,
            items: entries.map { .init(
                settingID: $0.settingID, title: $0.settingID.rawValue,
                currentValue: nil, desiredValue: $0.desiredValue, status: .ready, isSelected: true
            ) }
        )
        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: forcedPlan)
        XCTAssertEqual(report.results.count, entries.count)
        XCTAssertTrue(report.results.allSatisfy { $0.kind == .unsupported })
        XCTAssertTrue(report.rollbackPoint.entries.isEmpty)
    }

    func testDeferralPreservesKnownProfileValidationAndLocalPathRestrictions() throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let profile = SystemSettingsProfile(name: "Invalid", entries: [
            .init(settingID: "screenshots.destination", desiredValue: .url(
                URL(fileURLWithPath: "/private/tmp/mac-settings-test-destination")
            ), category: .screenshots),
            .init(settingID: "accessibility.sticky-keys", desiredValue: .integer(1), category: .accessibility),
        ])
        let validation = SystemSettingsProfileCodec.validate(profile, catalog: catalog)
        XCTAssertTrue(validation.errors.contains(.nonPortableSetting("screenshots.destination")))
        XCTAssertTrue(validation.errors.contains(.invalidDesiredValue("accessibility.sticky-keys")))
        XCTAssertThrowsError(try SystemSettingsProfileCodec.encode(profile, catalog: catalog))
    }

    func testAlreadyMatchingPreviewIsRecheckedWithoutApplyingUnselectedChanges() async {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let catalog = makeTestCatalog([record])
        let profile = SystemSettingsProfile(name: "Stale", entries: [
            .init(settingID: record.id, desiredValue: .boolean(false), category: .finder),
        ])
        let plan = SystemSettingsProfilePlanner.makePlan(
            profile: profile, catalog: catalog,
            currentValues: [record.id: .boolean(false)], availability: [record.id: .available]
        )
        adapter.value = .boolean(true)
        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: plan)
        XCTAssertEqual(report.results.first?.kind, .previewChanged)
        XCTAssertTrue(report.hasPartialSuccess)
        XCTAssertTrue(adapter.appliedValues.isEmpty, "A stale preview must not silently select an unapproved write")
    }

    func testBooleanOffIsDistinctFromExclusionAndChangingValueIncludes() {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(true))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let catalog = makeTestCatalog([record])
        var draft = SystemSettingsProfileDraft(
            name: "Test",
            profileDescription: "",
            items: [.init(settingID: record.id, isIncluded: false, desiredValue: .boolean(false))]
        )

        XCTAssertTrue(draft.makeProfile(catalog: catalog).entries.isEmpty)
        draft.setDesiredValue(.boolean(false), for: record.id)
        let profile = draft.makeProfile(catalog: catalog)
        XCTAssertEqual(profile.entries.count, 1)
        XCTAssertEqual(profile.entries.first?.desiredValue, .boolean(false))

        draft.setIncluded(false, for: record.id)
        XCTAssertTrue(draft.makeProfile(catalog: catalog).entries.isEmpty)
        XCTAssertEqual(adapter.value, .boolean(true), "Editing inclusion must not touch the current Mac")
    }

    func testImportPreservesUnknownIDsButNeverPlansExecution() throws {
        let known = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([known])
        let profile = SystemSettingsProfile(
            name: "Imported",
            entries: [
                .init(settingID: "future.setting", desiredValue: .boolean(true), category: nil),
            ]
        )
        let data = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
        let decoded = try SystemSettingsProfileCodec.decode(data, catalog: catalog)

        XCTAssertEqual(decoded.0.entries.first?.settingID, "future.setting")
        XCTAssertEqual(decoded.1.warnings, [.unknownSetting("future.setting")])
        let plan = SystemSettingsProfilePlanner.makePlan(
            profile: decoded.0,
            catalog: catalog,
            currentValues: [:],
            availability: [:]
        )
        XCTAssertEqual(plan.items.first?.status, .unknownSetting)
        XCTAssertFalse(plan.items.first?.isSelected ?? true)
    }

    func testImportRejectsOversizedFilesAndArbitraryCommandFields() throws {
        let record = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        XCTAssertThrowsError(try SystemSettingsProfileCodec.decode(
            Data(repeating: 0, count: SystemSettingsProfileCodec.maximumFileSize + 1),
            catalog: catalog
        )) {
            XCTAssertEqual($0 as? SystemSettingsProfileCodecError, .fileTooLarge)
        }

        let profile = SystemSettingsProfile(
            name: "Safe",
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: .finder)]
        )
        let valid = try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["command"] = "rm -rf /"
        let malicious = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try SystemSettingsProfileCodec.decode(malicious, catalog: catalog)) {
            XCTAssertEqual($0 as? SystemSettingsProfileCodecError, .malformedFile)
        }
    }

    func testAsyncProfileFileReaderRejectsOversizedFiles() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactools-profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 17).write(to: url)

        do {
            _ = try await SystemSettingsProfileFileReader.read(from: url, maximumFileSize: 16)
            XCTFail("Expected the bounded reader to reject an oversized file")
        } catch {
            XCTAssertEqual(error as? SystemSettingsProfileCodecError, .fileTooLarge)
        }
    }

    func testPlannerSkipsMatchesAndSupportsPerChangeSelection() {
        let first = makeTestRecord(
            id: "first",
            title: "First",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(true))
        )
        let second = makeTestRecord(
            id: "second",
            title: "Second",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([first, second])
        let profile = SystemSettingsProfile(
            name: "Plan",
            entries: [
                .init(settingID: first.id, desiredValue: .boolean(true), category: .finder),
                .init(settingID: second.id, desiredValue: .boolean(true), category: .finder),
            ]
        )
        let plan = SystemSettingsProfilePlanner.makePlan(
            profile: profile,
            catalog: catalog,
            currentValues: [first.id: .boolean(true), second.id: .boolean(false)],
            availability: [first.id: .available, second.id: .available]
        )

        XCTAssertEqual(plan.items[0].status, .alreadyMatches)
        XCTAssertFalse(plan.items[0].isSelected)
        XCTAssertEqual(plan.items[1].status, .ready)
        XCTAssertTrue(plan.items[1].isSelected)
        XCTAssertFalse(plan.selecting([]).items[1].isSelected)
        XCTAssertTrue(plan.items[1].isSelected, "Selecting a plan must not mutate the saved immutable plan")
    }

    func testPlannerAndExecutionRejectNonPortableSettings() async {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(
            id: "local-only",
            title: "Local Only",
            portability: .deviceSpecific,
            adapter: adapter
        )
        let catalog = makeTestCatalog([record])
        let profile = SystemSettingsProfile(
            name: "Unsafe",
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: .finder)]
        )
        let plan = SystemSettingsProfilePlanner.makePlan(
            profile: profile,
            catalog: catalog,
            currentValues: [record.id: .boolean(false)],
            availability: [record.id: .available]
        )

        XCTAssertEqual(plan.items.first?.status, .unsupported("This setting cannot be applied through a profile."))
        XCTAssertFalse(plan.items.first?.isSelected ?? true)

        let forcedPlan = SystemSettingsProfileApplyPlan(
            profileID: profile.id,
            profileName: profile.name,
            items: [
                .init(
                    settingID: record.id,
                    title: record.definition.title,
                    currentValue: .boolean(false),
                    desiredValue: .boolean(true),
                    status: .ready,
                    isSelected: true
                ),
            ]
        )
        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: forcedPlan)
        XCTAssertEqual(report.results.first?.kind, .unsupported)
        XCTAssertTrue(adapter.appliedValues.isEmpty)
    }

    func testProfileApplyReadsLiveValueImmediatelyBeforeWriting() async {
        let adapter = DeterministicSystemSettingAdapter(value: .integer(0))
        let record = makeTestRecord(
            id: "integer",
            title: "Integer",
            schema: .integer(range: 0 ... 2, step: 1),
            defaultValue: .integer(0),
            adapter: adapter
        )
        let catalog = makeTestCatalog([record])
        let plan = SystemSettingsProfileApplyPlan(
            profileID: UUID(),
            profileName: "Live",
            items: [
                .init(
                    settingID: record.id,
                    title: record.definition.title,
                    currentValue: .integer(0),
                    desiredValue: .integer(2),
                    status: .ready,
                    isSelected: true
                ),
            ]
        )
        adapter.value = .integer(1)

        let coordinator = SystemSettingsProfileApplyCoordinator(catalog: catalog)
        let report = await coordinator.apply(plan: plan)
        XCTAssertEqual(report.results.first?.previousValue, .integer(1))
        XCTAssertEqual(report.rollbackPoint.entries.first?.value, .integer(1))

        _ = await coordinator.rollback(report.rollbackPoint)
        XCTAssertEqual(adapter.value, .integer(1))
    }

    func testApplyReportsPartialResultsAndRollsBackVerificationFailure() async {
        let successfulAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let mismatchAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        mismatchAdapter.queuedVerificationOverrides = [.mismatch(actual: .boolean(false))]
        let successful = makeTestRecord(id: "success", title: "Success", adapter: successfulAdapter)
        let mismatch = makeTestRecord(id: "mismatch", title: "Mismatch", adapter: mismatchAdapter)
        let catalog = makeTestCatalog([successful, mismatch])
        let plan = SystemSettingsProfileApplyPlan(
            profileID: UUID(),
            profileName: "Apply",
            items: [
                .init(
                    settingID: successful.id,
                    title: successful.definition.title,
                    currentValue: .boolean(false),
                    desiredValue: .boolean(true),
                    status: .ready,
                    isSelected: true
                ),
                .init(
                    settingID: mismatch.id,
                    title: mismatch.definition.title,
                    currentValue: .boolean(false),
                    desiredValue: .boolean(true),
                    status: .ready,
                    isSelected: true
                ),
            ]
        )

        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: plan)
        XCTAssertEqual(report.results.map(\.kind), [.appliedAndVerified, .failedAndRolledBack])
        XCTAssertTrue(report.hasPartialSuccess)
        XCTAssertEqual(mismatchAdapter.rollbackValues, [.boolean(false)])
        XCTAssertEqual(report.rollbackPoint.entries.map(\.settingID), [successful.id])
    }

    func testUnavailableProfileResultsPreserveTheirActualReason() async {
        let catalog = makeTestCatalog([])
        let plan = SystemSettingsProfileApplyPlan(
            profileID: UUID(),
            profileName: "Unavailable",
            items: [
                .init(
                    settingID: "provider",
                    title: "Provider",
                    currentValue: nil,
                    desiredValue: .boolean(true),
                    status: .unavailable(.provider, "Missing provider"),
                    isSelected: false
                ),
                .init(
                    settingID: "hardware",
                    title: "Hardware",
                    currentValue: nil,
                    desiredValue: .boolean(true),
                    status: .unavailable(.hardware, "Missing hardware"),
                    isSelected: false
                ),
                .init(
                    settingID: "permission",
                    title: "Permission",
                    currentValue: nil,
                    desiredValue: .boolean(true),
                    status: .unavailable(.permission, "Missing permission"),
                    isSelected: false
                ),
                .init(
                    settingID: "version",
                    title: "Version",
                    currentValue: nil,
                    desiredValue: .boolean(true),
                    status: .unavailable(.systemVersion, "Unsupported version"),
                    isSelected: false
                ),
            ]
        )

        let report = await SystemSettingsProfileApplyCoordinator(catalog: catalog).apply(plan: plan)

        XCTAssertEqual(
            report.results.map(\.kind),
            [.providerUnavailable, .hardwareUnavailable, .permissionMissing, .systemVersionUnavailable]
        )
    }

    func testExportContainsNoSensitiveOrExecutableData() throws {
        let record = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        let profile = SystemSettingsProfile(
            name: "Portable",
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: .finder)]
        )
        let text = String(decoding: try SystemSettingsProfileCodec.encode(profile, catalog: catalog), as: UTF8.self)

        XCTAssertTrue(text.contains("known"))
        XCTAssertFalse(text.contains("command"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("preferenceDomain"))
    }

    func testProfilesRejectMachineSpecificAndSensitiveCatalogValues() {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let deviceSpecific = makeTestRecord(
            id: "device-specific",
            title: "Device",
            portability: .deviceSpecific,
            adapter: adapter
        )
        let sensitive = makeTestRecord(
            id: "sensitive",
            title: "Sensitive",
            portability: .prohibited,
            isSensitive: true,
            adapter: adapter
        )
        let catalog = makeTestCatalog([deviceSpecific, sensitive])
        let profile = SystemSettingsProfile(
            name: "Unsafe",
            entries: [
                .init(settingID: deviceSpecific.id, desiredValue: .boolean(true), category: .finder),
                .init(settingID: sensitive.id, desiredValue: .boolean(true), category: .finder),
            ]
        )

        let validation = SystemSettingsProfileCodec.validate(profile, catalog: catalog)

        XCTAssertTrue(validation.errors.contains(.nonPortableSetting(deviceSpecific.id)))
        XCTAssertTrue(validation.errors.contains(.sensitiveSetting(sensitive.id)))
    }
}
