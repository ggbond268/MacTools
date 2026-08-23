import Foundation

let broker = CLIBroker()
let listener = NSXPCListener(machServiceName: CLIServiceConfiguration.runtimeServiceName)
#if !DEBUG
guard let requirement = CLIPeerIdentityValidator().brokerListenerRequirement() else {
    exit(CLIExitCode.transportFailure.rawValue)
}
listener.setConnectionCodeSigningRequirement(requirement)
#endif
listener.delegate = broker
listener.resume()
