import SwiftUI
import XCTest
@testable import MacToolsPluginKit

@MainActor
final class PluginPanelIconWidgetTests: XCTestCase {
    func testCompactGeometryFitsFiveLabeledControlsWithinTheExistingPanelWidth() {
        let metrics = PluginPanelWidgetLayoutMetrics.default
        let span = PluginPanelIconWidget.descriptor.span
        XCTAssertEqual(span.grid, .compact)
        XCTAssertEqual(metrics.itemWidth(for: span), 52.8, accuracy: 0.001)
        XCTAssertEqual(metrics.itemWidth(for: span) * 5 + PluginPanelWidgetLayoutMetrics.compactSpacing * 4,
                       metrics.gridWidth, accuracy: 0.001)
        XCTAssertEqual(metrics.itemHeight(forSpanHeight: span.height), 64)
        XCTAssertEqual(PluginPanelIconWidget.Layout.iconSize, 42)
        XCTAssertEqual(PluginPanelIconWidget.Layout.symbolSize, 20)
        XCTAssertEqual(PluginPanelIconWidget.Layout.iconSize + PluginPanelIconWidget.Layout.titleSpacing
                       + PluginPanelIconWidget.Layout.titleHeight, 60)
        XCTAssertEqual(metrics.itemWidth(for: span) + PluginPanelWidgetLayoutMetrics.compactSpacing
                       - PluginPanelIconWidget.Layout.iconSize, 20.8, accuracy: 0.001)
        XCTAssertEqual(metrics.compactRowSpacing, 10)
        XCTAssertNil(PluginPanelWidgetSpan(width: 5, height: 9))
        XCTAssertNotNil(PluginPanelWidgetSpan(width: 5, height: 9, grid: .compact))
        XCTAssertNil(PluginPanelWidgetSpan(width: 6, height: 9, grid: .compact))
    }

    func testTooltipsKeepFullNamesStatusAndErrorsWithoutDuplicateLines() {
        XCTAssertEqual(PluginPanelIconWidget.helpText(title: "Control", state: makeState(error: "Failed")),
                       "Control\nStatus\nFailed")
        XCTAssertEqual(PluginPanelIconWidget.helpText(title: "Control", state: makeState(error: "Status")),
                       "Control\nStatus")
        let emptyState = PluginPanelRowState(subtitle: "  ", isOn: false, isEnabled: false,
                                            isAvailable: false, detail: nil, errorMessage: nil)
        XCTAssertEqual(PluginPanelIconWidget.helpText(title: "Control", state: emptyState), "Control")
    }

    func testLongLocalizedTitlesKeepTheSameFixedPreviewSizeAndFullTooltip() throws {
        let size = PluginPanelWidgetLayoutMetrics.default.compactCellSize
        for title in ["Control", "A control with a very long localized name", "自动切换输入法"] {
            let item = PluginPanelItem.iconWidget(
                id: "quick-control", title: title, systemImage: "keyboard",
                control: .toggle, state: makeState(), menuActionBehavior: .keepPresented, action: { _ in }
            )
            guard case let .widget(widget) = item.content else { return XCTFail("Expected a widget") }
            let hosting = NSHostingView(rootView: widget.makeView(makeContext(preview: true)).frame(width: size.width))
            XCTAssertEqual(hosting.fittingSize.width, size.width, accuracy: 1)
            XCTAssertEqual(hosting.fittingSize.height, size.height, accuracy: 1)
            XCTAssertEqual(PluginPanelIconWidget.helpText(title: title, state: makeState()), "\(title)\nStatus")
        }
    }

    func testOptionalWidgetSharesAvailabilityAndErrorWithoutHighlightingButtons() throws {
        for control in [PluginPanelIconControl.toggle, .button] {
            for isOn in [false, true] {
                let state = makeState(isOn: isOn, isEnabled: false, isAvailable: false, error: "Unavailable")
                let item = PluginPanelItem.iconWidget(
                    id: "quick-control", title: "Control", systemImage: "moon",
                    control: control, state: state, menuActionBehavior: .keepPresented, action: { _ in }
                )
                guard case let .widget(widget) = item.content else { return XCTFail("Expected a widget") }
                XCTAssertEqual(item.id, "quick-control")
                XCTAssertNil(item.initialPlacement)
                XCTAssertEqual(widget.state.isActive, control == .toggle && isOn)
                XCTAssertFalse(widget.state.isEnabled)
                XCTAssertFalse(widget.state.isAvailable)
                XCTAssertEqual(widget.state.subtitle, state.subtitle)
                XCTAssertEqual(widget.state.errorMessage, state.errorMessage)
                XCTAssertEqual(widget.descriptor.span.width, 1)
            }
        }
    }

