import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

enum WindowModifierDragHUDState: Equatable, Sendable {
    case armed(modifiers: ShortcutModifiers, pointer: CGPoint)
    case active(modifiers: ShortcutModifiers, pointer: CGPoint)
    case failure(message: String, pointer: CGPoint)
}

@MainActor
protocol WindowModifierDragHUDPresenting: AnyObject {
    func present(_ state: WindowModifierDragHUDState)
    func dismiss()
}

final class WindowModifierDragHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct WindowModifierDragHUDView: View {
    let state: WindowModifierDragHUDState
    let moveTitle: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case let .armed(modifiers, _):
                Text(modifiers.symbolString)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(moveTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            case let .active(modifiers, _):
                Text(modifiers.symbolString)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(moveTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            case let .failure(message, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(foregroundColor)
        .background {
            backgroundPill
        }
        .overlay {
            Capsule()
                .stroke(borderColor, lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.5)
        }
        .shadow(
            color: Color.black.opacity(reduceTransparency ? 0.05 : 0.18),
            radius: 4,
            x: 0,
            y: 2
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: state)
    }

    private var foregroundColor: Color {
        switch state {
        case .armed:
            return .primary
        case .active:
            return .white
        case .failure:
            return .primary
        }
    }

    @ViewBuilder
    private var backgroundPill: some View {
        switch state {
        case .active:
            Capsule().fill(Color.accentColor)
        case .armed, .failure:
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
    }

    private var borderColor: Color {
        switch state {
        case .active:
            return Color.white.opacity(0.3)
        case .armed, .failure:
            return colorSchemeContrast == .increased
                ? Color.primary.opacity(0.4)
                : Color.primary.opacity(0.12)
        }
    }
}

@MainActor
final class WindowModifierDragHUDController: WindowModifierDragHUDPresenting {
    private var panel: WindowModifierDragHUDPanel?
    private var hostingView: NSHostingView<WindowModifierDragHUDView>?
    private(set) var currentState: WindowModifierDragHUDState?

    private let visibleFramesProvider: () -> [CGRect]
    private let displayFramesProvider: () -> [CGRect]
    private let moveTitleProvider: () -> String
    private let announceAccessibility: (String) -> Void

    var presentedPanelForTests: WindowModifierDragHUDPanel? { panel }

    init(
        visibleFramesProvider: @escaping () -> [CGRect] = {
            NSScreen.screens.map(\.visibleFrame)
        },
        displayFramesProvider: @escaping () -> [CGRect] = {
            NSScreen.screens.map(\.frame)
        },
        moveTitleProvider: @escaping () -> String = { "Move" },
        announceAccessibility: @escaping (String) -> Void = { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    ) {
        self.visibleFramesProvider = visibleFramesProvider
        self.displayFramesProvider = displayFramesProvider
        self.moveTitleProvider = moveTitleProvider
        self.announceAccessibility = announceAccessibility
    }

    func present(_ state: WindowModifierDragHUDState) {
        currentState = state

        if case let .failure(message, _) = state {
            announceAccessibility(message)
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        let moveTitle = moveTitleProvider()
        let hudView = WindowModifierDragHUDView(state: state, moveTitle: moveTitle)

        let hosting: NSHostingView<WindowModifierDragHUDView>
        if let existing = hostingView {
            existing.rootView = hudView
            hosting = existing
        } else {
            let newHosting = NSHostingView(rootView: hudView)
            panel.contentView = newHosting
            self.hostingView = newHosting
            hosting = newHosting
        }

        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize
        let resolvedSize = CGSize(
            width: max(fittingSize.width, 40),
            height: max(fittingSize.height, 24)
        )

        let pointerLocation = Self.pointerLocation(from: state)
        let targetFrame = Self.panelFrame(
            at: pointerLocation,
            panelSize: resolvedSize,
            displayFrames: displayFramesProvider(),
            visibleFrames: visibleFramesProvider()
        )

        panel.setFrame(targetFrame, display: true)
        let textEditingRestoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            restoringTextEditingIn: NSApp.isActive ? NSApp.keyWindow : nil
        )
        panel.orderFrontRegardless()
        textEditingRestoration?.restore()
    }

    func dismiss() {
        currentState = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func makePanel() -> WindowModifierDragHUDPanel {
        let panel = WindowModifierDragHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("WindowModifierDragHUDPanel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        return panel
    }

    private static func pointerLocation(from state: WindowModifierDragHUDState) -> CGPoint {
        switch state {
        case let .armed(_, pointer):
            return pointer
        case let .active(_, pointer):
            return pointer
        case let .failure(_, pointer):
            return pointer
        }
    }

    static func panelFrame(
        at pointerLocation: CGPoint,
        panelSize: CGSize,
        displayFrames: [CGRect],
        visibleFrames: [CGRect],
        offset: CGPoint = CGPoint(x: 14, y: 12)
    ) -> CGRect {
        let targetScreenRect = CGRect(origin: pointerLocation, size: CGSize(width: 1, height: 1))
        let visibleFrame = matchingVisibleFrame(
            for: targetScreenRect,
            displayFrames: displayFrames,
            visibleFrames: visibleFrames
        )

        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - panelSize.width - 8
        let preferredX = pointerLocation.x + offset.x
        let clampedX: CGFloat
        if maxX >= minX {
            clampedX = min(max(preferredX, minX), maxX)
        } else {
            clampedX = visibleFrame.midX - panelSize.width / 2
        }

        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - panelSize.height - 8
        let belowY = pointerLocation.y - panelSize.height - offset.y
        let aboveY = pointerLocation.y + offset.y

        let preferredY: CGFloat
        if belowY >= minY {
            preferredY = belowY
        } else if aboveY <= maxY {
            preferredY = aboveY
        } else {
            preferredY = belowY
        }

        let clampedY: CGFloat
        if maxY >= minY {
            clampedY = min(max(preferredY, minY), maxY)
        } else {
            clampedY = visibleFrame.midY - panelSize.height / 2
        }

        return CGRect(
            origin: CGPoint(x: clampedX, y: clampedY),
            size: panelSize
        ).integral
    }

    private static func matchingVisibleFrame(
        for targetRect: CGRect,
        displayFrames: [CGRect],
        visibleFrames: [CGRect]
    ) -> CGRect {
        for (display, visible) in zip(displayFrames, visibleFrames) {
            if display.contains(targetRect.origin) {
                return visible
            }
        }
        for (display, visible) in zip(displayFrames, visibleFrames) {
            if display.intersects(targetRect) {
                return visible
            }
        }
        var bestVisible = visibleFrames.first ?? targetRect
        var minDistance = CGFloat.greatestFiniteMagnitude
        for (display, visible) in zip(displayFrames, visibleFrames) {
            let dist = distance(from: targetRect.origin, to: display)
            if dist < minDistance {
                minDistance = dist
                bestVisible = visible
            }
        }
        return bestVisible
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
