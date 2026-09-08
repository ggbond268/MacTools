import AppKit

@MainActor
final class WindowSnapCoordinator {
    let role: WindowRole
    let positionStore: WindowPositionStore
    let overlayController: WindowSnapOverlayController
    private(set) weak var window: NSWindow?

    private(set) var isDragging = false
    private var isSnappingX = false
    private var isSnappingY = false
    private var lastResult: WindowSnapResult?
    private var moveObserver: (any NSObjectProtocol)?
    private var dragReleaseTask: Task<Void, Never>?
    private let pressedMouseButtonsProvider: () -> Int
    private let dragReleasePollInterval: Duration

    init(
        role: WindowRole,
        positionStore: WindowPositionStore = .shared,
        overlayController: WindowSnapOverlayController = WindowSnapOverlayController(),
        pressedMouseButtonsProvider: @escaping () -> Int = { NSEvent.pressedMouseButtons },
        dragReleasePollInterval: Duration = .milliseconds(16)
    ) {
        self.role = role
        self.positionStore = positionStore
        self.overlayController = overlayController
        self.pressedMouseButtonsProvider = pressedMouseButtonsProvider
        self.dragReleasePollInterval = dragReleasePollInterval
    }

    isolated deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        dragReleaseTask?.cancel()
    }

    func attach(to window: NSWindow) {
        self.window = window
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowMoved()
            }
        }
    }

    func startDragging() {
        guard let window else { return }
        isDragging = true
        isSnappingX = false
        isSnappingY = false
        lastResult = nil
        updateGuides(for: window)
        monitorDragRelease()
    }

    func handleWindowMoved() {
        guard isDragging, let window else { return }
        updateGuides(for: window)
    }

    func finishDragging() {
        guard isDragging, let window else { return }
        isDragging = false
        dragReleaseTask?.cancel()
        dragReleaseTask = nil
        overlayController.hide()

        guard let screen = activeScreen(for: window) else { return }

        if let result = lastResult {
            if result.isFullySnapped {
                window.setFrame(result.snappedFrame, display: true)
                positionStore.savePosition(.defaultAnchor, for: role)
                return
            }

            if result.isSnappingX || result.isSnappingY {
                window.setFrame(result.snappedFrame, display: true)
                let point = WindowSnapGeometry.normalizedPoint(
                    for: result.snappedFrame,
                    in: screen.visibleFrame
                )
                positionStore.savePosition(.custom(normalizedPoint: point), for: role)
                return
            }
        }

        let clamped = WindowSnapGeometry.clampedFrame(window.frame, in: screen.visibleFrame)
        if clamped != window.frame {
            window.setFrame(clamped, display: true)
        }
        let point = WindowSnapGeometry.normalizedPoint(for: clamped, in: screen.visibleFrame)
        positionStore.savePosition(.custom(normalizedPoint: point), for: role)
    }

    func resetPosition() {
        positionStore.resetPosition(for: role)
        guard let window, let screen = activeScreen(for: window) else { return }
        let targetFrame = WindowSnapGeometry.defaultFrame(
            contentSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        )
        window.setFrame(targetFrame, display: true, animate: true)
    }

    private func updateGuides(for window: NSWindow) {
        guard let screen = activeScreen(for: window) else { return }

        let result = WindowSnapGeometry.calculate(
            proposedFrame: window.frame,
            contentSize: window.frame.size,
            visibleFrame: screen.visibleFrame,
            currentlySnappingX: isSnappingX,
            currentlySnappingY: isSnappingY
        )

        isSnappingX = result.isSnappingX
        isSnappingY = result.isSnappingY
        lastResult = result

        overlayController.showGuides(
            result.guides,
            on: screen,
            relativeTo: window
        )
    }

    private func monitorDragRelease() {
        dragReleaseTask?.cancel()
        dragReleaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: dragReleasePollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, isDragging else { return }
                if pressedMouseButtonsProvider() & 1 == 0 {
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
