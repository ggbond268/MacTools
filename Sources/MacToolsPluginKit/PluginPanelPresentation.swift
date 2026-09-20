import AppKit

/// Presentation policy for keyboard-driven global panels. Construct the panel
/// with this style mask: changing nonactivation after creation is not equivalent.
@MainActor
public enum PluginPanelPresentation {
    public static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    public static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications,
        .transient, .ignoresCycle,
    ]

    public static func configure(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = collectionBehavior
    }

    public static func present(_ panel: NSPanel) {
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// An ordinary nonactivating presentation needs no application restoration.
/// Retain the origin only for interactions that deliberately activate the host,
/// such as a native modal confirmation or preview gesture compatibility.
@MainActor
public final class PluginPanelFocusRestoration {
    public typealias Restoration = () -> Void
    private let captureRestoration: () -> Restoration?
    private let canRestore: () -> Bool
    private var pendingRestoration: Restoration?
    private var isPrepared = false

    public init(
        captureRestoration: @escaping () -> Restoration? = {
            guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
            if application != .current { return { application.activate() } }
            guard let window = NSApp.keyWindow, let responder = window.firstResponder else { return nil }
            let fieldEditor = responder as? NSTextView
            let originalResponder = fieldEditor?.isFieldEditor == true
                ? fieldEditor?.delegate as? NSResponder ?? responder : responder
            return { [weak window, weak originalResponder] in
                guard let window, window.isVisible, window.isKeyWindow,
                      let originalResponder else { return }
                window.makeFirstResponder(originalResponder)
            }
        },
        canRestore: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.captureRestoration = captureRestoration
        self.canRestore = canRestore
    }

    public func prepareForPresentation() {
        guard !isPrepared else { return }
        isPrepared = true
        pendingRestoration = captureRestoration()
    }

    public func dismiss(wasVisible: Bool, restoringFocus: Bool) {
        let restoration = pendingRestoration
        pendingRestoration = nil
        isPrepared = false
        guard wasVisible, restoringFocus, canRestore() else { return }
        restoration?()
    }
}

/// Observes panel ownership rather than requiring the host application to become
/// active. Callers protect their own sheets, shortcut recorders, and other
/// interactions through `isSuspended`. Pending events cannot close a new session.
@MainActor
public final class PluginPanelDismissalMonitor {
    private weak var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var localMouse: Any?
    private var globalMouse: Any?
    private var generation: UInt = 0
    private var trackingMenuCount = 0
    private var isSuspended: () -> Bool = { false }
    private var onDismiss: () -> Void = {}

    public init() {}

    isolated deinit { stop() }

    public func start(
        for panel: NSPanel,
        isSuspended: @escaping () -> Bool = { false },
        onDismiss: @escaping () -> Void
    ) {
        stop()
        self.panel = panel
        self.isSuspended = isSuspended
        self.onDismiss = onDismiss
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocusAfterCurrentEvent() }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackingMenuCount += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trackingMenuCount = max(0, self.trackingMenuCount - 1)
                self.checkFocusAfterCurrentEvent()
            }
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
                self?.dismissAfterCurrentEvent()
            }
        }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self?.mouseDown(in: event.window, at: point)
            }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouseDown(in: nil, at: NSEvent.mouseLocation)
            }
        }
    }

    public func stop() {
        generation &+= 1
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        workspaceObserver = nil
        localMouse = nil
        globalMouse = nil
        panel = nil
        trackingMenuCount = 0
        isSuspended = { false }
        onDismiss = {}
    }

    private func checkFocusAfterCurrentEvent() {
        schedule { monitor, panel in
            !panel.isKeyWindow && !monitor.contains(NSApp.keyWindow)
        }
    }

    private var protectsInteraction: Bool {
        isSuspended() || trackingMenuCount > 0 || panel?.attachedSheet != nil
    }

    private func contains(_ window: NSWindow?) -> Bool {
        guard let panel, let window else { return false }
        if window === panel { return true }
        return window.sheetParent === panel || window.parent === panel
    }

    func mouseDown(in window: NSWindow?, at point: NSPoint) {
        guard let panel, !contains(window), !panel.frame.contains(point) else { return }
        // An IME candidate is an external window. Let its mouse event finish
        // composition without tearing down the owning field editor.
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        dismissAfterCurrentEvent()
    }

    private func dismissAfterCurrentEvent() {
        schedule { _, _ in true }
    }

    private func schedule(_ shouldDismiss: @escaping (PluginPanelDismissalMonitor, NSPanel) -> Bool) {
        guard !protectsInteraction else { return }
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == currentGeneration,
                  let panel, panel.isVisible, !protectsInteraction,
                  shouldDismiss(self, panel) else { return }
            let dismiss = onDismiss
            stop()
            dismiss()
        }
    }
}
