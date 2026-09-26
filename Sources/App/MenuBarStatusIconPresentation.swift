import AppKit
import MacToolsPluginKit

/// Avoid assigning an unchanged image: NSStatusBarButton assignments also trigger
/// status-item layout and replication outside the application's view hierarchy.
@MainActor
final class MenuBarStatusIconPresentation {
    struct Key: Equatable {
        enum Source: Equatable {
            case plugin(generation: UUID?, revision: UInt64)
            case fallback(payload: MenuBarIconImagePayload, frameIndex: Int)
        }

        let source: Source
        let context: PluginMenuBarIconRenderContext
        let runningAutomationCount: Int
        var hasAvailableUpdate = false
    }

    private var lastKey: Key?

    func reset() {
        lastKey = nil
    }

    /// A failed image leaves the previous presentation intact so the caller can
    /// try a fallback. Metadata remains live even when the image is unchanged.
    @discardableResult
    func present(
        on button: NSButton,
        key: Key,
        tooltip: String,
        accessibilityDescription: String,
        makeImage: () -> NSImage?
    ) -> Bool {
        if lastKey != key {
            guard let image = makeImage() else { return false }
            lastKey = key
            button.image = image
        }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
        }
        if button.accessibilityLabel() != accessibilityDescription {
            button.setAccessibilityLabel(accessibilityDescription)
        }
        return true
    }
}
