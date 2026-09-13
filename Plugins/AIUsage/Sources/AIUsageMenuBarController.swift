import AppKit
import MacToolsPluginKit

@MainActor
final class AIUsageMenuBarController: NSObject {
    var openDashboard: (() -> Void)?
    var openSettings: (() -> Void)?
    private var item: NSStatusItem?
    private var presentation: AIUsageMenuBarPresentation?

    func update(_ presentation: AIUsageMenuBarPresentation, assets: AIUsageProviderAssets) {
        guard !presentation.segments.isEmpty else { remove(); return }
        if item == nil {
            PluginPresentationSafety.prepareForWindowOrdering()
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "AIUsage"
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageOnly
            self.item = item
        }
        guard self.presentation != presentation else { return }
        self.presentation = presentation
        item?.button?.toolTip = presentation.tooltip
        item?.button?.setAccessibilityLabel(presentation.tooltip)
        item?.button?.image = Self.makeImage(presentation, assets: assets)
    }

    static func makeImage(_ presentation: AIUsageMenuBarPresentation, assets: AIUsageProviderAssets) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textWidth = ceil(("100%" as NSString).size(withAttributes: attributes).width)
        let segmentWidth = 18 + 4 + textWidth
        let size = NSSize(width: CGFloat(presentation.segments.count) * segmentWidth
                          + CGFloat(max(0, presentation.segments.count - 1)) * 12, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        for (index, segment) in presentation.segments.enumerated() {
            let x = CGFloat(index) * (segmentWidth + 12)
            assets.image(for: segment.provider).draw(in: NSRect(x: x, y: 2, width: 18, height: 18),
                                                     from: .zero, operation: .sourceOver, fraction: 1)
            let text = segment.value as NSString
            let textSize = text.size(withAttributes: attributes)
            var valueAttributes = attributes
            valueAttributes[.foregroundColor] = NSColor.black.withAlphaComponent(segment.isStale ? 0.45 : 1)
            text.draw(at: NSPoint(x: x + 22 + textWidth - textSize.width, y: (22 - textSize.height) / 2),
                      withAttributes: valueAttributes)
        }
        image.isTemplate = true
        image.accessibilityDescription = presentation.tooltip
        return image
    }

    func remove() {
        if let item {
            PluginPresentationSafety.prepareForWindowOrdering()
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        presentation = nil
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { openSettings?() } else { openDashboard?() }
    }
}
