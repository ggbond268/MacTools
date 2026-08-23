import Foundation

enum CLICommand: Equatable {
    case help
    case version(json: Bool)
    case request(operation: CLIOperation, payload: Data?, json: Bool)
    case actionRun(CLIActionRunArguments)
}

struct CLIActionRunArguments: Equatable {
    let operation: CLIOperation
    let target: String
    let rawParameters: [String: String]
    let inputJSONPath: String?
    let noWait: Bool
    let json: Bool
}

enum CLIArgumentError: Error, Equatable {
    case invalidCommand
    case missingArgument(String)
    case invalidActionKey
    case duplicateParameter(String)
    case conflictingParameterSources
    case unexpectedArgument(String)
}

struct CLIArgumentParser {
    func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help }
        if first == "help" || first == "--help" || first == "-h" { return .help }
        if first == "version" {
            return .version(json: try onlyJSONFlag(Array(arguments.dropFirst())))
        }
        if first == "doctor" {
            return try simpleRequest(.doctor, arguments: Array(arguments.dropFirst()))
        }
        guard arguments.count >= 2 else { throw CLIArgumentError.invalidCommand }
        switch (first, arguments[1]) {
        case ("actions", "list"):
            var runnableOnly = false
            var json = false
            var continuationToken: String?
            var index = 2
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--runnable": runnableOnly = true; index += 1
                case "--json": json = true; index += 1
                case "--page-token":
                    guard index + 1 < arguments.count, continuationToken == nil else {
                        throw CLIArgumentError.missingArgument("page token")
                    }
                    continuationToken = arguments[index + 1]
                    index += 2
                default: throw CLIArgumentError.unexpectedArgument(argument)
                }
            }
            return try request(
                .actionsList,
                payload: CLIActionListRequest(
                    runnableOnly: runnableOnly,
                    continuationToken: continuationToken
                ),
                json: json
            )
        case ("actions", "describe"):
            return try actionTargetRequest(.actionsDescribe, arguments: Array(arguments.dropFirst(2)))
        case ("actions", "availability"):
            return try actionTargetRequest(.actionsAvailability, arguments: Array(arguments.dropFirst(2)))
        case ("actions", "run"):
            return try runArguments(.actionsRun, arguments: Array(arguments.dropFirst(2)))
        case ("workflows", "list"):
            return try listRequest(.workflowsList, arguments: Array(arguments.dropFirst(2)))
        case ("workflows", "describe"):
            return try workflowTargetRequest(.workflowsDescribe, arguments: Array(arguments.dropFirst(2)))
        case ("workflows", "run"):
            return try runArguments(.workflowsRun, arguments: Array(arguments.dropFirst(2)))
        case ("plugins", "list"):
            return try listRequest(.pluginsList, arguments: Array(arguments.dropFirst(2)))
        case ("plugins", "describe"):
            return try pluginTargetRequest(.pluginsDescribe, arguments: Array(arguments.dropFirst(2)))
        case ("plugins", "doctor"):
            return try pluginTargetRequest(.pluginsDoctor, arguments: Array(arguments.dropFirst(2)))
        default:
            throw CLIArgumentError.invalidCommand
        }
    }

    private func simpleRequest(_ operation: CLIOperation, arguments: [String]) throws -> CLICommand {
        .request(operation: operation, payload: nil, json: try onlyJSONFlag(arguments))
    }

    private func listRequest(_ operation: CLIOperation, arguments: [String]) throws -> CLICommand {
        var json = false
        var continuationToken: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                json = true
                index += 1
            case "--page-token":
                guard index + 1 < arguments.count, continuationToken == nil else {
                    throw CLIArgumentError.missingArgument("page token")
                }
                continuationToken = arguments[index + 1]
                index += 2
            default:
                throw CLIArgumentError.unexpectedArgument(arguments[index])
            }
        }
        return try request(
            operation,
            payload: CLIListRequest(continuationToken: continuationToken),
            json: json
        )
    }

    private func actionTargetRequest(
        _ operation: CLIOperation,
        arguments: [String]
    ) throws -> CLICommand {
        let parsed = try targetAndJSON(arguments, targetName: "action")
        guard let key = CLIActionKey(id: parsed.target) else {
            throw CLIArgumentError.invalidActionKey
        }
        return try request(
            operation,
            payload: CLIActionTargetRequest(key: key),
            json: parsed.json
        )
    }

    private func workflowTargetRequest(
        _ operation: CLIOperation,
        arguments: [String]
    ) throws -> CLICommand {
        let parsed = try targetAndJSON(arguments, targetName: "workflow")
        return try request(
            operation,
            payload: CLIWorkflowTargetRequest(nameOrID: parsed.target),
            json: parsed.json
        )
    }

    private func pluginTargetRequest(
        _ operation: CLIOperation,
        arguments: [String]
    ) throws -> CLICommand {
        let parsed = try targetAndJSON(arguments, targetName: "plugin")
        return try request(
            operation,
            payload: CLIPluginTargetRequest(pluginID: parsed.target),
            json: parsed.json
        )
    }

    private func targetAndJSON(
        _ arguments: [String],
        targetName: String
    ) throws -> (target: String, json: Bool) {
        guard let target = arguments.first, !target.hasPrefix("--") else {
            throw CLIArgumentError.missingArgument(targetName)
        }
        let json = try onlyJSONFlag(Array(arguments.dropFirst()))
        return (target, json)
    }

    private func runArguments(
        _ operation: CLIOperation,
        arguments: [String]
    ) throws -> CLICommand {
        guard let target = arguments.first, !target.hasPrefix("--") else {
            throw CLIArgumentError.missingArgument(operation == .actionsRun ? "action" : "workflow")
        }
        if operation == .actionsRun, CLIActionKey(id: target) == nil {
            throw CLIArgumentError.invalidActionKey
        }
        var parameters: [String: String] = [:]
        var inputJSONPath: String?
        var noWait = false
        var json = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--parameter":
                guard operation == .actionsRun else {
                    throw CLIArgumentError.unexpectedArgument(argument)
                }
                guard index + 1 < arguments.count else {
                    throw CLIArgumentError.missingArgument("name=value")
                }
                let pair = arguments[index + 1]
                guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                    throw CLIArgumentError.missingArgument("name=value")
                }
                let name = String(pair[..<separator])
                let value = String(pair[pair.index(after: separator)...])
                guard parameters[name] == nil else {
                    throw CLIArgumentError.duplicateParameter(name)
                }
                parameters[name] = value
                index += 2
            case "--input-json":
                guard operation == .actionsRun else {
                    throw CLIArgumentError.unexpectedArgument(argument)
                }
                guard index + 1 < arguments.count else {
                    throw CLIArgumentError.missingArgument("input JSON path")
                }
                guard inputJSONPath == nil else {
                    throw CLIArgumentError.duplicateParameter("--input-json")
                }
                inputJSONPath = arguments[index + 1]
                index += 2
            case "--no-wait":
                noWait = true
                index += 1
            case "--json":
                json = true
                index += 1
            default:
                throw CLIArgumentError.unexpectedArgument(argument)
            }
        }
        guard parameters.isEmpty || inputJSONPath == nil else {
            throw CLIArgumentError.conflictingParameterSources
        }
        return .actionRun(CLIActionRunArguments(
            operation: operation,
            target: target,
            rawParameters: parameters,
            inputJSONPath: inputJSONPath,
            noWait: noWait,
            json: json
        ))
    }

    private func onlyJSONFlag(_ arguments: [String]) throws -> Bool {
        guard arguments.allSatisfy({ $0 == "--json" }), arguments.count <= 1 else {
            throw CLIArgumentError.unexpectedArgument(
                arguments.first(where: { $0 != "--json" }) ?? "--json"
            )
        }
        return arguments.first == "--json"
    }

    private func request<T: Encodable>(
        _ operation: CLIOperation,
        payload: T,
        json: Bool
    ) throws -> CLICommand {
        .request(
            operation: operation,
            payload: try CLIProtocolCodec.encodeRequest(payload),
            json: json
        )
    }
}
