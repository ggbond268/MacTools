import Foundation
import XCTest
@testable import MacTools

final class CLIManagedInstallationTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cli-install-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func manifest(build: String = "123.1", host: String = "example.invalid",
                          minimum: Int = 1, maximum: Int = 3, channel: String = "nightly") -> CLIReleaseManifest {
        CLIReleaseManifest(schema: 1, channel: channel, appVersion: "1.3.0", appBuild: build,
            cliVersion: "1.3.0", cliBuild: build, sourceCommit: String(repeating: "a", count: 40),
            sourceRelease: URL(string: "https://\(host)/releases/\(build)")!,
            assetURL: URL(string: "https://\(host)/releases/\(build)/mactools-cli-1.3.0-\(build)-macos-arm64.zip")!,
            sha256: String(repeating: "a", count: 64), size: 100, architecture: "arm64",
            signingIdentifier: channel == "stable" ? "test.mactools.cli" : "test.mactools.nightly.cli", teamIdentifier: "TESTTEAM00",
            protocolMinimum: minimum, protocolMaximum: maximum)
    }

    private func prepare(_ manifest: CLIReleaseManifest) throws -> (CLIManagedStore, CLIManagedReceipt) {
        let store = CLIManagedStore(manifest: manifest, home: home)
        let lock = try store.lock(create: true)
        defer { close(lock) }
        let directory = store.root.appendingPathComponent(manifest.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let data = Data(("fixture-" + manifest.cliBuild).utf8)
        let executable = directory.appendingPathComponent("mactools")
        try data.write(to: executable)
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))
        let receipt = CLIManagedReceipt(owner: store.owner, manifest: manifest, executableHash: cliSHA256(data),
                                        managedPath: executable.path, linkPath: store.command.path)
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"))
        return (store, receipt)
    }

    func testManifestBindsBuildIdentityChannelAndImmutableURL() throws {
        let valid = manifest()
        try valid.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools.nightly", team: "TESTTEAM00")
        XCTAssertThrowsError(try valid.validate(version: "1.3.0", build: "124.1", identifier: "test.mactools.nightly", team: "TESTTEAM00"))
        XCTAssertThrowsError(try valid.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools", team: "TESTTEAM00"))
        XCTAssertThrowsError(try valid.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools.nightly", team: "OTHERTEAM0"))
        let bytes = try JSONEncoder().encode(valid)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (key, value) in ["channel": "stable", "architecture": "x86_64", "sha256": "invalid",
                             "sourceCommit": "unknown", "sourceRelease": "https://example.invalid/current",
                             "assetURL": "http://example.invalid/tool.zip", "cliBuild": "../../outside"] {
            var fields = original
            fields[key] = value
            let tampered = try JSONDecoder().decode(CLIReleaseManifest.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertThrowsError(try tampered.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools.nightly", team: "TESTTEAM00"), key)
        }
    }

    func testStableMetadataRequiresMatchingChannelIdentityAndRelease() throws {
        let valid = manifest(channel: "stable")
        try valid.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools", team: "TESTTEAM00", expectedChannel: "stable")
        XCTAssertThrowsError(try valid.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools", team: "TESTTEAM00", expectedChannel: "nightly"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        for path in ["/releases/download/v1.3.0", "/releases/download/v1.3.1", "/releases/download/nightly-123-1"] {
            var fields = original
            fields["sourceRelease"] = "https://example.invalid" + path
            fields["assetURL"] = "https://example.invalid" + path + "/mactools-cli-1.3.0-123.1-macos-arm64.zip"
            let candidate = try JSONDecoder().decode(CLIReleaseManifest.self, from: JSONSerialization.data(withJSONObject: fields))
            if path == "/releases/download/v1.3.0" {
                try candidate.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools", team: "TESTTEAM00")
            } else {
                XCTAssertThrowsError(try candidate.validate(version: "1.3.0", build: "123.1", identifier: "test.mactools", team: "TESTTEAM00"))
            }
        }
    }

    func testManagedUIRequiresSealedMetadataForStableAndExcludesDevelopment() {
        XCTAssertTrue(CLIInstallChannel.isAvailable(channel: "nightly", hasManifest: false))
        XCTAssertTrue(CLIInstallChannel.isAvailable(channel: "stable", hasManifest: true))
        XCTAssertFalse(CLIInstallChannel.isAvailable(channel: "stable", hasManifest: false))
        for channel in [nil, "development", "beta", ""] {
            XCTAssertFalse(CLIInstallChannel.isAvailable(channel: channel, hasManifest: true))
        }
    }

    func testStableAndNightlyCoexistAcrossUpdateRollbackAndRemoval() throws {
        let (stable, first) = try prepare(manifest(channel: "stable"))
        let (nightly, nightlyFirst) = try prepare(manifest())
        XCTAssertEqual(stable.command.lastPathComponent, "mactools")
        XCTAssertEqual(nightly.command.lastPathComponent, "mactools-nightly")
        XCTAssertNotEqual(stable.root, nightly.root)
        XCTAssertNotEqual(stable.owner, nightly.owner)
        _ = try stable.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        _ = try nightly.activate(nightlyFirst.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let nightlyInode = try XCTUnwrap(CLIManagedStore.entry(nightly.command)).st_ino
        let (_, next) = try prepare(manifest(build: "124.1", channel: "stable"))
        _ = try stable.activate(next.manifest.directoryName, automaticUpdates: true) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: stable.command), Data("fixture-124.1".utf8))
        _ = try stable.activate(first.manifest.directoryName, automaticUpdates: true,
                               rollbackForRelease: next.manifest.directoryName) { _, _ in }
        XCTAssertEqual(try stable.recover()?.rollbackForRelease, next.manifest.directoryName)
        try stable.remove()
        XCTAssertNil(try CLIManagedStore.entry(stable.command))
        XCTAssertEqual(try CLIManagedStore.entry(nightly.command)?.st_ino, nightlyInode)
        XCTAssertEqual(try Data(contentsOf: nightly.command), Data("fixture-123.1".utf8))
        XCTAssertEqual(try nightly.recover()?.active, nightlyFirst.manifest.directoryName)
    }

    func testStableCollisionsPreserveManualHomebrewAndOtherPublisherCommands() throws {
        let (store, first) = try prepare(manifest(channel: "stable"))
        try CLIManagedStore.directory(store.command.deletingLastPathComponent(), create: true)
        for target in ["file", "directory", "/missing", "/opt/homebrew/bin/mactools", "/other-publisher/current/mactools"] {
            if target == "file" { try Data("manual".utf8).write(to: store.command) }
            else if target == "directory" { try FileManager.default.createDirectory(at: store.command, withIntermediateDirectories: false) }
            else { XCTAssertEqual(symlink(target, store.command.path), 0) }
            let inode = try XCTUnwrap(CLIManagedStore.entry(store.command)).st_ino
            XCTAssertThrowsError(try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in })
            XCTAssertEqual(try CLIManagedStore.entry(store.command)?.st_ino, inode)
            try FileManager.default.removeItem(at: store.command)
        }
    }

    func testStableReceiptCannotChangeChannelWhileRetainingOwner() throws {
        let (store, first) = try prepare(manifest(channel: "stable"))
        let receiptURL = URL(fileURLWithPath: first.managedPath).deletingLastPathComponent().appendingPathComponent("receipt.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        var metadata = try XCTUnwrap(fields["manifest"] as? [String: Any])
        metadata["channel"] = "nightly"
        fields["manifest"] = metadata
        try JSONSerialization.data(withJSONObject: fields).write(to: receiptURL)
        XCTAssertThrowsError(try store.receipt(first.manifest.directoryName))
    }

    func testLaunchPolicyRequiresManagedReceiptAndHonorsReleaseSpecificRollback() throws {
        let (_, receipt) = try prepare(manifest())
        XCTAssertFalse(CLIInstallLaunchPolicy.shouldUpdate(receipt: nil, target: manifest(build: "124.1")))
        XCTAssertFalse(CLIInstallLaunchPolicy.shouldUpdate(receipt: receipt, target: manifest()))
        XCTAssertTrue(CLIInstallLaunchPolicy.shouldUpdate(receipt: receipt, target: manifest(build: "124.1")))
        XCTAssertTrue(CLIInstallLaunchPolicy.shouldUpdate(receipt: receipt, target: manifest(build: "122.1")))
    }

    func testRollbackMarkerSurvivesFailedAndInterruptedActivation() throws {
        let (store, first) = try prepare(manifest())
        let (_, next) = try prepare(manifest(build: "124.1"))
        let heldRelease = next.manifest.directoryName
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true,
            rollbackForRelease: heldRelease) { _, _ in }
        XCTAssertThrowsError(try store.activate(next.manifest.directoryName, automaticUpdates: true) { _, _ in
            throw CLIInstallError.filesystem
        })
        XCTAssertEqual(try store.readState()?.rollbackForRelease, heldRelease)
        XCTAssertEqual(try store.readState()?.active, first.manifest.directoryName)
        try store.writeState(CLIManagedState(owner: store.owner, active: next.manifest.directoryName,
            previous: first.manifest.directoryName, automaticUpdates: true, pending: true,
            rollbackForRelease: heldRelease))
        let recovered = try store.recover()
        XCTAssertEqual(recovered?.active, first.manifest.directoryName)
        XCTAssertEqual(recovered?.rollbackForRelease, heldRelease)
        XCTAssertFalse(CLIInstallLaunchPolicy.shouldUpdate(receipt: first, target: next.manifest,
            rollbackForRelease: recovered?.rollbackForRelease))
        XCTAssertTrue(CLIInstallLaunchPolicy.shouldUpdate(receipt: first, target: manifest(build: "125.1"),
            rollbackForRelease: recovered?.rollbackForRelease))
    }

    func testOldStateWithoutRollbackMarkerStillDecodes() throws {
        let legacy = Data(#"{"owner":"test","active":null,"previous":null,"automaticUpdates":false,"pending":false}"#.utf8)
        let state = try JSONDecoder().decode(CLIManagedState.self, from: legacy)
        XCTAssertNil(state.rollbackForRelease)
    }

    func testIncompatibleProtocolFailsClosed() {
        XCTAssertFalse(manifest(minimum: 4, maximum: 5).isCompatible)
        XCTAssertTrue(manifest(minimum: 2, maximum: 3).isCompatible)
        XCTAssertThrowsError(try manifest(minimum: 4, maximum: 5).validate(version: "1.3.0", build: "123.1",
            identifier: "test.mactools.nightly", team: "TESTTEAM00"))
    }

    func testUnsignedAppCannotAuthenticateMetadata() {
        XCTAssertThrowsError(try CLIReleaseManifest.authenticated(bundle: Bundle(for: Self.self)))
    }

    func testDifferentPublishersHaveSeparateOwnership() {
        let official = CLIManagedStore(manifest: manifest(host: "github.com"), home: home)
        let personal = CLIManagedStore(manifest: manifest(), home: home)
        XCTAssertNotEqual(official.owner, personal.owner)
        XCTAssertNotEqual(official.root, personal.root)
        XCTAssertEqual(official.command, personal.command)
    }

    func testInstallUpdateAndRollbackKeepPublicSymlinkInode() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let inode = try XCTUnwrap(CLIManagedStore.entry(store.command)).st_ino
        let (_, second) = try prepare(manifest(build: "124.1"))
        _ = try store.activate(second.manifest.directoryName, automaticUpdates: false) { _, _ in }
        XCTAssertEqual(try CLIManagedStore.entry(store.command)?.st_ino, inode)
        XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-124.1".utf8))
        XCTAssertEqual(try store.readState()?.previous, first.manifest.directoryName)
        XCTAssertEqual(try store.readState()?.automaticUpdates, false)
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: false) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-123.1".utf8))
    }

    func testFailedPostActivationDoctorRestoresPriorVersion() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, next) = try prepare(manifest(build: "124.1"))
        XCTAssertThrowsError(try store.activate(next.manifest.directoryName, automaticUpdates: true) { _, _ in
            throw CLIInstallError.validation
        })
        XCTAssertEqual(try store.readState()?.active, first.manifest.directoryName)
        XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-123.1".utf8))
        XCTAssertFalse(try XCTUnwrap(store.readState()).pending)
    }

    func testFailedFirstActivationLeavesNoCommand() throws {
        let (store, first) = try prepare(manifest())
        XCTAssertThrowsError(try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in
            throw CLIInstallError.validation
        })
        XCTAssertNil(try CLIManagedStore.entry(store.command))
        XCTAssertNil(try store.readState()?.active)
    }

    func testInterruptedUpdateRecoversBeforeAndAfterPointerSwitch() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, next) = try prepare(manifest(build: "124.1"))
        for switched in [false, true] {
            try store.writeState(CLIManagedState(owner: store.owner, active: next.manifest.directoryName,
                previous: first.manifest.directoryName, automaticUpdates: true, pending: true))
            if switched {
                let current = store.root.appendingPathComponent("current")
                XCTAssertEqual(unlink(current.path), 0)
                XCTAssertEqual(symlink(next.manifest.directoryName, current.path), 0)
            }
            _ = try store.recover()
            XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-123.1".utf8))
            XCTAssertEqual(try store.readState()?.active, first.manifest.directoryName)
        }
    }

    func testFilesDirectoriesAndDanglingSymlinksAreNeverOverwritten() throws {
        let (store, first) = try prepare(manifest())
        try CLIManagedStore.directory(store.command.deletingLastPathComponent(), create: true)
        for kind in ["file", "directory", "dangling", "foreign"] {
            switch kind {
            case "file": try Data("manual".utf8).write(to: store.command)
            case "directory": try FileManager.default.createDirectory(at: store.command, withIntermediateDirectories: false)
            default: XCTAssertEqual(symlink(kind == "dangling" ? "/missing" : "/opt/homebrew/bin/mactools", store.command.path), 0)
            }
            let before = try XCTUnwrap(CLIManagedStore.entry(store.command))
            XCTAssertThrowsError(try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }, kind)
            XCTAssertEqual(try CLIManagedStore.entry(store.command)?.st_ino, before.st_ino, kind)
            try FileManager.default.removeItem(at: store.command)
        }
    }

    func testReplacedCommandAndTamperedReceiptsBlockRemoval() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        XCTAssertEqual(unlink(store.command.path), 0)
        try Data("manual".utf8).write(to: store.command)
        XCTAssertThrowsError(try store.remove())
        XCTAssertEqual(try Data(contentsOf: store.command), Data("manual".utf8))
        try Data("modified".utf8).write(to: URL(fileURLWithPath: first.managedPath))
        XCTAssertThrowsError(try store.receipt(first.manifest.directoryName))
    }

    func testSymlinkedParentsAndExecutablesAreRejected() throws {
        let (store, first) = try prepare(manifest())
        let executable = URL(fileURLWithPath: first.managedPath)
        XCTAssertEqual(unlink(executable.path), 0)
        XCTAssertEqual(symlink("/bin/sh", executable.path), 0)
        XCTAssertThrowsError(try store.receipt(first.manifest.directoryName))
        let local = home.appendingPathComponent(".local")
        XCTAssertEqual(symlink("/tmp", local.path), 0)
        XCTAssertThrowsError(try CLIManagedStore.directory(store.command.deletingLastPathComponent(), create: true))
    }

    func testRetentionAndRemovalPreserveUnrecognizedFiles() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, second) = try prepare(manifest(build: "124.1"))
        _ = try store.activate(second.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, third) = try prepare(manifest(build: "125.1"))
        let active = try store.activate(third.manifest.directoryName, automaticUpdates: true) { _, _ in }
        try store.prune(keeping: active)
        XCTAssertNil(try CLIManagedStore.entry(URL(fileURLWithPath: first.managedPath)))
        let unexpected = store.root.appendingPathComponent("user-file")
        try Data("preserve".utf8).write(to: unexpected)
        XCTAssertThrowsError(try store.remove())
        XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-125.1".utf8))
        try FileManager.default.removeItem(at: unexpected)
        try store.remove()
        XCTAssertNil(try CLIManagedStore.entry(store.command))
        XCTAssertNil(try store.readState()?.active)
    }

    func testConcurrentInstallationLockIsExclusive() throws {
        let store = CLIManagedStore(manifest: manifest(), home: home)
        let first = try store.lock(create: true)
        defer { close(first) }
        XCTAssertThrowsError(try store.lock(create: false))
    }

    private func interruptDeletion(_ directory: URL, after removed: Int) throws {
        for file in ["mactools", "LICENSE", "receipt.json"].prefix(removed) {
            XCTAssertEqual(unlink(directory.appendingPathComponent(file).path), 0)
        }
        if removed == 4 { XCTAssertEqual(rmdir(directory.path), 0) }
    }

    func testInterruptedPruningResumesAfterEveryDeletionStepAndPreservesRollback() throws {
        let (store, previous) = try prepare(manifest(build: "124.1"))
        _ = try store.activate(previous.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, active) = try prepare(manifest(build: "125.1"))
        _ = try store.activate(active.manifest.directoryName, automaticUpdates: true) { _, _ in }
        for removed in 0...4 {
            let (_, old) = try prepare(manifest(build: "\(100 + removed).1"))
            let directory = try store.beginVersionDeletion(old.manifest.directoryName)
            XCTAssertNil(try CLIManagedStore.entry(URL(fileURLWithPath: old.managedPath)))
            try interruptDeletion(directory, after: removed)

            let relaunched = CLIManagedStore(manifest: active.manifest, home: home)
            let state = try XCTUnwrap(relaunched.recover())
            try relaunched.prune(keeping: state)
            XCTAssertNil(try CLIManagedStore.entry(directory))
            XCTAssertEqual(state.active, active.manifest.directoryName)
            XCTAssertEqual(state.previous, previous.manifest.directoryName)
            XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-125.1".utf8))
        }
        let (_, next) = try prepare(manifest(build: "126.1"))
        _ = try store.activate(next.manifest.directoryName, automaticUpdates: true) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-126.1".utf8))
    }

    func testInterruptedRemovalResumesAfterEveryDeletionStepAndAllowsReinstall() throws {
        for removed in 0...4 {
            let (store, first) = try prepare(manifest())
            _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
            // Removal has committed its empty state before retiring the version directory.
            XCTAssertEqual(unlink(store.command.path), 0)
            XCTAssertEqual(unlink(store.root.appendingPathComponent("current").path), 0)
            try store.writeState(CLIManagedState(owner: store.owner, active: nil, previous: nil,
                automaticUpdates: false, pending: false))
            let directory = try store.beginVersionDeletion(first.manifest.directoryName)
            try interruptDeletion(directory, after: removed)

            let relaunched = CLIManagedStore(manifest: first.manifest, home: home)
            try relaunched.remove()
            XCTAssertNil(try CLIManagedStore.entry(directory))
            XCTAssertNil(try CLIManagedStore.entry(store.command))
            XCTAssertNil(try relaunched.readState()?.active)
            let (_, next) = try prepare(manifest(build: "124.1"))
            _ = try relaunched.activate(next.manifest.directoryName, automaticUpdates: true) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-124.1".utf8))
            try relaunched.remove()
        }
    }

    func testDeletionCannotRetireActiveOrRollbackVersions() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, next) = try prepare(manifest(build: "124.1"))
        _ = try store.activate(next.manifest.directoryName, automaticUpdates: true) { _, _ in }
        for receipt in [first, next] {
            XCTAssertThrowsError(try store.beginVersionDeletion(receipt.manifest.directoryName))
            XCTAssertEqual(try store.receipt(receipt.manifest.directoryName), receipt)
        }
    }

    func testDeletionRecoveryRejectsForeignFilesLinksAndTampering() throws {
        for kind in ["extra", "symlink", "hardlink", "executable", "receipt", "missing-receipt"] {
            let (store, first) = try prepare(manifest())
            let directory = try store.beginVersionDeletion(first.manifest.directoryName)
            let executable = directory.appendingPathComponent("mactools")
            let receiptURL = directory.appendingPathComponent("receipt.json")
            switch kind {
            case "extra": try Data("preserve".utf8).write(to: directory.appendingPathComponent("user-file"))
            case "symlink":
                XCTAssertEqual(unlink(executable.path), 0)
                XCTAssertEqual(symlink("/bin/sh", executable.path), 0)
            case "hardlink": XCTAssertEqual(link(executable.path, home.appendingPathComponent("linked-cli").path), 0)
            case "executable": try Data("modified".utf8).write(to: executable)
            case "receipt":
                let foreign = CLIManagedReceipt(owner: "foreign", manifest: first.manifest,
                    executableHash: first.executableHash, managedPath: first.managedPath, linkPath: first.linkPath)
                try JSONEncoder().encode(foreign).write(to: receiptURL)
            default: XCTAssertEqual(unlink(receiptURL.path), 0)
            }
            let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            XCTAssertThrowsError(try store.recover(), kind)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before, kind)
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testPartialLiveVersionIsNotAdoptedAsInterruptedDeletion() throws {
        let (store, first) = try prepare(manifest())
        XCTAssertEqual(unlink(first.managedPath), 0)
        XCTAssertThrowsError(try store.deleteVersion(first.manifest.directoryName))
        XCTAssertNotNil(try CLIManagedStore.entry(URL(fileURLWithPath: first.managedPath)
            .deletingLastPathComponent().appendingPathComponent("receipt.json")))
    }

    func testInterruptedRemovalRestoresPreviousVersionAndMissingCommand() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        try store.writeState(CLIManagedState(owner: store.owner, active: nil,
            previous: first.manifest.directoryName, automaticUpdates: true, pending: true))
        XCTAssertEqual(unlink(store.command.path), 0)
        XCTAssertEqual(unlink(store.root.appendingPathComponent("current").path), 0)
        _ = try store.recover()
        XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-123.1".utf8))
    }

    func testInterruptedDownloadCleansOnlyMarkedStagingFiles() throws {
        let (store, _) = try prepare(manifest())
        let stage = store.root.appendingPathComponent(".stage-" + UUID().uuidString)
        try CLIManagedStore.directory(stage, create: true)
        try Data(store.owner.utf8).write(to: stage.appendingPathComponent("owner"))
        try Data("partial".utf8).write(to: stage.appendingPathComponent("archive.zip"))
        try store.cleanStaging()
        XCTAssertNil(try CLIManagedStore.entry(stage))
        try CLIManagedStore.directory(stage, create: true)
        try Data(store.owner.utf8).write(to: stage.appendingPathComponent("owner"))
        try Data("preserve".utf8).write(to: stage.appendingPathComponent("user-file"))
        XCTAssertThrowsError(try store.cleanStaging())
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("user-file")), Data("preserve".utf8))
    }

    func testInterruptedFinalStagingMoveRecoversUsingCompletedReceipt() throws {
        let (store, first) = try prepare(manifest())
        let stage = store.root.appendingPathComponent(".stage-" + UUID().uuidString)
        try FileManager.default.moveItem(at: store.root.appendingPathComponent(first.manifest.directoryName), to: stage)
        try store.cleanStaging()
        XCTAssertNil(try CLIManagedStore.entry(stage))
    }

    func testForeignCommandDuringInterruptedRemovalPreservesJournal() throws {
        let (store, first) = try prepare(manifest())
        _ = try store.activate(first.manifest.directoryName, automaticUpdates: true) { _, _ in }
        try store.writeState(CLIManagedState(owner: store.owner, active: nil,
            previous: first.manifest.directoryName, automaticUpdates: true, pending: true))
        XCTAssertEqual(unlink(store.command.path), 0)
        try Data("foreign".utf8).write(to: store.command)
        XCTAssertThrowsError(try store.recover())
        XCTAssertEqual(try Data(contentsOf: store.command), Data("foreign".utf8))
        XCTAssertTrue(try XCTUnwrap(store.readState()).pending)
    }

    func testReceiptCannotSubstituteAnotherSigningTeamWhileKeepingOwnerString() throws {
        let (store, first) = try prepare(manifest())
        let receiptURL = URL(fileURLWithPath: first.managedPath).deletingLastPathComponent().appendingPathComponent("receipt.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        var metadata = try XCTUnwrap(fields["manifest"] as? [String: Any])
        metadata["teamIdentifier"] = "OTHERTEAM0"
        fields["manifest"] = metadata
        try JSONSerialization.data(withJSONObject: fields).write(to: receiptURL)
        XCTAssertThrowsError(try store.receipt(first.manifest.directoryName))
    }

    func testFailedUpdatePreservesThePreviousSuccessfulRollbackTarget() throws {
        let (store, oldest) = try prepare(manifest(build: "122.1"))
        _ = try store.activate(oldest.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, current) = try prepare(manifest())
        _ = try store.activate(current.manifest.directoryName, automaticUpdates: true) { _, _ in }
        let (_, failed) = try prepare(manifest(build: "124.1"))
        XCTAssertThrowsError(try store.activate(failed.manifest.directoryName, automaticUpdates: true) { _, _ in
            throw CLIInstallError.validation
        })
        XCTAssertEqual(try store.readState()?.active, current.manifest.directoryName)
        XCTAssertEqual(try store.readState()?.previous, oldest.manifest.directoryName)
        XCTAssertNil(try store.readState()?.recoveryPrevious)
    }
}
