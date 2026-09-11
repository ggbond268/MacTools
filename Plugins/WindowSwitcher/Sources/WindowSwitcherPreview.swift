import AppKit
import ScreenCaptureKit
import MacToolsPluginKit

struct WindowSwitcherPreviewCandidate {
    var processID: pid_t
    var frame: CGRect
    var title: String?
    var layer: Int
}

/// One active capture plus one latest requested target. No captures are stored on
/// disk, and denied permission never blocks discovery or activation.
@MainActor
final class WindowSwitcherPreview {
    var onChange: ((NSImage?, String?) -> Void)?
    private var generation = 0
    private var pending: WindowSwitcherAppEntry?
    private var task: Task<Void, Never>?

    private let localization: PluginLocalization
    private let hasPermission: @MainActor () -> Bool
    private let capture: @MainActor (WindowSwitcherAppEntry) async throws -> NSImage?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main), hasPermission: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         capture: @escaping @MainActor (WindowSwitcherAppEntry) async throws -> NSImage? = WindowSwitcherPreview.capture) {
        self.localization = localization
        self.hasPermission = hasPermission
        self.capture = capture
    }

    var isPermissionGranted: Bool { hasPermission() }

    func cancel() {
        generation += 1
        pending = nil
        onChange?(nil, nil)
    }

    func select(_ entry: WindowSwitcherAppEntry?) {
        generation += 1
        pending = entry
        onChange?(nil, nil)
        guard let entry, entry.isWindowEntry, !entry.metadataUnavailable else {
            pending = nil
            onChange?(nil, localization.string("preview.unavailable", defaultValue: "此窗口暂时无法预览。"))
            return
        }
        guard hasPermission() else {
            pending = nil
            onChange?(nil, localization.string("preview.permission", defaultValue: "预览需要屏幕录制权限；仍可按标题切换。"))
            return
        }
        startNext()
    }

    private func startNext() {
        guard task == nil, let entry = pending else { return }
        pending = nil
        let token = generation
        task = Task { [weak self] in
            // A short debounce avoids starting a capture for every key repeat.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            if token == generation {
                do {
                    let image = try await capture(entry)
                    if token == generation {
                        if hasPermission() { onChange?(image, image == nil ? localization.string("preview.unavailable", defaultValue: "此窗口暂时无法预览。") : nil) }
                        else { onChange?(nil, localization.string("preview.permission", defaultValue: "预览需要屏幕录制权限；仍可按标题切换。")) }
                    }
                } catch {
                    if token == generation { onChange?(nil, localization.string("preview.failed", defaultValue: "无法读取预览；仍可按标题切换。")) }
                }
            }
            task = nil
            startNext()
        }
    }
    static func matchingIndex(for entry: WindowSwitcherAppEntry, candidates: [WindowSwitcherPreviewCandidate]) -> Int? {
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

    private static func capture(_ entry: WindowSwitcherAppEntry) async throws -> NSImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let candidates = content.windows.map {
            WindowSwitcherPreviewCandidate(processID: $0.owningApplication?.processID ?? -1,
                frame: $0.frame, title: $0.title, layer: $0.windowLayer)
        }
        guard let index = matchingIndex(for: entry, candidates: candidates) else { return nil }
        let window = content.windows[index]
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = 600
        configuration.height = max(1, min(600, Int(600 * entry.bounds.height / max(entry.bounds.width, 1))))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: image, size: .zero)
    }

}
