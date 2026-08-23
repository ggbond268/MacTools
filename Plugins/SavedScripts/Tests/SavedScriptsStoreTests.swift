import XCTest
@testable import SavedScriptsPlugin

@MainActor
final class SavedScriptsStoreTests: XCTestCase {
    func testSaveNormalizesSortsAndPersistsStableIdentifiers() throws {
        let storage = SavedScriptsTestStorage()
        let store = SavedScriptsStore(storage: storage)
        let firstID = UUID()

        let first = try XCTUnwrap(store.save(SavedScript(
            id: firstID,
            name: "  Zebra  ",
            kind: .zsh,
            source: "echo zebra",
            workingDirectory: "  ~/Projects  "
        )).get())
        _ = try store.save(SavedScript(
            name: "Alpha",
            kind: .appleScript,
            source: "return 1"
        )).get()

        XCTAssertEqual(first.name, "Zebra")
        XCTAssertEqual(first.workingDirectory, "~/Projects")
        XCTAssertEqual(store.scripts.map(\.name), ["Alpha", "Zebra"])

        let reloaded = SavedScriptsStore(storage: storage)
        XCTAssertEqual(reloaded.scripts.map(\.name), ["Alpha", "Zebra"])
        XCTAssertEqual(reloaded.script(id: firstID)?.actionID, "run.\(firstID.uuidString.lowercased())")
    }

    func testExecutionRevisionAdvancesOnlyWhenPublishedStateChanges() throws {
        let storage = SavedScriptsTestStorage()
        let store = SavedScriptsStore(storage: storage)
        XCTAssertEqual(store.revision, 0)

        var script = try store.save(SavedScript(
            name: "Mutable",
            kind: .zsh,
            source: "echo first"
        )).get()
        XCTAssertEqual(store.revision, 1)

        script.source = "echo second"
        _ = try store.save(script).get()
        XCTAssertEqual(store.revision, 2)

        storage.blocksWrites = true
        script.source = "echo rejected"
        XCTAssertThrowsError(try store.save(script).get())
        XCTAssertEqual(store.revision, 2)
    }

    func testPortableBackupIncludesOnlyOptedInSourceAndRemovesWorkingDirectory() throws {
        let source = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let included = try source.save(SavedScript(
            name: "Portable",
            kind: .bash,
            source: "printf portable",
            workingDirectory: "/private/example",
            includeSourceInBackup: true
        )).get()
        _ = try source.save(SavedScript(
            name: "Private",
            kind: .zsh,
            source: "printf private",
            includeSourceInBackup: false
        )).get()

        let backup = try XCTUnwrap(source.portableBackup())
        let restored = SavedScriptsStore(storage: SavedScriptsTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertEqual(restored.scripts.count, 1)
        XCTAssertEqual(restored.scripts.first?.id, included.id)
        XCTAssertEqual(restored.scripts.first?.source, "printf portable")
        XCTAssertEqual(restored.scripts.first?.workingDirectory, "")
    }

    func testIdenticalSaveAndPortableRestoreDoNotReportMutation() throws {
        let store = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let script = try store.save(SavedScript(
            name: "Portable",
            kind: .zsh,
            source: "echo portable",
            includeSourceInBackup: true
        )).get()
        let backup = try XCTUnwrap(store.portableBackup())
        var mutationCount = 0
        store.onMutation = { mutationCount += 1 }

        _ = try store.save(script).get()
        XCTAssertTrue(store.restorePortableBackup(backup))

        XCTAssertEqual(mutationCount, 0)
    }

    func testPortableRestoreRequiresRenewedTrustForExecution() throws {
        let source = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let included = try source.save(SavedScript(
            name: "Imported",
            kind: .bash,
            source: "printf imported",
            workingDirectory: "/private/example",
            confirmOutsideManager: false,
            allowExternalInvocation: true,
            includeSourceInBackup: true
        )).get()
        let backup = try XCTUnwrap(source.portableBackup())

        let destination = SavedScriptsStore(storage: SavedScriptsTestStorage())
        XCTAssertTrue(destination.restorePortableBackup(backup))

        let restored = try XCTUnwrap(destination.script(id: included.id))
        XCTAssertEqual(restored.source, included.source)
        XCTAssertEqual(restored.workingDirectory, "")
        XCTAssertTrue(restored.confirmOutsideManager)
        XCTAssertFalse(restored.allowExternalInvocation)
    }

    func testPortableRestoreReplacesScriptsAbsentFromBackup() throws {
        let source = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let included = try source.save(SavedScript(
            name: "Portable",
            kind: .bash,
            source: "printf portable",
            includeSourceInBackup: true
        )).get()
        let backup = try XCTUnwrap(source.portableBackup())

        let destination = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let localOnly = try destination.save(SavedScript(
            name: "Local Only",
            kind: .zsh,
            source: "printf local"
        )).get()

        XCTAssertTrue(destination.restorePortableBackup(backup))
        XCTAssertEqual(destination.scripts.map(\.id), [included.id])
        XCTAssertNil(destination.script(id: localOnly.id))
    }

    func testCorruptPayloadFailsClosedWithoutDeletingOriginalBytes() {
        let storage = SavedScriptsTestStorage()
        let corrupt = Data("not-json".utf8)
        storage.values["library.v1"] = corrupt

        let store = SavedScriptsStore(storage: storage)

        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertEqual(store.loadError, "invalid-saved-scripts-library")
        XCTAssertThrowsError(try store.save(SavedScript(
            name: "Must Not Overwrite",
            kind: .zsh,
            source: "echo protected"
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .recoveryRequired)
        }
        XCTAssertFalse(store.remove(id: UUID()))
        XCTAssertEqual(storage.data(forKey: "library.v1"), corrupt)
    }

    func testWriteReadbackFailureKeepsPublishedAndStoredLibraryUnchanged() throws {
        let storage = SavedScriptsTestStorage()
        let store = SavedScriptsStore(storage: storage)
        let original = try store.save(SavedScript(
            name: "Original",
            kind: .zsh,
            source: "echo original"
        )).get()
        let storedData = try XCTUnwrap(storage.data(forKey: "library.v1"))
        var changed = original
        changed.source = "echo changed"
        storage.blocksWrites = true

        XCTAssertThrowsError(try store.save(changed).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .persistenceFailed)
        }
        XCTAssertEqual(store.scripts, [original])
        XCTAssertEqual(storage.data(forKey: "library.v1"), storedData)
    }

    func testCorruptingWriteRestoresPreviousLibraryBytes() throws {
        let storage = SavedScriptsTestStorage()
        let store = SavedScriptsStore(storage: storage)
        let original = try store.save(SavedScript(
            name: "Original",
            kind: .zsh,
            source: "echo original"
        )).get()
        let storedData = try XCTUnwrap(storage.data(forKey: "library.v1"))
        var changed = original
        changed.source = "echo changed"
        storage.enqueueWriteBehaviors([.corrupt, .accept], forKey: "library.v1")

        XCTAssertThrowsError(try store.save(changed).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .persistenceFailed)
        }
        XCTAssertEqual(store.scripts, [original])
        XCTAssertEqual(storage.data(forKey: "library.v1"), storedData)
        XCTAssertEqual(SavedScriptsStore(storage: storage).scripts, [original])
    }

