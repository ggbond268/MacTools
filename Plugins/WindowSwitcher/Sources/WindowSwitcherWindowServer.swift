import AppKit
import Carbon
import Darwin

/// Optional WindowServer bridges for windows that public app activation and
/// ScreenCaptureKit cannot reach on another Space. Resolve symbols at runtime;
/// missing APIs preserve the public fallback instead of preventing plugin load.
enum WindowSwitcherWindowServer {
    private typealias ProcessLookup = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias FrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias FocusEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Capture = @convention(c) (UInt32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let value = dlsym(handle, name) else { return nil }
        return unsafeBitCast(value, to: type)
    }
    private static let processLookup = symbol("GetProcessForPID", as: ProcessLookup.self)
    private static let frontWindow = symbol("_SLPSSetFrontProcessWithOptions", as: FrontWindow.self)
    private static let focusEvent = symbol("SLPSPostEventRecordTo", as: FocusEvent.self)
    private static let connection = symbol("CGSMainConnectionID", as: Connection.self)
    private static let captureWindow = symbol("CGSHWCaptureWindowList", as: Capture.self)

    static var supportsExactActivation: Bool {
        processLookup != nil && frontWindow != nil && focusEvent != nil
    }

    static func matches(_ number: CGWindowID, pid: pid_t, records: [WindowSwitcherWindowRecord]) -> Bool {
        number != 0 && pid > 0 && records.contains { $0.windowNumber == number && $0.processIdentifier == pid }
    }

    private static func isCurrent(_ number: CGWindowID, pid: pid_t) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] else { return false }
        return matches(number, pid: pid, records: WindowSwitcherWindowRecord.parse(info))
    }

    static func isRevealable(_ number: CGWindowID, pid: pid_t) -> Bool {
        isCurrent(number, pid: pid) && (isOnScreen(number, pid: pid) || WindowSwitcherSpaceMembership.hasSpace(number) == true)
    }

    static func isOnScreen(_ number: CGWindowID, pid: pid_t) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] else { return false }
        return WindowSwitcherWindowRecord.parse(info).contains {
            $0.windowNumber == number && $0.processIdentifier == pid && $0.isOnScreen == true
        }
    }

    static func activate(_ number: CGWindowID, pid: pid_t, cancellation: WindowSwitcherActionCancellation? = nil) -> Bool {
        guard cancellation?.isCancelled != true, let processLookup, let frontWindow, let focusEvent, isRevealable(number, pid: pid) else { return false }
        var process = ProcessSerialNumber()
        guard processLookup(pid, &process) == 0 else { return false }
        guard frontWindow(&process, number, 0x200) == 0 else { return false }
        // Fronting identifies the Space; this window-addressed event transfers
        // key status. Its location is outside content and does not move the cursor.
        // AX main/focus/raise must follow, and observed exact focus remains decisive.
        if cancellation?.isCancelled != true {
            sendFocusEvents(number) { bytes in
                var event = bytes
                return focusEvent(&process, &event)
            }
        }
        return true
    }

    /// Balance the down event even if posting fails or the selection is cancelled
    /// during dispatch. Never leave drag-sensitive discovery seeing a held button.
    static func sendFocusEvents(_ number: CGWindowID, post: ([UInt8]) -> Int32) {
        var event = [UInt8](repeating: 0, count: 256)
        event[4] = 248
        event[8] = 1
        event[58] = 16
        event.withUnsafeMutableBytes {
            $0.storeBytes(of: CGPoint(x: 300_000, y: 300_000), toByteOffset: 32, as: CGPoint.self)
            $0.storeBytes(of: number, toByteOffset: 60, as: CGWindowID.self)
        }
        _ = post(event)
        event[8] = 2
        _ = post(event)
    }

    static func capture(_ number: CGWindowID, pid: pid_t, size: CGSize) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard CGPreflightScreenCaptureAccess(), isCurrent(number, pid: pid),
                  let connection, let captureWindow else { return nil }
            var window = number
            let options: UInt32 = (1 << 11) | (1 << 9)
            guard let images = captureWindow(connection(), &window, 1, options)?.takeRetainedValue() as? [CGImage],
                  images.count == 1, let image = images.first,
                  CGPreflightScreenCaptureAccess(), isCurrent(number, pid: pid) else { return nil }
            // Keep the same cache size budget as ScreenCaptureKit previews.
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            let scale = min(1, size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            guard scale < 1 else { return image }
            let width = max(1, Int(CGFloat(image.width) * scale))
            let height = max(1, Int(CGFloat(image.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }.value
    }
}
