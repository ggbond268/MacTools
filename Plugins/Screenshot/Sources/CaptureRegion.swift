import AppKit

/// One immutable, pixel-aligned selection shared by recording and scrolling capture.
struct CaptureRegion: Sendable, Equatable {
    let display: CaptureDisplay
    let sourceRect: CGRect
    let width: Int
    let height: Int

    var scale: CGFloat { display.scale }
    var globalRect: CGRect {
        CGRect(x: display.frame.minX + sourceRect.minX,
               y: display.frame.maxY - sourceRect.maxY,
               width: sourceRect.width, height: sourceRect.height)
    }

    init(selection: CGRect, display: CaptureDisplay) throws {
        guard display.scale.isFinite, display.scale > 0,
              [selection.minX, selection.minY, selection.width, selection.height].allSatisfy(\.isFinite) else {
            throw CaptureFailure.invalidRegion
        }
        let clipped = selection.intersection(CGRect(origin: .zero, size: display.frame.size))
        guard !clipped.isNull, !clipped.isEmpty else { throw CaptureFailure.invalidRegion }
        let pixels = Geometry.cropRect(viewRect: clipped, scale: display.scale,
                                       imagePixelHeight: CGFloat(display.pixelHeight))
            .intersection(CGRect(x: 0, y: 0, width: display.pixelWidth, height: display.pixelHeight))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { throw CaptureFailure.invalidRegion }
        self.display = display
        width = Int(pixels.width)
        height = Int(pixels.height)
        sourceRect = CGRect(x: pixels.minX / display.scale, y: pixels.minY / display.scale,
                            width: pixels.width / display.scale, height: pixels.height / display.scale)
    }

    func validate(displays: [CaptureDisplay]) throws {
        guard displays.contains(display) else { throw CaptureFailure.displayChanged }
    }

    @MainActor
    func validate() throws { try validate(displays: CaptureDisplay.current()) }
}

enum CaptureControlPlacement {
    /// Prefer outside the selection, but never sacrifice access to the controls to avoid overlap.
    static func frame(size: CGSize, near region: CGRect, visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
        var y = region.minY - 12 - size.height
        if y < visibleFrame.minY { y = region.maxY + 12 }
        return CGRect(x: min(max(region.midX - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width),
                      y: min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
