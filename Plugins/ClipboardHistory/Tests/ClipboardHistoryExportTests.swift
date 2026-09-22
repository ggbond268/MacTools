import AppKit
import Foundation
import ImageIO
import PDFKit
import MacToolsPluginKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryExportTests: XCTestCase {
    func testEmbeddedPDFExportsOriginalBytesAndFulfillsFilePromise() async throws {
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        })), at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let payload = ClipboardHistoryPayload(pasteboardItems: [ClipboardStoredPasteboardItem(representations: [
            ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.pdf, data: data),
        ])])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(item: item, payload: payload, format: .original, baseName: "Document")
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(item: item, payload: payload, plan: plan, baseName: "Document")
        XCTAssertEqual(artifacts.first?.data, data)

        let bundle = await ClipboardHistoryFilePromiseFactory.makeBundle(item: item, localization: PluginLocalization(bundle: .main), onSuccess: {})
        let provider = try XCTUnwrap(bundle?.writers.first as? NSFilePromiseProvider)
        let delegate = try XCTUnwrap(bundle?.delegates.first)
        let destination = try makeTemporaryDirectory().appendingPathComponent("Promised.pdf")
        let error: (any Error)? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testMalformedEmbeddedPDFIsRejected() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [ClipboardStoredPasteboardItem(representations: [
            ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.pdf, data: Data("not a PDF".utf8)),
        ])])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(item: item, payload: payload, format: .original, baseName: "Document")
        do {
            _ = try await ClipboardHistoryExportService.makeArtifacts(item: item, payload: payload, plan: plan, baseName: "Document")
            XCTFail("Malformed PDF must not be exported")
        } catch { XCTAssertEqual(error as? ClipboardExportError, .invalidPayload) }
    }

    func testNamingSanitizesUnsafeCharactersAndFindsCollisionFreeURL() throws {
        XCTAssertEqual(
            ClipboardHistoryExportNaming.sanitizedBaseName("  A/B:C\n  D  "),
            "A-B-C D"
        )

        let directory = try makeTemporaryDirectory()
        let first = directory.appendingPathComponent("Export.txt")
        try Data().write(to: first)
        XCTAssertEqual(
            try ClipboardHistoryExportNaming.availableURL(
                in: directory,
                preferredFileName: "Export.txt"
            ).lastPathComponent,
            "Export 2.txt"
        )
    }

    func testPlainTextExportUsesFullPayloadInsteadOfBoundedSearchText() async throws {
        let text = String(repeating: "abcdef", count: 2_000)
        let payload = ClipboardHistoryPayload.plainText(text)
        let item = item(payload: payload)
        XCTAssertLessThan(item.text.count, text.count)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .plainText,
            baseName: "Clipboard Text"
        )

        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Text"
        )

        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(String(data: try XCTUnwrap(artifacts[0].data), encoding: .utf8), text)
    }

    func testImageExportConvertsToRequestedFormatAndValidatesOutput() async throws {
        let payload = imagePayload()
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .jpeg,
            baseName: "Clipboard Image"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Image"
        )

        let data = try XCTUnwrap(artifacts[0].data)
        XCTAssertEqual(artifacts[0].contentTypeIdentifier, UTType.jpeg.identifier)
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
    }

    func testImageExportRejectsOversizedDeclaredDimensionsBeforeDecode() async throws {
        let data = try imageData(declaringWidth: 40_000, height: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(ClipboardImageExportPolicy.dimensions(of: source)?.width, 40_000)
        let payload = imagePayload(data: data)
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .png,
            baseName: "Unsafe Image"
        )

        do {
            _ = try await ClipboardHistoryExportService.makeArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: "Unsafe Image"
            )
            XCTFail("An oversized declared dimension must be rejected before bitmap decoding")
        } catch {
            XCTAssertEqual(error as? ClipboardExportError, .invalidPayload)
        }
    }

    func testRichHTMLSanitizerBlocksExecutableAndRemoteResources() {
        let html = """
        <html><head><link rel="stylesheet" href="https://example.com/a.css"></head>
        <body onload="steal()"><script>steal()</script><img src="https://example.com/a.png"><a href="https://example.com">Link</a></body></html>
        """
        let sanitized = ClipboardRichDocumentExporter.sanitizeHTML(html)

        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("stylesheet"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("onload"))
        XCTAssertFalse(sanitized.contains("src=\"https://"))
        XCTAssertTrue(sanitized.contains("href=\"https://example.com\""))
    }

    func testBatchWriteUsesUniqueGroupAndRejectsTraversal() throws {
        let directory = try makeTemporaryDirectory()
        let plan = ClipboardExportPlan(
            itemID: UUID(),
            format: .plainText,
            destination: .folder,
            suggestedName: "Clipboard Export.txt",
            contentTypeIdentifier: UTType.plainText.identifier,
            expectedArtifactCount: 2
        )
        let artifacts = [
            ClipboardExportArtifact(
                relativePath: "One.txt",
                contentTypeIdentifier: UTType.plainText.identifier,
                data: Data("one".utf8)
            ),
            ClipboardExportArtifact(
                relativePath: "Two.txt",
                contentTypeIdentifier: UTType.plainText.identifier,
                data: Data("two".utf8)
            ),
        ]

        let first = try ClipboardHistoryExportService.write(
            artifacts: artifacts,
            plan: plan,
            destinationURL: directory
        )
        let second = try ClipboardHistoryExportService.write(
            artifacts: artifacts,
            plan: plan,
            destinationURL: directory
        )
        XCTAssertEqual(first[0].deletingLastPathComponent().lastPathComponent, "Clipboard Export")
        XCTAssertEqual(second[0].deletingLastPathComponent().lastPathComponent, "Clipboard Export 2")

        let unsafe = ClipboardExportArtifact(
            relativePath: "Assets/../../Outside.txt",
            contentTypeIdentifier: UTType.plainText.identifier,
            data: Data()
        )
        XCTAssertThrowsError(try ClipboardHistoryExportService.write(
            artifacts: [unsafe, artifacts[0]],
            plan: plan,
            destinationURL: directory
        )) { error in
            XCTAssertEqual(error as? ClipboardExportError, .unsafeDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("Outside.txt").path
        ))

        XCTAssertThrowsError(try ClipboardHistoryExportService.write(
            artifacts: [artifacts[0]],
            plan: plan,
            destinationURL: directory
        )) { error in
            XCTAssertEqual(error as? ClipboardExportError, .invalidPayload)
        }
    }

    func testExplicitWriteDoesNotReplaceDestinationCreatedAfterApproval() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("Export.txt")
        let plan = singleFilePlan(destination: destination)
        let snapshot = try ClipboardHistoryExportService.destinationSnapshot(at: destination)

        XCTAssertThrowsError(try ClipboardHistoryExportService.writeExplicitFile(
            artifacts: [textArtifact("approved export")],
            plan: plan,
            destinationURL: destination,
            expectedDestination: snapshot,
            beforeCommit: {
                try Data("new owner".utf8).write(to: destination)
            }
        )) { error in
            XCTAssertEqual(error as? ClipboardExportError, .unsafeDestination)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new owner")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains(where: { $0.hasPrefix(".mactools-export-") }))
    }

    func testExplicitWriteReplacesUnchangedApprovedDestination() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("Export.txt")
        try Data("original".utf8).write(to: destination)
        let plan = singleFilePlan(destination: destination)
        let snapshot = try ClipboardHistoryExportService.destinationSnapshot(at: destination)

        let written = try ClipboardHistoryExportService.writeExplicitFile(
            artifacts: [textArtifact("replacement")],
            plan: plan,
            destinationURL: destination,
            expectedDestination: snapshot
        )

        XCTAssertEqual(written, [destination])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "replacement")
    }

    func testCopyToFolderCleansPartialStageAndCommittedFilesOnFailure() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("Source.txt")
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source)

        XCTAssertThrowsError(try ClipboardHistoryExportCoordinator.copy(
            sourceURLs: [source],
            to: destination,
            copyItem: { _, stage in
                try Data("partial".utf8).write(to: stage)
                throw ClipboardCopyTestError.injectedFailure
            }
        ))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testDetachedExportWorkPropagatesCancellation() async {
        let probe = ClipboardCancellationProbe()
        let task = Task {
            try await ClipboardHistoryExportAsyncWork.run {
                try probe.runUntilCancelled()
            }
        }
        while !probe.started {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled export work should throw")
        } catch is CancellationError {
            XCTAssertTrue(probe.observedCancellation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func item(
        payload: ClipboardHistoryPayload,
        imageSearchText: String? = nil,
        hasCompletedImageTextIndexing: Bool = false
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: imageSearchText,
            hasCompletedImageTextIndexing: hasCompletedImageTextIndexing
        )
    }

    private func imagePayload() -> ClipboardHistoryPayload {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let data = bitmap.representation(using: .png, properties: [:])!
        return imagePayload(data: data)
    }

    private func imagePayload(data: Data) -> ClipboardHistoryPayload {
        ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: data
                ),
            ]),
        ])
    }

    private func imageData(declaringWidth width: UInt32, height: UInt32) throws -> Data {
        var data = try XCTUnwrap(imagePayload().representations.first?.data)
        guard data.count >= 33,
              String(data: data[12..<16], encoding: .ascii) == "IHDR" else {
            throw ClipboardExportError.invalidPayload
        }
        data.replaceSubrange(16..<20, with: bytes(of: width.bigEndian))
        data.replaceSubrange(20..<24, with: bytes(of: height.bigEndian))
        let checksum = crc32(data[12..<29]).bigEndian
        data.replaceSubrange(29..<33, with: bytes(of: checksum))
        return data
    }

    private func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    private func crc32(_ bytes: Data.SubSequence) -> UInt32 {
        var checksum = UInt32.max
        for byte in bytes {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = checksum & 1 == 1
                    ? (checksum >> 1) ^ 0xEDB8_8320
                    : checksum >> 1
            }
        }
        return checksum ^ UInt32.max
    }

    private func singleFilePlan(destination: URL) -> ClipboardExportPlan {
        ClipboardExportPlan(
            itemID: UUID(),
            format: .plainText,
            destination: .file,
            suggestedName: destination.lastPathComponent,
            contentTypeIdentifier: UTType.plainText.identifier,
            expectedArtifactCount: 1
        )
    }

    private func textArtifact(_ text: String) -> ClipboardExportArtifact {
        ClipboardExportArtifact(
            relativePath: "Export.txt",
            contentTypeIdentifier: UTType.plainText.identifier,
            data: Data(text.utf8)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private enum ClipboardCopyTestError: Error {
    case injectedFailure
}

private final class ClipboardCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didObserveCancellation = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didObserveCancellation
    }

    func runUntilCancelled() throws {
        lock.lock()
        didStart = true
        lock.unlock()
        do {
            while true {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.001)
            }
        } catch {
            lock.lock()
            didObserveCancellation = true
            lock.unlock()
            throw error
        }
    }
}
