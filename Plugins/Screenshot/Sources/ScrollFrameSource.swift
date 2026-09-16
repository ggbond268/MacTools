import CoreImage
import CoreMedia
import ScreenCaptureKit

/// Mutable conversion state is confined to queue. AsyncStream owns the cross-queue handoff.
final class ScrollFrameSource: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "cc.ggbond.mactools.screenshot.scroll-frames", qos: .userInitiated)
    let frames: AsyncStream<CGImage>
    private let continuation: AsyncStream<CGImage>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var finished = false

    override init() {
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    func finish() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            continuation.finish()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            // Materialize independent pixels; queued work must not retain ScreenCaptureKit's IOSurfaces.
            guard let frame = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                    colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    deferred: false) else { return }
            continuation.yield(frame)
        }
    }
}
