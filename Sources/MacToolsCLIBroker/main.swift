import Dispatch
import Foundation

let broker = CLIBroker()
let listener = NSXPCListener(machServiceName: CLIServiceConfiguration.runtimeBrokerServiceName)
guard let requirement = CLIPeerIdentityValidator().brokerListenerRequirement() else {
    exit(CLIExitCode.transportFailure.rawValue)
}
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = broker
listener.resume()

// A standalone LaunchAgent does not get the implicit process lifetime of an XPC service bundle.
// Keep its dispatch-backed XPC listener alive after the top-level entry point finishes setup.
dispatchMain()
