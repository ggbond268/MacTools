import XCTest
@testable import MacSettingsPlugin

@MainActor
final class SystemSettingsProfileTests: XCTestCase {

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
