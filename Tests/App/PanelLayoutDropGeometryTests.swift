import AppKit
import Combine
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PanelLayoutDropGeometryTests: XCTestCase {
    func testCompactRowsSupportEveryHorizontalBoundaryAndRTL() throws {
        for count in [1, 3, 5, 8] {
            let frames = compactFrames(count: count)
            let geometry = PanelLayoutDropGeometry(frames: frames)
            for (index, item) in frames.enumerated() {
                for after in [false, true] {
                    let x = after ? item.frame.maxX - 1 : item.frame.minX + 1
                    let expected = index + (after ? 1 : 0)
                    for rtl in [false, true] {
                        let point = CGPoint(x: rtl ? 304 - x : x, y: item.frame.midY)
                        let target = geometry.target(at: point, rightToLeft: rtl)
                        XCTAssertEqual(target.offset, expected)
                        let marker = try XCTUnwrap(target.markerFrame)
                        XCTAssertEqual(marker.width, 3)
                        XCTAssertEqual(marker.height, item.frame.height)
                        XCTAssertEqual(geometry.target(at: CGPoint(x: marker.midX, y: marker.midY),
                                                       rightToLeft: rtl).offset, expected)
                    }
                }
            }
        }
    }

    func testPartialRowTrailingSpaceKeepsWidgetEdgeInsteadOfJumpingToNextRow() throws {
        var frames = compactFrames(count: 2)
        frames.append(frame(kind: .row, rect: CGRect(x: 0, y: 70, width: 304, height: 44)))
        let geometry = PanelLayoutDropGeometry(frames: frames)
        let trailing = geometry.target(at: CGPoint(x: 280, y: 63), rightToLeft: false)
        XCTAssertEqual(trailing.offset, 2)
        XCTAssertEqual(trailing.markerFrame, CGRect(x: frames[1].frame.maxX - 3, y: 0, width: 3, height: 64))
        let nextRow = geometry.target(at: CGPoint(x: 280, y: 71), rightToLeft: false)
        XCTAssertEqual(nextRow.offset, 2)
        XCTAssertEqual(nextRow.markerFrame, CGRect(x: 0, y: 70, width: 304, height: 3))
        let mirrored = geometry.target(at: CGPoint(x: 24, y: 63), rightToLeft: true)
        XCTAssertEqual(mirrored.offset, trailing.offset)
        XCTAssertEqual(try XCTUnwrap(mirrored.markerFrame).maxX, 304 - trailing.markerFrame!.minX, accuracy: 0.001)
    }

    func testWrappedBoundaryRetainsTheEdgeActuallyPointedAt() {
        let frames = compactFrames(count: 6)
        let geometry = PanelLayoutDropGeometry(frames: frames)
        let endOfLine = geometry.target(at: CGPoint(x: frames[4].frame.maxX - 1, y: frames[4].frame.midY), rightToLeft: false)
        let nextLine = geometry.target(at: CGPoint(x: frames[5].frame.minX + 1, y: frames[5].frame.midY), rightToLeft: false)
        XCTAssertEqual(endOfLine.offset, 5)
        XCTAssertEqual(nextLine.offset, 5)
        XCTAssertEqual(endOfLine.markerFrame?.minY, frames[4].frame.minY)
        XCTAssertEqual(nextLine.markerFrame?.minY, frames[5].frame.minY)
        XCTAssertNotEqual(endOfLine.markerFrame, nextLine.markerFrame)
    }

    func testFullWidthRowsUseVerticalHalvesAndCanvasHandlesEmptyAndEnd() {
        let frames = [frame(kind: .row, rect: CGRect(x: 0, y: 0, width: 304, height: 44)),
                      frame(kind: .row, rect: CGRect(x: 0, y: 52, width: 304, height: 44))]
        let geometry = PanelLayoutDropGeometry(frames: frames)
        for (y, expected) in [(-10.0, 0), (10, 0), (35, 1), (60, 1), (90, 2), (500, 2)] {
            let target = geometry.target(at: CGPoint(x: 150, y: y), rightToLeft: false)
            XCTAssertEqual(target.offset, expected)
            XCTAssertEqual(target.markerFrame?.width, 304)
            XCTAssertEqual(target.markerFrame?.height, 3)
        }
        let empty = PanelLayoutDropGeometry(frames: []).target(at: CGPoint(x: 100, y: 100), rightToLeft: true)
        XCTAssertEqual(empty.offset, 0)
        XCTAssertEqual(empty.markerFrame, CGRect(x: 0, y: 0, width: 304, height: 3))
    }

    func testMarkerChangesAtSameOffsetWithoutRebuildingTheEditorOrRepublishingDuplicates() {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c"]
        _ = session.begin(id: "a", ids: ids)
        var editorUpdates = 0
        var markerUpdates = 0
        let editor = session.objectWillChange.sink { editorUpdates += 1 }
        let marker = session.dragPreview.objectWillChange.sink { markerUpdates += 1 }
        defer { editor.cancel(); marker.cancel() }
        for rect in [CGRect(x: 50, y: 0, width: 3, height: 64), CGRect(x: 0, y: 74, width: 3, height: 64)] {
            for _ in 0..<100 {
                session.preview(target: .init(offset: 2, markerFrame: rect), ids: ids)
            }
        }
        XCTAssertEqual(session.destination, 2)
        XCTAssertEqual(markerUpdates, 2)
        XCTAssertEqual(editorUpdates, 0)
        session.leave()
        XCTAssertNil(session.dragPreview.target)
    }

    func testCompactControlsLeaveMostOfTheTileDraggableWithoutChangingItsFrame() {
        let bounds = CGRect(origin: .zero, size: PluginPanelWidgetLayoutMetrics.default.compactCellSize)
        let layout = PanelLayoutItemControlsLayout(size: bounds.size)
        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.controlCount, 1)
        XCTAssertGreaterThanOrEqual(layout.buttonSide, 24)
        for rtl in [false, true] {
            let controls = layout.buttonFrames(in: bounds, rightToLeft: rtl)
            XCTAssertEqual(controls.count, 1)
            XCTAssertTrue(bounds.contains(controls[0]))
            XCTAssertEqual(controls[0].midX, bounds.midX)
            XCTAssertEqual(controls[0].midY, bounds.midY)
            XCTAssertLessThan(controls[0].width * controls[0].height, bounds.width * bounds.height / 4)
        }
    }

    func testRegularAndTallCardsKeepThreeDistinctAccessibleControls() {
        for size in [CGSize(width: 304, height: 44), CGSize(width: 148, height: 96), CGSize(width: 70, height: 192)] {
            let bounds = CGRect(origin: .zero, size: size)
            let layout = PanelLayoutItemControlsLayout(size: size)
            XCTAssertFalse(layout.isCompact)
            XCTAssertGreaterThanOrEqual(layout.buttonSide, 24)
            for rtl in [false, true] {
                let frames = layout.buttonFrames(in: bounds, rightToLeft: rtl)
                XCTAssertEqual(frames.count, 3)
                for (index, frame) in frames.enumerated() {
                    XCTAssertTrue(bounds.contains(frame))
                    for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
                }
            }
        }
    }

    func testVacantSpaceBeforeFullWidthCardAcceptsLaterWidgetAndMirrorsItsFootprint() throws {
        let compact = PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact)!
        let fixture = widgetFixture([compact, compact, .init(width: 4, height: 12)!, compact])
        let source = fixture.components[3]
        let placement = ConfiguredMenuBarPanelLayout.placement(entries: fixture.entries,
            components: fixture.components, features: [])
        let frames = PanelLayoutEntryFrame.frames(entries: fixture.entries, placement: placement)
        let vacancies = PanelLayoutWidgetDropTargets.targets(source: source, entries: fixture.entries,
            components: fixture.components, features: [], frames: frames)
        let geometry = PanelLayoutDropGeometry(frames: frames, vacancies: vacancies)
        let gap = CGRect(x: 125.6, y: 0, width: 52.8, height: 64)
        for rtl in [false, true] {
            let point = CGPoint(x: rtl ? 304 - gap.midX : gap.midX, y: gap.midY)
            let target = geometry.target(at: point, rightToLeft: rtl)
            XCTAssertTrue(target.isVacancy)
            XCTAssertEqual(target.offset, 2)
            let marker = try XCTUnwrap(target.markerFrame)
            XCTAssertEqual(marker.minX, rtl ? 304 - gap.maxX : gap.minX, accuracy: 0.001)
            XCTAssertEqual(marker.minY, gap.minY)
            XCTAssertEqual(marker.width, gap.width, accuracy: 0.001)
            XCTAssertEqual(marker.height, gap.height)
        }
        let occupied = geometry.target(at: CGPoint(x: frames[1].frame.minX + 1, y: 32), rightToLeft: false)
        XCTAssertFalse(occupied.isVacancy, "Occupied widgets must retain ordinary before/after insertion")
    }

    func testVacancyTargetsMatchFinalPackingForSameAndCrossPanelMovesAcrossRowBoundaries() throws {
        let variants = [PluginPanelWidgetGrid.standard, .compact].flatMap { grid in
            (1...grid.rawValue).map { PluginPanelWidgetSpan(width: $0, height: $0 % 2 == 0 ? 16 : 8, grid: grid)! }
        }
        var checked = 0
        for seed in 0..<(variants.count * 6) {
            let fixture = widgetFixture((0..<6).map { variants[(seed + $0 * 5) % variants.count] })
            let row = MenuBarPanelEntry(placement: .init(item: .init(pluginID: "row", itemID: "row")), kind: .row)
            let feature = PluginPanelRowSnapshot(id: row.id, title: "Row", iconName: "circle", iconTint: .blue,
                controlStyle: .button, menuActionBehavior: .keepPresented, description: "", helpText: "",
                descriptionTone: .secondary, isOn: false, isExpanded: false, isEnabled: true,
                detail: nil, buttonActionID: nil, buttonTitle: nil)
            var entries = fixture.entries
            if seed % 2 == 0 { entries.insert(row, at: 3) }
            let features = entries.contains(row) ? [feature] : []
            for external in [false, true] {
                let source = external ? widgetFixture([variants[seed % variants.count]]).components[0]
                    : fixture.components[seed % fixture.components.count]
                let placement = ConfiguredMenuBarPanelLayout.placement(entries: entries,
                    components: fixture.components, features: features)
                let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
                let targets = PanelLayoutWidgetDropTargets.targets(source: source, entries: entries,
                    components: fixture.components, features: features, frames: frames)
                for target in targets {
                    var order = entries
                    if external {
                        let entry = MenuBarPanelEntry(placement: .init(id: UUID(uuidString: source.id)!,
                            item: .init(pluginID: "external", itemID: "widget")), kind: .widget)
                        order.insert(entry, at: target.offset)
                    } else {
                        let ids = PanelLayoutDestination.moving(source.id, toOffset: target.offset, in: entries.map(\.id))
                        let lookup = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                        order = ids.compactMap { lookup[$0] }
                    }
                    let result = ConfiguredMenuBarPanelLayout.placement(entries: order,
                        components: fixture.components + (external ? [source] : []), features: features)
                    let actual = try XCTUnwrap(result.components.first { $0.id == source.id })
                    XCTAssertEqual(PanelLayoutDestination.frame(actual), target.markerFrame,
                                   "A vacancy must show the exact committed frame")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func testOversizedWidgetDoesNotAdvertiseSmallVacancy() {
        let compact = PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact)!
        let fixture = widgetFixture([compact, compact, .init(width: 4, height: 12)!])
        let source = widgetFixture([.init(width: 4, height: 12)!]).components[0]
        let placement = ConfiguredMenuBarPanelLayout.placement(entries: fixture.entries,
            components: fixture.components, features: [])
        let frames = PanelLayoutEntryFrame.frames(entries: fixture.entries, placement: placement)
        let vacancies = PanelLayoutWidgetDropTargets.targets(source: source, entries: fixture.entries,
            components: fixture.components, features: [], frames: frames)
        let target = PanelLayoutDropGeometry(frames: frames, vacancies: vacancies)
            .target(at: CGPoint(x: 152, y: 32), rightToLeft: false)
        XCTAssertFalse(target.isVacancy)
    }

    func testThousandTallCardsOnlyOfferTheUnoccupiedTail() throws {
        let fixture = widgetFixture(Array(repeating: .init(width: 4, height: 50)!, count: 1000))
        let source = widgetFixture([.init(width: 1, height: 8, grid: .compact)!]).components[0]
        let placement = ConfiguredMenuBarPanelLayout.placement(entries: fixture.entries,
            components: fixture.components, features: [])
        let frames = PanelLayoutEntryFrame.frames(entries: fixture.entries, placement: placement)
        let targets = PanelLayoutWidgetDropTargets.targets(source: source, entries: fixture.entries,
            components: fixture.components, features: [], frames: frames)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.offset, 1000)
        XCTAssertEqual(try XCTUnwrap(targets.first?.markerFrame).minY,
                       placement.height + ComponentPanelLayout.verticalSpacing)
    }

    private func widgetFixture(_ spans: [PluginPanelWidgetSpan])
        -> (entries: [MenuBarPanelEntry], components: [PluginPanelWidgetSnapshot]) {
        let entries = spans.indices.map { index in
            MenuBarPanelEntry(placement: .init(item: .init(pluginID: "fixture-\(index)", itemID: "widget")), kind: .widget)
        }
        let components = zip(entries, spans).map { entry, span in
            PluginPanelWidgetSnapshot(id: entry.id, title: "Widget", iconName: "circle", iconTint: .blue,
                description: "", helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true)
        }
        return (entries, components)
    }

    private func compactFrames(count: Int) -> [PanelLayoutEntryFrame] {
        let span = PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact)!
        return ComponentGridPlacementEngine.placements(for: (0..<count).map { (String($0), span) })
            .map { frame(kind: .widget, rect: PanelLayoutDestination.frame($0)) }
    }

    private func frame(kind: PluginPanelItemKind, rect: CGRect) -> PanelLayoutEntryFrame {
        .init(entry: .init(placement: .init(item: .init(pluginID: "fixture", itemID: kind.rawValue)), kind: kind), frame: rect)
    }
}
