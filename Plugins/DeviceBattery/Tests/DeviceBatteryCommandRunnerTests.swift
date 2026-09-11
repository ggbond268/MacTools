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
            arguments: ["keep\nskip\nkeep-again\n"],
            timeout: 1,
            outputLineFilter: { $0.hasPrefix("keep") }
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "keep\nkeep-again\n", completion: .completed)
        )
    }

    func testTimeoutTerminatesCommandWithoutPollingDelay() async {
        let clock = ContinuousClock()
        let start = clock.now
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )

        XCTAssertEqual(output?.completion, .timedOut)
        XCTAssertEqual(output?.output, "")
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testTimeoutReturnsFilteredPartialOutputWithoutWaitingForDescendantPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: ["-c", "printf 'keep\\nskip\\n'; sleep 30"],
            // CI runs the full suite in parallel, so allow the fixture enough
            // time to launch and emit its output before forcing termination.
            // The elapsed-time assertion still proves that the inherited pipe
            // is closed without waiting for the descendant's 30-second sleep.
            timeout: 2,
            outputLineFilter: { $0 == "keep" }
        )

        XCTAssertEqual(output?.completion, .timedOut)
        XCTAssertEqual(output?.output, "keep\n")
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(5))
    }

    func testCompletedParentDoesNotWaitForDescendantHoldingPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: ["-c", "sleep 5 & printf done"],
            timeout: 2
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "done", completion: .completed)
        )
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testFiltersUTF8LineSplitAcrossPipeReads() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: [
                "-c",
                "printf 'keep \\360\\237'; sleep 0.05; printf '\\221\\213\\nskip\\n'"
            ],
            timeout: 1,
            outputLineFilter: { $0.hasPrefix("keep") }
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "keep 👋\n", completion: .completed)
        )
    }

    func testTaskCancellationTerminatesCommand() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            await DeviceBatteryCommandRunner.run(
                path: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                timeout: 10
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let output = await task.value
        XCTAssertNil(output)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }
}