    func testControlActionsKeepToggleAndButtonSemanticsSeparate() {
        XCTAssertEqual(PluginPanelIconControl.toggle.action(isOn: false), .setSwitch(true))
        XCTAssertEqual(PluginPanelIconControl.toggle.action(isOn: true), .setSwitch(false))
        XCTAssertEqual(PluginPanelIconControl.toggle.action(isOn: true, requestedToggleValue: true), .setSwitch(true))
        XCTAssertEqual(PluginPanelIconControl.toggle.action(isOn: false, requestedToggleValue: false), .setSwitch(false))
        XCTAssertEqual(PluginPanelIconControl.button.action(isOn: true), .invokeAction(controlID: "execute"))
        XCTAssertEqual(PluginPanelIconControl.button.action(isOn: false), .invokeAction(controlID: "execute"))
    }

    func testToggleUsesConfirmedSnapshotWithoutOptimisticState() {
        let dispatcher = PluginPanelIconActionDispatcher()
        var actions: [PluginPanelAction] = []
        for isOn in [false, false, true] {
            dispatcher.perform(control: .toggle, state: makeState(isOn: isOn), context: makeContext(),
                               behavior: .keepPresented) { actions.append($0) }
        }
        XCTAssertEqual(actions, [.setSwitch(true), .setSwitch(true), .setSwitch(false)])
        XCTAssertFalse(dispatcher.isDispatching)
    }

    func testDismissalPrecedesActionAndPendingActionOutlivesView() async {
        var dispatcher: PluginPanelIconActionDispatcher? = PluginPanelIconActionDispatcher()
        var events: [String] = []
        let completed = expectation(description: "Action survives dismissal")
        let context = makeContext(dismiss: { events.append("dismiss") })
        let handler: (PluginPanelAction) -> Void = {
            XCTAssertEqual($0, .invokeAction(controlID: "execute"))
            events.append("action")
            completed.fulfill()
        }
        for _ in 0..<2 {
            dispatcher?.perform(control: .button, state: makeState(isOn: true), context: context,
                                behavior: .dismissBeforeHandling, action: handler)
        }
        XCTAssertEqual(events, ["dismiss"])
        XCTAssertEqual(dispatcher?.isDispatching, true)
        dispatcher = nil
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(events, ["dismiss", "action"])
    }

    func testPreviewAndDisabledControlsNeverInvokeActions() async {
        for (preview, enabled, available) in [(true, true, true), (false, false, true), (false, true, false)] {
            for control in [PluginPanelIconControl.toggle, .button] {
                let dispatcher = PluginPanelIconActionDispatcher()
                var actions: [PluginPanelAction] = []
                var dismissals = 0
                dispatcher.perform(control: control,
                    state: makeState(isEnabled: enabled, isAvailable: available),
                    context: makeContext(preview: preview, dismiss: { dismissals += 1 }),
                    behavior: .dismissBeforeHandling) { actions.append($0) }
                await Task.yield()
                XCTAssertTrue(actions.isEmpty)
                XCTAssertEqual(dismissals, 0)
                XCTAssertFalse(dispatcher.isDispatching)
            }
        }
    }

    private func makeState(isOn: Bool = false, isEnabled: Bool = true, isAvailable: Bool = true,
                           error: String? = nil) -> PluginPanelRowState {
        .init(subtitle: "Status", isOn: isOn, isEnabled: isEnabled,
              isAvailable: isAvailable, detail: nil, errorMessage: error)
    }

    private func makeContext(preview: Bool = false, dismiss: @escaping () -> Void = {}) -> PluginPanelWidgetContext {
        .init(pluginID: "test", itemID: "quick-control", placementID: preview ? nil : UUID(), dismiss: dismiss)
    }
}
