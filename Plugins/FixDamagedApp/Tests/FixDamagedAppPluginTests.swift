import Darwin
import Foundation
import XCTest
import MacToolsPluginKit
@testable import FixDamagedAppPlugin

@MainActor
final class FixDamagedAppPluginTests: XCTestCase {
    func testPluginContract() {
        let plugin = FixDamagedAppPlugin()

        XCTAssertEqual(plugin.metadata.id, "fix-damaged-app")
        XCTAssertEqual(plugin.rowDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.rowDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.rowState.isEnabled)
        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertEqual(plugin.panelItems.map(\.id), ["control", "quick-control"])
        XCTAssertNil(plugin.panelItems.last?.initialPlacement)
    }

    func testManifestPanelCapabilitiesMatchRuntimeContract() throws {
        struct Manifest: Decodable {
            struct Capabilities: Decodable {
                let panelItems: [String]
            }

            let capabilities: Capabilities
        }

        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugin.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let plugin = FixDamagedAppPlugin()

        XCTAssertEqual(manifest.capabilities.panelItems, plugin.panelItems.map { $0.kind.rawValue })
    }

    func testCanonicalActionWaitsForRepairCompletion() async throws {
        let repair = FixDamagedAppRepairMock()
        let appURL = URL(fileURLWithPath: "/Applications/Test.app")
        let plugin = FixDamagedAppPlugin(
            appChooser: { appURL },
            quarantineRemover: { try await repair.removeQuarantine(at: $0) }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)

        let handle = try plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        )
        let resultTask = Task { await handle.result() }
        for _ in 0 ..< 20 where repair.paths.isEmpty { await Task.yield() }

        XCTAssertEqual(repair.paths, [appURL.path])
        XCTAssertFalse(plugin.rowState.isEnabled)
        repair.finish()
        let result = await resultTask.value
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.rowState.isEnabled)
    }

    func testCanonicalActionTreatsDismissedChooserAsCancellation() async throws {
        var removerCallCount = 0
        let plugin = FixDamagedAppPlugin(
            appChooser: { nil },
            quarantineRemover: { _ in removerCallCount += 1 }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(removerCallCount, 0)
    }

    func testCanonicalActionSurfacesRepairFailure() async throws {
        let plugin = FixDamagedAppPlugin(
            appChooser: { URL(fileURLWithPath: "/Applications/Test.app") },
            quarantineRemover: { _ in
                throw NSError(
                    domain: "FixDamagedAppPluginTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Repair rejected"]
                )
            }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(result, .failed(message: "Repair rejected"))
        XCTAssertEqual(plugin.rowState.errorMessage, "Repair rejected")
    }

    func testCanonicalActionMapsAuthorizationCancellation() async throws {
        let plugin = FixDamagedAppPlugin(
            appChooser: { URL(fileURLWithPath: "/Applications/Test.app") },
            quarantineRemover: { _ in throw NSError(domain: "FixDamagedAppPlugin", code: -128) }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testCanonicalActionCancellationCancelsTheRepairOperation() async throws {
        let plugin = FixDamagedAppPlugin(
            appChooser: { URL(fileURLWithPath: "/Applications/Test.app") },
            quarantineRemover: { _ in
                try await Task.sleep(for: .seconds(30))
            }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        )
        let task = Task { await handle.result() }
        for _ in 0 ..< 20 where plugin.rowState.isEnabled {
            await Task.yield()
        }

        handle.cancel()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(plugin.rowState.isEnabled)
    }

    nonisolated func testDefaultProcessExecutionTerminatesItsProcessGroupOnCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("repair.pid")
        let execution = FixDamagedAppProcessExecution(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM; echo $$ > \"$1\"; while :; do sleep 1; done",
                "mactools-fix-test",
                pidFile.path,
            ]
        )
        let task = Task { try await execution.run() }
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected process cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        for _ in 0 ..< 100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

@MainActor
private final class FixDamagedAppRepairMock {
    private(set) var paths: [String] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func removeQuarantine(at path: String) async throws {
        paths.append(path)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
