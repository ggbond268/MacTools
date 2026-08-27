import Foundation

enum CLICommand: Equatable {
    case help
    case version(json: Bool)
    case doctor(json: Bool)
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
        let json = try jsonFlag(Array(arguments.dropFirst()))
        switch command {
        case "version": return .version(json: json)
        case "doctor": return .doctor(json: json)
        default: throw CLIArgumentError.invalidCommand
        }
    }

    private func jsonFlag(_ arguments: [String]) throws -> Bool {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CLIArgumentError.invalidCommand
        }
        return !arguments.isEmpty
    }
}
