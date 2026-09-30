import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginSettingsSliderInteractionStateTests: XCTestCase {
    private let range = 0.0...100.0

    func testModelValueUpdateOnlySynchronizesDisplayedValue() {
        var state = makeState(value: 50)

        state.modelValueChanged(70)

        XCTAssertEqual(state.currentValue, 70)
        XCTAssertFalse(state.isEditing)
        // The synchronized value must not be replayed as a user action.
        XCTAssertEqual(
            state.userValueChanged(70, controlID: "level", range: range, step: 1),
            []
        )
        XCTAssertEqual(state.editingChanged(false, controlID: "level"), [])
    }

    func testKeyboardOrAssistiveValueChangeCommitsImmediately() {
        var state = makeState(value: 50)

        let actions = state.userValueChanged(
            70,
            controlID: "level",
            range: range,
            step: 1
        )

        XCTAssertEqual(
            actions,
            [
                .setNumber(controlID: "level", value: 70, phase: .changed),
                .setNumber(controlID: "level", value: 70, phase: .committed)
            ]
        )
        XCTAssertEqual(state.editingChanged(false, controlID: "level"), [])
    }

    func testEditingUserChangeCommitsOnceWhenEditingEnds() {
        var state = makeState(value: 50)

        XCTAssertEqual(state.editingChanged(true, controlID: "level"), [])
        XCTAssertEqual(
            state.userValueChanged(70, controlID: "level", range: range, step: 1),
            [.setNumber(controlID: "level", value: 70, phase: .changed)]
        )
        XCTAssertEqual(
            state.editingChanged(false, controlID: "level"),
            [.setNumber(controlID: "level", value: 70, phase: .committed)]
        )
    }

    func testRepeatedUserValueDoesNotDispatchAnAction() {
        var state = makeState(value: 50)

        XCTAssertEqual(
            state.userValueChanged(50, controlID: "level", range: range, step: 1),
            []
        )
    }

    private func makeState(value: Double) -> PluginSettingsSliderInteractionState {
        PluginSettingsSliderInteractionState(value: value)
    }
}
