import CoreGraphics

enum Geometry {
    /// Converts bottom-left view points to top-left image pixels.
    static func cropRect(viewRect rect: CGRect, scale: CGFloat, imagePixelHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale,
               y: imagePixelHeight - rect.maxY * scale,
               width: rect.width * scale,
               height: rect.height * scale).integral
    }
}