    func testFailedWriteRollbackReloadsRecoveryRequiredState() throws {
        let storage = SavedScriptsTestStorage()
        let store = SavedScriptsStore(storage: storage)
        let original = try store.save(SavedScript(
            name: "Original",
            kind: .zsh,
            source: "echo original"
        )).get()
        var changed = original
        changed.source = "echo changed"
        storage.enqueueWriteBehaviors([.corrupt, .ignore], forKey: "library.v1")

        XCTAssertThrowsError(try store.save(changed).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .persistenceFailed)
        }
        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertEqual(store.loadError, "invalid-saved-scripts-library")
        XCTAssertEqual(storage.object(forKey: "library.v1") as? String, "corrupt")
    }

    func testWrongTypedLibraryIsRecoveryRequiredAndNotOverwritten() {
        let storage = SavedScriptsTestStorage()
        storage.values["library.v1"] = "invalid"
        let store = SavedScriptsStore(storage: storage)

        XCTAssertEqual(store.loadError, "invalid-saved-scripts-library")
        XCTAssertThrowsError(try store.save(SavedScript(
            name: "Must Not Overwrite",
            kind: .zsh,
            source: "echo protected"
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .recoveryRequired)
        }
        XCTAssertEqual(storage.object(forKey: "library.v1") as? String, "invalid")
    }

    func testUnreadableLibraryDoesNotExportAnEmptyReplacementBackup() throws {
        let unreadableValues: [Any] = [
            "wrong-type",
            Data("malformed".utf8),
        ]

        for unreadableValue in unreadableValues {
            let sourceStorage = SavedScriptsTestStorage()
            sourceStorage.values["library.v1"] = unreadableValue
            let source = SavedScriptsStore(storage: sourceStorage)
            let destination = SavedScriptsStore(storage: SavedScriptsTestStorage())
            let retained = try destination.save(SavedScript(
                name: "Retained",
                kind: .zsh,
                source: "echo retained"
            )).get()

            let backup = source.portableBackup()
            if let backup {
                XCTFail("Unreadable source must not export a replacement payload")
                _ = destination.restorePortableBackup(backup)
            }

            XCTAssertNil(backup)
            XCTAssertEqual(destination.scripts, [retained])
            XCTAssertTrue(
                (sourceStorage.object(forKey: "library.v1") as? NSObject)?
                    .isEqual(unreadableValue) == true
            )
        }
    }

    func testValidationRejectsEmptyOversizedAndOutOfRangeScripts() {
        let store = SavedScriptsStore(storage: SavedScriptsTestStorage())
        XCTAssertThrowsError(try store.save(SavedScript(
            name: " ",
            kind: .zsh,
            source: "echo"
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .emptyName)
        }
        XCTAssertThrowsError(try store.save(SavedScript(
            name: "Timeout",
            kind: .zsh,
            source: "echo",
            timeoutSeconds: 301
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .invalidTimeout)
        }
        XCTAssertThrowsError(try store.save(SavedScript(
            name: "Large",
            kind: .zsh,
            source: String(repeating: "x", count: SavedScript.maximumSourceByteCount + 1)
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .sourceTooLong)
        }
    }

    func testDuplicateGetsANewStableIdentifierAndLocalizedSuffix() throws {
        let store = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let original = try store.save(SavedScript(
            name: "Report",
            kind: .sh,
            source: "echo report"
        )).get()

        let copy = try store.duplicate(id: original.id, copySuffix: "副本").get()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Report 副本")
        XCTAssertEqual(copy.source, original.source)
        XCTAssertNotEqual(copy.actionID, original.actionID)
    }
}
