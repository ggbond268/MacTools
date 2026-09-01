import Foundation
import MacToolsCLIProtocol

struct CLIApplication {
    let client: CLIBrokerClient
    private let output = CLIOutput()

    func run(arguments: [String]) async -> Int32 {
        let jsonRequested = arguments.contains("--json")
        let command: CLICommand
        do {
            command = try CLIArgumentParser().parse(arguments)
        } catch {
            writeFailure(
                output.localFailure(
                    command: arguments.first ?? "unknown",
                    outcome: .invalidInput,
                    category: "invalidCommand",
                    message: "Invalid command. Run 'mactools help' for usage.",
                    json: jsonRequested
                ),
                json: jsonRequested
            )
            return CLIExitCode.invalidInput.rawValue
        }

        switch command {
        case .help:
            write(helpText)
            return CLIExitCode.success.rawValue
        case let .version(json):
            let handshake = try? await client.handshakeWithoutHostLaunch()
            do {
                write(try output.renderVersion(
                    cli: client.version(),
                    handshake: handshake,
                    json: json
                ))
                return CLIExitCode.success.rawValue
            } catch {
                writeFailure("MacTools CLI could not render version output.", json: json)
                return CLIExitCode.transportFailure.rawValue
            }
        case let .doctor(json):
            return await interruptibleRequest(operation: .doctor, payload: nil, json: json)
        case let .discovery(operation, payload, json):
            return await interruptibleRequest(operation: operation, payload: payload, json: json)
        }
    }

    private func interruptibleRequest(operation: CLIOperation, payload: Data?, json: Bool) async -> Int32 {
        let taskState = CLICommandTaskState()
        let signalCoordinator = CLISignalCoordinator { taskState.cancel() }
        defer { signalCoordinator.finish() }
        let task = Task { try await request(operation: operation, payload: payload, json: json) }
        taskState.install(task)
        do {
            return try await task.value
        } catch is CancellationError {
            writeFailure(output.localFailure(
                command: operation.rawValue,
                outcome: .cancelled,
                category: "cancelled",
                message: "The request was cancelled.",
                json: json
            ), json: json)
            return CLIExitCode.cancellation.rawValue
        } catch CLIBrokerClientError.protocolIncompatible {
            writeFailure(output.localFailure(
                command: operation.rawValue,
                outcome: .protocolIncompatible,
                category: "protocolIncompatible",
                message: "The CLI protocol is incompatible with the installed MacTools components.",
                json: json
            ), json: json)
            return CLIExitCode.protocolIncompatible.rawValue
        } catch CLIBrokerClientError.invalidPeerResponse {
            writeFailure(output.localFailure(
                command: operation.rawValue,
                outcome: .protocolIncompatible,
                category: "invalidPeerResponse",
                message: "The authenticated broker or host returned an invalid response.",
                json: json
            ), json: json)
            return CLIExitCode.protocolIncompatible.rawValue
        } catch let CLIBrokerClientError.unavailable(message) {
            writeFailure(output.localFailure(
                command: operation.rawValue,
                outcome: .hostUnavailable,
                category: "hostUnavailable",
                message: message,
                json: json
            ), json: json)
            return CLIExitCode.transportFailure.rawValue
        } catch {
            writeFailure(output.localFailure(
                command: operation.rawValue,
                outcome: .hostUnavailable,
                category: "hostUnavailable",
                message: "MacTools command-line integration is unavailable.",
                json: json
            ), json: json)
            return CLIExitCode.transportFailure.rawValue
        }
    }

    private func request(operation: CLIOperation, payload: Data?, json: Bool) async throws -> Int32 {
        let deadline = CLIStartupDeadline(timeout: .seconds(10))
        let handshake = try await client.prepareHost(deadline: deadline)
        let response = try await client.send(operation: operation, payload: payload, deadline: deadline)
        let rendered: String
        if response.outcome == .completed {
            do {
                if operation == .doctor {
                    rendered = try output.renderDoctor(response, handshake: handshake, json: json)
                } else {
                    guard let payload else { throw CLIBrokerClientError.invalidPeerResponse }
                    rendered = try output.renderDiscovery(response, requestPayload: payload, json: json)
                }
            } catch {
                throw CLIBrokerClientError.invalidPeerResponse
            }
        } else {
            rendered = try output.renderFailure(response, json: json)
        }
        let code = exitCode(for: response.outcome)
        if code == .success {
            write(rendered)
        } else {
            writeFailure(rendered, json: json)
        }
        return code.rawValue
    }

    private func exitCode(for outcome: CLIOutcome) -> CLIExitCode {
        switch outcome {
        case .completed: .success
        case .cancelled: .cancellation
        case .invalidInput: .invalidInput
        case .unknownTarget: .unknownTarget
        case .hostUnavailable: .transportFailure
        case .protocolIncompatible: .protocolIncompatible
        }
    }

    private func write(_ value: String) {
        FileHandle.standardOutput.write(Data("\(value)\n".utf8))
    }

    private func writeFailure(_ value: String, json: Bool) {
        let handle = json ? FileHandle.standardOutput : FileHandle.standardError
        handle.write(Data("\(value)\n".utf8))
    }

    private var helpText: String {
        """
        Usage: mactools <command> [options]

          help
          version [--json]
          doctor [--json]
          actions list [--page-size 1...100] [--cursor <cursor>] [--json]
          actions describe <id-from-list> [--json]
          actions availability <id-from-list> [--json]

        Discovery is read-only. Action execution and parameter input are not supported.
        """
    }
}
