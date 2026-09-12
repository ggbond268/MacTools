import AppKit
import ScreenCaptureKit
import MacToolsPluginKit

struct WindowSwitcherPreviewCandidate {
    var processID: pid_t
    var frame: CGRect
    var title: String?
    var layer: Int
    var windowID: CGWindowID? = nil
}

/// One active capture, one latest target, and eight short-lived memory previews. No captures are stored on
/// disk, and denied permission never blocks discovery or activation.
@MainActor
final class WindowSwitcherPreview {
    var onChange: ((NSImage?, String?) -> Void)?
    private struct CacheKey: Hashable {
        var id: String
        var pid: pid_t
        var launchDate: Date?
        var windowNumber: CGWindowID?
        init(_ entry: WindowSwitcherAppEntry) {
            id = entry.id; pid = entry.processIdentifier
            launchDate = entry.applicationLaunchDate; windowNumber = entry.windowNumber
        }
    }
    private struct CachedPreview {
        var image: NSImage
        var capturedAt: Date
        var usedAt: Date
    }
    private var cache: [CacheKey: CachedPreview] = [:]
    private var selectedKey: CacheKey?
    private var generation = 0
    private var pending: WindowSwitcherAppEntry?
    private var task: Task<Void, Never>?

    private let systemCapture = WindowSwitcherSystemPreviewCapture()
    private let localization: PluginLocalization
    private let hasPermission: @MainActor () -> Bool
    private let capture: @MainActor (WindowSwitcherAppEntry) async throws -> NSImage?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main), hasPermission: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         capture: (@MainActor (WindowSwitcherAppEntry) async throws -> NSImage?)? = nil) {
        self.localization = localization
        self.hasPermission = hasPermission
        self.capture = capture ?? { [systemCapture] entry in try await systemCapture.capture(entry) }
    }

    var isPermissionGranted: Bool { hasPermission() }

    func cancel() {
        generation += 1
        pending = nil
        selectedKey = nil
        onChange?(nil, nil)
    }

    func select(_ entry: WindowSwitcherAppEntry?) {
        guard let entry, entry.isWindowEntry, !entry.metadataUnavailable else {
            cancel()
            onChange?(nil, localization.string("preview.unavailable", defaultValue: "此窗口暂时无法预览。"))
            return
        }
        guard hasPermission() else {
            cache.removeAll()
            systemCapture.invalidate()
            cancel()
            onChange?(nil, localization.string("preview.permission", defaultValue: "预览需要屏幕录制权限；仍可按标题切换。"))
            return
        }
        let key = CacheKey(entry)
        // Catalog metadata changes do not restart an unchanged selection.
        guard selectedKey != key else { return }
        selectedKey = key
        generation += 1
        pending = entry
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.capturedAt) < 30 }
        if var cached = cache[key] {
            cached.usedAt = now
            cache[key] = cached
            onChange?(cached.image, nil)
            if now.timeIntervalSince(cached.capturedAt) < 2 { pending = nil; return }
        } else {
            onChange?(nil, nil)
        }
        startNext()
    }

    private func startNext() {
        guard task == nil, let entry = pending else { return }
        pending = nil
        let token = generation
        task = Task { [weak self] in
            // A short debounce avoids starting a capture for every key repeat.
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            // Retry transient capture failures without keeping an unbounded
            // refresh loop alive. A new selection invalidates every old attempt.
            for attempt in 0..<3 {
                guard token == generation, hasPermission(), !Task.isCancelled else { break }
                do {
                    let image = try await capture(entry)
                    guard token == generation else { break }
                    guard hasPermission() else {
                        cache.removeAll()
                        systemCapture.invalidate()
                        onChange?(nil, localization.string("preview.permission", defaultValue: "预览需要屏幕录制权限；仍可按标题切换。"))
                        break
                    }
                    if let image {
                        let now = Date()
                        cache[CacheKey(entry)] = CachedPreview(image: image, capturedAt: now, usedAt: now)
                        while cache.count > 8, let oldest = cache.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
                            cache.removeValue(forKey: oldest)
                        }
                        onChange?(image, nil)
                        break
                    }
                    if attempt == 2, cache[CacheKey(entry)] == nil { onChange?(nil, localization.string("preview.unavailable", defaultValue: "此窗口暂时无法预览。")) }
                } catch {
                    guard token == generation else { break }
                    if attempt == 2, cache[CacheKey(entry)] == nil { onChange?(nil, localization.string("preview.failed", defaultValue: "无法读取预览；仍可按标题切换。")) }
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
            }
            task = nil
            startNext()
        }
    }
    static func matchingIndex(for entry: WindowSwitcherAppEntry, candidates: [WindowSwitcherPreviewCandidate]) -> Int? {
        if let number = entry.windowNumber {
            let exact = candidates.indices.filter {
                candidates[$0].windowID == number && candidates[$0].processID == entry.processIdentifier && candidates[$0].layer == 0
            }
            // A missing exact ID means the target disappeared; never preview a
            // different window that happens to occupy its former position.
            return exact.count == 1 ? exact[0] : nil
        }
        // Chrome can expose different AX and capture titles. A unique process
        // and geometry match is sufficient; titles disambiguate overlapping
        // windows only when exactly one matches. Never pick by array position.
        let geometry = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.processID == entry.processIdentifier && candidate.layer == 0 &&
                abs(candidate.frame.minX - entry.bounds.minX) < 2 && abs(candidate.frame.minY - entry.bounds.minY) < 2 &&
                abs(candidate.frame.width - entry.bounds.width) < 2 && abs(candidate.frame.height - entry.bounds.height) < 2
        }
        if geometry.count == 1 { return geometry.first }
        let titled = geometry.filter { (candidates[$0].title ?? "") == (entry.windowTitle ?? "") }
        return titled.count == 1 ? titled.first : nil
    }

    static func captureSize(for frame: CGRect) -> CGSize {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(2, 1600 / max(frame.width, frame.height))
        return CGSize(width: max(1, floor(frame.width * scale)), height: max(1, floor(frame.height * scale)))
    }

}

