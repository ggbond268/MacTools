import Foundation

public enum CLIProtocolCodecError: Error, Equatable {
    case payloadTooLarge
    case responseTooLarge
    case invalidObject
    case unknownFields([String])
    case duplicateFields([String])
    case encodingFailed
}

public enum CLIProtocolCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(format))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let timeSeparator = value.firstIndex(of: "T"),
                  value[value.index(after: timeSeparator)...].contains("."),
                  let date = try? format.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 timestamp with fractional seconds."
                )
            }
            return date
        }
        return decoder
    }

    public static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    public static func encodeRequest<T: Encodable>(_ value: T) throws -> Data {
        let data = try makeEncoder().encode(value)
        guard data.count <= CLIProtocolVersion.maximumRequestBytes else {
            throw CLIProtocolCodecError.payloadTooLarge
        }
        return data
    }

    public static func encodeResponse<T: Encodable>(_ value: T) throws -> Data {
        let data = try makeEncoder().encode(value)
        guard data.count <= CLIProtocolVersion.maximumResponseBytes else {
            throw CLIProtocolCodecError.responseTooLarge
        }
        return data
    }

    public static func decodeRequest<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        allowedKeys: Set<String>? = nil
    ) throws -> T {
        guard data.count <= CLIProtocolVersion.maximumRequestBytes else {
            throw CLIProtocolCodecError.payloadTooLarge
        }
        if let allowedKeys {
            try rejectUnknownFields(in: data, allowedKeys: allowedKeys)
        }
        return try makeDecoder().decode(type, from: data)
    }

    public static func decodeResponse<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        allowedKeys: Set<String>? = nil
    ) throws -> T {
        guard data.count <= CLIProtocolVersion.maximumResponseBytes else {
            throw CLIProtocolCodecError.responseTooLarge
        }
        if let allowedKeys {
            try rejectUnknownFields(in: data, allowedKeys: allowedKeys)
        }
        return try makeDecoder().decode(type, from: data)
    }

    public static func rejectDuplicateTopLevelFields(in data: Data) throws {
        let duplicates = Dictionary(grouping: try topLevelKeys(in: data), by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        guard duplicates.isEmpty else {
            throw CLIProtocolCodecError.duplicateFields(duplicates)
        }
    }

    public static func rejectDuplicateFieldsRecursively(in data: Data) throws {
        var scanner = CLIJSONDuplicateFieldScanner(data: data)
        try scanner.scan()
    }

    public static func validateResponseEnvelopeShape(in data: Data) throws {
        try rejectDuplicateFieldsRecursively(in: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CLIProtocolCodecError.invalidObject }
        guard let rejection = object["rejection"] else { return }
        if rejection is NSNull { return }
        guard let rejection = rejection as? [String: Any] else {
            throw CLIProtocolCodecError.invalidObject
        }
        let unknown = Set(rejection.keys).subtracting(["category", "message"]).sorted()
        guard unknown.isEmpty else {
            throw CLIProtocolCodecError.unknownFields(unknown)
        }
    }

    private static func rejectUnknownFields(in data: Data, allowedKeys: Set<String>) throws {
        try rejectDuplicateTopLevelFields(in: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIProtocolCodecError.invalidObject
        }
        let unknown = Set(object.keys).subtracting(allowedKeys).sorted()
        guard unknown.isEmpty else {
            throw CLIProtocolCodecError.unknownFields(unknown)
        }
    }

    private static func topLevelKeys(in data: Data) throws -> [String] {
        let bytes = Array(data)
        var keys: [String] = []
        var objectDepth = 0
        var arrayDepth = 0
        var expectingKey = false
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: // {
                objectDepth += 1
                if objectDepth == 1 { expectingKey = true }
                index += 1
            case 0x7D: // }
                objectDepth -= 1
                index += 1
            case 0x5B: // [
                arrayDepth += 1
                index += 1
            case 0x5D: // ]
                arrayDepth -= 1
                index += 1
            case 0x2C where objectDepth == 1 && arrayDepth == 0: // ,
                expectingKey = true
                index += 1
            case 0x22: // "
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    let byte = bytes[index]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        break
                    }
                    index += 1
                }
                guard index < bytes.count else { throw CLIProtocolCodecError.invalidObject }
                if objectDepth == 1, arrayDepth == 0, expectingKey {
                    let quoted = Data(bytes[start...index])
                    guard let key = try? makeDecoder().decode(String.self, from: quoted) else {
                        throw CLIProtocolCodecError.invalidObject
                    }
                    keys.append(key)
                    expectingKey = false
                }
                index += 1
            default:
                index += 1
            }
            guard objectDepth >= 0, arrayDepth >= 0 else {
                throw CLIProtocolCodecError.invalidObject
            }
        }
        return keys
    }
}

private struct CLIJSONDuplicateFieldScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func scan() throws {
        skipWhitespace()
        try scanValue()
        skipWhitespace()
        guard index == bytes.count else { throw CLIProtocolCodecError.invalidObject }
    }

    private mutating func scanValue() throws {
        skipWhitespace()
        guard index < bytes.count else { throw CLIProtocolCodecError.invalidObject }
        switch bytes[index] {
        case 0x7B: try scanObject() // {
        case 0x5B: try scanArray() // [
        case 0x22: _ = try scanString() // "
        default: try scanPrimitive()
        }
    }

    private mutating func scanObject() throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw CLIProtocolCodecError.invalidObject
            }
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw CLIProtocolCodecError.duplicateFields([key])
            }
            skipWhitespace()
            guard consume(0x3A) else { throw CLIProtocolCodecError.invalidObject } // :
            try scanValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw CLIProtocolCodecError.invalidObject } // ,
        }
    }

    private mutating func scanArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try scanValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw CLIProtocolCodecError.invalidObject }
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let quoted = Data(bytes[start...index])
                index += 1
                guard let value = try? JSONDecoder().decode(String.self, from: quoted) else {
                    throw CLIProtocolCodecError.invalidObject
                }
                return value
            }
            index += 1
        }
        throw CLIProtocolCodecError.invalidObject
    }

    private mutating func scanPrimitive() throws {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw CLIProtocolCodecError.invalidObject }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
