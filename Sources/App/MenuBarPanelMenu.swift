import AppKit
import SwiftUI

/// Acquire application focus before native menu tracking from a nonactivating popover.
/// Only an explicit menu request acquires activation; idle panels install no observers.
@MainActor
final class MenuBarPanelMenuPresenter: ObservableObject {
    private let notificationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let isApplicationActive: () -> Bool
    private let activateApplication: () -> Void
    private var activationObserver: NSObjectProtocol?
    private var applicationSwitchObserver: NSObjectProtocol?
    private var pendingPresentation: (() -> Void)?
    private weak var anchor: NSView?
    private var trackingMenu: NSMenu?
    private(set) var generation: UInt = 0
    private(set) var isPresenting = false
    var isTrackingMenu: Bool { trackingMenu != nil }

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        isApplicationActive: @escaping () -> Bool = { NSApp.isActive },
        activateApplication: @escaping () -> Void = { NSApp.activate() }
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        self.isApplicationActive = isApplicationActive
        self.activateApplication = activateApplication
    }

    isolated deinit { cancel() }

    func present(from view: NSView, at point: NSPoint? = nil, makeMenu: @escaping () -> NSMenu) {
        guard let window = view.window, window.isVisible else { return }
        requestPresentation(isValid: { [weak view, weak window] in
            guard let view, let window else { return false }
            return view.window === window && window.isVisible && !view.isHiddenOrHasHiddenAncestor
        }) { [weak self, weak view, weak window] in
            guard let self, let view, let window else { return }
            let menu = makeMenu()
            guard !menu.items.isEmpty else { return }
            self.trackingMenu = menu
            window.makeKey()
            let location = point ?? NSPoint(x: view.bounds.minX,
                                           y: view.isFlipped ? view.bounds.maxY : view.bounds.minY)
            menu.popUp(positioning: nil, at: location, in: view)
        }
        anchor = view
    }

    /// Keep activation and cancellation testable without moving desktop focus.
    func requestPresentation(isValid: @escaping () -> Bool, present: @escaping () -> Void) {
        cancel()
        guard isValid() else { return }
        isPresenting = true
        let requestGeneration = generation
        pendingPresentation = { [weak self] in
            guard let self, self.generation == requestGeneration else { return }
            self.pendingPresentation = nil
            self.removeActivationObservers()
            defer { if self.generation == requestGeneration { self.cancel() } }
            guard self.isApplicationActive(), isValid() else { return }
            present()
        }

        if isApplicationActive() {
            schedulePresentation()
            return
        }

        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePresentation() }
        }
        applicationSwitchObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.cancel() }
        }
        activateApplication()
        // Activation can finish synchronously, or report completion through the observer.
        if isApplicationActive() { schedulePresentation() }
    }

    private func schedulePresentation() {
        let requestGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == requestGeneration else { return }
            self.pendingPresentation?()
        }
    }

    func cancel(from view: NSView) {
        if anchor === view { cancel() }
    }

    func cancel() {
        generation &+= 1
        pendingPresentation = nil
        anchor = nil
        isPresenting = false
        removeActivationObservers()
        let menu = trackingMenu
        trackingMenu = nil
        menu?.cancelTracking()
    }

    private func removeActivationObservers() {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        if let applicationSwitchObserver { workspaceCenter.removeObserver(applicationSwitchObserver) }
        activationObserver = nil
        applicationSwitchObserver = nil
    }
}

/// Keep the SwiftUI label and keyboard behavior, but own the native menu's opening sequence.
struct MenuBarPanelMenu<Label: View>: View {
    let makeMenu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @EnvironmentObject private var presenter: MenuBarPanelMenuPresenter
    @StateObject private var anchor = MenuBarPanelMenuAnchor.Storage()

    var body: some View {
        Button {
            presenter.present(from: anchor.view, makeMenu: makeMenu)
        } label: {
            label()
        }
        .background(MenuBarPanelMenuAnchor(view: anchor.view, presenter: presenter).allowsHitTesting(false))
        .onDisappear { presenter.cancel(from: anchor.view) }
    }
}

private struct MenuBarPanelMenuAnchor: NSViewRepresentable {
    let view: View
    let presenter: MenuBarPanelMenuPresenter

    func makeNSView(context: Context) -> View {
        view.presenter = presenter
        return view
    }
    func updateNSView(_ nsView: View, context: Context) {}

    @MainActor
    final class Storage: ObservableObject {
        let view = View()
    }

    final class View: NSView {
        weak var presenter: MenuBarPanelMenuPresenter?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow { presenter?.cancel(from: self) }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

@MainActor
final class MenuBarPanelMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, isEnabled: Bool = true,
         identifier: String? = nil, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        self.image = image
        self.isEnabled = isEnabled
        if let identifier { self.setAccessibilityIdentifier(identifier) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}
