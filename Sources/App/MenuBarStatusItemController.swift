import AppKit
import Combine
import SwiftUI

enum MenuBarStatusItemInvocation: Equatable {
    case featurePanel
    case componentPanel

    static func invocation(for event: NSEvent?) -> MenuBarStatusItemInvocation {
        guard let event else {
            return .componentPanel
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            return .featurePanel
        }

        return .componentPanel
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject {
    private static let statusIconName = NSImage.Name("MenuBarIcon")
    private static let statusIconSize = NSSize(width: 18, height: 18)

    private let pluginHost: PluginHost
    private let windowRouter: AppWindowRouter
    private let statusItem: NSStatusItem
    private let featurePopover = NSPopover()
    private let componentPopover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

    init(pluginHost: PluginHost, windowRouter: AppWindowRouter) {
        self.pluginHost = pluginHost
        self.windowRouter = windowRouter
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopovers()
        observePluginHost()
        updateStatusIcon()
    }

    func dismissPanels() {
        featurePopover.performClose(nil)
        componentPopover.performClose(nil)
        removeDismissMonitorsIfNeeded()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MacTools"
    }

    private func configurePopovers() {
        featurePopover.behavior = .transient
        featurePopover.animates = true
        featurePopover.delegate = self
        componentPopover.behavior = .transient
        componentPopover.animates = true
        componentPopover.delegate = self
    }

    private func observePluginHost() {
        pluginHost.$hasActivePlugin
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        pluginHost.$settingsPresentationRequestCount
            .dropFirst()
            .sink { [weak self] _ in
                self?.windowRouter.showSettings()
                self?.dismissPanels()
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        let image = NSImage(named: Self.statusIconName)
        image?.size = Self.statusIconSize
        image?.isTemplate = true

        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        switch MenuBarStatusItemInvocation.invocation(for: NSApp.currentEvent) {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: sender)
        case .componentPanel:
            toggleComponentPanel(relativeTo: sender)
        }
    }

    private func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        if featurePopover.isShown {
            featurePopover.performClose(nil)
            return
        }

        componentPopover.performClose(nil)
        let hostingController = NSHostingController(
            rootView: MenuBarContent(
                pluginHost: pluginHost,
                onDismiss: { [weak self] in
                    self?.featurePopover.performClose(nil)
                },
                onOpenSettings: { [weak self] in
                    self?.windowRouter.showSettings()
                },
                onOpenDiskCleanDetails: { [weak self] in
                    self?.windowRouter.showDiskCleanDetails()
                }
            )
        )
        featurePopover.contentViewController = hostingController
        featurePopover.contentSize = hostingController.view.fittingSize
        featurePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        focusPresentedPopover(featurePopover)
        installDismissMonitorsIfNeeded()
        refreshAfterPresentation()
    }

    private func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        if componentPopover.isShown {
            componentPopover.performClose(nil)
            return
        }

        featurePopover.performClose(nil)
        let panelHeight = ComponentPanelLayout.preferredPanelHeight(
            for: pluginHost.componentItems,
            screen: button.window?.screen ?? NSScreen.main
        )
        componentPopover.contentSize = NSSize(
            width: ComponentPanelLayout.panelWidth,
            height: panelHeight
        )
        componentPopover.contentViewController = NSHostingController(
            rootView: ComponentPanelContent(
                pluginHost: pluginHost,
                panelHeight: panelHeight,
                onDismiss: { [weak self] in
                    self?.componentPopover.performClose(nil)
                }
            )
        )
        componentPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        focusPresentedPopover(componentPopover)
        installDismissMonitorsIfNeeded()
        refreshAfterPresentation()
    }

    private func installDismissMonitorsIfNeeded() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                self?.handleLocalMouseEvent(event) ?? event
            }
        }

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
                Task { @MainActor in
                    self?.dismissPanels()
                }
            }
        }

        if appActivationObserver == nil {
            appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard !Self.isCurrentApplicationActivationNotification(notification) else {
                    return
                }

                Task { @MainActor in
                    self?.dismissPanels()
                }
            }
        }
    }

    private func removeDismissMonitorsIfNeeded() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func focusPresentedPopover(_ popover: NSPopover) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        Task { @MainActor [weak popover] in
            await Task.yield()
            guard let popover, popover.isShown else {
                return
            }

            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent {
        guard featurePopover.isShown || componentPopover.isShown else {
            removeDismissMonitorsIfNeeded()
            return event
        }

        guard !isEventInsidePopover(event), !isEventInsideStatusButton(event) else {
            return event
        }

        dismissPanels()
        return event
    }

    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else {
            return false
        }

        return eventWindow === featurePopover.contentViewController?.view.window
            || eventWindow === componentPopover.contentViewController?.view.window
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard
            let button = statusItem.button,
            event.window === button.window
        else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    nonisolated private static func isCurrentApplicationActivationNotification(_ notification: Notification) -> Bool {
        guard
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return false
        }

        return activatedApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func refreshAfterPresentation() {
        Task { @MainActor in
            await Task.yield()
            pluginHost.refreshAll()
        }
    }
}

extension MenuBarStatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard !featurePopover.isShown, !componentPopover.isShown else {
            return
        }

        removeDismissMonitorsIfNeeded()
    }
}
