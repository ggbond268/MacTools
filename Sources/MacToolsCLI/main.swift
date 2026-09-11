import Darwin
import Foundation

let exitCode = await CLIApplication(client: CLIBrokerClient()).run(
    arguments: Array(CommandLine.arguments.dropFirst())
)
exit(exitCode)
