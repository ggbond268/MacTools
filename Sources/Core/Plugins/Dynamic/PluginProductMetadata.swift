import Foundation
import MacToolsPluginKit

struct PluginLocalizedText: Codable, Equatable {
    let values: [String: String]
    let sourceReference: String?

    init(_ values: [String: String]) {
        self.values = values
        sourceReference = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let reference = try? container.decode(String.self),
           reference == "@displayName" || reference == "@summary" {
            values = [:]
            sourceReference = reference
        } else {
            values = try container.decode([String: String].self)
            sourceReference = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let sourceReference {
            try container.encode(sourceReference)
        } else {
            try container.encode(values)
        }
    }

    func localizedValue(preferredLanguages: [String] = PluginRuntimeLocalization.preferredLanguages) -> String? {
        for language in preferredLanguages {
            for candidate in PluginRuntimeLocalization.candidateLanguageIdentifiers(for: language) {
                if let value = values[candidate] {
                    return value
                }
                if let value = values.first(where: {
                    $0.key.caseInsensitiveCompare(candidate) == .orderedSame
                })?.value {
                    return value
                }
            }
        }
        return values["en"] ?? values["zh-Hans"] ?? values.values.first
    }
}

struct PluginProductMetadata: Codable, Equatable {
    struct Presentation: Codable, Equatable {
        struct Example: Codable, Equatable {
            let id: String
            let text: PluginLocalizedText
        }

        struct Asset: Codable, Equatable {
            let id: String
            let path: String
            let mediaType: String?
            let sha256: String?
            let size: Int64?
            let width: Int?
            let height: Int?
            let alt: PluginLocalizedText
        }

        let longDescription: PluginLocalizedText
        let examples: [Example]
        let screenshots: [Asset]
        let documentationURL: URL?
        let supportURL: URL?
        let publisher: String
        let license: String
    }

    struct Discovery: Codable, Equatable {
        struct UseCase: Codable, Equatable {
            let id: String
            let title: PluginLocalizedText
        }

        let keywords: [String]
        let localizedSynonyms: [String: [String]]
        let useCases: [UseCase]
        let goalCategories: [String]
        let relatedPluginIDs: [String]
        let alternativePluginIDs: [String]
    }

    struct Requirements: Codable, Equatable {
        struct Application: Codable, Equatable {
            let bundleID: String
            let name: String
        }

        let minimumMacOSVersion: String?
        let architectures: [String]
        let hardware: [String]
        let applications: [Application]
        let executables: [String]
        let permissionIDs: [String]
        let setupComplexity: String
        let requiresRelaunch: Bool
    }

    struct Privacy: Codable, Equatable {
        struct Retention: Codable, Equatable {
            let policy: String
            let description: PluginLocalizedText?
        }

        let dataObserved: [String]
        let dataPersisted: [String]
        let retention: Retention
        let networkUse: String
        let networkDomains: [String]
        let allowsUserConfiguredDomains: Bool?
        let telemetry: String
        let processesSensitiveUserContent: Bool
        let diagnosticExportsContainUserData: Bool
    }

    struct Actions: Codable, Equatable {
        struct Parameter: Codable, Equatable {
            let id: String
            let kind: String
            let isRequired: Bool
            let portability: String
        }

        struct StaticAction: Codable, Equatable {
            let id: String
            let title: PluginLocalizedText
            let description: PluginLocalizedText
            let keywords: [String]
            let systemImage: String
            let parameters: [Parameter]
            let parameterSummary: PluginLocalizedText?
            let permissionIDs: [String]
            let risk: String
            let surfaces: [String]
            let automaticEligible: Bool
            let externalInvocation: String
        }

        struct DynamicTemplate: Codable, Equatable {
            let id: String
            let title: PluginLocalizedText
            let description: PluginLocalizedText
            let entrySource: String
            let keywords: [String]
            let parameters: [Parameter]
            let parameterSummary: PluginLocalizedText
            let localOnlyIdentity: Bool
            let riskVariesByEntry: Bool?
            let automaticEligibilityVariesByEntry: Bool?
            let permissionIDs: [String]
            let risk: String
            let surfaces: [String]
            let automaticEligible: Bool
            let externalInvocation: String
        }

