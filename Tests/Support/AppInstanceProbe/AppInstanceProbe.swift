import Foundation

@main
struct AppInstanceProbe {
    static func main() async {
        guard CommandLine.arguments.count >= 3 else {
            exit(64)
        }

        let namespace = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let coordinator = AppInstanceCoordinator(bundleIdentifier: namespace)
        await coordinator.setCommandHandler { _ in
            print("command-accepted")
            fflush(stdout)
            if mode == "unresponsive" {
                Thread.sleep(forTimeInterval: 5)
            }
            return .accepted
        }

        if await coordinator.claimPrimaryPortIfPossible() {
            print("primary")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(30))
            await coordinator.invalidate()
            return
        }

        let disposition = await coordinator.resolveSecondaryLaunch(requestSettings: false)
        switch disposition {
        case .primary:
            print("promoted")
        case .secondary(.acknowledged):
            print("secondary-acknowledged")
        case .secondary(.timedOut):
            print("secondary-timed-out")
        case .secondary(.rejected):
            print("secondary-rejected")
        }
        fflush(stdout)
        await coordinator.invalidate()
    }
}
