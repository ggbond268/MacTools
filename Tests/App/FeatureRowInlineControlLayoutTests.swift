import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class FeatureRowInlineControlLayoutTests: XCTestCase {
    func testInlineOptionsDoNotWidenRowsOrOverflowTheirNativeControl() throws {
        let model = InlineControlFixtureModel()
        let (host, window) = makeHost(model)
        defer { window.close() }

        for title in ["Never", "永不", "Niemals", "Jamais", "Никогда", "أبدًا", "Nunca", "決して", "절대로"] {
            model.foreverTitle = title
            for enabled in [false, true, false] {
                model.enabled = enabled
                settle(host)

                for frames in model.rowFrames.values {
                    for frame in frames {
                        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
                        XCTAssertEqual(frame.width, MenuBarPanelLayout.surfaceWidth, accuracy: 0.5)
                    }
                }
                if enabled {
                    let segmented = try XCTUnwrap(segmentedControl(in: host))
                    let frame = segmented.convert(segmented.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, MenuBarPanelLayout.surfaceWidth)
                    XCTAssertLessThanOrEqual(segmented.intrinsicContentSize.width, frame.width + 0.5)
                    XCTAssertEqual(frame.height, 24, accuracy: 0.5)
                }
            }
        }
        XCTAssertFalse(model.rowFrames.isEmpty)
    }

    func testInlineSelectionPreservesActionsExternalUpdatesAndDisabledState() throws {
        let model = InlineControlFixtureModel()
        model.enabled = true
        let (host, window) = makeHost(model)
        defer { window.close() }
        settle(host)

        let segmented = try XCTUnwrap(segmentedControl(in: host))
        XCTAssertEqual(segmented.selectedSegment, 0)
        XCTAssertEqual(segmented.label(forSegment: 0), "Never")
        segmented.selectedSegment = 2
        segmented.sendAction(try XCTUnwrap(segmented.action), to: segmented.target)
        XCTAssertEqual(model.selections, ["duration:one-hour"])

        model.selectedID = "five-hours"
        model.controlEnabled = false
        model.layoutDirection = .rightToLeft
        settle(host)
        XCTAssertEqual(segmented.selectedSegment, 4)
        XCTAssertFalse(segmented.isEnabled)
        XCTAssertEqual(segmented.userInterfaceLayoutDirection, .rightToLeft)
        XCTAssertEqual(segmented.label(forSegment: 4), "5h")
        segmented.selectedSegment = 1
        segmented.sendAction(try XCTUnwrap(segmented.action), to: segmented.target)
        XCTAssertEqual(model.selections, ["duration:one-hour"])
    }

    private func makeHost(_ model: InlineControlFixtureModel) -> (NSHostingView<InlineControlFixture>, NSWindow) {
        let host = NSHostingView(rootView: InlineControlFixture(model: model))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: MenuBarPanelLayout.surfaceWidth, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (host, window)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let segmented = view as? NSSegmentedControl { return segmented }
        return view.subviews.lazy.compactMap { self.segmentedControl(in: $0) }.first
    }
}

@MainActor
private final class InlineControlFixtureModel: ObservableObject {
    @Published var enabled = false
    @Published var selectedID = "forever"
    @Published var controlEnabled = true
    @Published var foreverTitle = "Never"
    @Published var layoutDirection = LayoutDirection.leftToRight
    var rowFrames: [Int: [CGRect]] = [:]
    var selections: [String] = []

    func item(_ index: Int) -> PluginPanelItem {
        let detail = PluginPanelDetail(primaryControls: [PluginPanelControl(
            id: "duration", kind: .segmented,
            options: [
                .init(id: "forever", title: foreverTitle),
                .init(id: "thirty-minutes", title: "30min"),
                .init(id: "one-hour", title: "1h"),
                .init(id: "two-hours", title: "2h"),
                .init(id: "five-hours", title: "5h")
            ],
            selectedOptionID: selectedID,
            dateValue: nil, minimumDate: nil, displayedComponents: nil,
            datePickerStyle: nil, sectionTitle: nil, isEnabled: controlEnabled
        )], secondaryPanel: nil)
        return PluginPanelItem(
            id: "fixture-\(index)", title: "Keep Awake", iconName: "cup.and.saucer",
            iconTint: .blue, controlStyle: .switch, menuActionBehavior: .keepPresented,
            description: enabled ? "No automatic stop" : "Keep your Mac awake",
            helpText: "Keep Awake", descriptionTone: .secondary,
            isOn: enabled, isExpanded: false, isEnabled: true,
            detail: enabled && index == 0 ? detail : nil, buttonActionID: nil, buttonTitle: nil
        )
    }
}

private struct InlineControlFixture: View {
    @ObservedObject var model: InlineControlFixtureModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: MenuBarPanelLayout.featureRowSpacing) {
                ForEach(0..<2) { index in
                    FeatureRowView(
                        item: model.item(index), indicator: nil, compactIndicator: nil,
                        onDisclosureToggle: { _ in },
                        onSelectionChange: { controlID, optionID in
                            model.selections.append("\(controlID):\(optionID)")
                            model.selectedID = optionID
                        },
                        onNavigationSelectionChange: { _, _ in },
                        onNavigationHoverChange: { _, _, _ in },
                        onNavigationRowFrameChange: { _, _, _ in },
                        onDateChange: { _, _ in }, onSwitchChange: { $0 },
                        onSliderChange: { _, _, _ in }, onActionInvoke: { _, _ in }
                    )
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("rows")) } action: { frame in
                        model.rowFrames[index, default: []].append(frame)
                    }
                }
            }
            .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
            .coordinateSpace(name: "rows")
        }
        .frame(width: MenuBarPanelLayout.surfaceWidth, height: 300)
        .environment(\.layoutDirection, model.layoutDirection)
    }
}
