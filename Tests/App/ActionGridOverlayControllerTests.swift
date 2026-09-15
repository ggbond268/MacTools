import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class ActionGridOverlayControllerTests: XCTestCase {
    private let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
    private var originalPreference: String?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        PluginRuntimeLocalization.source.setPreference("en")
    }

    override func tearDown() {
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        originalPreference = nil
        super.tearDown()
    }

    func testActionSurfacesChooseSupportedModeAndExposeExecutionFailures() {
        let backgroundOnly = ActionDefinition(
            key: ActionKey(providerID: "test", actionID: "background"),
            title: "Background",
            description: "",
            systemImage: "bolt",
            capabilities: [.background]
        )
        let foreground = ActionDefinition(
            key: ActionKey(providerID: "test", actionID: "foreground"),
            title: "Foreground",
            description: "",
            systemImage: "bolt",
            capabilities: [.background, .foregroundInteractive]
        )
        let durableProgress = ActionDefinition(
            key: ActionKey(providerID: "test", actionID: "durable-progress"),
            title: "Durable Progress",
            description: "",
            systemImage: "clock",
            capabilities: [.foregroundInteractive, .reportsProgress]
        )

        XCTAssertEqual(ActionSurfaceExecutionSupport.preferredMode(for: backgroundOnly), .background)
        XCTAssertEqual(ActionSurfaceExecutionSupport.preferredMode(for: foreground), .foreground)
        XCTAssertFalse(ActionSurfaceExecutionSupport.continuesAfterSurfaceDismissal(
            for: foreground
        ))
        XCTAssertTrue(ActionSurfaceExecutionSupport.continuesAfterSurfaceDismissal(
            for: durableProgress
        ))
        XCTAssertEqual(
            ActionSurfaceExecutionSupport.feedback(for: .completed(.failed(message: "failed"))),
            "failed"
        )
        XCTAssertEqual(
            ActionSurfaceExecutionSupport.feedback(for: .rejected(.executionTimedOut)),
            "The action timed out."
        )
        XCTAssertNil(ActionSurfaceExecutionSupport.feedback(for: .completed(.succeeded())))
    }

    func testConfirmationSheetKeepsActionGridAliveWhilePanelResignsKey() {
        XCTAssertFalse(ActionGridPanelDismissalPolicy.shouldCloseWhenResigningKey(
            isPresentingConfirmation: true
        ))
        XCTAssertTrue(ActionGridPanelDismissalPolicy.shouldCloseWhenResigningKey(
            isPresentingConfirmation: false
        ))
    }

    func testConfirmationRequiredActionUsesGridAnchoredPresenter() async throws {
        let plugin = ConfirmationActionGridTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        var requests: [ActionConfirmationRequest] = []
        let controller = ActionGridOverlayController(
            pluginHost: host,
            confirmationPresenter: { request, window in
                requests.append(request)
                XCTAssertEqual(
                    window.identifier,
                    ActionGridOverlayController.panelIdentifier
                )
                return true
            }
        )
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [
            ActionGridPresentationEntry(
                id: "confirmed",
                reference: plugin.actionReference
            ),
        ]))
        XCTAssertTrue(controller.processKeyEvent(try keyEvent(keyCode: 36, characters: "\r")))

        for _ in 0 ..< 100 where plugin.executionCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(plugin.executionCount, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.source, .actionGrid)
    }

    func testGeometryClampsGridToPointerDisplayVisibleFrame() {
        let visible = CGRect(x: 1_000, y: 200, width: 700, height: 500)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: CGPoint(x: 1_680, y: 210),
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertTrue(visible.insetBy(dx: 9, dy: 9).contains(frame))
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 6), 3)
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 7), 3)
    }

    func testNestedGeometryAdaptsColumnsAndKeepsNavigationReadable() {
        XCTAssertEqual(
            ActionGridOverlayGeometry.columnCount(for: 1, isNested: true),
            1
        )
        XCTAssertEqual(
            ActionGridOverlayGeometry.columnCount(for: 2, isNested: true),
            2
        )
        XCTAssertEqual(
            ActionGridOverlayGeometry.columnCount(for: 3, isNested: true),
            3
        )
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 1), 3)

        let empty = ActionGridOverlayGeometry.contentSize(
            for: 0,
            includesNavigationHeader: true
        )
        let oneItem = ActionGridOverlayGeometry.contentSize(
            for: 1,
            includesNavigationHeader: true
        )
        let twoItems = ActionGridOverlayGeometry.contentSize(
            for: 2,
            includesNavigationHeader: true
        )

        XCTAssertEqual(empty.width, 288)
        XCTAssertEqual(oneItem.width, 288)
        XCTAssertEqual(twoItems.width, 364)
        XCTAssertLessThan(empty.height, oneItem.height)
        XCTAssertLessThan(twoItems.width, ActionGridOverlayGeometry.contentSize(for: 9).width)
    }

    func testGeometryPlacesCenterCellAtPointerWhenDisplayHasRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let pointer = CGPoint(x: 720, y: 450)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: pointer,
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertEqual(frame.midX, pointer.x, accuracy: 0.001)
        XCTAssertEqual(frame.midY, pointer.y, accuracy: 0.001)
    }

    func testGeometryMovesRelativeToPointerToRemainFullyVisible() {
        let visible = CGRect(x: 1_000, y: 200, width: 700, height: 500)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: CGPoint(x: visible.maxX - 1, y: visible.maxY - 1),
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertEqual(frame.maxX, visible.maxX - 10, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visible.maxY - 10, accuracy: 0.001)
        XCTAssertTrue(visible.insetBy(dx: 9, dy: 9).contains(frame))
    }

    func testScreenSelectionUsesPointerDisplayAcrossOffsetCoordinateSpaces() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_512, height: 982),
            CGRect(x: 1_512, y: -42, width: 1_366, height: 1_024),
        ]

        XCTAssertEqual(
            ActionGridScreenSelection.screenIndex(
                containing: CGPoint(x: 2_400, y: 300),
                screenFrames: screens
            ),
            1
        )
        XCTAssertEqual(
            ActionGridScreenSelection.screenIndex(
                containing: CGPoint(x: 800, y: 500),
                screenFrames: screens
            ),
            0
        )
    }

    func testScreenSelectionFallsBackToNearestDisplayInsteadOfPrimaryDisplay() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_200, y: 100, width: 800, height: 600),
        ]

        XCTAssertEqual(
            ActionGridScreenSelection.screenIndex(
                containing: CGPoint(x: 1_150, y: 400),
                screenFrames: screens
            ),
            1
        )
        XCTAssertNil(ActionGridScreenSelection.screenIndex(
            containing: .zero,
            screenFrames: []
        ))
    }

    func testKeyboardNavigationUsesStableRowMajorPositions() {
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 0, direction: .left, itemCount: 6, columns: 2), 0)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 0, direction: .right, itemCount: 6, columns: 2), 1)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 1, direction: .right, itemCount: 6, columns: 2), 1)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 1, direction: .down, itemCount: 6, columns: 2), 3)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 5, direction: .down, itemCount: 6, columns: 2), 5)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 53, characters: nil), .dismiss)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 36, characters: nil), .activateSelected)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 123, characters: nil), .move(.left))
        XCTAssertEqual(
            ActionGridKeyCommand.resolve(
                keyCode: 123,
                characters: nil,
                layoutDirection: .rightToLeft
            ),
            .move(.right)
        )
        XCTAssertEqual(
            ActionGridKeyCommand.resolve(
                keyCode: 124,
                characters: nil,
                layoutDirection: .rightToLeft
            ),
            .move(.left)
        )
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 0, characters: "7"), .select(7))
        XCTAssertNil(ActionGridKeyCommand.resolve(keyCode: 0, characters: "0"))
        XCTAssertNil(ActionGridKeyCommand.resolve(
            keyCode: 124,
            characters: nil,
            modifierFlags: [.control, .option]
        ))
        XCTAssertNil(ActionGridKeyCommand.resolve(
            keyCode: 36,
            characters: "\r",
            modifierFlags: .command
        ))
        XCTAssertNil(ActionGridKeyCommand.resolve(
            keyCode: 0,
            characters: "1",
            modifierFlags: .command
        ))
        XCTAssertEqual(ActionGridKeyCommand.resolve(
            keyCode: 76,
            characters: "\r",
            modifierFlags: [.numericPad]
        ), .activateSelected)
    }

    func testModifiedNavigationEventsPassThroughWithoutChangingSelection() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "run")
        )
        XCTAssertTrue(controller.present(entries: [
            ActionGridPresentationEntry(id: "one", reference: reference, slotIndex: 0),
            ActionGridPresentationEntry(id: "two", reference: reference, slotIndex: 1),
        ]))

        let initialSelection = controller.presentedSelectedIndex
        let voiceOverRight = try keyEvent(
            keyCode: 124,
            characters: "\u{F703}",
            modifierFlags: [.control, .option]
        )

        XCTAssertFalse(controller.processKeyEvent(voiceOverRight))
        XCTAssertEqual(controller.presentedSelectedIndex, initialSelection)
        XCTAssertTrue(controller.isShown)
    }

    func testKeyboardNavigationPreservesSparseGridSlots() {
        let occupied: Set<Int> = [0, 2, 7]

        XCTAssertEqual(
            ActionGridKeyboardNavigation.nextOccupiedSlot(
                from: 0,
                direction: .right,
                occupiedSlots: occupied
            ),
            2
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.nextOccupiedSlot(
                from: 7,
                direction: .up,
                occupiedSlots: occupied
            ),
            7
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.nextOccupiedSlot(
                from: 2,
                direction: .left,
                occupiedSlots: occupied
            ),
            0
        )
    }

    func testKeyboardNavigationPrefersCenterThenNearestOccupiedSlot() {
        XCTAssertEqual(
            ActionGridKeyboardNavigation.preferredInitialSlot(
                occupiedSlots: [0, 1, 4, 8]
            ),
            4
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.preferredInitialSlot(
                occupiedSlots: [0, 1, 8]
            ),
            1
        )
        XCTAssertEqual(
            ActionGridKeyboardNavigation.preferredInitialSlot(occupiedSlots: []),
            0
        )
    }

    func testModelSelectsCenterEntryWhenPresentedAndInsideFolders() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: entry.customTitle ?? entry.id,
                    ownerTitle: "Owner",
                    systemImage: "bolt",
                    availability: .available,
                    children: entry.children
                )
            },
            executor: { _ in .terminal(.completed(.succeeded())) }
        )
        let children = [
            ActionGridPresentationEntry(id: "child-top", reference: reference, slotIndex: 0),
            ActionGridPresentationEntry(id: "child-center", reference: reference, slotIndex: 4),
        ]
        model.update([
            ActionGridPresentationEntry(id: "top", reference: reference, slotIndex: 0),
            ActionGridPresentationEntry(
                id: "folder",
                folderTitle: "Folder",
                children: children,
                slotIndex: 4
            ),
        ])

        XCTAssertEqual(model.selectedIndex, 4)
        model.activateSelected()
        XCTAssertEqual(model.navigationTitle, "Folder")
        XCTAssertEqual(model.selectedIndex, 4)
    }

    func testPointerActivationWaitsForGestureReleaseGracePeriod() {
        let presentedAt: TimeInterval = 10

        XCTAssertFalse(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt,
            presentationUptime: presentedAt,
            source: .globalShortcut
        ))
        XCTAssertFalse(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.34,
            presentationUptime: presentedAt,
            source: .globalShortcut
        ))
        XCTAssertTrue(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.36,
            presentationUptime: presentedAt,
            source: .globalShortcut
        ))
        XCTAssertFalse(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.79,
            presentationUptime: presentedAt,
            source: .trackpadGesture
        ))
        XCTAssertTrue(ActionGridPointerActivationPolicy.acceptsPointerEvent(
            eventUptime: presentedAt + 0.81,
            presentationUptime: presentedAt,
            source: .trackpadGesture
        ))
    }

    func testAccessibilityLabelIncludesOwnerAvailabilityAndDisabledReason() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let available = ResolvedActionGridEntry(
            id: "available",
            reference: reference,
            title: "运行",
            ownerTitle: "测试插件",
            systemImage: "bolt",
            availability: .available
        )
        let unavailable = ResolvedActionGridEntry(
            id: "unavailable",
            reference: reference,
            title: "运行",
            ownerTitle: "测试插件",
            systemImage: "bolt",
            availability: .unavailable("需要权限。")
        )

        XCTAssertEqual(available.accessibilityLabel, "运行 and 测试插件")
        XCTAssertEqual(available.accessibilityValue, "Available")
        XCTAssertEqual(unavailable.accessibilityLabel, "运行 and 测试插件")
        XCTAssertEqual(unavailable.accessibilityValue, "Not available, 需要权限。")
    }

    func testTilePresentationSeparatesStableTitleStatusAndInvocationDetail() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let active = ResolvedActionGridEntry(
            id: "active",
            reference: reference,
            title: "Keep Awake",
            invocationTitle: "Turn Off Keep Awake",
            subtitle: "No automatic stop",
            compactDetail: "No automatic stop",
            ownerTitle: "Keep Awake",
            systemImage: "moon",
            availability: .available,
            presentationState: .active
        )
        let unavailable = ResolvedActionGridEntry(
            id: "unavailable",
            reference: reference,
            title: "Connect First Available Display",
            ownerTitle: "Sidecar",
            systemImage: "display",
            availability: .unavailable(
                "A Sidecar display is already connected; use the device’s Switch action"
            )
        )

        XCTAssertEqual(active.tileStatus, "On · No automatic stop")
        XCTAssertEqual(active.accessibilityValue, "On · No automatic stop, Available")
        XCTAssertEqual(active.accessibilityHint, "Turn Off Keep Awake")
        XCTAssertEqual(unavailable.tileStatus, "Not available")
        XCTAssertTrue(unavailable.helpText.contains("A Sidecar display is already connected"))
        XCTAssertTrue(unavailable.helpText.contains("Sidecar"))
    }

    func testTilePresentationRemovesDuplicateMetadataAndShowsFolderCounts() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let duplicateOwner = ResolvedActionGridEntry(
            id: "lock",
            reference: reference,
            title: "Lock Screen",
            ownerTitle: "Lock Screen",
            systemImage: "lock",
            availability: .available
        )
        let folder = ResolvedActionGridEntry(
            id: "folder",
            reference: reference,
            title: "System",
            ownerTitle: "Folder",
            systemImage: "folder",
            availability: .available,
            children: []
        )
        let folderWithOneAction = ResolvedActionGridEntry(
            id: "one-action-folder",
            reference: reference,
            title: "System",
            ownerTitle: "Folder",
            systemImage: "folder",
            availability: .available,
            children: [ActionGridPresentationEntry(id: "one", reference: reference)]
        )
        let folderWithTwoActions = ResolvedActionGridEntry(
            id: "two-action-folder",
            reference: reference,
            title: "System",
            ownerTitle: "Folder",
            systemImage: "folder",
            availability: .available,
            children: [
                ActionGridPresentationEntry(id: "one", reference: reference),
                ActionGridPresentationEntry(id: "two", reference: reference),
            ]
        )

        XCTAssertNil(duplicateOwner.tileStatus)
        XCTAssertEqual(duplicateOwner.helpText, "Lock Screen")
        XCTAssertEqual(folder.tileStatus, "Empty folder")
        XCTAssertEqual(folderWithOneAction.tileStatus, "1 action")
        XCTAssertEqual(folderWithTwoActions.tileStatus, "2 actions")
    }

    func testFeedbackAddsReservedBannerHeight() {
        let base = ActionGridOverlayGeometry.contentSize(for: 9)
        let withFeedback = ActionGridOverlayGeometry.contentSize(
            for: 9,
            includesFeedback: true
        )

        XCTAssertEqual(withFeedback.width, base.width)
        XCTAssertEqual(withFeedback.height - base.height, 48)
    }

    func testOverlayRendersLightAndDarkLocalizedFixtures() throws {
        let fixtures: [(locale: String, appearance: NSAppearance.Name, title: String)] = [
            ("en", .aqua, "Connect First Available Display"),
            ("ar", .darkAqua, "الاتصال بأول شاشة Sidecar متاحة"),
        ]

        for fixture in fixtures {
            PluginRuntimeLocalization.source.setPreference(fixture.locale)
            let reference = ActionReference(
                key: ActionKey(providerID: "fixture", actionID: "run")
            )
            let model = ActionGridOverlayModel(
                resolver: { entry in
                    switch entry.id {
                    case "active":
                        return ResolvedActionGridEntry(
                            id: entry.id,
                            reference: reference,
                            title: "Keep Awake",
                            invocationTitle: "Turn Off Keep Awake",
                            subtitle: "No automatic stop",
                            compactDetail: "No automatic stop",
                            ownerTitle: "Keep Awake",
                            systemImage: "moon",
                            availability: .available,
                            presentationState: .active
                        )
                    case "unavailable":
                        return ResolvedActionGridEntry(
                            id: entry.id,
                            reference: reference,
                            title: fixture.title,
                            ownerTitle: "Sidecar",
                            systemImage: "display",
                            availability: .unavailable(
                                "A Sidecar display is already connected; use the device’s Switch action"
                            )
                        )
                    case "folder":
                        return ResolvedActionGridEntry(
                            id: entry.id,
                            reference: reference,
                            title: "System",
                            ownerTitle: "Folder",
                            systemImage: "folder.fill",
                            availability: .available,
                            children: []
                        )
                    default:
                        return ResolvedActionGridEntry(
                            id: entry.id,
                            reference: reference,
                            title: "Action \(entry.id)",
                            ownerTitle: "MacTools",
                            systemImage: "bolt",
                            availability: .available
                        )
                    }
                },
                executor: { _ in .terminal(.completed(.succeeded())) }
            )
            model.update([
                ActionGridPresentationEntry(id: "one", reference: reference, slotIndex: 0),
                ActionGridPresentationEntry(id: "two", reference: reference, slotIndex: 1),
                ActionGridPresentationEntry(id: "three", reference: reference, slotIndex: 2),
                ActionGridPresentationEntry(id: "four", reference: reference, slotIndex: 3),
                ActionGridPresentationEntry(id: "unavailable", reference: reference, slotIndex: 4),
                ActionGridPresentationEntry(id: "six", reference: reference, slotIndex: 5),
                ActionGridPresentationEntry(id: "folder", reference: reference, slotIndex: 6),
                ActionGridPresentationEntry(id: "active", reference: reference, slotIndex: 7),
                ActionGridPresentationEntry(id: "nine", reference: reference, slotIndex: 8),
            ])
            if fixture.locale == "en" {
                model.activateSelected()
            }

            let size = ActionGridOverlayGeometry.contentSize(
                for: 9,
                includesFeedback: model.feedback != nil
            )
            let host = NSHostingView(
                rootView: ActionGridOverlayRootView(model: model, onDismiss: {})
            )
            host.appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(
                host.bitmapImageRepForCachingDisplay(in: host.bounds)
            )
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

            XCTAssertGreaterThan(png.count, 10_000)
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Action Grid \(fixture.locale) \(fixture.appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testRepeatedPresentationReusesOneOverlayPanel() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(key: ActionKey(providerID: "missing", actionID: "run"))
        )

        XCTAssertTrue(controller.present(entries: [entry]))
        XCTAssertTrue(
            controller.present(
                entries: [
                    ActionGridPresentationEntry(
                        id: "replacement",
                        reference: ActionReference(
                            key: ActionKey(providerID: "missing", actionID: "replacement")
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(controller.presentedEntryIDs, ["replacement"])
        XCTAssertEqual(controller.presentedSelectedIndex, 0)
        XCTAssertEqual(
            NSApp.windows.filter { $0.identifier == ActionGridOverlayController.panelIdentifier }.count,
            1
        )
    }

    func testPresentationRejectsInvalidSlotsInsideNestedFolders() {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "run")
        )
        let folder = ActionGridPresentationEntry(
            id: "folder",
            folderTitle: "Folder",
            children: [
                ActionGridPresentationEntry(id: "one", reference: reference, slotIndex: 2),
                ActionGridPresentationEntry(id: "two", reference: reference, slotIndex: 2),
            ]
        )

        XCTAssertFalse(controller.present(entries: [folder]))
        XCTAssertFalse(controller.isShown)
    }

    func testRepeatedPresentationReturnsNestedGridToFreshRoot() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "run")
        )
        let folder = ActionGridPresentationEntry(
            id: "folder",
            folderTitle: "Folder",
            children: [ActionGridPresentationEntry(id: "child", reference: reference)]
        )

        XCTAssertTrue(controller.present(entries: [folder]))
        XCTAssertTrue(controller.processKeyEvent(try keyEvent(keyCode: 36, characters: "\r")))
        XCTAssertEqual(controller.presentedEntryIDs, ["child"])

        let replacement = ActionGridPresentationEntry(
            id: "replacement",
            reference: reference,
            slotIndex: 8
        )
        XCTAssertTrue(controller.present(entries: [replacement]))

        XCTAssertEqual(controller.presentedEntryIDs, ["replacement"])
        XCTAssertEqual(controller.presentedSelectedIndex, 8)
        XCTAssertEqual(
            try XCTUnwrap(controller.presentedPanelFrame?.size),
            ActionGridOverlayGeometry.contentSize(for: 9)
        )
    }

    func testPresentationRefreshesOnlyStatefulActionProvidersBeforeResolvingCells() throws {
        let plugin = StatefulActionGridTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = plugin.toggleReference

        let initial = try host.actionRegistry.registeredAction(for: reference).get()
        XCTAssertEqual(initial.catalogEntry?.presentationState, .inactive)
        let refreshCountBeforePresentation = plugin.refreshCount

        plugin.nextState = true
        XCTAssertTrue(controller.present(entries: [
            ActionGridPresentationEntry(id: "stateful", reference: reference),
        ]))

        XCTAssertEqual(plugin.refreshCount, refreshCountBeforePresentation + 1)
        let refreshedAction = try host.actionRegistry.registeredAction(for: reference).get()
        let refreshed = try XCTUnwrap(refreshedAction.catalogEntry)
        XCTAssertEqual(refreshed.title, "Turn Off Test State")
        XCTAssertEqual(refreshed.presentationState, .active)

        let tile = try XCTUnwrap(controller.presentedEntries.first)
        XCTAssertEqual(tile.title, "Toggle Test State")
        XCTAssertEqual(tile.invocationTitle, "Turn Off Test State")
        XCTAssertEqual(tile.tileStatus, "On")
        XCTAssertEqual(tile.accessibilityHint, "Turn Off Test State")
    }

    func testHostActionUsesCompactTitleWithoutProviderFooter() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(
                providerID: "mactools",
                actionID: AppShortcutAction.toggleFeaturePanel.rawValue
            )
        )

        XCTAssertTrue(controller.present(entries: [
            ActionGridPresentationEntry(id: "feature-panel", reference: reference),
        ]))

        let tile = try XCTUnwrap(controller.presentedEntries.first)
        XCTAssertEqual(tile.title, "Feature Panel")
        XCTAssertEqual(tile.invocationTitle, "Panel 2")
        XCTAssertNil(tile.tileStatus)
        XCTAssertTrue(tile.helpText.contains("MacTools"))
    }

    func testHostActionUsesLocalizedCompactTitleUnlessUserCustomizedIt() throws {
        PluginRuntimeLocalization.source.setPreference("zh-Hans")
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(
                providerID: "mactools",
                actionID: AppShortcutAction.toggleDashboard.rawValue
            )
        )

        XCTAssertTrue(controller.present(entries: [
            ActionGridPresentationEntry(id: "localized", reference: reference),
            ActionGridPresentationEntry(
                id: "customized",
                reference: reference,
                customTitle: "Dashboard"
            ),
        ]))

        XCTAssertEqual(controller.presentedEntries.map(\.title), ["仪表盘", "Dashboard"])
    }

    func testRepeatedCloseAndPresentationKeepsOneLiveOverlayPanel() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(key: ActionKey(providerID: "missing", actionID: "run"))
        )

        for _ in 0 ..< 20 {
            XCTAssertTrue(controller.present(entries: [entry]))
            controller.close(restoringFocus: false)
        }

        XCTAssertFalse(controller.isShown)
        XCTAssertTrue(NSApp.windows.filter {
            $0.identifier == ActionGridOverlayController.panelIdentifier && $0.isVisible
        }.isEmpty)
    }

    func testPresentedPanelSupportsSpacesAndEscapeDismissal() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [testEntry()]))
        let behavior = try XCTUnwrap(controller.presentedPanelCollectionBehavior)
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(behavior.contains(.moveToActiveSpace))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.transient))
        XCTAssertTrue(behavior.contains(.ignoresCycle))

        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        XCTAssertTrue(controller.processKeyEvent(escape))
        XCTAssertFalse(controller.isShown)
    }

    func testFolderNavigationResizesPanelForNestedGridAndBack() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let reference = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "run")
        )
        let folder = ActionGridPresentationEntry(
            id: "folder",
            folderTitle: "Folder",
            children: [
                ActionGridPresentationEntry(id: "top", reference: reference, slotIndex: 0),
                ActionGridPresentationEntry(id: "middle", reference: reference, slotIndex: 4),
                ActionGridPresentationEntry(id: "bottom", reference: reference, slotIndex: 8),
            ]
        )

        XCTAssertTrue(controller.present(entries: [folder]))
        let rootFrame = try XCTUnwrap(controller.presentedPanelFrame)
        XCTAssertTrue(controller.processKeyEvent(try keyEvent(keyCode: 36, characters: "\r")))
        let nestedFrame = try XCTUnwrap(controller.presentedPanelFrame)
        XCTAssertGreaterThan(nestedFrame.height, rootFrame.height)
        XCTAssertEqual(
            nestedFrame.height,
            ActionGridOverlayGeometry.contentSize(
                for: 9,
                includesNavigationHeader: true
            ).height
        )
        XCTAssertGreaterThan(
            nestedFrame.height,
            ActionGridOverlayGeometry.contentSize(for: 9).height
        )

        XCTAssertTrue(controller.processKeyEvent(try keyEvent(keyCode: 53, characters: "\u{1B}")))
        XCTAssertEqual(
            try XCTUnwrap(controller.presentedPanelFrame?.height),
            rootFrame.height,
            accuracy: 1
        )
        XCTAssertTrue(controller.isShown)
    }

    func testPointerDismissalKeepsInsideClickAndClosesForOutsideClick() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [testEntry()]))
        let frame = try XCTUnwrap(controller.presentedPanelFrame)
        controller.dismissIfPointerIsOutside(
            CGPoint(x: frame.midX, y: frame.midY)
        )
        XCTAssertTrue(controller.isShown)

        controller.dismissIfPointerIsOutside(
            CGPoint(x: frame.maxX + 1, y: frame.maxY + 1)
        )
        XCTAssertFalse(controller.isShown)
    }

    func testDashboardActionExecutesThroughOverlayAndDismisses() async throws {
        let host = makePluginHostForTests(plugins: [])
        var presentationRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { presentationRequests.append($0) }
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "dashboard",
            reference: ActionReference(
                key: ActionKey(
                    providerID: "mactools",
                    actionID: AppShortcutAction.toggleDashboard.rawValue
                )
            )
        )

        XCTAssertTrue(controller.present(entries: [entry]))
        let enter = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        XCTAssertTrue(controller.processKeyEvent(enter))

        for _ in 0 ..< 50 where presentationRequests.isEmpty || controller.isShown {
            await Task.yield()
        }

        XCTAssertEqual(presentationRequests, [.toggleDashboard])
        XCTAssertFalse(controller.isShown)
    }

    func testSuccessfulExecutionRestoresFocusOnlyWhileGridOwnsActiveFocus() {
        XCTAssertTrue(
            ActionGridSuccessfulExecutionFocusPolicy.shouldRestorePreviousApplication(
                panelIsKey: true,
                applicationIsActive: true
            )
        )
        XCTAssertFalse(
            ActionGridSuccessfulExecutionFocusPolicy.shouldRestorePreviousApplication(
                panelIsKey: false,
                applicationIsActive: true
            )
        )
        XCTAssertFalse(
            ActionGridSuccessfulExecutionFocusPolicy.shouldRestorePreviousApplication(
                panelIsKey: true,
                applicationIsActive: false
            )
        )
    }

    func testResizeScreenSelectionUsesRelocatedPanelAfterPresentationDisplayDisconnects() {
        let remainingScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let context = ActionGridResizeScreenSelection.context(
            presentationPointer: CGPoint(x: 2200, y: 500),
            panelFrame: CGRect(x: 500, y: 300, width: 600, height: 500),
            screenFrames: [remainingScreen]
        )

        XCTAssertEqual(context?.screenIndex, 0)
        XCTAssertEqual(context?.pointer, CGPoint(x: 800, y: 550))
    }

    func testResizeScreenSelectionKeepsPresentationPointerWhileItsDisplayExists() {
        let context = ActionGridResizeScreenSelection.context(
            presentationPointer: CGPoint(x: 2200, y: 500),
            panelFrame: CGRect(x: 500, y: 300, width: 600, height: 500),
            screenFrames: [
                CGRect(x: 0, y: 0, width: 1512, height: 982),
                CGRect(x: 1512, y: 0, width: 1280, height: 900),
            ]
        )

        XCTAssertEqual(context?.screenIndex, 1)
        XCTAssertEqual(context?.pointer, CGPoint(x: 2200, y: 500))
    }

    func testAccessibilityPolicyHonorsReducedMotionAndTransparency() {
        let standard = ActionGridOverlayAccessibilityPolicy(
            reduceMotion: false,
            reduceTransparency: false
        )
        XCTAssertTrue(standard.animatesSelection)
        XCTAssertTrue(standard.usesMaterialBackground)

        let reduced = ActionGridOverlayAccessibilityPolicy(
            reduceMotion: true,
            reduceTransparency: true
        )
        XCTAssertFalse(reduced.animatesSelection)
        XCTAssertFalse(reduced.usesMaterialBackground)
    }

    func testOverlayRootUsesSelectedLocaleDirection() {
        XCTAssertEqual(
            ActionGridOverlayRootView.layoutDirection(for: Locale(identifier: "ar")),
            .rightToLeft
        )
        XCTAssertEqual(
            ActionGridOverlayRootView.layoutDirection(for: Locale(identifier: "de")),
            .leftToRight
        )
    }

    func testModelReresolvesVisibleEntriesAfterRuntimeLanguageChange() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var title = "English"
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: title,
                    ownerTitle: "Owner",
                    systemImage: "bolt",
                    availability: .available
                )
            },
            executor: { _ in .terminal(.completed(.succeeded())) }
        )
        model.update([ActionGridPresentationEntry(id: "entry", reference: reference)])
        XCTAssertEqual(model.entries.first?.title, "English")

        title = "العربية"
        model.refreshLocalization()

        XCTAssertEqual(model.entries.first?.title, "العربية")
    }

    func testUnavailableEntryKeepsGridOpenAndSuccessfulExecutionRequestsDismissal() async {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var executionCount = 0
        var dismissed = false
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "运行",
                    ownerTitle: "测试",
                    systemImage: "bolt",
                    availability: entry.id == "available" ? .available : .unavailable("当前不可用。")
                )
            },
            executor: { _ in
                executionCount += 1
                return .terminal(.completed(.succeeded()))
            }
        )
        model.onSuccessfulExecution = { dismissed = true }
        model.update([
            ActionGridPresentationEntry(id: "unavailable", reference: reference, slotIndex: 4),
            ActionGridPresentationEntry(id: "available", reference: reference, slotIndex: 1),
        ])

        model.activateSelected()
        XCTAssertEqual(model.feedback, "当前不可用。")
        XCTAssertEqual(executionCount, 0)
        XCTAssertFalse(dismissed)

        model.select(number: 2)
        for _ in 0 ..< 20 where model.isExecuting {
            await Task.yield()
        }
        XCTAssertEqual(executionCount, 1)
        XCTAssertTrue(dismissed)
    }

    func testHandedOffExecutionRequestsDismissalWithoutWaitingForTerminalResult() async {
        let reference = ActionReference(key: ActionKey(providerID: "automation", actionID: "run"))
        var dismissed = false
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "Long Workflow",
                    ownerTitle: "Automation",
                    systemImage: "clock",
                    availability: .available
                )
            },
            executor: { _ in .handedOff }
        )
        model.onSuccessfulExecution = { dismissed = true }
        model.update([ActionGridPresentationEntry(id: "workflow", reference: reference)])

        model.activateSelected()
        for _ in 0 ..< 20 where model.isExecuting {
            await Task.yield()
        }

        XCTAssertTrue(dismissed)
        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executingEntryID)
    }

    func testModelPublishesExecutingCellAndReservesFeedbackLayout() async {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var continuation: CheckedContinuation<ActionGridExecutionOutcome, Never>?
        var layoutStates: [(slotCount: Int, navigation: Bool, feedback: Bool)] = []
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "Run",
                    ownerTitle: "Test",
                    systemImage: "bolt",
                    availability: .available
                )
            },
            executor: { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        )
        model.onLayoutChange = { layoutStates.append(($0, $1, $2)) }
        model.update([ActionGridPresentationEntry(id: "run", reference: reference)])

        model.activateSelected()
        await Task.yield()
        XCTAssertTrue(model.isExecuting)
        XCTAssertEqual(model.executingEntryID, "run")

        continuation?.resume(returning: .terminal(.completed(
            .failed(message: "The test action failed.")
        )))
        for _ in 0 ..< 20 where model.isExecuting {
            await Task.yield()
        }

        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executingEntryID)
        XCTAssertEqual(model.feedback, "The test action failed.")
        XCTAssertEqual(layoutStates.last?.feedback, true)
    }

    func testModelIgnoresCompletionFromExecutionInvalidatedByUpdate() async {
        let reference = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "run")
        )
        var continuation: CheckedContinuation<ActionGridExecutionOutcome, Never>?
        var successfulExecutionCount = 0
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: entry.id,
                    ownerTitle: "Test",
                    systemImage: "bolt",
                    availability: .available
                )
            },
            executor: { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        )
        model.onSuccessfulExecution = { successfulExecutionCount += 1 }
        model.update([ActionGridPresentationEntry(id: "old", reference: reference)])
        model.activateSelected()
        for _ in 0 ..< 100 where continuation == nil {
            await Task.yield()
        }

        model.update([ActionGridPresentationEntry(id: "new", reference: reference)])
        continuation?.resume(returning: .terminal(.completed(
            .failed(message: "stale failure")
        )))
        await Task.yield()

        XCTAssertEqual(model.entries.map(\.id), ["new"])
        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.feedback)
        XCTAssertEqual(successfulExecutionCount, 0)
    }

    func testFolderNavigationStaysInOverlayAndDoesNotExecuteFolderSentinel() {
        let actionReference = ActionReference(
            key: ActionKey(providerID: "lock-screen", actionID: "lock")
        )
        let child = ActionGridPresentationEntry(id: "lock", reference: actionReference)
        let folder = ActionGridPresentationEntry(
            id: "system",
            folderTitle: "System",
            children: [child]
        )
        var executed: [ActionReference] = []
        let model = ActionGridOverlayModel(
            resolver: { entry in
                if let children = entry.children {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? "Folder",
                        ownerTitle: "Folder",
                        systemImage: "folder.fill",
                        availability: .available,
                        children: children
                    )
                }
                return ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "Lock Screen",
                    ownerTitle: "System",
                    systemImage: "lock",
                    availability: .available
                )
            },
            executor: {
                executed.append($0)
                return .terminal(.completed(.succeeded()))
            }
        )
        model.update([folder])

        model.activateSelected()
        XCTAssertEqual(model.navigationTitle, "System")
        XCTAssertEqual(model.entries.map(\.title), ["Lock Screen"])
        XCTAssertTrue(executed.isEmpty)

        XCTAssertTrue(model.navigateBack())
        XCTAssertNil(model.navigationTitle)
        XCTAssertEqual(model.entries.map(\.title), ["System"])
        XCTAssertFalse(model.navigateBack())
    }

    func testEmptyNestedFolderPublishesCompactEmptyLayout() {
        let folder = ActionGridPresentationEntry(
            id: "empty",
            folderTitle: "Empty",
            children: []
        )
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: entry.customTitle ?? "Folder",
                    ownerTitle: "Folder",
                    systemImage: "folder.fill",
                    availability: .available,
                    children: entry.children
                )
            },
            executor: { _ in .terminal(.completed(.succeeded())) }
        )
        model.update([folder])

        model.activateSelected()

        XCTAssertEqual(model.navigationTitle, "Empty")
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.slotCount, 0)
        XCTAssertEqual(model.columns, 0)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    private func testEntry() -> ActionGridPresentationEntry {
        ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(
                key: ActionKey(providerID: "missing", actionID: "run")
            )
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

@MainActor
private final class StatefulActionGridTestPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "stateful-action-grid-test",
        title: "Stateful Test",
        iconName: "bolt",
        iconTint: Color.accentColor,
        order: 0,
        defaultDescription: "Tests state refresh."
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var nextState = false
    private(set) var currentState = false
    private(set) var refreshCount = 0

    var toggleReference: ActionReference {
        ActionReference(key: actionDefinitions[0].key)
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: "toggle"),
                title: "Toggle Test State",
                description: "Toggle test state.",
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.background]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleReference,
                title: currentState ? "Turn Off Test State" : "Turn On Test State",
                subtitle: currentState ? "On" : "Off",
                presentationState: currentState ? .active : .inactive
            ),
        ]
    }

    func refresh() {
        refreshCount += 1
        currentState = nextState
        onStateChange?()
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class ConfirmationActionGridTestPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "confirmation-action-grid-test",
        title: "Confirmation Test",
        iconName: "checkmark.shield",
        iconTint: Color.accentColor,
        order: 0,
        defaultDescription: "Tests grid-anchored confirmation."
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var executionCount = 0

    var actionReference: ActionReference {
        ActionReference(key: actionDefinitions[0].key)
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: "run"),
                title: "Run Confirmed Action",
                description: "Run after approval.",
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: "Run Action?",
                    message: "Confirm the action.",
                    confirmButtonTitle: "Run"
                ),
                capabilities: [.background]
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        executionCount += 1
        return ActionExecutionHandle { .succeeded() }
    }
}
