import AppKit
import Foundation
import ImageIO
import MacToolsPluginKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryExportTests: XCTestCase {
    func testPDFSharingPreservesPDFDataInsteadOfDegradingToEmbeddedText() async {
        let pdfData = Data("%PDF-1.7 test".utf8)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("Searchable PDF text".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.pdf,
                    data: pdfData
                ),
            ]),
        ])

        let preparedShare = await ClipboardHistoryShareCoordinator.prepareSingleShare(
            for: item(payload: payload)
        )
        XCTAssertEqual(preparedShare, .PDF(pdfData))
    }

    func testPlannerOffersExpectedFormatsAndDefaults() throws {
        let richPayload = try richTextPayload("Title\nBody")
        let richItem = item(payload: richPayload)
        let richOptions = ClipboardHistoryExportPlanner.options(for: richItem)

        XCTAssertEqual(richOptions.map(\.format), [.html, .pdf, .markdown, .plainText, .original])
        XCTAssertEqual(richOptions.filter(\.isDefault).map(\.format), [.html])

        let plainItem = item(payload: .plainText("Plain note"))
        let plainOptions = ClipboardHistoryExportPlanner.options(for: plainItem)
        XCTAssertEqual(plainOptions.map(\.format), [.plainText, .markdown, .pdf])
        XCTAssertEqual(plainOptions.filter(\.isDefault).map(\.format), [.plainText])

        let imageItem = item(payload: imagePayload())
        XCTAssertEqual(ClipboardHistoryExportPlanner.defaultFormat(for: imageItem), .png)
    }

    func testPlannerUsesFolderForMultipleEmbeddedImages() throws {
        let representation = imagePayload().pasteboardItems[0].representations[0]
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [representation]),
            ClipboardStoredPasteboardItem(representations: [representation]),
        ])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .png,
            baseName: "Clipboard Image"
        )

        XCTAssertEqual(plan.destination, .folder)
        XCTAssertEqual(plan.expectedArtifactCount, 2)
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

    func testPlainTextExportsMarkdownVerbatimAndReadablePDF() async throws {
        let text = "# Heading\n\nLiteral <tag> & **markers**"
        let payload = ClipboardHistoryPayload.plainText(text)
        let item = item(payload: payload)

        let markdownPlan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .markdown,
            baseName: "Clipboard Text"
        )
        let markdownArtifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: markdownPlan,
            baseName: "Clipboard Text"
        )
        XCTAssertEqual(markdownPlan.suggestedName, "Clipboard Text.md")
        XCTAssertEqual(
            String(data: try XCTUnwrap(markdownArtifacts[0].data), encoding: .utf8),
            text
        )

        let html = try ClipboardRichDocumentExporter.plainTextHTML(for: payload)
        XCTAssertTrue(html.contains("Literal &lt;tag&gt; &amp; **markers**"), html)
        XCTAssertFalse(html.contains("Literal <tag>"), html)

        let pdfPlan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .pdf,
            baseName: "Clipboard Text"
        )
        let pdfArtifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: pdfPlan,
            baseName: "Clipboard Text"
        )
        XCTAssertEqual(pdfPlan.suggestedName, "Clipboard Text.pdf")
        XCTAssertTrue(try XCTUnwrap(pdfArtifacts[0].data).starts(with: Data("%PDF".utf8)))
    }

    func testRecognizedTextExportRunsRecognizerInsteadOfUsingSearchIndex() async throws {
        let payload = imagePayload()
        let item = item(
            payload: payload,
            imageSearchText: "bounded old result",
            hasCompletedImageTextIndexing: true
        )
        let recognized = String(repeating: "recognized ", count: 2_500)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .recognizedText,
            baseName: "Clipboard Image"
        )

        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Image",
            recognizer: StaticClipboardRecognizer(text: recognized)
        )

        XCTAssertEqual(String(data: try XCTUnwrap(artifacts[0].data), encoding: .utf8), recognized)
        XCTAssertGreaterThan(recognized.count, 20_000)
    }

    func testRecognizedTextExportPropagatesCancellationInsteadOfReportingUnavailable() async throws {
        let payload = imagePayload()
        let item = item(payload: payload)
        let recognizer = CancellableClipboardRecognizer()
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .recognizedText,
            baseName: "Clipboard Image"
        )
        let task = Task {
            try await ClipboardHistoryExportService.makeArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: "Clipboard Image",
                recognizer: recognizer
            )
        }
        while !recognizer.started { await Task.yield() }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled OCR export should throw cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExportRecognizerProcessesEveryImageWithoutIndexTruncation() async throws {
        let first = String(repeating: "first", count: 5_000)
        let second = String(repeating: "second", count: 5_000)
        let payload = ClipboardHistoryPayload(pasteboardItems: [Data([1]), Data([2])].map { data in
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: data
                ),
            ])
        })
        let recognizer = VisionClipboardImageTextExportRecognizer { data in
            data == Data([1]) ? first : second
        }

        let recognizedText = await recognizer.recognizeText(in: payload)
        let text = try XCTUnwrap(recognizedText)

        XCTAssertEqual(text, first + "\n\n" + second)
        XCTAssertGreaterThan(text.count, 20_000)
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

    func testLinkExportCreatesWebLocationPropertyList() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.url,
                    data: Data("https://example.com/path".utf8)
                ),
            ]),
        ])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .webLocation,
            baseName: "Clipboard Link"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Link"
        )
        let object = try PropertyListSerialization.propertyList(
            from: try XCTUnwrap(artifacts[0].data),
            options: [],
            format: nil
        ) as? [String: String]

        XCTAssertEqual(object?["URL"], "https://example.com/path")
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

    func testRichHTMLInlinesAttachmentImagesWithoutFileReferences() throws {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(data: try XCTUnwrap(imagePayload().representations.first?.data))
        let attributed = NSMutableAttributedString(string: "Before ")
        attributed.append(NSAttributedString(attachment: attachment))
        attributed.append(NSAttributedString(string: " After"))
        let rtfd = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtfd,
                    data: rtfd
                ),
            ]),
        ])

        let html = String(decoding: try ClipboardRichDocumentExporter.html(for: payload), as: UTF8.self)

        XCTAssertTrue(html.contains("data:image/png;base64,"), html)
        XCTAssertFalse(html.localizedCaseInsensitiveContains("file://"), html)
    }

    func testRichTextExportsHTMLMarkdownPlainTextAndPDF() async throws {
        let payload = try richTextPayload("Title\nBody link")
        let item = item(payload: payload)

        for format in [ClipboardExportFormat.html, .markdown, .plainText, .pdf] {
            let plan = try ClipboardHistoryExportPlanner.makePlan(
                item: item,
                payload: payload,
                format: format,
                baseName: "Clipboard Rich Text"
            )
            let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: "Clipboard Rich Text"
            )
            let data = try XCTUnwrap(artifacts[0].data)
            XCTAssertFalse(data.isEmpty, format.rawValue)
            if format == .html {
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Content-Security-Policy"))
            } else if format == .markdown {
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Title"))
            } else if format == .pdf {
                XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
            }
        }
    }

    func testOriginalRTFDExportUsesDeterministicRTFDExtensionAndFlatType() async throws {
        let payload = try rtfdPayload(includeRTFFallback: false)
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .original,
            baseName: "Clipboard Rich Text"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Rich Text"
        )

        XCTAssertEqual(plan.suggestedName, "Clipboard Rich Text.rtfd")
        XCTAssertEqual(artifacts[0].contentTypeIdentifier, UTType.flatRTFD.identifier)
        XCTAssertEqual(artifacts[0].relativePath, "Clipboard Rich Text.rtfd")
        XCTAssertNotNil(ClipboardRichText.attributedString(for: payload))
    }

    func testOriginalRichExportPrefersRTFDBeforeRTF() async throws {
        let payload = try rtfdPayload(includeRTFFallback: true)
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .original,
            baseName: "Clipboard Rich Text"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Rich Text"
        )

        XCTAssertEqual(artifacts[0].contentTypeIdentifier, UTType.flatRTFD.identifier)
    }

    func testOriginalRichExportPrefersRTFDEvenWhenRTFComesFirst() async throws {
        let source = try rtfdPayload(includeRTFFallback: true)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: Array(source.representations.reversed())),
        ])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .original,
            baseName: "Clipboard Rich Text"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Rich Text"
        )

        XCTAssertEqual(plan.suggestedName, "Clipboard Rich Text.rtfd")
        XCTAssertEqual(artifacts[0].contentTypeIdentifier, UTType.flatRTFD.identifier)
    }

    func testCorruptRTFDCannotPassValidationThroughValidRTFFallback() async throws {
        let fallback = try XCTUnwrap(richTextPayload("Valid fallback").representations.first(where: {
            $0.typeIdentifier == ClipboardRepresentationType.rtf
        }))
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtfd,
                    data: Data("not rtfd".utf8)
                ),
                fallback,
            ]),
        ])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .original,
            baseName: "Clipboard Rich Text"
        )

        do {
            _ = try await ClipboardHistoryExportService.makeArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: "Clipboard Rich Text"
            )
            XCTFail("Corrupt RTFD should not be exported")
        } catch {
            XCTAssertEqual(error as? ClipboardExportError, .invalidPayload)
        }
    }

    func testCorruptOriginalRTFIsRejected() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data("not rtf".utf8)
                ),
            ]),
        ])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .original,
            baseName: "Clipboard Rich Text"
        )

        do {
            _ = try await ClipboardHistoryExportService.makeArtifacts(
                item: item,
                payload: payload,
                plan: plan,
                baseName: "Clipboard Rich Text"
            )
            XCTFail("Corrupt RTF should not be exported")
        } catch {
            XCTAssertEqual(error as? ClipboardExportError, .invalidPayload)
        }
    }

    func testMarkdownUsesLocalizedAttachmentNamesAndLinksNonImageAttachments() async throws {
        let attachment = NSTextAttachment()
        let wrapper = FileWrapper(regularFileWithContents: Data("%PDF-1.7\n%%EOF".utf8))
        wrapper.preferredFilename = "Spec.pdf"
        attachment.fileWrapper = wrapper
        let attributed = NSMutableAttributedString(string: "Document ")
        attributed.append(NSAttributedString(attachment: attachment))
        let range = NSRange(location: 0, length: attributed.length)
        let rtfd = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtfd,
                    data: rtfd
                ),
            ]),
        ])
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .markdown,
            baseName: "剪贴板富文本",
            markdownAttachmentDirectorySuffix: "附件",
            markdownAttachmentBaseName: "附件"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "剪贴板富文本"
        )
        let markdown = String(decoding: try XCTUnwrap(artifacts[0].data), as: UTF8.self)

        XCTAssertEqual(artifacts[1].relativePath, "剪贴板富文本-附件/附件 1.pdf")
        XCTAssertTrue(markdown.contains("[Spec\\.pdf]("), markdown)
        XCTAssertFalse(markdown.contains("![Spec\\.pdf]("), markdown)
    }

    func testUntypedAttachmentsDoNotReceiveGenericBinFallback() {
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: Data("opaque".utf8))

        XCTAssertNil(ClipboardRichDocumentExporter.attachmentData(attachment))
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

    func testExplicitWriteDoesNotReplaceDestinationChangedAfterApproval() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("Export.txt")
        try Data("original".utf8).write(to: destination)
        let plan = singleFilePlan(destination: destination)
        let snapshot = try ClipboardHistoryExportService.destinationSnapshot(at: destination)

        XCTAssertThrowsError(try ClipboardHistoryExportService.writeExplicitFile(
            artifacts: [textArtifact("approved export")],
            plan: plan,
            destinationURL: destination,
            expectedDestination: snapshot,
            beforeCommit: {
                try Data("changed after approval and deliberately longer".utf8).write(to: destination)
            }
        )) { error in
            XCTAssertEqual(error as? ClipboardExportError, .unsafeDestination)
        }
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "changed after approval and deliberately longer"
        )
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

    func testExplicitWriteCancellationCleansStageWithoutCreatingDestination() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("Export.txt")
        let plan = singleFilePlan(destination: destination)

        XCTAssertThrowsError(try ClipboardHistoryExportService.writeExplicitFile(
            artifacts: [textArtifact("cancelled")],
            plan: plan,
            destinationURL: destination,
            expectedDestination: .absent,
            beforeCommit: { throw CancellationError() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCollisionAllocationRemainsDeterministicPastTenThousand() throws {
        let index = try ClipboardHistoryExportNaming.firstAvailableCollisionIndex { candidate in
            candidate <= 10_000
        }

        XCTAssertEqual(index, 10_001)
    }

    func testSoundIsConsistentlyUnsupportedWhileConcreteMediaIsCounted() async throws {
        let sound = ClipboardStoredPasteboardItem(representations: [
            ClipboardStoredRepresentation(
                typeIdentifier: ClipboardRepresentationType.sound,
                data: Data("sound".utf8)
            ),
        ])
        let soundPayload = ClipboardHistoryPayload(pasteboardItems: [sound])
        XCTAssertTrue(ClipboardHistoryExportPlanner.options(for: item(payload: soundPayload)).isEmpty)

        let media = ClipboardStoredPasteboardItem(representations: [
            ClipboardStoredRepresentation(
                typeIdentifier: UTType.mp3.identifier,
                data: Data("ID3".utf8)
            ),
        ])
        let mixedPayload = ClipboardHistoryPayload(pasteboardItems: [sound, media])
        let mixedItem = item(payload: mixedPayload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: mixedItem,
            payload: mixedPayload,
            format: .original,
            baseName: "Clipboard Media"
        )
        let artifacts = try await ClipboardHistoryExportService.makeArtifacts(
            item: mixedItem,
            payload: mixedPayload,
            plan: plan,
            baseName: "Clipboard Media"
        )

        XCTAssertEqual(plan.expectedArtifactCount, 1)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].contentTypeIdentifier, UTType.mp3.identifier)
    }

    func testFileReferenceDragUsesNativeURLs() async throws {
        let directory = try makeTemporaryDirectory()
        let first = directory.appendingPathComponent("One.txt")
        let second = directory.appendingPathComponent("Two.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let payload = ClipboardHistoryPayload(pasteboardItems: [first, second].map { url in
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(url.absoluteString.utf8)
                ),
            ])
        })
        let item = item(payload: payload)
        let optionalBundle = await ClipboardHistoryFilePromiseFactory.makeBundle(
            item: item,
            localization: PluginLocalization(bundle: .main),
            onSuccess: {}
        )
        let bundle = try XCTUnwrap(optionalBundle)

        XCTAssertEqual(bundle.writers.count, 2)
        XCTAssertTrue(bundle.delegates.isEmpty)
        XCTAssertTrue(bundle.writers.allSatisfy { $0 is NSURL })
    }

    func testFileReferenceValidationIsOffMainAndAllOrNothing() async throws {
        let directory = try makeTemporaryDirectory()
        let existing = directory.appendingPathComponent("Existing.txt")
        let missing = directory.appendingPathComponent("Missing.txt")
        try Data("existing".utf8).write(to: existing)
        let observation = ClipboardThreadObservation()

        let validated = await ClipboardHistoryFileReferenceValidator.validate(
            urls: [existing, missing]
        ) { url in
            observation.record(isMainThread: Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.01)
            return FileManager.default.fileExists(atPath: url.path)
        }

        XCTAssertNil(validated)
        XCTAssertFalse(observation.observedMainThread)

        let payload = ClipboardHistoryPayload(pasteboardItems: [existing, missing].map { url in
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(url.absoluteString.utf8)
                ),
            ])
        })
        let bundle = await ClipboardHistoryFilePromiseFactory.makeBundle(
            item: item(payload: payload),
            localization: PluginLocalization(bundle: .main),
            onSuccess: {}
        )
        XCTAssertNil(bundle)
    }

    func testCancellingFileReferenceValidationStopsRemainingFilesystemProbes() async {
        let urls = (0..<1_024).map { URL(fileURLWithPath: "/tmp/clipboard-reference-\($0)") }
        let probe = ClipboardFileValidationProbe()
        let task = Task {
            await ClipboardHistoryFileReferenceValidator.validate(urls: urls) { _ in
                probe.recordProbe()
                Thread.sleep(forTimeInterval: 0.002)
                return true
            }
        }
        while probe.count == 0 { await Task.yield() }

        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertLessThan(probe.count, urls.count)
    }

    func testPromiseProviderRetainsDelegateAfterBundleIsReleased() async throws {
        var bundle: ClipboardHistoryPromiseBundle? = await ClipboardHistoryFilePromiseFactory.makeBundle(
            item: item(payload: imagePayload()),
            localization: PluginLocalization(bundle: .main),
            onSuccess: {}
        )
        let provider = try XCTUnwrap(bundle?.writers.first as? NSFilePromiseProvider)
        weak let delegate = bundle?.delegates.first

        bundle = nil

        XCTAssertNotNil(delegate)
        XCTAssertTrue((provider.userInfo as AnyObject?) === delegate)
        provider.userInfo = nil
        XCTAssertNil(delegate)
    }

    func testPromiseDelegateWritesToExactSuppliedDestination() async throws {
        let payload = imagePayload()
        let item = item(payload: payload)
        let plan = try ClipboardHistoryExportPlanner.makePlan(
            item: item,
            payload: payload,
            format: .png,
            baseName: "Clipboard Image"
        )
        let loader = ClipboardHistoryPromisedArtifactLoader(
            item: item,
            payload: payload,
            plan: plan,
            baseName: "Clipboard Image"
        )
        let delegate = ClipboardHistoryFilePromiseDelegate(
            artifactLoader: loader,
            plan: plan,
            artifactIndex: 0,
            promisedFileName: plan.suggestedName,
            contentTypeIdentifier: UTType.png.identifier,
            onSuccess: {}
        )
        let provider = NSFilePromiseProvider(
            fileType: UTType.png.identifier,
            delegate: delegate
        )
        let destination = try makeTemporaryDirectory().appendingPathComponent("Exact.png")

        let completionError: (any Error)? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(
                provider,
                writePromiseTo: destination,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }

        XCTAssertNil(completionError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(plan.suggestedName).path
        ))
        XCTAssertNotNil(CGImageSourceCreateWithURL(destination as CFURL, nil))
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

    func testStaleOperationCannotClearReplacementOperation() {
        let registry = ClipboardHistoryExportOperationRegistry()
        let firstID = UUID()
        let secondID = UUID()
        let firstTask = Task<Void, Never> {}
        let secondTask = Task<Void, Never> {}

        XCTAssertTrue(registry.install(id: firstID, task: firstTask))
        registry.cancel()
        XCTAssertTrue(registry.install(id: secondID, task: secondTask))

        registry.finish(id: firstID)
        XCTAssertFalse(registry.isIdle)

        registry.finish(id: secondID)
        XCTAssertTrue(registry.isIdle)
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

    private func richTextPayload(_ text: String) throws -> ClipboardHistoryPayload {
        let attributed = NSMutableAttributedString(string: text)
        let titleLength = min(5, attributed.length)
        attributed.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 24, weight: .bold),
            range: NSRange(location: 0, length: titleLength)
        )
        if let linkRange = text.range(of: "link") {
            attributed.addAttribute(
                .link,
                value: URL(string: "https://example.com")!,
                range: NSRange(linkRange, in: text)
            )
        }
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        return ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: rtf
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data(text.utf8)
                ),
            ]),
        ])
    }

    private func rtfdPayload(includeRTFFallback: Bool) throws -> ClipboardHistoryPayload {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(data: try XCTUnwrap(imagePayload().representations.first?.data))
        let attributed = NSMutableAttributedString(string: "Rich attachment ")
        attributed.append(NSAttributedString(attachment: attachment))
        let range = NSRange(location: 0, length: attributed.length)
        let rtfd = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        var representations = [
            ClipboardStoredRepresentation(
                typeIdentifier: ClipboardRepresentationType.rtfd,
                data: rtfd
            ),
        ]
        if includeRTFFallback {
            representations.append(ClipboardStoredRepresentation(
                typeIdentifier: ClipboardRepresentationType.rtf,
                data: try attributed.data(
                    from: range,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                )
            ))
        }
        return ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: representations),
        ])
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
        return ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: data
                ),
            ]),
        ])
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

private struct StaticClipboardRecognizer: ClipboardImageTextRecognizing {
    let text: String?

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        text
    }
}

private final class CancellableClipboardRecognizer: ClipboardImageTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        recordStart()
        while !Task.isCancelled { await Task.yield() }
        return nil
    }

    private func recordStart() {
        lock.lock()
        didStart = true
        lock.unlock()
    }
}

private enum ClipboardCopyTestError: Error {
    case injectedFailure
}

private final class ClipboardThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var didObserveMainThread = false

    var observedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didObserveMainThread
    }

    func record(isMainThread: Bool) {
        lock.lock()
        didObserveMainThread = didObserveMainThread || isMainThread
        lock.unlock()
    }
}

private final class ClipboardFileValidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var probeCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return probeCount
    }

    func recordProbe() {
        lock.lock()
        probeCount += 1
        lock.unlock()
    }
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
