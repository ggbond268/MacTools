import AppKit
import MacToolsPluginKit

@MainActor
protocol DuoStatusMenuBarPresenting: AnyObject {
    var openSettings: (() -> Void)? { get set }
    func update(snapshot: DuoSystemStatusSnapshot, tooltip: String)
    func remove()
}

@MainActor
final class DuoStatusMenuBarController: NSObject, DuoStatusMenuBarPresenting {
    var openSettings: (() -> Void)?
    private var item: NSStatusItem?
    private var appearanceObserver: DuoStatusAppearanceObserverView?
    private var snapshot: DuoSystemStatusSnapshot?
    private var tooltip: String?

    isolated deinit {
        remove()
    }

    func update(snapshot: DuoSystemStatusSnapshot, tooltip: String) {
        let needsRedraw = item == nil || self.snapshot != snapshot
        self.snapshot = snapshot
        if item == nil {
            PluginPresentationSafety.prepareForWindowOrdering()
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "DuoStatus"
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageOnly
            self.item = item

            // A menu bar can change appearance with its wallpaper or display,
            // independently of the host app's selected appearance.
            let observer = DuoStatusAppearanceObserverView(frame: .zero)
            observer.setAccessibilityElement(false)
            item.button?.addSubview(observer)
            observer.onAppearanceChange = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.redraw()
                }
            }
            appearanceObserver = observer
        }
        if self.tooltip != tooltip {
            self.tooltip = tooltip
            item?.button?.toolTip = tooltip
            item?.button?.setAccessibilityLabel(tooltip)
        }
        if needsRedraw { redraw() }
    }

    func remove() {
        appearanceObserver?.onAppearanceChange = nil
        appearanceObserver?.removeFromSuperview()
        appearanceObserver = nil
        if let item {
            item.button?.target = nil
            item.button?.action = nil
            PluginPresentationSafety.prepareForWindowOrdering()
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        snapshot = nil
        tooltip = nil
    }

    private func redraw() {
        guard let snapshot, let button = item?.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = DuoStatusIcon.image(for: snapshot, appearance: isDark ? .dark : .light)
    }

    @objc private func clicked() {
        openSettings?()
    }
}

private final class DuoStatusAppearanceObserverView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