/// Shares only a short-lived window inventory, not images or a recording stream.
/// Stable window IDs are required for reuse; geometry-only matches use a fresh inventory.
@MainActor
final class WindowSwitcherSystemPreviewCapture {
    private var content: SCShareableContent?
    private var capturedAt = Date.distantPast
    private let now: () -> Date
    private let discover: () async throws -> SCShareableContent

    init(now: @escaping () -> Date = Date.init,
         discover: @escaping () async throws -> SCShareableContent = {
             try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
         }) {
        self.now = now
        self.discover = discover
    }

    func invalidate() { content = nil; capturedAt = .distantPast }

    func capture(_ entry: WindowSwitcherAppEntry) async throws -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { invalidate(); return nil }
        if let launchDate = entry.applicationLaunchDate,
           NSRunningApplication(processIdentifier: entry.processIdentifier)?.launchDate != launchDate { return nil }
        if content == nil || now().timeIntervalSince(capturedAt) >= 2 || entry.windowNumber == nil {
            content = try await discover()
            capturedAt = now()
        }
        guard let content else { return nil }
        let candidates = content.windows.map {
            WindowSwitcherPreviewCandidate(processID: $0.owningApplication?.processID ?? -1,
                frame: $0.frame, title: $0.title, layer: $0.windowLayer, windowID: $0.windowID)
        }
        guard let index = WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates) else {
            invalidate()
            return nil
        }
        let window = content.windows[index]
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let pixels = WindowSwitcherPreview.captureSize(for: window.frame)
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard CGPreflightScreenCaptureAccess() else { invalidate(); return nil }
            return NSImage(cgImage: image, size: .zero)
        } catch {
            invalidate()
            throw error
        }
    }
}