        struct Provider: Codable, Equatable {
            let id: String
            let kind: String
            let staticActions: [StaticAction]
            let dynamicTemplates: [DynamicTemplate]
        }

        let providers: [Provider]
    }

    struct Setup: Codable, Equatable {
        struct Step: Codable, Equatable {
            let id: String
            let title: PluginLocalizedText
            let description: PluginLocalizedText
        }

        struct TestAction: Codable, Equatable {
            let providerID: String
            let actionID: String
        }

        let steps: [Step]
        let suggestedTestAction: TestAction?
        let optionalSurfaces: [String]
        let missingDependencyHelp: PluginLocalizedText?
    }

    struct Relationships: Codable, Equatable {
        let relatedPluginIDs: [String]
        let includedPackIDs: [String]
        let suggestedRecipeIDs: [String]
        let supersedesPluginIDs: [String]
    }

    let presentation: Presentation?
    let discovery: Discovery?
    let requirements: Requirements?
    let privacy: Privacy?
    let actions: Actions?
    let setup: Setup?
    let relationships: Relationships?

    var searchKeywords: [String] {
        Self.searchKeywords(
            presentation: presentation,
            discovery: discovery,
            requirements: requirements,
            privacy: privacy,
            actions: actions,
            setup: setup,
            relationships: relationships
        )
    }

    static func searchKeywords(
        presentation: Presentation?,
        discovery: Discovery?,
        requirements: Requirements?,
        privacy: Privacy?,
        actions: Actions?,
        setup: Setup?,
        relationships: Relationships?
    ) -> [String] {
        var values: [String] = []
        if let presentation {
            values.append(contentsOf: [presentation.longDescription.localizedValue()].compactMap { $0 })
            values.append(contentsOf: presentation.examples.compactMap { $0.text.localizedValue() })
        }
        if let discovery {
            values.append(contentsOf: discovery.keywords)
            values.append(contentsOf: discovery.localizedSynonyms.values.flatMap { $0 })
            values.append(contentsOf: discovery.useCases.compactMap { $0.title.localizedValue() })
            values.append(contentsOf: discovery.goalCategories)
            values.append(contentsOf: discovery.relatedPluginIDs)
            values.append(contentsOf: discovery.alternativePluginIDs)
        }
        if let requirements {
            values.append(contentsOf: requirements.architectures)
            values.append(contentsOf: requirements.hardware)
            values.append(contentsOf: requirements.applications.flatMap { [$0.name, $0.bundleID] })
            values.append(contentsOf: requirements.executables)
            values.append(contentsOf: requirements.permissionIDs)
        }
        if let privacy {
            values.append(contentsOf: privacy.dataObserved)
            values.append(contentsOf: privacy.dataPersisted)
            values.append(contentsOf: privacy.networkDomains)
        }
        if let actions {
            for provider in actions.providers {
                values.append(provider.id)
                for action in provider.staticActions {
                    values.append(action.id)
                    values.append(contentsOf: action.keywords)
                    values.append(contentsOf: [
                        action.title.localizedValue(),
                        action.description.localizedValue(),
                        action.parameterSummary?.localizedValue(),
                    ].compactMap { $0 })
                }
                for template in provider.dynamicTemplates {
                    values.append(contentsOf: [template.id, template.entrySource])
                    values.append(contentsOf: template.keywords)
                    values.append(contentsOf: [
                        template.title.localizedValue(),
                        template.description.localizedValue(),
                        template.parameterSummary.localizedValue(),
                    ].compactMap { $0 })
                }
            }
        }
        if let setup {
            values.append(contentsOf: setup.steps.flatMap {
                [$0.title.localizedValue(), $0.description.localizedValue()].compactMap { $0 }
            })
            values.append(contentsOf: setup.optionalSurfaces)
            values.append(contentsOf: [setup.missingDependencyHelp?.localizedValue()].compactMap { $0 })
        }
        if let relationships {
            values.append(contentsOf: relationships.relatedPluginIDs)
            values.append(contentsOf: relationships.includedPackIDs)
            values.append(contentsOf: relationships.suggestedRecipeIDs)
            values.append(contentsOf: relationships.supersedesPluginIDs)
        }

        var seen: Set<String> = []
        return values.filter {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized.lowercased()).inserted
        }
    }
}
