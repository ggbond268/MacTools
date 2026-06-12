import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol ScreenshotRegionCapturing {
    func captureRegion() async -> ScreenshotCaptureResult
}

struct ScreenshotOverlaySelection: Equatable, Sendable {
    var displayID: CGDirectDisplayID?
    var screenFrame: CGRect
    var backingScaleFactor: CGFloat
    var selectedRect: CGRect

    init(
        displayID: CGDirectDisplayID?,
        screenFrame: CGRect,
        backingScaleFactor: CGFloat,
        selectedRect: CGRect
    ) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.backingScaleFactor = backingScaleFactor
        self.selectedRect = selectedRect
    }

    @MainActor
    init(screen: NSScreen, selectedRect: CGRect) {
        self.init(
            displayID: screen.displayID,
            screenFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor,
            selectedRect: selectedRect
        )
    }
}

enum ScreenshotOverlaySelectionResult: Equatable, Sendable {
    case success(ScreenshotOverlaySelection)
    case failure(ScreenshotCaptureError)
}

@MainActor
protocol ScreenshotOverlaySelecting: AnyObject {
    func selectRegion() async -> ScreenshotOverlaySelectionResult
}

@MainActor
final class ScreenshotRegionCapturer: ScreenshotRegionCapturing {
    private let screenRecordingPermissionProvider: () -> Bool
    private let overlaySelector: any ScreenshotOverlaySelecting
    private let displayImageProvider: (CGDirectDisplayID) -> CGImage?
    private let onlineDisplayProvider: () -> Set<CGDirectDisplayID>
    private let displayPixelSizeProvider: (CGDirectDisplayID) -> CGSize?

    init(
        screenRecordingPermissionProvider: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        },
        overlaySelector: (any ScreenshotOverlaySelecting)? = nil,
        displayImageProvider: @escaping (CGDirectDisplayID) -> CGImage? = CGDisplayCreateImage,
        onlineDisplayProvider: @escaping () -> Set<CGDirectDisplayID> = ScreenshotRegionCapturer.onlineDisplayIDs,
        displayPixelSizeProvider: @escaping (CGDirectDisplayID) -> CGSize? = ScreenshotRegionCapturer.displayModePixelSize
    ) {
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
        self.overlaySelector = overlaySelector ?? ScreenshotOverlaySession()
        self.displayImageProvider = displayImageProvider
        self.onlineDisplayProvider = onlineDisplayProvider
        self.displayPixelSizeProvider = displayPixelSizeProvider
    }

    func captureRegion() async -> ScreenshotCaptureResult {
        guard screenRecordingPermissionProvider() else {
            return .failure(.screenRecordingPermissionRequired)
        }

        switch await overlaySelector.selectRegion() {
        case let .success(selection):
            return capture(selection)
        case let .failure(error):
            return .failure(error)
        }
    }

    private func capture(_ selection: ScreenshotOverlaySelection) -> ScreenshotCaptureResult {
        guard let screenID = selection.displayID else {
            return .failure(.noScreen)
        }

        // macOS 27 beta: CGDisplayCreateImage no longer returns nil for a stale
        // displayID (e.g. after a hot-unplug) — it returns a full multi-display
        // union image instead, so the historical nil-guard is dead and OCR
        // would silently read the wrong region. Defend by (1) confirming the
        // display is still online and (2) confirming the captured image is not
        // substantially larger than this display's own current mode pixel size.
        //
        // The size check compares against the display MODE's pixel dimensions
        // (CGDisplayModeGetPixelWidth/Height) — NOT frame × backingScaleFactor.
        // On a scaled HiDPI mode (the common "More Space"/"Larger Text" built-in
        // option and most scaled external 4K/5K configs) the rendered backing
        // buffer diverges from frame × backingScaleFactor by hundreds of pixels
        // (cf. DisplayResolution's `isHiDPI = pixelWidth > width`), so a
        // frame-based exact gate would fail OCR on those configs on macOS 14…26.
        // The mode pixel size is exactly what CGDisplayCreateImage returns for a
        // single legitimate display on every shipping macOS, so this never
        // rejects a real capture. If the mode is unavailable we skip the gate
        // (the online check + crop-to-bounds clamp remain the real guards).
        guard onlineDisplayProvider().contains(screenID) else {
            return .failure(.screenshotFailed)
        }

        guard let displayImage = displayImageProvider(screenID) else {
            return .failure(.screenshotFailed)
        }

        if Self.imageSpansBeyondDisplayMode(
            imageWidth: displayImage.width,
            imageHeight: displayImage.height,
            displayModePixelSize: displayPixelSizeProvider(screenID)
        ) {
            return .failure(.screenshotFailed)
        }

        let scale = selection.backingScaleFactor
        let cropRect = CGRect(
            x: selection.selectedRect.minX * scale,
            y: selection.selectedRect.minY * scale,
            width: selection.selectedRect.width * scale,
            height: selection.selectedRect.height * scale
        ).integral

        let imageBounds = CGRect(
            origin: .zero,
            size: CGSize(width: displayImage.width, height: displayImage.height)
        )
        let boundedCropRect = cropRect.intersection(imageBounds)

        guard !boundedCropRect.isNull,
              !boundedCropRect.isEmpty,
              let croppedImage = displayImage.cropping(to: boundedCropRect) else {
            return .failure(.screenshotFailed)
        }

        let image = NSImage(cgImage: croppedImage, size: selection.selectedRect.size)
        return .success(
            image: image,
            selectedRect: selection.selectedRect,
            screenFrame: selection.screenFrame
        )
    }

    /// Snapshot of currently online display IDs (CGGetOnlineDisplayList).
    nonisolated static func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Set(ids.prefix(Int(count)))
    }

    /// Current display mode's pixel dimensions (CGDisplayModeGetPixelWidth/
    /// Height). This is exactly the pixel extent CGDisplayCreateImage returns
    /// for a single legitimate display on every shipping macOS — including
    /// scaled HiDPI modes, where it diverges from frame × backingScaleFactor.
    /// Returns nil when the mode is unavailable so callers can skip the gate.
    nonisolated static func displayModePixelSize(_ displayID: CGDirectDisplayID) -> CGSize? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return nil
        }
        let width = mode.pixelWidth
        let height = mode.pixelHeight
        guard width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Pure "union image" gate (extracted for headless testing). Returns true
    /// only when the captured image is substantially WIDER or TALLER than this
    /// display's own current mode pixel size — the signature of the macOS 27
    /// beta stale-ID behaviour, where CGDisplayCreateImage returns a
    /// whole-desktop union image spanning every display.
    ///
    /// The comparison is against the display MODE pixels (the true single
    /// display extent), not frame × backingScaleFactor, so a legitimate scaled
    /// HiDPI capture — whose pixels equal its mode size — always passes. When
    /// the mode size is unavailable (nil) we do not fabricate a rejection; the
    /// online check and crop-to-bounds clamp remain the guards.
    static func imageSpansBeyondDisplayMode(
        imageWidth: Int,
        imageHeight: Int,
        displayModePixelSize: CGSize?,
        tolerance: CGFloat = 4
    ) -> Bool {
        guard let displayModePixelSize,
              displayModePixelSize.width > 0,
              displayModePixelSize.height > 0 else {
            return false
        }
        return CGFloat(imageWidth) > displayModePixelSize.width + tolerance
            || CGFloat(imageHeight) > displayModePixelSize.height + tolerance
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
