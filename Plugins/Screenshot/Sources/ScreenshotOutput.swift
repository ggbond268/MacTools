import AppKit
import MacToolsPluginKit
import UniformTypeIdentifiers

enum SaveMode { case clipboard, folder, ask }

/// Shared output operations use the enabled plugin's preferences and auxiliary windows.
@MainActor
enum ScreenshotOutput {
    static func copyToPasteboard(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    static func save(_ png: Data, mode: SaveMode, environment: ScreenshotEnvironment) {
        copyToPasteboard(png)
        switch mode {
        case .clipboard:
            environment.showToast(environment.string("output.copied", "已复制到剪贴板"))
        case .folder:
            let url = environment.fileURL(prefix: environment.string("output.screenshotName", "截图"), ext: "png")
            do {
                try png.write(to: url, options: .atomic)
                environment.showToast(environment.format("output.savedAndCopied", "已保存到「%@」，并复制到剪贴板", environment.saveFolderDisplayName))
            } catch {
                environment.showToast(environment.format("output.saveFailed", "保存失败：%@", error.localizedDescription))
            }
        case .ask:
            saveAs(png, suggestedName: "\(environment.string("output.screenshotName", "截图")) \(environment.stamp()).png", environment: environment)
        }
    }

    static func saveAs(_ png: Data, suggestedName: String, environment: ScreenshotEnvironment) {
        let panel = NSSavePanel()
        panel.directoryURL = environment.saveFolder
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        environment.savePanel = panel
        defer { if environment.savePanel === panel { environment.savePanel = nil } }
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            environment.showToast(environment.format("output.saved", "已保存到「%@」", url.deletingLastPathComponent().lastPathComponent))
        } catch {
            environment.showToast(environment.format("output.saveFailed", "保存失败：%@", error.localizedDescription))
        }
    }

    static func finishLong(_ image: CGImage, scale: CGFloat, environment: ScreenshotEnvironment) {
        let rep = NSBitmapImageRep(cgImage: image)
        let points = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        rep.size = points
        guard let png = rep.representation(using: .png, properties: [:]) else {
            environment.showToast(environment.string("output.longExportFailed", "长截图导出失败"))
            return
        }
        copyToPasteboard(png)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let room = screen.visibleFrame
        let fit = min(1, room.width * 0.85 / points.width, room.height * 0.85 / points.height)
        let size = NSSize(width: points.width * fit, height: points.height * fit)
        environment.pin(png, at: NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2,
                                       width: size.width, height: size.height),
                        bakedShadow: false,
                        name: "\(environment.string("output.longScreenshotName", "长截图")) \(environment.stamp()).png")
        environment.showToast(environment.string("output.longCopiedAndPinned", "已复制到剪贴板，并钉在屏幕上 · ⌘S 保存"))
    }
}
