// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Combine

// MARK: - MenuBarHiddenObserver
//
// Aggregates the system signals that indicate the menu bar layout may have
// changed and debounces them into a single `onRefresh` callback. Optional
// short polling can be turned on while a relevant UI surface is visible,
// so SwiftUI views see late-arriving status items quickly.

@MainActor
final class MenuBarHiddenObserver {
    var onRefresh: ((MenuBarHiddenRefreshReason) -> Void)?
    var onDraggingChanged: ((Bool, NSPoint?) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var pollingTask: Task<Void, Never>?
    private var debounceTimer: Timer?
    private var pendingReason: MenuBarHiddenRefreshReason?
    private var localDragMonitor: Any?
    private var globalDragMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var isDraggingMenuBarItem = false
    private var mouseDownStartedInMenuBar = false
    private var mouseDownLocation: NSPoint?

    private let debounceInterval: TimeInterval = 0.2
    private let pollInterval: Duration = .milliseconds(1500)

    func start() {
        guard cancellables.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(.appLaunched) }
            .store(in: &cancellables)

        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(.appTerminated) }
            .store(in: &cancellables)

        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(.spaceChanged) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(.screenChanged) }
            .store(in: &cancellables)

        startDragMonitoring()
    }

    func stop() {
        cancellables.removeAll()
        stopDragMonitoring()
        stopPolling()
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollIntervalDefault)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.schedule(.initial) }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Debounce

    private func schedule(_ reason: MenuBarHiddenRefreshReason) {
        pendingReason = reason
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: debounceInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let r = self.pendingReason ?? reason
                self.pendingReason = nil
                self.onRefresh?(r)
            }
        }
    }

    private static let pollIntervalDefault: Duration = .milliseconds(1500)

    // MARK: - Menu bar drag monitoring

    private func startDragMonitoring() {
        guard localDragMonitor == nil, globalDragMonitor == nil else { return }

        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown]
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            self?.handleMouseDown(modifierFlags: event.modifierFlags)
            return event
        }
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleMouseDown(modifierFlags: modifierFlags)
            }
        }

        let dragMask: NSEvent.EventTypeMask = [.leftMouseDragged]
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: dragMask) { [weak self] event in
            self?.handleMouseDragged(modifierFlags: event.modifierFlags)
            return event
        }
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: dragMask) { [weak self] event in
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleMouseDragged(modifierFlags: modifierFlags)
            }
        }

        let mouseUpMask: NSEvent.EventTypeMask = [.leftMouseUp]
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseUpMask) { [weak self] event in
            self?.handleMouseUp()
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseUpMask) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseUp()
            }
        }
    }

    private func stopDragMonitoring() {
        for monitor in [
            localDragMonitor,
            globalDragMonitor,
            localMouseDownMonitor,
            globalMouseDownMonitor,
            localMouseUpMonitor,
            globalMouseUpMonitor,
        ].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localDragMonitor = nil
        globalDragMonitor = nil
        localMouseDownMonitor = nil
        globalMouseDownMonitor = nil
        localMouseUpMonitor = nil
        globalMouseUpMonitor = nil
        mouseDownStartedInMenuBar = false
        mouseDownLocation = nil
        setDraggingMenuBarItem(false)
    }

    private func handleMouseDown(modifierFlags: NSEvent.ModifierFlags) {
        if isDraggingMenuBarItem {
            setDraggingMenuBarItem(false)
        }
        mouseDownStartedInMenuBar = isCommandPressed(modifierFlags) && isMouseInsideMenuBarBand()
        mouseDownLocation = mouseDownStartedInMenuBar ? NSEvent.mouseLocation : nil
    }

    private func handleMouseDragged(modifierFlags: NSEvent.ModifierFlags) {
        guard
            !isDraggingMenuBarItem,
            mouseDownStartedInMenuBar || isCommandPressed(modifierFlags),
            isMouseInsideMenuBarBand()
        else {
            return
        }

        setDraggingMenuBarItem(true)
    }

    private func handleMouseUp() {
        mouseDownStartedInMenuBar = false
        setDraggingMenuBarItem(false)
        mouseDownLocation = nil
    }

    private func setDraggingMenuBarItem(_ dragging: Bool) {
        guard isDraggingMenuBarItem != dragging else { return }
        isDraggingMenuBarItem = dragging
        onDraggingChanged?(dragging, mouseDownLocation)
    }

    private func isMouseInsideMenuBarBand() -> Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            let menuBarRect = CGRect(
                x: screen.frame.minX,
                y: screen.visibleFrame.maxY,
                width: screen.frame.width,
                height: screen.frame.maxY - screen.visibleFrame.maxY
            )
            let fallbackHeight = max(NSStatusBar.system.thickness + 2, 26)
            let fallbackRect = CGRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - fallbackHeight,
                width: screen.frame.width,
                height: fallbackHeight
            )
            return menuBarRect.insetBy(dx: 0, dy: -4).contains(mouse)
                || fallbackRect.insetBy(dx: 0, dy: -4).contains(mouse)
        }
    }

    private func isCommandPressed(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command)
    }
}
