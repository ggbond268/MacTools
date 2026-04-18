import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MockHideNotchWallpaperController: HideNotchWallpaperControlling {
    var onStateChange: (() -> Void)?
    var snapshotValue = HideNotchSnapshot(
        hasSupportedDisplay: false,
        supportedDisplayCount: 0,
        managedDisplayCount: 0,
        unsupportedVisibleDisplayCount: 0,
        pendingRestoreCount: 0,
        isEnabled: false,
        isProcessing: false,
        isAwaitingDisplay: false,
        errorMessage: nil
    )
    private(set) var refreshCallCount = 0
    private(set) var setEnabledCalls: [Bool] = []

    func snapshot() -> HideNotchSnapshot {
        snapshotValue
    }

    func refresh() {
        refreshCallCount += 1
    }

    func setEnabled(_ isEnabled: Bool) {
        setEnabledCalls.append(isEnabled)
        snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: snapshotValue.hasSupportedDisplay,
            supportedDisplayCount: snapshotValue.supportedDisplayCount,
            managedDisplayCount: isEnabled ? max(snapshotValue.managedDisplayCount, 1) : 0,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: isEnabled,
            isProcessing: false,
            isAwaitingDisplay: isEnabled && !snapshotValue.hasSupportedDisplay,
            errorMessage: snapshotValue.errorMessage
        )
    }
}

@MainActor
final class InMemoryHideNotchStateStore: HideNotchStateStoring {
    var desiredEnabled = false
}

struct StubHideNotchDisplayCatalog: HideNotchDisplayCatalogProviding {
    let records: [HideNotchDisplayRecord]

    func listDisplayRecords() -> [HideNotchDisplayRecord] {
        records
    }
}

@MainActor
final class MutableHideNotchDisplayCatalog: HideNotchDisplayCatalogProviding {
    var records: [HideNotchDisplayRecord]

    init(records: [HideNotchDisplayRecord]) {
        self.records = records
    }

    func listDisplayRecords() -> [HideNotchDisplayRecord] {
        records
    }
}

@MainActor
final class RecordingHideNotchDesktopMaskManager: HideNotchDesktopMaskManaging {
    var managedDisplayIdentifiers: Set<String> = []
    var synchronizeError: Error?

    private(set) var synchronizeCalls: [[HideNotchDisplayContext]] = []
    private(set) var hideAllCallCount = 0

    func synchronizeMasks(for displays: [HideNotchDisplayContext]) throws {
        if let synchronizeError {
            throw synchronizeError
        }

        synchronizeCalls.append(displays)
        managedDisplayIdentifiers = Set(displays.filter(\.isSupported).map(\.displayIdentifier))
    }

    func hideAllMasks() {
        hideAllCallCount += 1
        managedDisplayIdentifiers.removeAll()
    }
}

@MainActor
final class RecordingHideNotchDesktopMaskWindow: HideNotchDesktopMaskWindowing {
    private(set) var frames: [CGRect]
    private(set) var showCallCount = 0
    private(set) var closeCallCount = 0

    init(frame: CGRect) {
        frames = [frame]
    }

    func setFrame(_ frame: CGRect) {
        frames.append(frame)
    }

    func show() {
        showCallCount += 1
    }

    func close() {
        closeCallCount += 1
    }
}

enum StubHideNotchDesktopMaskWindowBuilderError: LocalizedError {
    case forcedFailure

    var errorDescription: String? {
        "forced failure"
    }
}

@MainActor
final class RecordingHideNotchDesktopMaskWindowBuilder: HideNotchDesktopMaskWindowBuilding {
    var makeWindowError: Error?

    private(set) var windowsByOriginX: [CGFloat: RecordingHideNotchDesktopMaskWindow] = [:]
    private(set) var createdFrames: [CGRect] = []

    func makeWindow(frame: CGRect) throws -> HideNotchDesktopMaskWindowing {
        if let makeWindowError {
            throw makeWindowError
        }

        let window = RecordingHideNotchDesktopMaskWindow(frame: frame)
        createdFrames.append(frame)
        windowsByOriginX[frame.minX] = window
        return window
    }
}

func makeHideNotchDisplayRecord(
    id displayID: CGDirectDisplayID,
    displayIdentifier: String,
    spaces: [HideNotchDisplaySpace] = [HideNotchDisplaySpace(identifier: "space-1", isCurrent: true)],
    name: String = "Built-in Retina Display",
    frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982),
    backingScaleFactor: CGFloat = 2,
    notchHeightPoints: CGFloat = 36,
    isBuiltin: Bool = true,
    isSupported: Bool = true
) -> HideNotchDisplayRecord {
    HideNotchDisplayRecord(
        context: HideNotchDisplayContext(
            displayID: displayID,
            displayIdentifier: displayIdentifier,
            name: name,
            frame: frame,
            backingScaleFactor: backingScaleFactor,
            notchHeightPoints: notchHeightPoints,
            isBuiltin: isBuiltin,
            isSupported: isSupported
        ),
        spaces: spaces
    )
}

func makeIsolatedUserDefaults() -> UserDefaults {
    let suiteName = "HideNotchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

func waitUntil(
    timeout: TimeInterval = 1,
    pollInterval: TimeInterval = 0.02,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }

    XCTFail("Condition not satisfied before timeout", file: file, line: line)
}
