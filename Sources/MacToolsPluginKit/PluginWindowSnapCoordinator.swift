import AppKit

/// Adds the host's centered reference guides and snapping behavior to a plugin-owned window.
/// The current window frame is sampled for every drag update, so guides remain accurate after resizing.
@MainActor
public final class PluginWindowSnapCoordinator {
    private let overlayController: WindowSnapOverlayController
    private let pressedMouseButtonsProvider: () -> Int
    private let dragReleasePollInterval: Duration
    private let referenceInsets: NSEdgeInsets
    private let dragReleaseGracePeriod: Duration = .milliseconds(120)
    private let requiredReleasedPollCount = 2

    private weak var window: NSWindow?
    private var moveStartObserver: (any NSObjectProtocol)?
    private var moveObserver: (any NSObjectProtocol)?
    private var resizeObserver: (any NSObjectProtocol)?
    private var dragReleaseTask: Task<Void, Never>?
    private var isSnappingX = false
    private var isSnappingY = false
    private var lastResult: WindowSnapResult?

    public private(set) var isDragging = false

    public init(
        overlayController: WindowSnapOverlayController = WindowSnapOverlayController(),
        pressedMouseButtonsProvider: @escaping () -> Int = {
            CGEventSource.buttonState(.combinedSessionState, button: .left) ? 1 : 0
        },
        dragReleasePollInterval: Duration = .milliseconds(16),
        referenceInsets: NSEdgeInsets = NSEdgeInsets()
    ) {
        self.overlayController = overlayController
        self.pressedMouseButtonsProvider = pressedMouseButtonsProvider
        self.dragReleasePollInterval = dragReleasePollInterval
        self.referenceInsets = referenceInsets
    }

    isolated deinit {
        if let moveStartObserver {
            NotificationCenter.default.removeObserver(moveStartObserver)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        dragReleaseTask?.cancel()
    }

    public func attach(to window: NSWindow) {
        detach()
        self.window = window
        moveStartObserver = observeMoveStart(for: window)
        moveObserver = observe(NSWindow.didMoveNotification, for: window)
        resizeObserver = observe(NSWindow.didResizeNotification, for: window)
    }

    public func startDragging() {
        guard let window else { return }
        isDragging = true
        isSnappingX = false
        isSnappingY = false
        lastResult = nil
        updateGuides(for: window)
        monitorDragRelease()
    }

    public func finishDragging() {
        guard isDragging, let window else { return }
        isDragging = false
        dragReleaseTask?.cancel()
        dragReleaseTask = nil
        overlayController.hide()

        guard let screen = activeScreen(for: window) else { return }
        let finalFrame: CGRect
        if let lastResult, lastResult.isSnappingX || lastResult.isSnappingY {
            finalFrame = lastResult.snappedFrame
        } else {
            finalFrame = WindowSnapGeometry.clampedFrame(window.frame, in: screen.visibleFrame)
        }
        if finalFrame != window.frame {
            window.setFrame(finalFrame, display: true)
        }
    }

    public func cancelDragging() {
        isDragging = false
        dragReleaseTask?.cancel()
        dragReleaseTask = nil
        lastResult = nil
        overlayController.hide()
    }

    private func detach() {
        cancelDragging()
        if let moveStartObserver {
            NotificationCenter.default.removeObserver(moveStartObserver)
            self.moveStartObserver = nil
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        window = nil
    }

    private func observeMoveStart(for window: NSWindow) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !self.isDragging,
                      self.pressedMouseButtonsProvider() & 1 != 0
                else { return }
                self.startDragging()
            }
        }
    }

    private func observe(_ name: Notification.Name, for window: NSWindow) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDragging, let window = self.window else { return }
                self.updateGuides(for: window)
            }
        }
    }

    private func updateGuides(for window: NSWindow) {
        guard let screen = activeScreen(for: window) else { return }
        let result = WindowSnapGeometry.calculate(
            proposedFrame: window.frame,
            contentSize: window.frame.size,
            visibleFrame: screen.visibleFrame,
            referenceInsets: referenceInsets,
            currentlySnappingX: isSnappingX,
            currentlySnappingY: isSnappingY
        )
        isSnappingX = result.isSnappingX
        isSnappingY = result.isSnappingY
        lastResult = result
        overlayController.showGuides(result.guides, on: screen, relativeTo: window)
    }

    private func monitorDragRelease() {
        dragReleaseTask?.cancel()
        dragReleaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock.now
            var releasedPollCount = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: dragReleasePollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, isDragging else { return }
                if pressedMouseButtonsProvider() & 1 != 0 {
                    releasedPollCount = 0
                    continue
                }

                // AppKit hands performDrag off to the Window Server immediately. During
                // that handoff, pressedMouseButtons can briefly report no button even
                // though the physical drag is still beginning. Keep the guides alive
                // through that gap and require a stable release before finishing.
                guard ContinuousClock.now - startedAt >= dragReleaseGracePeriod else {
                    continue
                }
                releasedPollCount += 1
                if releasedPollCount >= requiredReleasedPollCount {
                    finishDragging()
                    return
                }
            }
        }
    }

    private func activeScreen(for window: NSWindow) -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        return screens.first { $0.frame.contains(pointer) }
            ?? window.screen
            ?? NSScreen.main
            ?? screens.first
    }
}
