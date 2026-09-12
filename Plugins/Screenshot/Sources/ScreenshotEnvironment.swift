import AppKit
import MacToolsPluginKit

/// Owns preferences and auxiliary windows for one enabled plugin instance.
@MainActor
final class ScreenshotEnvironment {
    let storage: any PluginStorage
    private let localization: PluginLocalization
    private var pins: [PinWindow] = []
    private var captureControls: [NSWindow] = []
    private var toast: NSPanel?
    private var toastTask: Task<Void, Never>?
    var savePanel: NSSavePanel?

    convenience init(context: PluginRuntimeContext) {
        self.init(storage: context.storage, localization: PluginLocalization(bundle: context.resourceBundle))
    }

    init(storage: any PluginStorage, localization: PluginLocalization) {
        self.storage = storage
        self.localization = localization
    }

    var saveFolder: URL {
        get {
            if let path = storage.string(forKey: "saveFolder"), path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        }
        set {
            guard newValue.isFileURL else { return }
            storage.set(newValue.standardizedFileURL.path, forKey: "saveFolder")
        }
    }

    var saveFolderDisplayName: String { FileManager.default.displayName(atPath: saveFolder.path) }

    func string(_ key: String, _ defaultValue: String) -> String {
        localization.string(key, defaultValue: defaultValue)
    }

    func format(_ key: String, _ defaultValue: String, _ arguments: CVarArg...) -> String {
        String(format: string(key, defaultValue), locale: PluginRuntimeLocalization.locale, arguments: arguments)
    }

    func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }

    func fileURL(prefix: String, ext: String) -> URL {
        saveFolder.appendingPathComponent("\(prefix) \(stamp()).\(ext)")
    }

    func captureControlWindowIDs(availableWindowIDs: Set<CGWindowID>) throws -> Set<CGWindowID> {
        let ids = Set(captureControls.compactMap { window -> CGWindowID? in
            guard window.windowNumber > 0 else { return nil }
            return CGWindowID(exactly: window.windowNumber)
        })
        guard !ids.isEmpty, ids.count == captureControls.count, ids.isSubset(of: availableWindowIDs) else {
            throw ScreenshotControlError.notReady
        }
        return ids
    }

    func registerCaptureControls(_ windows: [NSWindow]) {
        captureControls.append(contentsOf: windows)
    }

    func removeCaptureControls(_ windows: [NSWindow]) {
        captureControls.removeAll { control in windows.contains { $0 === control } }
    }

    func pin(_ png: Data, at frame: NSRect, bakedShadow: Bool, name: String) {
        pins.removeAll { !$0.isVisible }
        let window = PinWindow(png: png, at: frame, name: name, environment: self)
        window.hasShadow = !bakedShadow
        pins.append(window)
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.orderFrontRegardless()
        window.makeKey()
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast?.orderOut(nil)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let box = NSStackView()
        box.orientation = .horizontal
        box.spacing = 8
        box.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            box.addArrangedSubview(icon)
        }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        box.addArrangedSubview(label)
        let size = box.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = Glass.wrap(box, radius: size.height / 2, blending: .behindWindow)
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                     y: screen.visibleFrame.minY + 80))
        toast = panel
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.orderFrontRegardless()
        toastTask = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(1.8)) }
            catch { return }
            panel?.orderOut(nil)
            if self?.toast === panel { self?.toast = nil }
        }
    }

    func closeAll() {
        // Startup controls can be visible before their async session has returned to the coordinator.
        for control in captureControls { control.orderOut(nil) }
        captureControls.removeAll()
        toastTask?.cancel()
        toastTask = nil
        toast?.orderOut(nil)
        toast = nil
        savePanel?.cancel(nil)
        savePanel = nil
        for pin in pins { pin.close() }
        pins.removeAll()
    }
}

enum ScreenshotControlError: Error { case notReady }
