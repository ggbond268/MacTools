import AppKit
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryPanelKeyboardTests: XCTestCase {
    func testGlobalShortcutDismissesOnlyTheVisibleKeyHistoryPanel() {
        XCTAssertTrue(ClipboardHistoryPanelController.shouldDismissForGlobalShortcut(
            isVisible: true,
            isKeyWindow: true
        ))
        XCTAssertFalse(ClipboardHistoryPanelController.shouldDismissForGlobalShortcut(
            isVisible: true,
            isKeyWindow: false
        ))
        XCTAssertFalse(ClipboardHistoryPanelController.shouldDismissForGlobalShortcut(
            isVisible: false,
            isKeyWindow: false
        ))
    }

    func testFailedClearKeepsPreservedHistoryVisibleWithInlineError() {
        let presentation = ClipboardHistoryPanelPresentation.resolve(
            itemCount: 2,
            visibleItemCount: 2,
            hasStorageError: true
        )

        XCTAssertFalse(presentation.showsErrorOnly)
        XCTAssertTrue(presentation.showsHistory)
        XCTAssertTrue(presentation.showsInlineStorageError)
    }

    func testLoadFailureWithoutUsableHistoryUsesErrorOnlyState() {
        let presentation = ClipboardHistoryPanelPresentation.resolve(
            itemCount: 0,
            visibleItemCount: 0,
            hasStorageError: true
        )

        XCTAssertTrue(presentation.showsErrorOnly)
        XCTAssertFalse(presentation.showsHistory)
        XCTAssertFalse(presentation.showsInlineStorageError)
    }

    func testFocusRestorationTargetIsReplacedAndConsumedForEveryPresentation() {
        var state = ClipboardHistoryPreviousApplicationState<String>()
        state.beginPresentation(frontmostApplication: "Browser", isExternal: { _ in true })
        XCTAssertEqual(state.application, "Browser")

        state.beginPresentation(frontmostApplication: "MacTools", isExternal: { _ in false })
        XCTAssertNil(state.application)
        XCTAssertNil(state.consume())

        state.beginPresentation(frontmostApplication: "Editor", isExternal: { _ in true })
        XCTAssertEqual(state.consume(), "Editor")
        XCTAssertNil(state.application)
    }

    func testCommandsRequireTheActivePanelWithoutAnAttachedSheet() {
        XCTAssertNil(command(keyCode: 36, isPanelEvent: false))
        XCTAssertNil(command(keyCode: 36, isPanelKeyWindow: false))
        XCTAssertNil(command(keyCode: 36, hasAttachedSheet: true))
    }

    func testMarkedTextPassesReturnAndEscapeToTheInputMethod() {
        XCTAssertNil(command(keyCode: 36, hasMarkedText: true))
        XCTAssertNil(command(keyCode: 53, hasMarkedText: true))
    }

    func testPanelCommandsResolveWhenTextIsNotBeingComposed() {
        XCTAssertEqual(command(keyCode: 36), .pasteSelection(asPlainText: false))
        XCTAssertEqual(
            command(keyCode: 36, modifiers: .shift),
            .pasteSelection(asPlainText: true)
        )
        XCTAssertEqual(command(keyCode: 53), .close)
        XCTAssertEqual(command(keyCode: 35, modifiers: .command), .togglePin)
        XCTAssertNil(command(keyCode: 47, modifiers: .command))
    }

    func testSharedPaletteSearchFieldUsesShiftReturnForPlainTextPaste() {
        XCTAssertEqual(
            PluginPaletteSearchField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false,
                modifierFlags: .shift,
                alternateSubmitModifier: .shift
            ),
            .alternateSubmit
        )
        XCTAssertEqual(
            PluginPaletteSearchField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false,
                alternateSubmitModifier: .shift
            ),
            .submit
        )
        XCTAssertFalse(
            PluginPaletteSearchField.isAlternateSubmitKeyEquivalent(
                keyCode: 36,
                modifierFlags: .command,
                alternateSubmitModifier: .shift
            )
        )
    }

    func testArrowKeysMoveHistorySelectionWhileSearchIsFocused() {
        XCTAssertEqual(command(keyCode: 125, isEditingText: true), .moveSelection(offset: 1))
        XCTAssertEqual(command(keyCode: 126, isEditingText: true), .moveSelection(offset: -1))
        XCTAssertEqual(
            command(keyCode: 125, modifiers: [.numericPad, .function], isEditingText: true),
            .moveSelection(offset: 1)
        )
        XCTAssertEqual(
            command(keyCode: 126, modifiers: [.numericPad, .function], isEditingText: true),
            .moveSelection(offset: -1)
        )
        XCTAssertNil(command(keyCode: 125, modifiers: .command, isEditingText: true))
    }

    func testControlPNMoveSelectionWhileSearchIsFocused() {
        XCTAssertEqual(
            command(keyCode: 35, modifiers: .control, isEditingText: true),
            .moveSelection(offset: -1)
        )
        XCTAssertEqual(
            command(keyCode: 45, modifiers: .control, isEditingText: true),
            .moveSelection(offset: 1)
        )
        XCTAssertEqual(command(keyCode: 35, modifiers: .command), .togglePin)
    }

    func testCommandNumberPastesTheCorrespondingVisibleItem() {
        let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

        for (index, keyCode) in numberRowKeyCodes.enumerated() {
            XCTAssertEqual(
                command(keyCode: keyCode, modifiers: .command),
                .pasteVisibleItem(index: index)
            )
        }
    }

    func testControlNumberSelectsContentFilter() {
        let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]

        for (filter, keyCode) in zip(ClipboardHistoryContentFilter.allCases, keyCodes) {
            XCTAssertEqual(
                command(keyCode: keyCode, modifiers: .control, isEditingText: true),
                .selectFilter(filter)
            )
        }

        XCTAssertNil(command(keyCode: 29, modifiers: .control, isEditingText: true))
    }

    func testVisibleOrderPlacesPinnedItemsFirstForNumberedPaste() {
        let recent = item(text: "recent", pinned: false)
        let pin = item(text: "pin", pinned: true)
        let model = ClipboardHistoryPanelModel()

        model.updateItems([recent, pin])

        XCTAssertEqual(model.visibleItems.map(\.id), [pin.id, recent.id])
    }

    func testContentFilterShowsOnlyMatchingTypesAndGroupsRichTextWithText() {
        let plainText = item(text: "plain", pinned: false)
        let richText = item(
            payload: payload(typeIdentifier: ClipboardRepresentationType.rtf),
            pinned: false
        )
        let image = item(
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            pinned: false
        )
        let model = ClipboardHistoryPanelModel()
        model.updateItems([plainText, richText, image])

        model.contentFilter = .text
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([plainText.id, richText.id]))

        model.contentFilter = .image
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])
    }

    func testFinderFilesMatchBothFilesAndTheirSemanticTypeFilters() {
        let pdf = item(payload: filePayload(named: "Guide.PDF"), pinned: false)
        let image = item(payload: filePayload(named: "Screenshot.png"), pinned: false)
        let audio = item(payload: filePayload(named: "Recording.m4a"), pinned: false)
        let video = item(payload: filePayload(named: "Demo.mov"), pinned: false)
        let ordinaryFile = item(payload: filePayload(named: "Notes.txt"), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.updateItems([pdf, image, audio, video, ordinaryFile])

        XCTAssertEqual(pdf.kind, .files)
        XCTAssertEqual(audio.kind, .files)

        model.contentFilter = .files
        XCTAssertEqual(
            Set(model.visibleItems.map(\.id)),
            Set([pdf.id, image.id, audio.id, video.id, ordinaryFile.id])
        )

        model.contentFilter = .pdf
        XCTAssertEqual(model.visibleItems.map(\.id), [pdf.id])

        model.contentFilter = .image
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])

        model.contentFilter = .media
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([audio.id, video.id]))
    }

    func testPayloadWithMultipleRepresentationsMatchesEveryRelevantFilter() {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.pdf,
                    data: Data([0x01])
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.tiff,
                    data: Data([0x02])
                ),
            ]),
        ])

        XCTAssertTrue(ClipboardHistoryContentFilter.pdf.matches(payload))
        XCTAssertTrue(ClipboardHistoryContentFilter.image.matches(payload))
        XCTAssertFalse(ClipboardHistoryContentFilter.files.matches(payload))
    }

    func testPanelPresentationResetsTheTypeFilter() {
        let text = item(text: "plain", pinned: false)
        let image = item(
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            pinned: false
        )
        let model = ClipboardHistoryPanelModel()
        model.updateItems([text, image])
        model.contentFilter = .image

        model.prepareForPresentation(items: [text, image])

        XCTAssertEqual(model.contentFilter, .all)
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([text.id, image.id]))
    }

    func testPanelPresentationOrdersUsedItemsByRecentActivityWithinPinGroups() {
        let now = Date()
        let recentlyCaptured = item(
            text: "new capture",
            pinned: false,
            capturedAt: now,
            lastUsedAt: nil
        )
        let recentlyUsed = item(
            text: "old but used",
            pinned: false,
            capturedAt: now.addingTimeInterval(-300),
            lastUsedAt: now.addingTimeInterval(10)
        )
        let pinned = item(
            text: "pin",
            pinned: true,
            capturedAt: now.addingTimeInterval(-600),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()

        model.prepareForPresentation(items: [recentlyCaptured, recentlyUsed, pinned])

        XCTAssertEqual(model.visibleItems.map(\.id), [pinned.id, recentlyUsed.id, recentlyCaptured.id])
    }

    func testUsageUpdateDoesNotReorderAnAlreadyOpenPanel() {
        let now = Date()
        let first = item(text: "first", pinned: false, capturedAt: now, lastUsedAt: nil)
        let second = item(
            text: "second",
            pinned: false,
            capturedAt: now.addingTimeInterval(-60),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])

        var usedSecond = second
        usedSecond.lastUsedAt = now.addingTimeInterval(30)
        model.updateItems([first, usedSecond])

        XCTAssertEqual(model.visibleItems.map(\.id), [first.id, second.id])
        model.prepareForPresentation(items: [first, usedSecond])
        XCTAssertEqual(model.visibleItems.map(\.id), [second.id, first.id])
    }

    func testDeletingSelectedMiddleItemKeepsSelectionAtItsPosition() {
        let now = Date()
        let first = item(text: "first", pinned: false, capturedAt: now, lastUsedAt: nil)
        let middle = item(
            text: "middle",
            pinned: false,
            capturedAt: now.addingTimeInterval(-1),
            lastUsedAt: nil
        )
        let last = item(
            text: "last",
            pinned: false,
            capturedAt: now.addingTimeInterval(-2),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, middle, last])
        model.selectedItemID = middle.id

        model.selectNeighborBeforeRemoving(itemID: middle.id)
        model.updateItems([first, last])

        XCTAssertEqual(model.selectedItemID, last.id)
    }

    func testDeletingLastSelectedItemSelectsPreviousAndNonselectedDeletePreservesSelection() {
        let first = item(text: "first", pinned: false)
        let middle = item(text: "middle", pinned: false)
        let last = item(text: "last", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, middle, last])
        model.selectedItemID = last.id

        model.selectNeighborBeforeRemoving(itemID: last.id)
        XCTAssertEqual(model.selectedItemID, middle.id)

        model.selectNeighborBeforeRemoving(itemID: first.id)
        XCTAssertEqual(model.selectedItemID, middle.id)
    }

    func testImageTextAvailabilityDistinguishesPendingAvailableAndUnavailable() {
        var image = ClipboardHistoryItem(
            id: UUID(),
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        XCTAssertEqual(ClipboardImageTextAvailability(item: image), .pending)

        image.hasCompletedImageTextIndexing = true
        image.imageSearchText = "Recognized"
        XCTAssertEqual(ClipboardImageTextAvailability(item: image), .available)

        image.imageSearchText = "  "
        XCTAssertEqual(ClipboardImageTextAvailability(item: image), .unavailable)
    }

    func testImagePreviewLayoutAspectFitsWideAndTallImagesWithPadding() {
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: CGSize(width: 400, height: 200),
                containerSize: CGSize(width: 300, height: 300),
                padding: 10
            ),
            CGSize(width: 280, height: 140)
        )
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: CGSize(width: 200, height: 400),
                containerSize: CGSize(width: 300, height: 300),
                padding: 10
            ),
            CGSize(width: 140, height: 280)
        )
    }

    func testImagePreviewLayoutRejectsInvalidOrUnusableGeometry() {
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: .zero,
                containerSize: CGSize(width: 300, height: 300)
            ),
            .zero
        )
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: CGSize(width: 100, height: 100),
                containerSize: CGSize(width: 20, height: 20),
                padding: 20
            ),
            .zero
        )
    }

    func testRelativeTimestampUsesOneMeaningfulLocalizedUnit() {
        let locale = Locale(identifier: "en_US")
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let fifteenHoursAgo = referenceDate.addingTimeInterval(-15 * 60 * 60)
        let fiveMinutesAgo = referenceDate.addingTimeInterval(-5 * 60)
        let oneMinuteAgo = referenceDate.addingTimeInterval(-60)

        let hours = ClipboardHistoryTimestampFormatting.relativeString(
            for: fifteenHoursAgo,
            relativeTo: referenceDate,
            locale: locale
        )
        let minutes = ClipboardHistoryTimestampFormatting.relativeString(
            for: fiveMinutesAgo,
            relativeTo: referenceDate,
            locale: locale
        )
        let oneMinute = ClipboardHistoryTimestampFormatting.relativeString(
            for: oneMinuteAgo,
            relativeTo: referenceDate,
            locale: locale
        )

        XCTAssertEqual(hours, "15 hours ago")
        XCTAssertEqual(minutes, "5 minutes ago")
        XCTAssertEqual(oneMinute, "1 minute ago")
    }

    func testCommandDeleteRemovesASelectedItemWithoutClaimingPlainBackspace() {
        XCTAssertNil(command(keyCode: 51, isEditingText: true))
        XCTAssertNil(command(keyCode: 51))
        XCTAssertEqual(
            command(keyCode: 51, modifiers: .command, isEditingText: true),
            .deleteSelection
        )
        XCTAssertEqual(command(keyCode: 51, modifiers: .command), .deleteSelection)
    }

    func testRichTextPreviewAndPlainTextConversionPreserveUsefulContent() throws {
        let richItem = item(
            payload: ClipboardHistoryPayload(pasteboardItems: [
                ClipboardStoredPasteboardItem(representations: [
                    ClipboardStoredRepresentation(
                        typeIdentifier: ClipboardRepresentationType.rtf,
                        data: Data("{\\rtf1\\b Formatted\\b0  note}".utf8)
                    ),
                ]),
            ]),
            pinned: false
        )
        let attributedString = try XCTUnwrap(ClipboardRichText.attributedString(for: richItem.payload))

        XCTAssertEqual(attributedString.string, "Formatted note")
        XCTAssertEqual(ClipboardPlainTextConversion.text(for: richItem), "Formatted note")
        guard case let .formatted(preview) = ClipboardRichTextPreviewPolicy.makePreview(
            payload: richItem.payload,
            fallbackText: richItem.text
        ) else {
            return XCTFail("Expected a formatted rich-text preview")
        }
        XCTAssertEqual(String(preview.characters), "Formatted note")

        let imageItem = ClipboardHistoryItem(
            id: UUID(),
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: "Recognized screenshot text",
            hasCompletedImageTextIndexing: true
        )
        XCTAssertEqual(
            ClipboardPlainTextConversion.text(for: imageItem),
            "Recognized screenshot text"
        )
    }

    func testOversizedRichTextUsesBoundedPlainTextWithoutImportingFormatting() {
        let fallbackText = String(repeating: "a", count: 20_000)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data(
                        repeating: 0x20,
                        count: ClipboardRichTextPreviewPolicy.maximumFormattedByteCount + 1
                    )
                ),
            ]),
        ])

        guard case let .plainText(preview, isSimplified) =
            ClipboardRichTextPreviewPolicy.makePreview(
                payload: payload,
                fallbackText: fallbackText
            ) else {
            return XCTFail("Expected a simplified preview")
        }

        XCTAssertTrue(isSimplified)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(preview.dropLast().count, ClipboardRichTextPreviewPolicy.maximumFormattedCharacterCount)
        let item = item(payload: payload, pinned: false)
        XCTAssertFalse(ClipboardPlainTextConversion.isAvailable(for: item))
    }

    private func command(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isPanelEvent: Bool = true,
        isPanelKeyWindow: Bool = true,
        hasAttachedSheet: Bool = false,
        isEditingText: Bool = false,
        hasMarkedText: Bool = false
    ) -> ClipboardHistoryPanelController.KeyboardCommand? {
        ClipboardHistoryPanelController.keyboardCommand(
            keyCode: keyCode,
            modifiers: modifiers,
            isPanelEvent: isPanelEvent,
            isPanelKeyWindow: isPanelKeyWindow,
            hasAttachedSheet: hasAttachedSheet,
            isEditingText: isEditingText,
            hasMarkedText: hasMarkedText
        )
    }

    private func item(text: String, pinned: Bool) -> ClipboardHistoryItem {
        item(text: text, pinned: pinned, capturedAt: Date(), lastUsedAt: nil)
    }

    private func item(
        text: String,
        pinned: Bool,
        capturedAt: Date,
        lastUsedAt: Date?
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: capturedAt,
            sourceApplication: nil,
            isPinned: pinned,
            lastUsedAt: lastUsedAt
        )
    }

    private func item(payload: ClipboardHistoryPayload, pinned: Bool) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: pinned,
            lastUsedAt: nil
        )
    }

    private func payload(typeIdentifier: String) -> ClipboardHistoryPayload {
        ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: typeIdentifier,
                    data: Data([0x01])
                ),
            ]),
        ])
    }

    private func filePayload(named name: String) -> ClipboardHistoryPayload {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(url.absoluteString.utf8)
                ),
            ]),
        ])
    }
}
