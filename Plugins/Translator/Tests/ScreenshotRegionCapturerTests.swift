import AppKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class ScreenshotRegionCapturerTests: XCTestCase {
    func testPermissionDeniedSkipsOverlayAndReturnsPermissionError() async {
        let overlay = RecordingScreenshotOverlaySelector(result: .failure(.cancelled))
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { false },
            overlaySelector: overlay
        )

        let result = await capturer.captureRegion()

        XCTAssertEqual(result.error, .screenRecordingPermissionRequired)
        XCTAssertEqual(overlay.startCount, 0)
    }

    func testOverlayCancellationReturnsCancelledError() async {
        let overlay = RecordingScreenshotOverlaySelector(result: .failure(.cancelled))
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay
        )

        let result = await capturer.captureRegion()

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertEqual(overlay.startCount, 1)
    }

    func testCaptureClampsIntegralCropRectToDisplayImageBounds() async throws {
        let displayImage = try XCTUnwrap(makeDisplayImage(width: 10, height: 10))
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 1,
                    screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    backingScaleFactor: 1,
                    selectedRect: CGRect(x: 0, y: 0, width: 10.1, height: 10.1)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in displayImage },
            onlineDisplayProvider: { [1] },
            displayPixelSizeProvider: { _ in CGSize(width: 10, height: 10) }
        )

        let result = await capturer.captureRegion()

        XCTAssertNil(result.error)
        XCTAssertNotNil(result.image)
    }

    // MARK: - macOS 27 beta stale-displayID defense

    func testCaptureFailsWhenDisplayIsNoLongerOnline() async throws {
        // After a hot-unplug the selected display is gone. CGDisplayCreateImage
        // would return a stale union image on the beta, so we must reject before
        // calling it.
        let displayImage = try XCTUnwrap(makeDisplayImage(width: 10, height: 10))
        var imageProviderCalls = 0
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 7,
                    screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    backingScaleFactor: 1,
                    selectedRect: CGRect(x: 0, y: 0, width: 5, height: 5)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in
                imageProviderCalls += 1
                return displayImage
            },
            onlineDisplayProvider: { [1] },
            displayPixelSizeProvider: { _ in CGSize(width: 10, height: 10) }
        )

        let result = await capturer.captureRegion()

        XCTAssertEqual(result.error, .screenshotFailed)
        XCTAssertEqual(imageProviderCalls, 0, "Must short-circuit before capturing a stale display")
    }

    func testCaptureFailsWhenCapturedImageSpansWholeDesktopUnion() async throws {
        // Online check passes, but CGDisplayCreateImage returns a full-desktop
        // union image (4288 wide = summed display widths) — wider than this
        // display's own 3456px mode, so reject rather than OCR the wrong region.
        let unionImage = try XCTUnwrap(makeDisplayImage(width: 4288, height: 1440))
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 1,
                    screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                    backingScaleFactor: 2,
                    selectedRect: CGRect(x: 0, y: 0, width: 5, height: 5)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in unionImage },
            onlineDisplayProvider: { [1] },
            // Built-in 1728pt@2x → 3456x2234 mode pixels; union (4288) is wider.
            displayPixelSizeProvider: { _ in CGSize(width: 3456, height: 2234) }
        )

        let result = await capturer.captureRegion()

        XCTAssertEqual(result.error, .screenshotFailed)
    }

    func testCaptureSucceedsWhenImageMatchesDisplayModePixels() async throws {
        // Image equals the display mode's pixel size → legitimate single-display
        // capture, must pass.
        let displayImage = try XCTUnwrap(makeDisplayImage(width: 20, height: 20))
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 1,
                    screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    backingScaleFactor: 2,
                    selectedRect: CGRect(x: 0, y: 0, width: 5, height: 5)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in displayImage },
            onlineDisplayProvider: { [1] },
            displayPixelSizeProvider: { _ in CGSize(width: 20, height: 20) }
        )

        let result = await capturer.captureRegion()

        XCTAssertNil(result.error)
        XCTAssertNotNil(result.image)
    }

    func testCaptureSucceedsOnScaledHiDPIModeWherePixelsDifferFromFrameTimesScale() async throws {
        // Non-regression lock for the common "More Space"/"Larger Text" scaled
        // HiDPI mode and most scaled external 4K/5K configs: CGDisplayCreateImage
        // returns the mode's rendered backing buffer, whose pixel size does NOT
        // equal frame × backingScaleFactor. Example: a 3024-wide panel running a
        // looks-like-1800 scaled mode renders 3456-wide pixels while
        // frame(1800)×scale(2) = 3600 — a 144px divergence, hundreds beyond any
        // sub-pixel tolerance. A frame×scale exact-match gate would fail OCR
        // entirely here on macOS 14…26. The mode-pixel gate must still pass it
        // because the image equals the mode pixel size.
        let scaledModeImage = try XCTUnwrap(makeDisplayImage(width: 3456, height: 2234))
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 1,
                    // Logical point frame at looks-like-1800 (e.g. 1800x1169).
                    screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                    backingScaleFactor: 2,
                    selectedRect: CGRect(x: 100, y: 100, width: 200, height: 80)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in scaledModeImage },
            onlineDisplayProvider: { [1] },
            // Mode pixels match the rendered buffer, NOT frame(1800)×scale(2)=3600.
            displayPixelSizeProvider: { _ in CGSize(width: 3456, height: 2234) }
        )

        let result = await capturer.captureRegion()

        XCTAssertNil(result.error, "Scaled HiDPI capture must not be hard-rejected")
        XCTAssertNotNil(result.image)
    }

    func testCaptureSkipsSizeGateWhenDisplayModeUnavailable() async throws {
        // If the display mode can't be read we don't fabricate a rejection: the
        // online check + crop-to-bounds clamp remain the guards, so a normal
        // capture still succeeds.
        let displayImage = try XCTUnwrap(makeDisplayImage(width: 20, height: 20))
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 1,
                    screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    backingScaleFactor: 2,
                    selectedRect: CGRect(x: 0, y: 0, width: 5, height: 5)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in displayImage },
            onlineDisplayProvider: { [1] },
            displayPixelSizeProvider: { _ in nil }
        )

        let result = await capturer.captureRegion()

        XCTAssertNil(result.error)
        XCTAssertNotNil(result.image)
    }

    func testImageSpansBeyondDisplayModePureGate() {
        // Image equals mode pixel size: single display, must pass (false).
        XCTAssertFalse(
            ScreenshotRegionCapturer.imageSpansBeyondDisplayMode(
                imageWidth: 3456,
                imageHeight: 2234,
                displayModePixelSize: CGSize(width: 3456, height: 2234)
            )
        )
        // Image within sub-pixel tolerance of the mode: must pass (false).
        XCTAssertFalse(
            ScreenshotRegionCapturer.imageSpansBeyondDisplayMode(
                imageWidth: 3458,
                imageHeight: 2234,
                displayModePixelSize: CGSize(width: 3456, height: 2234)
            )
        )
        // Whole-desktop union wider than this display's mode: reject (true).
        XCTAssertTrue(
            ScreenshotRegionCapturer.imageSpansBeyondDisplayMode(
                imageWidth: 4288,
                imageHeight: 1440,
                displayModePixelSize: CGSize(width: 3456, height: 2234)
            )
        )
        // Union taller than the mode (vertical tiling) is also rejected (true).
        XCTAssertTrue(
            ScreenshotRegionCapturer.imageSpansBeyondDisplayMode(
                imageWidth: 2560,
                imageHeight: 3674,
                displayModePixelSize: CGSize(width: 2560, height: 1440)
            )
        )
        // Mode unavailable: do not fabricate a rejection (false).
        XCTAssertFalse(
            ScreenshotRegionCapturer.imageSpansBeyondDisplayMode(
                imageWidth: 4288,
                imageHeight: 1440,
                displayModePixelSize: nil
            )
        )
    }

    private func makeDisplayImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

@MainActor
private final class RecordingScreenshotOverlaySelector: ScreenshotOverlaySelecting {
    var result: ScreenshotOverlaySelectionResult
    private(set) var startCount = 0

    init(result: ScreenshotOverlaySelectionResult) {
        self.result = result
    }

    func selectRegion() async -> ScreenshotOverlaySelectionResult {
        startCount += 1
        return result
    }
}
