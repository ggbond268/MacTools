import AppKit
import CoreGraphics
import Foundation

enum HideNotchDesktopMaskWindowError: LocalizedError {
    case creationFailed

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "无法创建隐藏刘海遮挡层。"
        }
    }
}

private final class HideNotchDesktopMaskWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HideNotchDesktopMaskView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

private final class SystemHideNotchDesktopMaskWindow: HideNotchDesktopMaskWindowing {
    private let window: HideNotchDesktopMaskWindow

    init(frame: CGRect) {
        let window = HideNotchDesktopMaskWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.animationBehavior = .none
        window.contentView = HideNotchDesktopMaskView(
            frame: CGRect(origin: .zero, size: frame.size)
        )
        self.window = window
    }

    func setFrame(_ frame: CGRect) {
        window.setFrame(frame, display: true)
        window.contentView?.frame = CGRect(origin: .zero, size: frame.size)
    }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    private static let windowLevel = NSWindow.Level(
        rawValue: max(
            Int(CGWindowLevelForKey(.desktopWindow)) + 1,
            Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        )
    )
}

@MainActor
final class HideNotchDesktopMaskWindowBuilder: HideNotchDesktopMaskWindowBuilding {
    func makeWindow(frame: CGRect) throws -> HideNotchDesktopMaskWindowing {
        guard !frame.isEmpty else {
            throw HideNotchDesktopMaskWindowError.creationFailed
        }

        return SystemHideNotchDesktopMaskWindow(frame: frame)
    }
}
