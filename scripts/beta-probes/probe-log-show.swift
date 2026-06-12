#!/usr/bin/env swift
// `log show` predicate regression probe (DeviceBattery's bluetooth power
// channel). On 26A5353q `log show --process X --predicate Y` silently drops
// the predicate (returns the per-process firehose); the app dropped --process
// as a workaround (DeviceBatterySampler.bluetoothPowerLogShowArguments).
// All invocations are bounded with --last 1m and a hard kill timeout.

import Foundation

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

// The three failure modes must stay distinguishable: a clean non-zero exit
// means `log show` rejected the invocation (actionable break for the
// predicate-only run the app ships), while launch failure / watchdog SIGTERM
// are environment problems.
enum LogShowOutcome {
    case lines(Int)
    case launchFailure(String)
    case terminatedBySignal
    case exitedNonZero(Int32)
}

func runLogShow(extraArguments: [String], timeout: TimeInterval) -> LogShowOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    // Mirrors DeviceBatterySampler.bluetoothPowerLogShowArguments base args.
    process.arguments = ["show", "--info", "--last", "1m", "--style", "compact"] + extraArguments

    let stdout = Pipe()
    process.standardOutput = stdout
    // stderr is never inspected; an undrained pipe could fill up (64KB) and
    // deadlock a chatty `log show` until the watchdog fires.
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return .launchFailure(error.localizedDescription)
    }

    let watchdog = DispatchWorkItem {
        if process.isRunning {
            process.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

    var newlineCount = 0
    let handle = stdout.fileHandleForReading
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty {
            break
        }
        newlineCount += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    process.waitUntilExit()
    watchdog.cancel()

    guard process.terminationReason == .exit else {
        return .terminatedBySignal
    }
    guard process.terminationStatus == 0 else {
        return .exitedNonZero(process.terminationStatus)
    }
    return .lines(newlineCount)
}

func failureDetail(_ outcome: LogShowOutcome) -> String {
    switch outcome {
    case .lines(let count):
        return "succeeded with \(count) lines"
    case .launchFailure(let reason):
        return "failed to launch (\(reason))"
    case .terminatedBySignal:
        return "timed out and was terminated"
    case .exitedNonZero(let status):
        return "exited rc=\(status)"
    }
}

let probeName = "log-predicate-with-process"
// A highly selective predicate is required to discriminate: a broad one
// (e.g. just the subsystem pin) matches more lines than `--process
// bluetoothd` itself, because other processes also log to the subsystem.
let predicate = "subsystem == \"com.apple.bluetooth\" AND category == \"CBPowerSource\""
let perRunTimeout: TimeInterval = 90

let processOnlyOutcome = runLogShow(extraArguments: ["--process", "bluetoothd"], timeout: perRunTimeout)
guard case .lines(let processOnly) = processOnlyOutcome else {
    report(.inconclusive, probeName, "`log show --process bluetoothd` \(failureDetail(processOnlyOutcome))")
    exit(0)
}
let combinedOutcome = runLogShow(
    extraArguments: ["--process", "bluetoothd", "--predicate", predicate],
    timeout: perRunTimeout
)
guard case .lines(let combined) = combinedOutcome else {
    report(.inconclusive, probeName, "`log show --process --predicate` \(failureDetail(combinedOutcome))")
    exit(0)
}
let predicateOnlyOutcome = runLogShow(extraArguments: ["--predicate", predicate], timeout: perRunTimeout)
let predicateOnly: Int
switch predicateOnlyOutcome {
case .lines(let count):
    predicateOnly = count
case .exitedNonZero(let status):
    report(
        .broken,
        probeName,
        "`log show --predicate` exited rc=\(status) — predicate rejected; DeviceBattery's current predicate-only log path is dead"
    )
    exit(0)
case .launchFailure, .terminatedBySignal:
    report(
        .inconclusive,
        probeName,
        "`log show --predicate` (the app's current path) \(failureDetail(predicateOnlyOutcome))"
    )
    exit(0)
}

let counts = "process-only=\(processOnly) combined=\(combined) predicate-only=\(predicateOnly) lines in --last 1m"

// CBPowerSource events are rare (a handful per minute at most), so a count
// anywhere near the process-only volume means the filter was not applied.
let droppedWithProcess = combined * 10 >= processOnly * 9
let ignoredStandalone = predicateOnly >= processOnly

if processOnly < 50 {
    report(
        .inconclusive,
        probeName,
        counts + " — bluetoothd too quiet to discriminate; rerun while Bluetooth devices are active"
    )
} else if ignoredStandalone {
    report(
        .broken,
        probeName,
        counts + " — predicate ignored even standalone; DeviceBattery's predicate-only log path is dead"
    )
} else if droppedWithProcess {
    report(
        .degraded,
        probeName,
        counts + " — predicate still dropped when --process is present (26A5353q regression persists); keep the predicate-only workaround, keep the Apple Feedback open"
    )
} else {
    report(
        .ok,
        probeName,
        counts + " — predicate honored alongside --process again; the --process optimization could be restored"
    )
}
