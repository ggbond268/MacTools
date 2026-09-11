import Foundation

/// App activation and unhiding are asynchronous requests. Wait for their observed
/// state before raising a particular window, without repeating either request.
@MainActor
enum WindowSwitcherApplicationActivation {
    struct State {
        var isHidden: Bool
        var isFrontmost: Bool
        var isTerminated: Bool = false
    }
    enum Request { case unhide, activate }

    static func prepare(
        state: () -> State,
        request: (Request) -> Void,
        timeout: Duration = .seconds(1),
        activateAllSpaces: Bool = false
    ) async -> WindowSwitcherActionResult {
        let deadline = ContinuousClock.now + timeout
        func wait(until ready: (State) -> Bool) async -> WindowSwitcherActionResult {
            while true {
                guard !Task.isCancelled else { return .cancelled }
                let current = state()
                guard !current.isTerminated else { return .unavailable }
                if ready(current) { return .succeeded }
                guard ContinuousClock.now < deadline else { return .failed }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        guard !state().isTerminated else { return .unavailable }
        if state().isHidden {
            request(.unhide)
            let visible = await wait { !$0.isHidden }
            guard visible == .succeeded else { return visible }
        }
        guard !Task.isCancelled else { return .cancelled }
        if activateAllSpaces || !state().isFrontmost { request(.activate) }
        return await wait { !$0.isHidden && $0.isFrontmost }
    }
}
