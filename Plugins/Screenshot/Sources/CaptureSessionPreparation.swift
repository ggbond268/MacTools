import AppKit
import OSLog
import ScreenCaptureKit

/// ScreenCaptureKit discovery descriptions are immutable; consume them only on the main actor.
private struct ShareableContentSnapshot: @unchecked Sendable {
    let content: SCShareableContent
}

@MainActor
enum CaptureSessionPreparation {
    static func content() async throws -> SCShareableContent {
        let snapshot = try await CaptureCompletion<ShareableContentSnapshot>.receive(timeout: .seconds(10)) { completion in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let content { completion(.success(ShareableContentSnapshot(content: content))) }
                else { completion(.failure(error ?? CaptureFailure.unavailable)) }
            }
        }
        return snapshot.content
    }

    static func filter(region: CaptureRegion, controls: CaptureControls) async throws -> SCContentFilter {
        try region.validate()
        controls.prepare()
        let content = try await content()
        try Task.checkCancellation()
        try region.validate()
        guard let display = content.displays.first(where: { $0.displayID == region.display.id }) else {
            throw CaptureFailure.displayChanged
        }
        let ids = try controls.windowIDs(available: Set(content.windows.map(\.windowID)))
        return SCContentFilter(display: display, excludingWindows: content.windows.filter { ids.contains($0.windowID) })
    }

    static func configuration(region: CaptureRegion, framesPerSecond: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = CapturePipeline.streamConfiguration(pixelWidth: region.width, pixelHeight: region.height)
        configuration.sourceRect = region.sourceRect
        configuration.showsCursor = showsCursor
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.capturesAudio = false
        if #available(macOS 15, *) { configuration.captureMicrophone = false }
        return configuration
    }
}

/// Controls belong to exactly one session, never to a process-wide exclusion registry.
@MainActor
final class CaptureControls {
    private let windows: [NSWindow]
    private static let logger = Logger(subsystem: "cc.ggbond.mactools.screenshot", category: "CaptureControls")

    init(_ windows: [NSWindow]) { self.windows = windows }

    func prepare() {
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = window.windowNumber
        }
    }

    func windowIDs(available: Set<CGWindowID>) throws -> Set<CGWindowID> {
        let ids = Set(windows.compactMap { $0.windowNumber > 0 ? CGWindowID(exactly: $0.windowNumber) : nil })
        let missing = ids.subtracting(available)
        guard !ids.isEmpty, ids.count == windows.count, missing.isEmpty else {
            Self.logger.error("Control resolution failed: expected=\(self.windows.count), resolved=\(ids.count), missing=\(String(describing: missing), privacy: .public)")
            throw ScreenshotControlError.notReady
        }
        return ids
    }

    func hide() { for window in windows { window.orderOut(nil) } }
}

enum ScreenshotControlError: Error { case notReady }
