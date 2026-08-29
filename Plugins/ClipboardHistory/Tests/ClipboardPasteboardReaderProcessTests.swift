import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardPasteboardReaderProcessTests: XCTestCase {
    func testHelperReadsMultipleClipboardRevisionsWithoutRelaunching() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first", forType: .string))
        let first = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: first), "first")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("second", forType: .string))
        let second = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: second), "second")
        let launchCount = await reader.launchCountForTesting
        XCTAssertEqual(launchCount, 1)
    }

    func testResidentMemoryWatchdogStopsWhileReusableHelperIsIdle() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("idle", forType: .string))
        let stateFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-watchdog-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: stateFileURL) }
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            helperArguments: ["--watchdog-state-file", stateFileURL.path],
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        let response = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: response), "idle")

        var states = ""
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: stateFileURL) {
                states = String(decoding: data, as: UTF8.self)
            }
            if states == "active\nidle\n" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(states, "active\nidle\n")
        let helperRemainsReusable = await reader.hasLiveSessionForTesting
        XCTAssertTrue(helperRemainsReusable)

        try await Task.sleep(for: .milliseconds(100))
        let unchangedStates = try Data(contentsOf: stateFileURL)
        XCTAssertEqual(String(decoding: unchangedStates, as: UTF8.self), states)
    }

    func testHelperReadsOnlyPlainTextForPlainTextRequest() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let response = try await reader.read(request(for: pasteboard, kind: .plainText))
        XCTAssertEqual(response.status, .payload)
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].representations.count, 1)
        XCTAssertEqual(response.items[0].representations[0].typeIdentifier, ClipboardRepresentationType.plainText)
        XCTAssertEqual(plainText(in: response), "plain")
    }

    func testPlainTextRequestRejectsSensitiveProducerTypesAndRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sensitiveItem = NSPasteboardItem()
        XCTAssertTrue(sensitiveItem.setString("secret", forType: .string))
        XCTAssertTrue(sensitiveItem.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sensitiveItem]))
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        let sensitiveResponse = try await reader.read(request(for: pasteboard, kind: .plainText))
        XCTAssertEqual(sensitiveResponse.status, .unsafe)
        XCTAssertNil(plainText(in: sensitiveResponse))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("public", forType: .string))
        let recovered = try await reader.read(request(for: pasteboard, kind: .plainText))
        XCTAssertEqual(plainText(in: recovered), "public")
    }

    func testPlainTextRequestEnforcesByteLimitAndReaderRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("too long", forType: .string))
        let oversized = try await reader.read(
            request(for: pasteboard, kind: .plainText, maximumByteCount: 3)
        )
        XCTAssertEqual(oversized.status, .oversized)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("ok", forType: .string))
        let recovered = try await reader.read(request(for: pasteboard, kind: .plainText))
        XCTAssertEqual(plainText(in: recovered), "ok")
    }

    @MainActor
    func testProductionPlainTextReadTimesOutStalledLazyOwnerAndRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let owner = Process()
        let readinessPipe = Pipe()
        owner.executableURL = helperURL
        owner.arguments = ["--stall-plain-text-owner", pasteboard.name.rawValue]
        owner.standardOutput = readinessPipe
        owner.standardError = FileHandle.nullDevice
        try owner.run()
        defer {
            if owner.isRunning { owner.terminate() }
            pasteboard.clearContents()
        }
        let readiness = try readinessPipe.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(readiness.flatMap { String(data: $0, encoding: .utf8) }, "ready\n")

        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .milliseconds(75)
        )
        let access = GeneralClipboardPasteboard(
            pasteboard: pasteboard,
            payloadReader: reader
        )
        defer { Task { await reader.stop() } }
        let stalledChangeCount = pasteboard.changeCount
        let readTask = Task { @MainActor in
            await access.readPlainTextAsynchronously(
                maximumByteCount: 1_024,
                expectedChangeCount: stalledChangeCount
            )
        }
        await Task.yield()
        let mainActorRemainedResponsive = await Task { @MainActor in true }.value
        XCTAssertTrue(mainActorRemainedResponsive)
        let stalledResult = await readTask.value
        XCTAssertEqual(stalledResult, .changed)
        let hasLiveSession = await reader.hasLiveSessionForTesting
        XCTAssertFalse(hasLiveSession)

        if owner.isRunning { owner.terminate() }
        owner.waitUntilExit()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("recovered", forType: .string))
        let recovered = await access.readPlainTextAsynchronously(
            maximumByteCount: 1_024,
            expectedChangeCount: pasteboard.changeCount
        )
        XCTAssertEqual(recovered, .payload(.plainText("recovered")))
        let launchCount = await reader.launchCountForTesting
        XCTAssertEqual(launchCount, 2)
    }

    func testNeverRespondingHelperIsKilledWithinDeadline() async throws {
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { URL(fileURLWithPath: "/bin/sleep") },
            helperArguments: ["60"],
            requestTimeout: .milliseconds(50)
        )
        let request = ClipboardPasteboardReaderRequest(
            pasteboardName: NSPasteboard.Name.general.rawValue,
            maximumByteCount: 1_024,
            expectedChangeCount: NSPasteboard.general.changeCount
        )

        do {
            _ = try await reader.read(request)
            XCTFail("A helper that never responds must time out")
        } catch {
            XCTAssertTrue(error is ClipboardPasteboardReaderProcess.TimeoutError
                || error is ClipboardPasteboardReaderWireError)
        }
        let hasLiveSession = await reader.hasLiveSessionForTesting
        let launchCount = await reader.launchCountForTesting
        XCTAssertFalse(hasLiveSession)
        XCTAssertEqual(launchCount, 1)
    }

    func testExitedHelperIsRelaunchedForTheNextClipboardRevision() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            helperArguments: ["--maximum-requests", "1"],
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first", forType: .string))
        let first = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: first), "first")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("second", forType: .string))
        let second = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: second), "second")
        let launchCount = await reader.launchCountForTesting
        XCTAssertEqual(launchCount, 2)
    }

    func testConcurrentRequestsKeepEachResponsePairedWithItsRequest() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboards = (0..<8).map { index -> NSPasteboard in
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("value-\(index)", forType: .string))
            return pasteboard
        }
        defer { pasteboards.forEach { $0.releaseGlobally() } }
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            helperArguments: ["--response-delay-milliseconds", "20"],
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        let results = try await withThrowingTaskGroup(
            of: (Int, ClipboardPasteboardReaderResponse).self
        ) { group in
            for (index, pasteboard) in pasteboards.enumerated() {
                let request = request(for: pasteboard)
                group.addTask {
                    (index, try await reader.read(request))
                }
            }
            var results: [(Int, ClipboardPasteboardReaderResponse)] = []
            for try await result in group { results.append(result) }
            return results
        }

        for (index, response) in results {
            XCTAssertEqual(plainText(in: response), "value-\(index)")
        }
        let launchCount = await reader.launchCountForTesting
        XCTAssertEqual(launchCount, 1)
    }

    func testHugeLazyRepresentationIsRejectedAndReaderRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let owner = Process()
        let readinessPipe = Pipe()
        owner.executableURL = helperURL
        owner.arguments = [
            "--large-data-owner", pasteboard.name.rawValue,
            "--large-data-byte-count", String(128 * 1_024 * 1_024),
        ]
        owner.standardOutput = readinessPipe
        owner.standardError = FileHandle.nullDevice
        try owner.run()
        defer {
            if owner.isRunning { owner.terminate() }
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let readiness = try readinessPipe.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(readiness.flatMap { String(data: $0, encoding: .utf8) }, "ready\n")

        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            helperArguments: ["--memory-headroom-byte-count", String(64 * 1_024 * 1_024)],
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }
        let oversized = try await reader.read(request(
            for: pasteboard,
            kind: .completeSnapshot,
            maximumByteCount: 1 * 1_024 * 1_024
        ))
        XCTAssertEqual(oversized.status, .oversized)

        if owner.isRunning { owner.terminate() }
        owner.waitUntilExit()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("recovered", forType: .string))
        let recovered = try await reader.read(request(
            for: pasteboard,
            kind: .completeSnapshot
        ))
        XCTAssertEqual(plainText(in: recovered), "recovered")
    }

    func testHelperMemoryCeilingTerminatesPrivateAllocationAndRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let oversizedPasteboard = NSPasteboard.withUniqueName()
        let recoveryPasteboard = NSPasteboard.withUniqueName()
        defer {
            oversizedPasteboard.releaseGlobally()
            recoveryPasteboard.releaseGlobally()
        }
        oversizedPasteboard.clearContents()
        XCTAssertTrue(oversizedPasteboard.setString("trigger", forType: .string))
        recoveryPasteboard.clearContents()
        XCTAssertTrue(recoveryPasteboard.setString("recovered", forType: .string))

        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            helperArguments: [
                "--memory-headroom-byte-count", String(96 * 1_024 * 1_024),
                "--allocate-when-pasteboard-name", oversizedPasteboard.name.rawValue,
                "--allocate-byte-count", String(256 * 1_024 * 1_024),
            ],
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        do {
            _ = try await reader.read(request(for: oversizedPasteboard))
            XCTFail("The helper must terminate when its private memory ceiling is exceeded")
        } catch {
            let hasLiveSession = await reader.hasLiveSessionForTesting
            XCTAssertFalse(hasLiveSession)
        }

        let recovered = try await reader.read(request(for: recoveryPasteboard))
        XCTAssertEqual(plainText(in: recovered), "recovered")
    }

    private func request(
        for pasteboard: NSPasteboard,
        kind: ClipboardPasteboardReaderRequest.Kind = .payload,
        maximumByteCount: Int = 1_024 * 1_024
    ) -> ClipboardPasteboardReaderRequest {
        ClipboardPasteboardReaderRequest(
            kind: kind,
            pasteboardName: pasteboard.name.rawValue,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: pasteboard.changeCount
        )
    }

    private func plainText(in response: ClipboardPasteboardReaderResponse) -> String? {
        response.items.lazy
            .flatMap(\.representations)
            .first { $0.typeIdentifier == ClipboardRepresentationType.plainText }
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    private static var helperURL: URL? {
        var directory = Bundle(for: Self.self).bundleURL
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("ClipboardHistory.bundle", isDirectory: true)
                .appendingPathComponent("Contents/Resources/PasteboardReaderHelper", isDirectory: true)
                .appendingPathComponent("mactools-clipboard-pasteboard-reader-helper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
