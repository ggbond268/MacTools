import Foundation

struct CLIApplication {
    let client: CLIBrokerClient
    let output = CLIOutput()

    func run(arguments: [String]) async -> Int32 {
        let jsonRequested = arguments.contains("--json")
        let command: CLICommand
        do {
            command = try CLIArgumentParser().parse(arguments)
        } catch {
            emitLocalFailure(
                command: commandName(arguments),
                outcome: .invalidInput,
                category: "invalidCommand",
                message: "Invalid command. Run 'mactools help' for usage.",
                json: jsonRequested
            )
            return CLIExitCode.invalidInput.rawValue
        }
        do {
            switch command {
            case .help:
                write(helpText)
                return CLIExitCode.success.rawValue
            case let .version(json):
                return try await version(json: json)
            case let .request(operation, payload, json):
                if operation == .doctor {
                    return try await doctor(payload: payload, json: json)
                }
                _ = try await client.prepareHost()
                return try await execute(operation: operation, payload: payload, json: json)
            case let .actionRun(arguments):
                _ = try await client.prepareHost()
                return try await executeRun(arguments)
            }
        } catch CLIBrokerClientError.protocolIncompatible {
            emitLocalFailure(
                command: commandName(arguments),
                outcome: .protocolIncompatible,
                category: "protocolIncompatible",
                message: "The MacTools CLI protocol is incompatible with the installed app.",
                json: jsonRequested
            )
            return CLIExitCode.protocolIncompatible.rawValue
        } catch let CLIBrokerClientError.unavailable(message) {
            emitLocalFailure(
                command: commandName(arguments),
                outcome: .hostUnavailable,
                category: "hostTransportFailure",
                message: message,
                json: jsonRequested
            )
            return CLIExitCode.transportFailure.rawValue
        } catch let error where error is CLIArgumentError
            || error is CLIParameterInputError
            || error is CLIProtocolCodecError {
            emitLocalFailure(
                command: commandName(arguments),
                outcome: .invalidInput,
                category: "invalidInput",
                message: "The command input is invalid.",
                json: jsonRequested
            )
            return CLIExitCode.invalidInput.rawValue
        } catch {
            emitLocalFailure(
                command: commandName(arguments),
                outcome: .failed,
                category: "cliFailure",
                message: "MacTools CLI failed: \(error.localizedDescription)",
                json: jsonRequested
            )
            return CLIExitCode.actionFailure.rawValue
        }
    }

    private func version(json: Bool) async throws -> Int32 {
        let version = client.containingAppVersion()
        let handshake = try? await client.handshakeWithoutLaunching()
        if json {
            let object: [String: Any] = [
                "cliVersion": version.version,
                "cliBuild": version.build,
                "brokerVersion": handshake.map { $0.brokerVersion as Any } ?? NSNull(),
                "brokerBuild": handshake.map { $0.brokerBuild as Any } ?? NSNull(),
                "hostVersion": handshake?.hostVersion.map { $0 as Any } ?? NSNull(),
                "hostBuild": handshake?.hostBuild.map { $0 as Any } ?? NSNull(),
                "protocolVersion": handshake?.selectedProtocolVersion.map { $0 as Any } ?? NSNull(),
            ]
            write(try output.renderLocal(
                command: "version",
                outcome: .completed,
                message: nil,
                rejectionCategory: nil,
                data: object,
                protocolVersion: handshake?.selectedProtocolVersion
            ))
        } else {
            var lines = ["mactools \(version.version) (\(version.build))"]
            if let handshake {
                lines.append("broker \(handshake.brokerVersion) (\(handshake.brokerBuild))")
                if let hostVersion = handshake.hostVersion, let hostBuild = handshake.hostBuild {
                    lines.append("host \(hostVersion) (\(hostBuild))")
                }
                if let protocolVersion = handshake.selectedProtocolVersion {
                    lines.append("protocol \(protocolVersion)")
                }
            }
            write(lines.joined(separator: "\n"))
        }
        return CLIExitCode.success.rawValue
    }

