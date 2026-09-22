import XCTest
@testable import DeviceBatteryPlugin

final class DeviceBatteryCommandRunnerTests: XCTestCase {
    func testReturnsCompleteOutput() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/usr/bin/printf",
            arguments: ["battery-output"],
            timeout: 1
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "battery-output", completion: .completed)
        )
    }

    func testFiltersOutputWhileDrainingPipe() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/usr/bin/printf",
            arguments: ["keep 👋\nskip 🌍\nkeep 中文\n"],
            timeout: 5,
            outputLineFilter: { $0.hasPrefix("keep") }
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "keep 👋\nkeep 中文\n", completion: .completed)
        )
    }

    func testTimeoutTerminatesCommand() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )

        XCTAssertEqual(output?.completion, .timedOut)
        XCTAssertEqual(output?.output, "")
    }

    func testTaskCancellationTerminatesCommand() async {
        let task = Task {
            await DeviceBatteryCommandRunner.run(
                path: "/bin/sleep",
                arguments: ["5"],
                timeout: 10
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let output = await task.value
        XCTAssertNil(output)
    }
}
