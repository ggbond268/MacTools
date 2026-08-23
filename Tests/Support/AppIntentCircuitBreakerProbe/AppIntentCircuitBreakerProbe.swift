import Darwin
import Foundation

@main
struct AppIntentCircuitBreakerProbe {
    static func main() async {
        guard CommandLine.arguments.count == 7,
              let window = TimeInterval(CommandLine.arguments[3]),
              let perActionLimit = Int(CommandLine.arguments[4]),
              let globalLimit = Int(CommandLine.arguments[5])
        else {
            exit(64)
        }

        let barrierURL = URL(fileURLWithPath: CommandLine.arguments[6])
        let readyURL = URL(fileURLWithPath: "\(barrierURL.path).\(getpid()).ready")
        _ = FileManager.default.createFile(atPath: readyURL.path, contents: Data())
        let barrierDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: barrierURL.path),
              Date() < barrierDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard FileManager.default.fileExists(atPath: barrierURL.path) else {
            exit(75)
        }

        let breaker = MacToolsAppIntentCircuitBreaker(
            stateURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            window: window,
            maximumInvocationCountPerAction: perActionLimit,
            maximumGlobalInvocationCount: globalLimit
        )
        let admission = await breaker.admitInvocation(
            actionIdentifier: CommandLine.arguments[2]
        )
        switch admission {
        case .admitted:
            print("admitted")
        case .rateLimited:
            print("rate-limited")
        case .unavailable:
            print("unavailable")
        }
    }
}
