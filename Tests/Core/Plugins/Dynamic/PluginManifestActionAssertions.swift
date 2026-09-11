import Foundation
import XCTest
import MacToolsPluginKit

enum PluginManifestActionAssertions {
    static func dynamicTemplate(
        pluginDirectoryName: String,
        id: String
    ) throws -> [String: Any] {
        let manifest = try sourceManifest(pluginDirectoryName: pluginDirectoryName)
        let actions = try XCTUnwrap(manifest["actions"] as? [String: Any])
        let providers = try XCTUnwrap(actions["providers"] as? [[String: Any]])
        let templates = providers.flatMap {
            $0["dynamicTemplates"] as? [[String: Any]] ?? []
        }
        return try XCTUnwrap(templates.first { $0["id"] as? String == id })
    }

    @MainActor
    static func assertConsistency(
        pluginDirectoryName: String,
        definitions: [ActionDefinition],
        permissionIDs: (ActionKey) -> [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let manifest = try sourceManifest(pluginDirectoryName: pluginDirectoryName)
        let actions = try XCTUnwrap(manifest["actions"] as? [String: Any], file: file, line: line)
        let providers = try XCTUnwrap(actions["providers"] as? [[String: Any]], file: file, line: line)
        let descriptors: [(providerID: String, kind: String, value: [String: Any])] = providers.flatMap { provider in
            let providerID = provider["id"] as? String ?? ""
            let staticActions = provider["staticActions"] as? [[String: Any]] ?? []
            let dynamicTemplates = provider["dynamicTemplates"] as? [[String: Any]] ?? []
            return staticActions.map { (providerID, "static", $0) }
                + dynamicTemplates.map { (providerID, "dynamic", $0) }
        }

        XCTAssertEqual(
            Set(descriptors.map { "\($0.providerID)/\($0.value["id"] as? String ?? "")" }),
            Set(definitions.map(\.key.id)),
            "Manifest actions must exactly match runtime action identities.",
            file: file,
            line: line
        )

        for definition in definitions {
            let descriptor = try XCTUnwrap(
                descriptors.first {
                    $0.providerID == definition.key.providerID
                        && $0.value["id"] as? String == definition.key.actionID
                },
                "Missing manifest descriptor for \(definition.key.id)",
                file: file,
                line: line
            )
            XCTAssertEqual(descriptor.value["risk"] as? String, definition.risk.rawValue, file: file, line: line)
            XCTAssertEqual(
                descriptor.value["externalInvocation"] as? String,
                definition.externalInvocationPolicy.rawValue,
                file: file,
                line: line
            )
            XCTAssertEqual(
                descriptor.value["automaticEligible"] as? Bool,
                definition.capabilities.contains(.automatic),
                file: file,
                line: line
            )
            XCTAssertEqual(
                descriptor.value["permissionIDs"] as? [String] ?? [],
                permissionIDs(definition.key),
                file: file,
                line: line
            )
            if descriptor.kind == "static" {
                XCTAssertEqual(
                    descriptor.value["systemImage"] as? String,
                    definition.systemImage,
                    file: file,
                    line: line
                )
            }
            let manifestParameters = descriptor.value["parameters"] as? [[String: Any]] ?? []
            XCTAssertEqual(
                manifestParameters.compactMap { $0["id"] as? String },
                definition.parameters.map(\.id),
                file: file,
                line: line
            )
            for parameter in definition.parameters {
                let value = try XCTUnwrap(
                    manifestParameters.first { $0["id"] as? String == parameter.id },
                    file: file,
                    line: line
                )
                XCTAssertEqual(value["kind"] as? String, parameter.kind.rawValue, file: file, line: line)
                XCTAssertEqual(value["isRequired"] as? Bool, parameter.isRequired, file: file, line: line)
                XCTAssertEqual(value["portability"] as? String, parameter.portability.rawValue, file: file, line: line)
            }
        }
    }

    private static func sourceManifest(pluginDirectoryName: String) throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
            .appendingPathComponent("plugin.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}