    private func doctor(payload: Data?, json: Bool) async throws -> Int32 {
        do {
            _ = try await client.prepareHost()
            return try await execute(operation: .doctor, payload: payload, json: json)
        } catch let CLIBrokerClientError.unavailable(message) {
            let applicationURL = CLIServiceConfiguration.containingApplicationURL()
            let signatureAccepted = applicationURL.map {
                CLIPeerIdentityValidator().acceptsApplication(at: $0, as: .host)
            } ?? false
            let guidance = "Open System Settings > General > Login Items & Extensions and allow the MacTools background item, then retry."
            if json {
                write(try output.renderLocal(
                    command: "doctor",
                    outcome: .hostUnavailable,
                    message: message,
                    rejectionCategory: "brokerUnavailableOrApprovalRequired",
                    data: [
                        "containingAppPath": applicationURL?.path as Any? ?? NSNull(),
                        "containingAppSignatureAccepted": signatureAccepted,
                        "brokerServiceName": CLIServiceConfiguration.runtimeServiceName,
                        "brokerStatus": "unreachableOrApprovalRequired",
                        "guidance": guidance,
                    ]
                ))
            } else {
                writeError([message, guidance].joined(separator: "\n"))
            }
            return CLIExitCode.transportFailure.rawValue
        }
    }

    private func executeRun(_ arguments: CLIActionRunArguments) async throws -> Int32 {
        if arguments.operation == .workflowsRun {
            let payload = try CLIProtocolCodec.encodeRequest(CLIWorkflowRunRequest(
                nameOrID: arguments.target,
                noWait: arguments.noWait
            ))
            return try await execute(operation: .workflowsRun, payload: payload, json: arguments.json)
        }
        guard let key = CLIActionKey(id: arguments.target) else {
            throw CLIArgumentError.invalidActionKey
        }
        let values: [String: CLIParameterValue]
        let source: CLIParameterInputSource
        if let path = arguments.inputJSONPath {
            let parsed = try CLIParameterInput().json(path: path)
            values = parsed.values
            source = parsed.source
        } else if !arguments.rawParameters.isEmpty {
            let describePayload = try CLIProtocolCodec.encodeRequest(CLIActionTargetRequest(key: key))
            let describe = try await client.send(operation: .actionsDescribe, payload: describePayload)
            guard describe.outcome == .completed, let payload = describe.payload else {
                return try emit(
                    describe.replacingOperation(.actionsRun),
                    json: arguments.json
                )
            }
            let action = try CLIProtocolCodec.decodeResponse(CLIActionRecord.self, from: payload)
            values = try CLIParameterInput().arguments(
                arguments.rawParameters,
                definitions: action.parameters
            )
            source = .arguments
        } else {
            values = [:]
            source = .arguments
        }
        let payload = try CLIProtocolCodec.encodeRequest(CLIActionRunRequest(
            key: key,
            parameters: values,
            inputSource: source,
            noWait: arguments.noWait
        ))
        return try await execute(operation: .actionsRun, payload: payload, json: arguments.json)
    }

    private func execute(operation: CLIOperation, payload: Data?, json: Bool) async throws -> Int32 {
        let requestID = UUID()
        let signalCoordinator = CLISignalCoordinator { [client] in
            Task { _ = await client.cancel(requestID: requestID) }
        }
        _ = signalCoordinator
        let response = try await client.send(
            operation: operation,
            payload: payload,
            requestID: requestID
        )
        return try emit(response, json: json)
    }

    private func emit(_ response: CLIResponseEnvelope, json: Bool) throws -> Int32 {
        let rendered = try output.render(response, json: json)
        if output.exitCode(for: response) == .success {
            write(rendered)
        } else {
            if json { write(rendered) } else { writeError(rendered) }
        }
        return output.exitCode(for: response).rawValue
    }

    private func write(_ string: String) {
        FileHandle.standardOutput.write(Data("\(string)\n".utf8))
    }

    private func writeError(_ string: String) {
        FileHandle.standardError.write(Data("\(string)\n".utf8))
    }

    private func emitLocalFailure(
        command: String,
        outcome: CLIOutcome,
        category: String,
        message: String,
        json: Bool
    ) {
        if json,
           let rendered = try? output.renderLocal(
               command: command,
               outcome: outcome,
               message: message,
               rejectionCategory: category
           ) {
            write(rendered)
        } else {
            writeError(message)
        }
    }

    private func commandName(_ arguments: [String]) -> String {
        let parts = arguments.prefix(2).filter { !$0.hasPrefix("-") }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ".")
    }

    private var helpText: String {
        """
        Usage: mactools <command> [options]

          version [--json]
          doctor [--json]
          actions list [--runnable] [--page-token token] [--json]
          actions describe <provider/action> [--json]
          actions availability <provider/action> [--json]
          actions run <provider/action> [--parameter name=value ...]
              [--input-json <path|->] [--no-wait] [--json]
          workflows list [--page-token token] [--json]
          workflows describe <name-or-id> [--json]
          workflows run <name-or-id> [--no-wait] [--json]
          plugins list [--page-token token] [--json]
          plugins describe <plugin-id> [--json]
          plugins doctor <plugin-id> [--json]
        """
    }
}
