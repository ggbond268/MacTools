import Darwin
import CoreFoundation
import Foundation

enum CLIParameterInputError: Error, Equatable {
    case unknownParameter(String)
    case invalidValue(String)
    case sensitiveArgument(String)
    case invalidJSON
    case invalidFile
    case insecureFile
    case oversizedInput
}

struct CLIParameterInput {
    func arguments(
        _ values: [String: String],
        definitions: [CLIActionParameter]
    ) throws -> [String: CLIParameterValue] {
        let definitionsByID = try definitionsByID(definitions)
        return try values.mapValuesWithKeys { name, rawValue in
            guard let definition = definitionsByID[name] else {
                throw CLIParameterInputError.unknownParameter(name)
            }
            guard definition.privacy != "sensitive" else {
                throw CLIParameterInputError.sensitiveArgument(name)
            }
            return try parse(rawValue, kind: definition.kind, name: name)
        }
    }

    func json(
        path: String,
        definitions: [CLIActionParameter]
    ) throws -> (values: [String: CLIParameterValue], source: CLIParameterInputSource) {
        let data: Data
        let source: CLIParameterInputSource
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
            source = .standardInput
        } else {
            data = try protectedFileData(path: path)
            source = .protectedFile
        }
        guard data.count <= CLIProtocolVersion.maximumRequestBytes else {
            throw CLIParameterInputError.oversizedInput
        }
        do {
            try CLIProtocolCodec.rejectDuplicateTopLevelFields(in: data)
        } catch {
            throw CLIParameterInputError.invalidJSON
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIParameterInputError.invalidJSON
        }
        let definitionsByID = try definitionsByID(definitions)
        var values: [String: CLIParameterValue] = [:]
        for (name, value) in object {
            guard values[name] == nil else { throw CLIParameterInputError.invalidJSON }
            guard let definition = definitionsByID[name] else {
                throw CLIParameterInputError.unknownParameter(name)
            }
            switch definition.kind {
            case "string":
                guard let value = value as? String else {
                    throw CLIParameterInputError.invalidValue(name)
                }
                values[name] = .string(value)
            case "boolean":
                guard let value = value as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw CLIParameterInputError.invalidValue(name)
                }
                values[name] = .boolean(value.boolValue)
            case "integer":
                guard let value = value as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID() else {
                    throw CLIParameterInputError.invalidValue(name)
                }
                let decimal = value.decimalValue
                var rounded = Decimal()
                var decimalToRound = decimal
                NSDecimalRound(&rounded, &decimalToRound, 0, .plain)
                guard rounded == decimal,
                      decimal >= Decimal(Int64.min), decimal <= Decimal(Int64.max) else {
                    throw CLIParameterInputError.invalidValue(name)
                }
                values[name] = .integer(NSDecimalNumber(decimal: decimal).int64Value)
            case "double":
                guard let value = value as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID() else {
                    throw CLIParameterInputError.invalidValue(name)
                }
                let double = value.doubleValue
                guard double.isFinite else { throw CLIParameterInputError.invalidValue(name) }
                values[name] = .double(double)
            default:
                throw CLIParameterInputError.invalidValue(name)
            }
        }
        return (values, source)
    }

    private func definitionsByID(
        _ definitions: [CLIActionParameter]
    ) throws -> [String: CLIActionParameter] {
        var values: [String: CLIActionParameter] = [:]
        for definition in definitions {
            guard values.updateValue(definition, forKey: definition.id) == nil else {
                throw CLIParameterInputError.invalidValue(definition.id)
            }
        }
        return values
    }

    private func protectedFileData(path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CLIParameterInputError.invalidFile }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw CLIParameterInputError.invalidFile
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else {
            throw CLIParameterInputError.insecureFile
        }
        guard metadata.st_size <= CLIProtocolVersion.maximumRequestBytes else {
            throw CLIParameterInputError.oversizedInput
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
    }

    private func parse(_ value: String, kind: String, name: String) throws -> CLIParameterValue {
        switch kind {
        case "string": return .string(value)
        case "integer":
            guard let parsed = Int64(value) else { throw CLIParameterInputError.invalidValue(name) }
            return .integer(parsed)
        case "double":
            guard let parsed = Double(value), parsed.isFinite else {
                throw CLIParameterInputError.invalidValue(name)
            }
            return .double(parsed)
        case "boolean":
            switch value.lowercased() {
            case "true", "1", "yes": return .boolean(true)
            case "false", "0", "no": return .boolean(false)
            default: throw CLIParameterInputError.invalidValue(name)
            }
        default:
            throw CLIParameterInputError.invalidValue(name)
        }
    }
}

extension Dictionary {
    func mapValuesWithKeys<T>(
        _ transform: (Key, Value) throws -> T
    ) rethrows -> [Key: T] {
        try Dictionary<Key, T>(uniqueKeysWithValues: map { key, value in
            (key, try transform(key, value))
        })
    }
}
