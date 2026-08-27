import Dispatch
import Foundation
import MacToolsCLIProtocol

let broker = CLIBroker()
let listener = NSXPCListener(machServiceName: CLIServiceConfiguration.runtimeBrokerServiceName)
guard let requirement = CLIPeerIdentityValidator().brokerListenerRequirement() else {
    exit(CLIExitCode.transportFailure.rawValue)
}
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = broker
listener.resume()
dispatchMain()
