import AppKit
import ApplicationServices
import MacToolsPluginKit

struct WindowCenteredGuideCandidate {
    let processIdentifier: pid_t
    let windowNumber: Int
    let frame: CGRect
    var pointer: CGPoint = .zero
}

@MainActor
protocol WindowCenteredGuideEnvironment: AnyObject {
    var isTrusted: Bool { get }
    func candidate(at pointer: CGPoint) -> WindowCenteredGuideCandidate?
    func resolve(_ candidate: WindowCenteredGuideCandidate) async throws -> AccessibilityWindowHandle
    func snapshot(_ window: AccessibilityWindowHandle) async throws -> WindowCenteredGuideSnapshot
    func screens() -> [WindowScreen]
    func usableFrame(for screen: WindowScreen) -> CGRect
    func show(_ result: WindowSnapResult, on screen: WindowScreen)
    func hide()
    func snap(_ window: AccessibilityWindowHandle, expected: CGRect, target: CGRect, usableFrame: CGRect) async throws
}

@MainActor
final class SystemWindowCenteredGuideEnvironment: WindowCenteredGuideEnvironment {
    var respectsStageManager = true
    var isTrusted: Bool { AXIsProcessTrusted() }
    private let worker = WindowAccessibilityWorker()
    private let screenProvider = SystemWindowScreenProvider()
    private let safeArea = SystemStageManagerSafeAreaProvider()
    private let overlay = WindowSnapOverlayController()

    func candidate(at pointer: CGPoint) -> WindowCenteredGuideCandidate? {
        guard isTrusted,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let target = SystemWindowUnderPointerResolver.windowTarget(at: pointer, in: info),
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let entry = info.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == target.windowNumber
              }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              WindowCenteredGuidePolicy.valid(frame) else { return nil }
        return WindowCenteredGuideCandidate(
            processIdentifier: target.processIdentifier, windowNumber: target.windowNumber, frame: frame, pointer: pointer
        )
    }

    func resolve(_ candidate: WindowCenteredGuideCandidate) async throws -> AccessibilityWindowHandle {
        // Hit-test once to support apps that do not expose AXWindowNumber. Verify the
        // captured CG identity when available, and otherwise require the original frame.
        // A delayed resolution that can no longer identify the candidate is discarded.
        let window = try await worker.resolveFocusedWindow(target: ExternalFocusedWindowTarget(
            processIdentifier: candidate.processIdentifier,
            bundleIdentifier: NSRunningApplication(processIdentifier: candidate.processIdentifier)?.bundleIdentifier,
            preferredWindowNumber: candidate.windowNumber,
            pointerLocation: candidate.pointer
        ))
        let frame = try await worker.frame(of: window)
        guard Self.matchesCandidate(candidate, window: window, frame: frame) else {
            throw WindowLayoutError.windowUnavailable
        }
        return window
    }

    static func matchesCandidate(
        _ candidate: WindowCenteredGuideCandidate,
        window: AccessibilityWindowHandle,
        frame: CGRect
    ) -> Bool {
        guard candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              window.identity.processIdentifier == candidate.processIdentifier,
              window.hostWindow == nil else { return false }
        if let number = window.windowNumber { return number == candidate.windowNumber }
        return WindowCenteredGuidePolicy.matches(candidate.frame, frame, tolerance: 1)
    }

    func snapshot(_ window: AccessibilityWindowHandle) async throws -> WindowCenteredGuideSnapshot {
        try await worker.centeredGuideSnapshot(window)
    }

    func screens() -> [WindowScreen] { screenProvider.currentScreens() }

    func usableFrame(for screen: WindowScreen) -> CGRect {
        respectsStageManager ? safeArea.safeVisibleFrame(for: screen) : screen.visibleFrame
    }

    func show(_ result: WindowSnapResult, on screen: WindowScreen) {
        guard let nativeScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == screen.directDisplayID
        }), let anchor = WindowCoordinateSpace.anchorMaximumY(in: NSScreen.screens) else { return }
        // Snap geometry operates in AX coordinates; the overlay consumes AppKit coordinates.
        let guides = WindowCenteredGuidePolicy.appKitGuides(for: result, anchorMaximumY: anchor)
        overlay.showGuides(guides, on: nativeScreen, relativeTo: nil)
    }

    func hide() { overlay.hide() }

    func snap(_ window: AccessibilityWindowHandle, expected: CGRect, target: CGRect, usableFrame: CGRect) async throws {
        try await worker.snapCenteredGuide(window, expected: expected, target: target, usableFrame: usableFrame)
    }
}
