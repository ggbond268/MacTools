import Foundation
import MacToolsCLIProtocol

enum CLICommand: Equatable {
    case help
    case version(json: Bool)
    case doctor(json: Bool)
    case discovery(operation: CLIOperation, payload: Data, json: Bool)
}

enum CLIArgumentError: Error, Equatable {
    case invalidCommand
}

struct CLIArgumentParser {
    func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { return .help }
        if command == "help" || command == "--help" || command == "-h" {
            guard arguments.count == 1 else { throw CLIArgumentError.invalidCommand }
            return .help
        }
        if command == "actions" { return try discovery(Array(arguments.dropFirst())) }
        let json = try jsonFlag(Array(arguments.dropFirst()))
        switch command {
        case "version": return .version(json: json)
        case "doctor": return .doctor(json: json)
        default: throw CLIArgumentError.invalidCommand
        }
    }

    private func discovery(_ arguments: [String]) throws -> CLICommand {
        guard let verb = arguments.first else { throw CLIArgumentError.invalidCommand }
        var remaining = Array(arguments.dropFirst())
        let json = remaining.contains("--json")
        guard remaining.filter({ $0 == "--json" }).count <= 1 else { throw CLIArgumentError.invalidCommand }
        remaining.removeAll { $0 == "--json" }
        if verb == "list" {
            var pageSize = CLIDiscoveryLimits.defaultPageSize
            var cursor: String?
            var seen = Set<String>()
            while !remaining.isEmpty {
                let flag = remaining.removeFirst()
                guard seen.insert(flag).inserted, !remaining.isEmpty else { throw CLIArgumentError.invalidCommand }
                let value = remaining.removeFirst()
                switch flag {
                case "--page-size":
                    guard let size = Int(value), String(size) == value else { throw CLIArgumentError.invalidCommand }
                    pageSize = size
                case "--cursor": cursor = value
                default: throw CLIArgumentError.invalidCommand
                }
            }
            let request = CLIActionListRequest(pageSize: pageSize, cursor: cursor)
            try CLIDiscoveryValidation.validate(request)
            return .discovery(operation: .actionsList, payload: try CLIProtocolCodec.encodeRequest(request), json: json)
        }
        guard remaining.count == 1, verb == "describe" || verb == "availability" else {
            throw CLIArgumentError.invalidCommand
        }
        let request = CLIActionTargetRequest(id: remaining[0])
        try CLIDiscoveryValidation.validate(request)
        return .discovery(operation: verb == "describe" ? .actionsDescribe : .actionsAvailability,
                          payload: try CLIProtocolCodec.encodeRequest(request), json: json)
    }

    private func jsonFlag(_ arguments: [String]) throws -> Bool {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CLIArgumentError.invalidCommand
        }
        return !arguments.isEmpty
    }
}
