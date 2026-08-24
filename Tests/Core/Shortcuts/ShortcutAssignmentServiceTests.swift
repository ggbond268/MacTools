import Carbon
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ShortcutAssignmentServiceTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutAssignmentServiceTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAssignmentPersistsAndRegistersThroughInjectedCarbonRegistrar() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: reference),
            .success
        )

        let item = try XCTUnwrap(harness.service.settingsItems.first)
        XCTAssertEqual(item.assignment.reference, reference)
        XCTAssertEqual(item.state, .registered)
        XCTAssertEqual(harness.registrar.registeredBindings, [harness.bindings[0]])
        XCTAssertEqual(
            harness.service.reference(
                forShortcutID: try XCTUnwrap(
                    harness.manager.debugRegistrationsForTests.first {
                        $0.binding == harness.bindings[0]
                    }?.shortcutID
                )
            ),
            reference
        )

        let reloadedStore = ActionShortcutAssignmentStore(defaults: harness.defaults)
        XCTAssertEqual(reloadedStore.assignments(), harness.service.assignments)
    }

    func testCorruptAssignmentPayloadRejectsOrdinaryMutationWithoutOverwritingBytes() throws {
        let harness = try makeHarness()
        let corrupt = Data("not-json".utf8)
        harness.defaults.set(corrupt, forKey: "action-shortcuts.assignments")

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .failure(.recoveryRequired)
        )
        XCTAssertEqual(
            harness.service.clear(harness.references[0]),
            .failure(.recoveryRequired)
        )
        XCTAssertEqual(harness.defaults.data(forKey: "action-shortcuts.assignments"), corrupt)
    }

    func testWrongTypedAssignmentPayloadRequiresRecoveryWithoutOverwritingValue() throws {
        let harness = try makeHarness()
        let key = "action-shortcuts.assignments"
        harness.defaults.set("recovery-sentinel", forKey: key)

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .failure(.recoveryRequired)
        )
        XCTAssertEqual(
            harness.service.clear(harness.references[0]),
            .failure(.recoveryRequired)
        )
        XCTAssertEqual(harness.defaults.object(forKey: key) as? String, "recovery-sentinel")
    }

    func testRejectedAssignmentPayloadWriteRestoresPreviousBytes() {
        let defaults = RejectingActionShortcutDefaults()
        let store = ActionShortcutAssignmentStore(defaults: defaults)
        let first = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "first")
            ),
            binding: ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        )
        XCTAssertEqual(store.replaceAll([first]), .committed)
        let previousData = defaults.data(forKey: "action-shortcuts.assignments")

        defaults.blockedSetKeys = ["action-shortcuts.assignments"]
        let second = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "second")
            ),
            binding: ShortcutBinding(keyCode: 11, modifiers: [.command, .shift])
        )

        XCTAssertEqual(
            store.replaceAll([second]),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(defaults.data(forKey: "action-shortcuts.assignments"), previousData)
        XCTAssertEqual(store.assignments(), [first])
    }

    func testRejectedRecoveryWriteRestoresWrongTypedAssignmentValue() {
        let defaults = ScriptedActionShortcutDefaults()
        let key = "action-shortcuts.assignments"
        defaults.set("recovery-sentinel", forKey: key)
        defaults.payloadWriteBehaviors = [.corrupt, .accept]
        let store = ActionShortcutAssignmentStore(defaults: defaults)
        let record = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "recovered")
            ),
            binding: ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        )

        XCTAssertEqual(
            store.replaceAllForRecovery([record]),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(defaults.object(forKey: key) as? String, "recovery-sentinel")
        XCTAssertTrue(store.assignments().isEmpty)
        XCTAssertNotNil(store.loadError)

        XCTAssertEqual(store.replaceAllForRecovery([record]), .committed)
        XCTAssertEqual(store.assignments(), [record])
        XCTAssertNil(store.loadError)
    }

    func testConflictReplacementIsAtomicAndReservedBindingsCannotBeReplaced() throws {
        let harness = try makeHarness()
        let first = harness.references[0]
        let second = harness.references[1]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: first), .success)

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: second),
            .failure(.conflict(ownerDescription: "操作 1"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [first])

        XCTAssertEqual(
            harness.service.assign(
                harness.bindings[0],
                to: second,
                replacingConflictingActionAssignments: true
            ),
            .success
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])

        let reserved = GlobalShortcutManager.Registration(
            shortcutID: "special.release-aware",
            binding: harness.bindings[1]
        )
        harness.service.synchronize(
            reservedRegistrations: [reserved],
            reservedOwnerDescriptions: [reserved.shortcutID: "亮度连续调节"]
        )
        XCTAssertEqual(
            harness.service.assign(
                harness.bindings[1],
                to: first,
                replacingConflictingActionAssignments: true
            ),
            .failure(.conflict(ownerDescription: "亮度连续调节"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])
    }

    func testPresetReplacementIsConflictCheckedAndAtomic() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[1]),
            .success
        )

        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1"],
                bindingsByActionID: ["action-1": harness.bindings[0]]
            ),
            .failure(.conflict(ownerDescription: "操作 2"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [harness.references[1]])

        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1", "action-2"],
                bindingsByActionID: [
                    "action-1": harness.bindings[0],
                    "action-2": harness.bindings[1],
                ]
            ),
            .success
        )
        XCTAssertEqual(
            Set(harness.service.assignments.map(\.reference)),
            Set(harness.references)
        )

        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1", "action-2"],
                bindingsByActionID: [:]
            ),
            .success
        )
        XCTAssertTrue(harness.service.assignments.isEmpty)
    }

    func testPresetPreviewShowsChangesWithoutMutatingAssignments() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        let assignmentsBeforePreview = harness.service.assignments

        let preview = harness.service.replacementPreview(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1", "action-2"],
            bindingsByActionID: [
                "action-1": harness.bindings[1],
                "action-2": harness.bindings[0],
            ]
        )

        XCTAssertTrue(preview.canApply)
        XCTAssertTrue(preview.hasChanges)
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertEqual(
            preview.items.first(where: { $0.actionID == "action-1" })?.currentBinding,
            harness.bindings[0]
        )
        XCTAssertEqual(harness.service.assignments, assignmentsBeforePreview)
    }

    func testPresetPreviewReportsConvergedAssignmentNormalizationAsAChange() throws {
        let harness = try makeHarness()
        let records = [
            ActionShortcutAssignmentRecord(
                reference: harness.references[0],
                binding: harness.bindings[0]
            ),
            ActionShortcutAssignmentRecord(
                reference: harness.references[0],
                binding: harness.bindings[1]
            ),
        ]
        XCTAssertEqual(
            ActionShortcutAssignmentStore(defaults: harness.defaults).replaceAll(records),
            .committed
        )

        let preview = harness.service.replacementPreview(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: ["action-1": harness.bindings[0]]
        )

        XCTAssertEqual(
            harness.service.currentBindings(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1"]
            )["action-1"],
            harness.bindings
        )
        XCTAssertTrue(preview.hasChanges)
        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1"],
                bindingsByActionID: ["action-1": harness.bindings[0]]
            ),
            .success
        )
        XCTAssertEqual(harness.service.assignments.map(\.binding), [harness.bindings[0]])
    }

    func testReplacementTransactionRestoresExactConvergedRecordsWhenMutationFails() throws {
        let reporter = PreferencesBackupChangeReporter()
        var reportedSources: [PreferencesBackupChangeSource] = []
        reporter.onCommittedChange = { reportedSources.append($0) }
        let harness = try makeHarness(preferencesBackupChangeReporter: reporter)
        let records = [
            ActionShortcutAssignmentRecord(
                reference: harness.references[0],
                binding: harness.bindings[0]
            ),
            ActionShortcutAssignmentRecord(
                reference: harness.references[0],
                binding: harness.bindings[1]
            ),
        ]
        XCTAssertEqual(
            ActionShortcutAssignmentStore(defaults: harness.defaults).replaceAll(records),
            .committed
        )

        let error = harness.service.performReplacementTransaction(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: [:]
        ) {
            "Layout storage failed"
        }

        XCTAssertEqual(error, "Layout storage failed")
        XCTAssertEqual(harness.service.assignments, records)
        XCTAssertEqual(reportedSources, [])
    }

    func testReplacementTransactionReportsChangedAssignmentsAfterMutationSucceeds() throws {
        let reporter = PreferencesBackupChangeReporter()
        var reportedSources: [PreferencesBackupChangeSource] = []
        reporter.onCommittedChange = { reportedSources.append($0) }
        let harness = try makeHarness(preferencesBackupChangeReporter: reporter)

        let error = harness.service.performReplacementTransaction(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: ["action-1": harness.bindings[0]]
        ) {
            nil
        }

        XCTAssertNil(error)
        XCTAssertEqual(reportedSources, [.actionShortcutAssignments])
    }

    func testReplacementTransactionDoesNotReportNoOpAssignments() throws {
        let reporter = PreferencesBackupChangeReporter()
        var reportedSources: [PreferencesBackupChangeSource] = []
        reporter.onCommittedChange = { reportedSources.append($0) }
        let harness = try makeHarness(preferencesBackupChangeReporter: reporter)

        let error = harness.service.performReplacementTransaction(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: [:]
        ) {
            nil
        }

        XCTAssertNil(error)
        XCTAssertEqual(reportedSources, [])
    }

    func testReplacementTransactionDoesNotReportWhenRollbackFails() throws {
        let defaults = ScriptedActionShortcutDefaults()
        let initialRecord = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "action-1")
            ),
            binding: ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        )
        XCTAssertEqual(
            ActionShortcutAssignmentStore(defaults: defaults).replaceAll([initialRecord]),
            .committed
        )

        let reporter = PreferencesBackupChangeReporter()
        var reportedSources: [PreferencesBackupChangeSource] = []
        reporter.onCommittedChange = { reportedSources.append($0) }
        let harness = try makeHarness(
            defaults: defaults,
            preferencesBackupChangeReporter: reporter
        )
        defaults.payloadWriteBehaviors = [.accept, .corrupt, .ignore]

        let error = harness.service.performReplacementTransaction(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: ["action-1": harness.bindings[1]]
        ) {
            "Layout storage failed"
        }

        XCTAssertEqual(
            error,
            "Layout storage failed "
                + ActionShortcutAssignmentError.persistenceRollbackFailed.localizedDescription
        )
        XCTAssertEqual(reportedSources, [])
    }

    func testPresetPreviewReportsConflictOutsideManagedAssignments() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[1]),
            .success
        )

        let preview = harness.service.replacementPreview(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: ["action-1": harness.bindings[0]]
        )

        XCTAssertFalse(preview.canApply)
        XCTAssertEqual(preview.items.first?.conflictOwnerDescription, "操作 2")
        XCTAssertEqual(harness.service.assignments.map(\.reference), [harness.references[1]])
    }

    func testPresetCanPreviewAndClearRetiredManagedAction() throws {
        let harness = try makeHarness()
        let retiredReference = ActionReference(
            key: ActionKey(providerID: "shortcut-tests", actionID: "retired-action")
        )
        let retiredRecord = ActionShortcutAssignmentRecord(
            reference: retiredReference,
            binding: harness.bindings[0]
        )
        XCTAssertEqual(
            ActionShortcutAssignmentStore(defaults: harness.defaults)
                .replaceAll([retiredRecord]),
            .committed
        )

        let preview = harness.service.replacementPreview(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1", "retired-action"],
            bindingsByActionID: ["action-1": harness.bindings[1]]
        )

        XCTAssertTrue(preview.canApply)
        XCTAssertEqual(
            preview.items.first(where: { $0.actionID == "retired-action" })?.currentBinding,
            harness.bindings[0]
        )
        XCTAssertNil(
            preview.items.first(where: { $0.actionID == "retired-action" })?.proposedBinding
        )
        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1", "retired-action"],
                bindingsByActionID: ["action-1": harness.bindings[1]]
            ),
            .success
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [harness.references[0]])
    }

    func testExplicitRetirementRemovesOnlyMatchingPluginAssignments() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        XCTAssertEqual(
            harness.service.assign(harness.bindings[1], to: harness.references[1]),
            .success
        )

        XCTAssertEqual(
            harness.service.removeRetiredAssignments(
                providerID: "shortcut-tests",
                actionIDs: ["action-1"]
            ),
            .success
        )

        XCTAssertEqual(harness.service.assignments.map(\.reference), [harness.references[1]])
        XCTAssertEqual(
            harness.service.removeRetiredAssignments(
                providerID: "shortcut-tests",
                actionIDs: ["action-1"]
            ),
            .success
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [harness.references[1]])
    }

    func testUnavailableAssignmentsAreRetainedButNotRegistered() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: reference), .success)

        harness.registry.synchronize([])
        harness.service.synchronize(
            reservedRegistrations: [],
            reservedOwnerDescriptions: [:]
        )

        XCTAssertEqual(harness.service.assignments.first?.reference, reference)
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .unavailable(reason: FeatureL10n.string("操作不可用。"))
        )
        XCTAssertFalse(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )
    }

    func testAssignmentUnregistersWhenForegroundCapabilityDisappearsAndRecovers() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: reference), .success)
        let provider = ShortcutActionTestProvider()

        func registration(
            capabilities: ActionExecutionCapabilities
        ) -> ActionProviderRegistration {
            let definitions = harness.references.map { reference in
                ActionDefinition(
                    key: reference.key,
                    title: reference.key.actionID,
                    description: "",
                    systemImage: "bolt",
                    externalInvocationPolicy: .allowed,
                    capabilities: capabilities
                )
            }
            return ActionProviderRegistration(
                providerID: reference.key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: definitions,
                catalogEntries: definitions.map {
                    ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
                },
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            )
        }

        harness.registry.synchronize([registration(capabilities: [.background])])
        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])

        XCTAssertEqual(harness.service.assignments.first?.reference, reference)
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .unavailable(reason: FeatureL10n.string("操作不可用。"))
        )
        XCTAssertFalse(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )

        harness.registry.synchronize([
            registration(capabilities: [.background, .foregroundInteractive]),
        ])
        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])

        XCTAssertEqual(harness.service.settingsItems.first?.state, .registered)
        XCTAssertTrue(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )
    }

    func testCarbonRegistrationFailureIsVisibleAndRecoverable() throws {
        let harness = try makeHarness()
        harness.registrar.failures[harness.bindings[0]] = -9876

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .registrationFailed(code: -9876)
        )

        harness.registrar.failures.removeAll()
        harness.service.synchronize(
            reservedRegistrations: [],
            reservedOwnerDescriptions: [:]
        )
        XCTAssertEqual(harness.service.settingsItems.first?.state, .registered)
    }

    func testBindingRevisionChangesOnlyWhenPublishedAssignmentStateChanges() throws {
        let harness = try makeHarness()
        let initialRevision = harness.service.revision

        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(harness.service.revision, initialRevision)

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        let assignedRevision = harness.service.revision
        XCTAssertEqual(assignedRevision, initialRevision + 1)

        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(harness.service.revision, assignedRevision)

        harness.registry.synchronize([])
        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(harness.service.revision, assignedRevision + 1)
    }

    func testLegacyMigrationIsIdempotentAndClearsSourceOnlyAfterPersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ActionShortcutAssignmentStore(userDefaults: defaults)
        let reference = ActionReference(
            key: ActionKey(providerID: "mactools", actionID: "app.open-settings")
        )
        let binding = ShortcutBinding(keyCode: 12, modifiers: [.command, .option])
        var didPersistCount = 0

        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(reference, binding)]) {
                XCTAssertTrue(defaults.bool(forKey: "action-shortcuts.migrated-app-shortcuts"))
                didPersistCount += 1
            },
            .migrated
        )
        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(reference, binding)]) {
                didPersistCount += 1
            },
            .alreadyMigrated
        )
        XCTAssertEqual(didPersistCount, 1)
        XCTAssertEqual(store.assignments().map(\.reference), [reference])
        XCTAssertEqual(store.assignments().map(\.binding), [binding])
    }

    func testStoredActionReferenceAliasesConvergeWithoutDroppingBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ActionShortcutAssignmentStore(userDefaults: defaults)
        let key = ActionKey(providerID: "shortcut-tests", actionID: "migrated")
        let legacy = ActionReference(key: key, schemaVersion: 1)
        let current = ActionReference(key: key, schemaVersion: 2)
        let firstID = UUID()
        let secondID = UUID()
        let binding = ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        let secondBinding = ShortcutBinding(keyCode: 11, modifiers: [.command, .option])
        XCTAssertEqual(
            store.replaceAll([
                ActionShortcutAssignmentRecord(id: firstID, reference: legacy, binding: binding),
                ActionShortcutAssignmentRecord(id: secondID, reference: current, binding: secondBinding),
            ]),
            .committed
        )
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let definition = ActionDefinition(
            key: key,
            parameterSchemaVersion: 2,
            title: "迁移操作",
            description: "测试迁移",
            systemImage: "bolt",
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: current, title: "迁移操作")],
                availability: { _ in .available },
                migrate: { reference, version in
                    ActionReference(
                        key: reference.key,
                        schemaVersion: version,
                        parameters: reference.parameters
                    )
                },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let registrar = FakeCarbonHotKeyRegistrar()
        let service = ShortcutAssignmentService(
            registry: registry,
            store: store,
            shortcutManager: GlobalShortcutManager(registrar: registrar)
        )

        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])

        XCTAssertEqual(service.assignments.map(\.id), [firstID, secondID])
        XCTAssertEqual(service.assignments.map(\.reference), [current, current])
        XCTAssertEqual(service.assignments.map(\.binding), [binding, secondBinding])
        XCTAssertEqual(service.settingsItems.map(\.state), [.registered, .registered])
        XCTAssertEqual(Set(registrar.registeredBindings), Set([binding, secondBinding]))

        let replacement = ShortcutBinding(keyCode: 12, modifiers: [.command, .shift])
        XCTAssertEqual(
            service.assign(replacement, to: current, assignmentID: secondID),
            .success
        )
        XCTAssertEqual(service.assignments.map(\.id), [firstID, secondID])
        XCTAssertEqual(service.assignments.map(\.binding), [binding, replacement])
        XCTAssertEqual(
            service.assign(binding, to: current, assignmentID: secondID),
            .failure(.conflict(ownerDescription: "迁移操作"))
        )

        XCTAssertEqual(service.clear(current, assignmentID: firstID), .success)
        XCTAssertEqual(service.assignments.map(\.id), [secondID])
        XCTAssertEqual(service.assignments.map(\.binding), [replacement])
        XCTAssertEqual(service.settingsItems.map(\.id), [secondID])
    }

    func testLegacyMigrationRejectsMarkerBeforeCleanupAndRollsBackPayload() {
        let defaults = RejectingActionShortcutDefaults()
        let store = ActionShortcutAssignmentStore(defaults: defaults)
        let existing = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "existing")
            ),
            binding: ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        )
        XCTAssertEqual(store.replaceAll([existing]), .committed)
        let previousData = defaults.data(forKey: "action-shortcuts.assignments")
        let migratedReference = ActionReference(
            key: ActionKey(providerID: "shortcut-tests", actionID: "migrated")
        )
        let migratedBinding = ShortcutBinding(keyCode: 11, modifiers: [.command, .shift])
        defaults.blockedSetKeys = ["action-shortcuts.migrated-app-shortcuts"]
        var cleanupCount = 0

        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(migratedReference, migratedBinding)]) {
                cleanupCount += 1
            },
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertFalse(defaults.bool(forKey: "action-shortcuts.migrated-app-shortcuts"))
        XCTAssertEqual(defaults.data(forKey: "action-shortcuts.assignments"), previousData)

        defaults.blockedSetKeys = []
        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(migratedReference, migratedBinding)]) {
                XCTAssertTrue(defaults.bool(forKey: "action-shortcuts.migrated-app-shortcuts"))
                XCTAssertEqual(store.assignments().map(\.reference), [existing.reference, migratedReference])
                cleanupCount += 1
            },
            .migrated
        )
        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(migratedReference, migratedBinding)]) {
                cleanupCount += 1
            },
            .alreadyMigrated
        )
        XCTAssertEqual(cleanupCount, 1)
    }

    func testRollbackFailureReconcilesRuntimeToUnreadableDurablePayload() throws {
        let defaults = ScriptedActionShortcutDefaults()
        let store = ActionShortcutAssignmentStore(defaults: defaults)
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let reference = ActionReference(
            key: ActionKey(providerID: "shortcut-tests", actionID: "action")
        )
        let definition = ActionDefinition(
            key: reference.key,
            title: "操作",
            description: "",
            systemImage: "bolt",
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: reference.key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "操作")],
                availability: { _ in .available },
                begin: { _ in .success(ActionExecutionHandle(operation: { .succeeded() })) }
            ),
        ])
        let originalBinding = ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        XCTAssertEqual(
            store.replaceAll([
                ActionShortcutAssignmentRecord(reference: reference, binding: originalBinding),
            ]),
            .committed
        )
        let manager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let service = ShortcutAssignmentService(registry: registry, store: store, shortcutManager: manager)
        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(service.settingsItems.map(\.state), [.registered])

        defaults.payloadWriteBehaviors = [.corrupt, .ignore]
        let replacement = ShortcutBinding(keyCode: 11, modifiers: [.command, .shift])
        XCTAssertEqual(
            service.assign(replacement, to: reference),
            .failure(.persistenceRollbackFailed)
        )
        XCTAssertTrue(service.settingsItems.isEmpty)
        XCTAssertNil(service.reference(forShortcutID: manager.debugRegistrationsForTests.first?.shortcutID ?? ""))
        XCTAssertTrue(manager.debugRegistrationsForTests.isEmpty)
        XCTAssertNotNil(store.loadError)
    }

    private func makeHarness(
        defaults suppliedDefaults: (any ActionShortcutAssignmentPersisting)? = nil,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) throws -> ShortcutServiceHarness {
        let defaults: any ActionShortcutAssignmentPersisting
        if let suppliedDefaults {
            defaults = suppliedDefaults
        } else {
            let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            userDefaults.removePersistentDomain(forName: suiteName)
            defaults = userDefaults
        }
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let definitions = (1 ... 2).map { index in
            ActionDefinition(
                key: ActionKey(providerID: "shortcut-tests", actionID: "action-\(index)"),
                title: "操作 \(index)",
                description: "测试操作",
                systemImage: "bolt",
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive]
            )
        }
        let entries = definitions.map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
        }
        registry.synchronize([
            ActionProviderRegistration(
                providerID: "shortcut-tests",
                identity: ObjectIdentifier(provider),
                definitions: definitions,
                catalogEntries: entries,
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let service = ShortcutAssignmentService(
            registry: registry,
            store: ActionShortcutAssignmentStore(
                defaults: defaults,
                preferencesBackupChangeReporter: preferencesBackupChangeReporter
            ),
            shortcutManager: manager
        )
        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        return ShortcutServiceHarness(
            defaults: defaults,
            registry: registry,
            registrar: registrar,
            manager: manager,
            service: service,
            references: entries.map(\.reference),
            bindings: [
                ShortcutBinding(keyCode: 10, modifiers: [.command, .option]),
                ShortcutBinding(keyCode: 11, modifiers: [.command, .shift]),
            ]
        )
    }
}

@MainActor
private final class ShortcutActionTestProvider {}

@MainActor
private final class RejectingActionShortcutDefaults: ActionShortcutAssignmentPersisting {
    var blockedSetKeys: Set<String> = []
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) {
        guard !blockedSetKeys.contains(defaultName) else { return }
        values[defaultName] = value
    }
    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

@MainActor
private final class ScriptedActionShortcutDefaults: ActionShortcutAssignmentPersisting {
    enum PayloadWriteBehavior {
        case accept
        case corrupt
        case ignore
    }

    var payloadWriteBehaviors: [PayloadWriteBehavior] = []
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }

    func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "action-shortcuts.assignments", !payloadWriteBehaviors.isEmpty {
            switch payloadWriteBehaviors.removeFirst() {
            case .accept:
                values[defaultName] = value
            case .corrupt:
                values[defaultName] = Data("corrupt".utf8)
            case .ignore:
                break
            }
            return
        }
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

@MainActor
private struct ShortcutServiceHarness {
    let defaults: any ActionShortcutAssignmentPersisting
    let registry: ActionRegistry
    let registrar: FakeCarbonHotKeyRegistrar
    let manager: GlobalShortcutManager
    let service: ShortcutAssignmentService
    let references: [ActionReference]
    let bindings: [ShortcutBinding]
}

@MainActor
final class FakeCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
    var failures: [ShortcutBinding: OSStatus] = [:]
    private(set) var registeredBindings: [ShortcutBinding] = []
    private(set) var unregisteredCount = 0

    func register(
        binding: ShortcutBinding,
        signature: OSType,
        carbonID: UInt32
    ) -> Result<EventHotKeyRef, GlobalShortcutRegistrationError> {
        if let status = failures[binding] {
            return .failure(.system(status))
        }
        registeredBindings.append(binding)
        return .success(OpaquePointer(bitPattern: Int(carbonID))!)
    }

    func unregister(_ reference: EventHotKeyRef) {
        unregisteredCount += 1
    }
}
