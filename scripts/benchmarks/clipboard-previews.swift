// Compares uncached thumbnail decoding with window-scoped preview reuse.
// All source pixels are generated in memory; no clipboard/database access.
import AppKit
import ImageIO
@testable import ClipboardHistoryPlugin

let context = CGContext(data: nil, width: 2_400, height: 1_800, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_800))
let png = NSMutableData()
let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
    .init(typeIdentifier: ClipboardRepresentationType.png, data: png as Data)
])])
let item = ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: .now,
    sourceApplication: nil, isPinned: false, lastUsedAt: nil)
guard ClipboardRepresentationType.isImage(ClipboardRepresentationType.png) else {
    FileHandle.standardError.write(Data("macOS image-type lookup is unavailable. Run this generated-data probe with LaunchServices access.\n".utf8))
    exit(2)
}

func ms(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
}

var started = ContinuousClock.now
for _ in 0..<10 {
    let image = await ClipboardEmbeddedPreviewLoader.load(for: item)
    precondition(image != nil, "The uncached decoder rejected the generated PNG fixture")
}
print("10 uncached image decodes: \(ms(ContinuousClock.now - started)) ms")
var decodes = 0
let cache = ClipboardEmbeddedPreviewCache { item in
    decodes += 1
    return await ClipboardEmbeddedPreviewLoader.load(for: item)
}
started = .now
for _ in 0..<10 {
    let image = await cache.image(for: item)
    precondition(image != nil)
}
print("10 visits with cache (includes first decode): \(ms(ContinuousClock.now - started)) ms; decodes=\(decodes); budgetedBytes=\(cache.totalCost)")
precondition(decodes == 1, "The generated thumbnail should fit the cache budget")
started = .now
for _ in 0..<10 {
    let image = await cache.image(for: item)
    precondition(image != nil)
}
print("10 warm preview visits: \(ms(ContinuousClock.now - started)) ms")
cache.removeAll()
