#!/usr/bin/env -S xcrun swift

import CryptoKit
import Foundation

private enum CatalogCryptoError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

private struct SignOptions {
    let inputURL: URL
    let outputURL: URL
}

private let privateKeyEnvironmentName = "PLUGIN_CATALOG_PRIVATE_KEY_BASE64"

private func fail(_ message: String) throws -> Never {
    throw CatalogCryptoError.message(message)
}

private func fileURL(for path: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
        .appendingPathComponent(path)
        .standardizedFileURL
}

private func requiredValue(
    for option: String,
    arguments: inout ArraySlice<String>
) throws -> String {
    guard let value = arguments.popFirst(), !value.isEmpty else {
        try fail("Missing value for \(option).")
    }
    return value
}

private func parseSignOptions(_ rawArguments: [String]) throws -> SignOptions {
    var arguments = rawArguments[...]
    var inputPath: String?
    var outputPath: String?

    while let option = arguments.popFirst() {
        switch option {
        case "--input":
            inputPath = try requiredValue(for: option, arguments: &arguments)
        case "--output":
            outputPath = try requiredValue(for: option, arguments: &arguments)
        default:
            try fail("Unknown sign option: \(option)")
        }
    }

    guard let inputPath, let outputPath else {
        try fail("sign requires --input and --output.")
    }
    return SignOptions(
        inputURL: fileURL(for: inputPath),
        outputURL: fileURL(for: outputPath)
    )
}

private func parsePublicKey(_ rawArguments: [String]) throws -> Curve25519.Signing.PublicKey {
    var arguments = rawArguments[...]
    var publicKeyBase64: String?

    while let option = arguments.popFirst() {
        switch option {
        case "--public-key-base64":
            publicKeyBase64 = try requiredValue(for: option, arguments: &arguments)
        default:
            try fail("Unknown verify-key-pair option: \(option)")
        }
    }

    guard let publicKeyBase64,
          let publicKeyData = Data(base64Encoded: publicKeyBase64)
    else {
        try fail("--public-key-base64 must contain a valid Base64-encoded Ed25519 public key.")
    }

    do {
        return try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    } catch {
        try fail("--public-key-base64 must contain a 32-byte Ed25519 public key.")
    }
}

private func privateKey() throws -> Curve25519.Signing.PrivateKey {
    guard let encodedKey = ProcessInfo.processInfo.environment[privateKeyEnvironmentName],
          !encodedKey.isEmpty,
          let keyData = Data(base64Encoded: encodedKey)
    else {
        try fail("\(privateKeyEnvironmentName) must contain a valid Base64-encoded Ed25519 private key.")
    }

    do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    } catch {
        try fail("\(privateKeyEnvironmentName) must contain a 32-byte Ed25519 private key.")
    }
}

private func catalogDictionary(from data: Data) throws -> [String: Any] {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        try fail("Input catalog is not valid JSON: \(error.localizedDescription)")
    }

    guard let dictionary = object as? [String: Any] else {
        try fail("Input catalog must contain a JSON object.")
    }
    return dictionary
}

private func canonicalPayload(from dictionary: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(dictionary) else {
        try fail("Input catalog contains unsupported JSON values.")
    }
    return try JSONSerialization.data(
        withJSONObject: dictionary,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func signCatalog(options: SignOptions) throws {
    let inputData: Data
    do {
        inputData = try Data(contentsOf: options.inputURL)
    } catch {
        try fail("Cannot read input catalog: \(error.localizedDescription)")
    }

    var catalog = try catalogDictionary(from: inputData)
    catalog.removeValue(forKey: "signature")
    let signature = try privateKey().signature(for: canonicalPayload(from: catalog))
    catalog["signature"] = [
        "algorithm": "ed25519",
        "value": signature.base64EncodedString(),
    ]

    var outputData = try JSONSerialization.data(
        withJSONObject: catalog,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    outputData.append(0x0A)

    let parentURL = options.outputURL.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        try outputData.write(to: options.outputURL, options: .atomic)
    } catch {
        try fail("Cannot write signed catalog: \(error.localizedDescription)")
    }
}

private func verifyKeyPair(publicKey: Curve25519.Signing.PublicKey) throws {
    let signingKey = try privateKey()
    guard signingKey.publicKey.rawRepresentation == publicKey.rawRepresentation else {
        try fail("Plugin catalog private key does not match the public key embedded in the app.")
    }
    print("Verified plugin catalog signing key pair.")
}

private func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else {
        try fail("Expected a command: sign or verify-key-pair.")
    }

    let command = arguments.removeFirst()
    switch command {
    case "sign":
        try signCatalog(options: parseSignOptions(arguments))
    case "verify-key-pair":
        try verifyKeyPair(publicKey: parsePublicKey(arguments))
    default:
        try fail("Unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}
