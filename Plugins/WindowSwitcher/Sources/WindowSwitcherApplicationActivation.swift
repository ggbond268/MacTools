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
        request: (Request) async -> Void,
        timeout: Duration = .seconds(1),
        activateAllSpaces: Bool = false,
        fallbackRequest: (() async -> Void)? = nil,
        fallbackDelay: Duration = .milliseconds(200),
        shouldContinue: () -> Bool = { true }
    ) async -> WindowSwitcherActionResult {
        let deadline = ContinuousClock.now + timeout
        func wait(allowFallback: Bool = false, until ready: (State) -> Bool) async -> WindowSwitcherActionResult {
            let fallbackTime = ContinuousClock.now + fallbackDelay
            var usedFallback = false
            while true {
                guard !Task.isCancelled, shouldContinue() else { return .cancelled }
                let current = state()
                guard !current.isTerminated else { return .unavailable }
                if ready(current) { return .succeeded }
                guard ContinuousClock.now < deadline else { return .failed }
                if allowFallback, !usedFallback, ContinuousClock.now >= fallbackTime, let fallbackRequest {
                    // An accepted native request is not proof of activation. Try
                    // the alternate mechanism once, only while intent is current.
                    usedFallback = true
                    await fallbackRequest()
                    continue
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled, shouldContinue() else { return .cancelled }
        guard !state().isTerminated else { return .unavailable }
        if state().isHidden {
            await request(.unhide)
            let visible = await wait { !$0.isHidden }
            guard visible == .succeeded else { return visible }
        }
        guard !Task.isCancelled, shouldContinue() else { return .cancelled }
        if activateAllSpaces || !state().isFrontmost { await request(.activate) }
        return await wait(allowFallback: true) { !$0.isHidden && $0.isFrontmost }
    }
}
