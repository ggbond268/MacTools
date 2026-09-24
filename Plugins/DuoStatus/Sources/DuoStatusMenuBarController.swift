import AppKit
import MacToolsPluginKit

@MainActor
protocol DuoStatusMenuBarPresenting: AnyObject {
    var openSettings: (() -> Void)? { get set }
    func update(snapshot: DuoSystemStatusSnapshot, options: DuoStatusIconOptions, tooltip: String)
    func remove()
}

@MainActor
final class DuoStatusMenuBarController: NSObject, DuoStatusMenuBarPresenting {
    var openSettings: (() -> Void)?
    private var item: NSStatusItem?
    private var appearanceObserver: DuoStatusAppearanceObserverView?
    private var snapshot: DuoSystemStatusSnapshot?
    private var options = DuoStatusIconOptions.default
    private var tooltip: String?
    private let iconPresentation = DuoStatusIconPresentation()
    private var isRedrawScheduled = false

    isolated deinit {
        remove()
    }

    func update(snapshot: DuoSystemStatusSnapshot, options: DuoStatusIconOptions, tooltip: String) {
        self.snapshot = snapshot
        self.options = options
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
                self?.scheduleRedraw()
            }
            appearanceObserver = observer
        }
        if self.tooltip != tooltip {
            self.tooltip = tooltip
            item?.button?.toolTip = tooltip
            item?.button?.setAccessibilityLabel(tooltip)
        }
        redraw()
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
        options = .default
        tooltip = nil
        iconPresentation.reset()
    }

    private func scheduleRedraw() {
        guard !isRedrawScheduled else { return }
        isRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRedrawScheduled = false
            redraw()
        }
    }

    private func redraw() {
        guard let snapshot, let button = item?.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        iconPresentation.update(on: button, snapshot: snapshot, options: options, context: .init(
            pointSize: DuoStatusIcon.size,
            displayScale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            appearance: isDark ? .dark : .light
        ))
    }

    @objc private func clicked() {
        openSettings?()
    }
}

@MainActor
final class DuoStatusIconPresentation {
    private struct RenderState: Equatable {
        let snapshot: DuoSystemStatusSnapshot
        let options: DuoStatusIconOptions
        let context: PluginMenuBarIconRenderContext
    }

    private var lastRenderState: RenderState?

    func reset() { lastRenderState = nil }

    func update(
        on button: NSButton,
        snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions,
        context: PluginMenuBarIconRenderContext
    ) {
        let state = RenderState(snapshot: snapshot, options: options, context: context)
        guard state != lastRenderState else { return }
        // AppKit can notify appearance changes while replicating a status item.
        // Reassigning an unchanged image here can schedule another replication.
        lastRenderState = state
        button.image = DuoStatusIcon.image(for: snapshot, options: options,
            appearance: context.appearance == .dark ? .dark : .light, pointSize: context.pointSize)
    }
}

private final class DuoStatusAppearanceObserverView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onAppearanceChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
