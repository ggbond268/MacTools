import CoreGraphics
import Foundation
import MacToolsPluginKit

enum WindowModifierDragGestureAction: Equatable {
    case begin(generation: UInt64, origin: CGPoint, pointer: CGPoint)
    case update(generation: UInt64, pointer: CGPoint)
    case cancel(generation: UInt64)
}

struct WindowModifierDragGesture {
    private enum State {
        case idle
        case armed(generation: UInt64, origin: CGPoint)
        case active(generation: UInt64)
        case blocked
    }

    var requiredModifiers: ShortcutModifiers
    var activationDistance: CGFloat = 4
    private var state: State = .idle
    private var nextGeneration: UInt64 = 0

    init(
        requiredModifiers: ShortcutModifiers,
        activationDistance: CGFloat = 4
    ) {
        self.requiredModifiers = requiredModifiers
        self.activationDistance = activationDistance
    }

    func shouldProcessPointerMovement(modifiers: ShortcutModifiers) -> Bool {
        if modifiers == requiredModifiers { return true }
        switch state {
        case .armed, .active:
            return true
        case .idle, .blocked:
            return false
        }
    }

    mutating func modifiersChanged(
        _ modifiers: ShortcutModifiers,
        pointer: CGPoint
    ) -> WindowModifierDragGestureAction? {
        if modifiers == requiredModifiers {
            guard case .idle = state else { return nil }
            nextGeneration &+= 1
            state = .armed(generation: nextGeneration, origin: pointer)
            return nil
        }

        let cancellation = cancelIfNeeded()
        if modifiers.isEmpty {
            state = .idle
        } else if cancellation != nil || !modifiers.isSubset(of: requiredModifiers) {
            state = .blocked
        } else {
            state = .idle
        }
        return cancellation
    }

    mutating func pointerMoved(
        to pointer: CGPoint,
        modifiers: ShortcutModifiers
    ) -> WindowModifierDragGestureAction? {
        guard modifiers == requiredModifiers else {
            return modifiersChanged(modifiers, pointer: pointer)
        }

        switch state {
        case .idle:
            nextGeneration &+= 1
            state = .armed(generation: nextGeneration, origin: pointer)
            return nil
        case let .armed(generation, origin):
            guard hypot(pointer.x - origin.x, pointer.y - origin.y) >= activationDistance else {
                return nil
            }
            state = .active(generation: generation)
            return .begin(generation: generation, origin: origin, pointer: pointer)
        case let .active(generation):
            return .update(generation: generation, pointer: pointer)
        case .blocked:
            return nil
        }
    }

    mutating func mouseButtonPressed() -> WindowModifierDragGestureAction? {
        let cancellation = cancelIfNeeded()
        state = cancellation == nil ? .idle : .blocked
        return cancellation
    }

    mutating func reset() -> WindowModifierDragGestureAction? {
        let cancellation = cancelIfNeeded()
        state = .idle
        return cancellation
    }

    private mutating func cancelIfNeeded() -> WindowModifierDragGestureAction? {
        switch state {
        case let .armed(generation, _), let .active(generation):
            return .cancel(generation: generation)
        case .idle, .blocked:
            return nil
        }
    }
}

private extension ShortcutModifiers {
    func isSubset(of other: ShortcutModifiers) -> Bool {
        intersection(other) == self
    }
}
