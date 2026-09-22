import AppKit
import CoreImage
import Vision
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class AnnotationRendererTests: XCTestCase {
    func testExportKeepsQRCodeRedactedUnderOtherAnnotationsAtBothDisplayScales() throws {
        let payload = "mactools-private-token"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let generated = try XCTUnwrap(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let qr = try XCTUnwrap(CIContext().createCGImage(generated, from: generated.extent))
        let padding = 24
        let width = qr.width + padding * 2
        let height = qr.height + padding * 2
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(qr, in: CGRect(x: padding, y: padding, width: qr.width, height: qr.height))
        let original = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(try decodedPayloads(original), [payload], "The source fixture must be readable")

        for scale: CGFloat in [1, 2] {
            let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
            let region = NSRect(x: CGFloat(padding) / scale, y: CGFloat(padding) / scale,
                                width: CGFloat(qr.width) / scale, height: CGFloat(qr.height) / scale)
            let stroke = Stroke(color: .red, width: 2)
            let renderer = AnnotationRenderer(image: original, scale: scale, size: size)
            // These effects sample the unredacted source, so neither may uncover the mask.
            let raster = try XCTUnwrap(renderer.render(
                selection: NSRect(origin: .zero, size: size),
                items: [.qrMask(region), Item(shape: .mosaic(region), stroke: stroke)],
                draft: Item(shape: .blur(region), stroke: stroke),
                radius: 0, shadowSize: 0, shadowColor: .black
            ))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: ScreenshotImageEncoder.encodePNG(raster)))
            XCTAssertTrue(try decodedPayloads(XCTUnwrap(bitmap.cgImage)).isEmpty, "Scale: \(scale)")
            let center = try XCTUnwrap(bitmap.colorAt(x: width / 2, y: height / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(center.alphaComponent, 1)
            XCTAssertEqual(center.redComponent, 0)
            XCTAssertEqual(center.greenComponent, 0)
            XCTAssertEqual(center.blueComponent, 0)
            let outside = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(outside.redComponent, 1)
        }
    }

    private func decodedPayloads(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}
