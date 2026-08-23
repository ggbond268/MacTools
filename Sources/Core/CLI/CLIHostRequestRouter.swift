import Foundation
import MacToolsPluginKit

@MainActor
final class CLIHostRequestRouter {
    private let pluginHost: PluginHost
    private let serviceStatus: () -> String

    init(pluginHost: PluginHost, serviceStatus: @escaping () -> String) {
        self.pluginHost = pluginHost
        self.serviceStatus = serviceStatus
    }

    func handle(_ request: CLIRequestEnvelope) async -> CLIResponseEnvelope {
        let startedAt = Date()
        guard (CLIProtocolVersion.minimum...CLIProtocolVersion.current)
            .contains(request.protocolVersion) else {
            return .failure(
                request: request,
                outcome: .protocolIncompatible,
                category: "protocolIncompatible",
                message: "The CLI protocol version is not supported.",
                startedAt: startedAt
            )
        }

        do {
            switch request.operation {
            case .doctor:
                return try response(
                    request,
                    startedAt: startedAt,
                    payload: CLIDoctorRecord(
                        hostVersion: AppMetadata.shortVersion ?? "unknown",
                        hostBuild: AppMetadata.buildNumber ?? "unknown",
                        protocolVersion: CLIProtocolVersion.current,
                        actionCount: pluginHost.actionRegistry.catalogEntries.count,
                        workflowCount: pluginHost.automationController.workflows.count,
                        pluginCount: pluginHost.pluginManagementItems.count,
                        brokerServiceStatus: serviceStatus()
                    )
                )
            case .actionsList:
                let payload = try decode(
                    CLIActionListRequest.self,
                    request: request,
                    allowedKeys: ["runnableOnly", "continuationToken"]
                )
                let actions = pluginHost.actionRegistry.catalogEntries.map(actionRecord)
                    .filter { !payload.runnableOnly || $0.cliEligibility.isAvailable }
                    .sorted { lhs, rhs in
                        if lhs.title == rhs.title { return lhs.reference.key.id < rhs.reference.key.id }
                        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    }
                return try response(
                    request,
                    startedAt: startedAt,
                    payload: try page(actions, continuationToken: payload.continuationToken)
                )
            case .actionsDescribe:
                let payload = try actionTarget(request)
                guard let record = actionRecord(for: payload.key) else {
                    return unknown(request, startedAt: startedAt, noun: "action")
                }
                return try response(request, startedAt: startedAt, payload: record)
            case .actionsAvailability:
                let payload = try actionTarget(request)
                guard let record = actionRecord(for: payload.key) else {
                    return unknown(request, startedAt: startedAt, noun: "action")
                }
                return try response(request, startedAt: startedAt, payload: record.availability)
            case .actionsRun:
                let payload = try decode(
                    CLIActionRunRequest.self,
                    request: request,
                    allowedKeys: ["key", "parameters", "inputSource", "noWait"]
                )
                return await runAction(payload, request: request, startedAt: startedAt)
            case .workflowsList:
                let list = try listRequest(request)
                return try response(
                    request,
                    startedAt: startedAt,
                    payload: try page(
                        pluginHost.automationController.workflows
                            .map(workflowRecord)
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                        continuationToken: list.continuationToken
                    )
                )
            case .workflowsDescribe:
                let payload = try workflowTarget(request)
                guard let workflow = resolveWorkflow(payload.nameOrID) else {
                    if let ambiguous = ambiguousWorkflowMessage(payload.nameOrID) {
                        return .failure(
                            request: request,
                            outcome: .invalidInput,
                            category: "ambiguousWorkflowName",
                            message: ambiguous,
                            startedAt: startedAt
                        )
                    }
                    return unknown(request, startedAt: startedAt, noun: "workflow")
                }
                return try response(request, startedAt: startedAt, payload: workflowRecord(workflow))
            case .workflowsRun:
                let payload = try decode(
                    CLIWorkflowRunRequest.self,
                    request: request,
                    allowedKeys: ["nameOrID", "noWait"]
                )
                guard let workflow = resolveWorkflow(payload.nameOrID) else {
                    if let ambiguous = ambiguousWorkflowMessage(payload.nameOrID) {
                        return .failure(
                            request: request,
                            outcome: .invalidInput,
                            category: "ambiguousWorkflowName",
                            message: ambiguous,
                            startedAt: startedAt
                        )
                    }
                    return unknown(request, startedAt: startedAt, noun: "workflow")
                }
                return await runAction(
                    CLIActionRunRequest(
                        key: CLIActionKey(
                            providerID: workflow.actionKey.providerID,
                            actionID: workflow.actionKey.actionID
                        ),
                        parameters: [:],
                        inputSource: .arguments,
                        noWait: payload.noWait
                    ),
                    request: request,
                    startedAt: startedAt
                )
            case .pluginsList:
                let list = try listRequest(request)
                return try response(
                    request,
                    startedAt: startedAt,
                    payload: try page(
                        pluginHost.pluginManagementItems
                            .map(pluginRecord)
                            .sorted { $0.id < $1.id },
                        continuationToken: list.continuationToken
                    )
                )
            case .pluginsDescribe, .pluginsDoctor:
                let payload = try decode(
                    CLIPluginTargetRequest.self,
                    request: request,
                    allowedKeys: ["pluginID"]
                )
                guard let item = pluginHost.pluginManagementItems.first(where: { $0.id == payload.pluginID }) else {
                    return unknown(request, startedAt: startedAt, noun: "plugin")
                }
                return try response(request, startedAt: startedAt, payload: pluginRecord(item))
            }
        } catch {
            return .failure(
                request: request,
                outcome: .invalidInput,
                category: "invalidInput",
                message: "The request payload is invalid.",
                startedAt: startedAt
            )
        }
    }

    private func actionTarget(_ request: CLIRequestEnvelope) throws -> CLIActionTargetRequest {
        try decode(
            CLIActionTargetRequest.self,
            request: request,
            allowedKeys: ["key"]
        )
    }

    private func listRequest(_ request: CLIRequestEnvelope) throws -> CLIListRequest {
        try decode(
            CLIListRequest.self,
            request: request,
            allowedKeys: ["continuationToken"]
        )
    }

    private func page<Record: Codable & Equatable & Sendable>(
        _ records: [Record],
        continuationToken: String?
    ) throws -> CLIPage<Record> {
        let offset: Int
        if let continuationToken {
            guard let parsed = Int(continuationToken), parsed >= 0, parsed <= records.count else {
                throw CLIProtocolCodecError.invalidObject
            }
            offset = parsed
        } else {
            offset = 0
        }
        let end = min(offset + CLIProtocolVersion.maximumPageSize, records.count)
        return CLIPage(
            records: Array(records[offset..<end]),
            continuationToken: end < records.count ? String(end) : nil
        )
    }

    private func workflowTarget(_ request: CLIRequestEnvelope) throws -> CLIWorkflowTargetRequest {
        try decode(
            CLIWorkflowTargetRequest.self,
            request: request,
            allowedKeys: ["nameOrID"]
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        request: CLIRequestEnvelope,
        allowedKeys: Set<String>
    ) throws -> T {
        guard let payload = request.payload else { throw CLIProtocolCodecError.invalidObject }
        return try CLIProtocolCodec.decodeRequest(type, from: payload, allowedKeys: allowedKeys)
    }

    private func response<T: Encodable>(
        _ request: CLIRequestEnvelope,
        startedAt: Date,
        payload: T,
        actionReference: CLIActionReference? = nil,
        outcome: CLIOutcome = .completed,
        message: String? = nil,
        finishedAt: Date? = .now
    ) throws -> CLIResponseEnvelope {
        CLIResponseEnvelope(
            schemaVersion: 1,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            operation: request.operation,
            actionReference: actionReference,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            message: message,
            rejection: nil,
            payload: try CLIProtocolCodec.encodeResponse(payload)
        )
    }

    private func unknown(
        _ request: CLIRequestEnvelope,
        startedAt: Date,
        noun: String
    ) -> CLIResponseEnvelope {
        .failure(
            request: request,
            outcome: .unknownTarget,
            category: "unknown\(noun.capitalized)",
            message: "The requested \(noun) was not found.",
            startedAt: startedAt
        )
    }

    private func actionRecord(for key: CLIActionKey) -> CLIActionRecord? {
        pluginHost.actionRegistry.catalogEntries
            .first(where: { entry in
                entry.reference.key.providerID == key.providerID
                    && entry.reference.key.actionID == key.actionID
            })
            .map(actionRecord)
    }

    private func actionRecord(_ entry: ActionCatalogEntry) -> CLIActionRecord {
        guard case let .success(action) = pluginHost.actionRegistry.registeredAction(
            for: entry.reference
        ) else {
            let definition = pluginHost.actionRegistry.definition(for: entry.reference.key)
            let unavailable = CLIAvailabilityRecord(
                isAvailable: false,
                reason: "The action provider is not registered."
            )
            return CLIActionRecord(
                reference: CLIActionReference(
                    key: CLIActionKey(
                        providerID: entry.reference.key.providerID,
                        actionID: entry.reference.key.actionID
                    ),
                    schemaVersion: entry.reference.schemaVersion
                ),
                title: entry.title,
                subtitle: entry.subtitle,
                description: definition?.description ?? "Action provider is unavailable.",
                systemImage: definition?.systemImage ?? "questionmark.circle",
                parameters: definition?.parameters.map(parameterRecord) ?? [],
                availability: unavailable,
                cliEligibility: unavailable,
                capabilities: definition.map { capabilityNames($0.capabilities) } ?? [],
                externalInvocationPolicy: definition?.externalInvocationPolicy.rawValue
                    ?? "unavailable"
            )
        }
        let availability = pluginHost.actionRegistry.availability(for: entry.reference)
        let eligibility = cliEligibility(action: action, availability: availability)
        return CLIActionRecord(
            reference: CLIActionReference(
                key: CLIActionKey(
                    providerID: entry.reference.key.providerID,
                    actionID: entry.reference.key.actionID
                ),
                schemaVersion: action.definition.parameterSchemaVersion
            ),
            title: entry.title,
            subtitle: entry.subtitle,
            description: action.definition.description,
            systemImage: action.definition.systemImage,
            parameters: action.definition.parameters.map(parameterRecord),
            availability: CLIAvailabilityRecord(
                isAvailable: availability.isAvailable,
                reason: availability.reason
            ),
            cliEligibility: eligibility,
            capabilities: capabilityNames(action.definition.capabilities),
            externalInvocationPolicy: action.definition.externalInvocationPolicy.rawValue
        )
    }

    private func parameterRecord(_ definition: ActionParameterDefinition) -> CLIActionParameter {
        CLIActionParameter(
            id: definition.id,
            title: definition.title,
            kind: definition.kind.rawValue,
            isRequired: definition.isRequired,
            privacy: definition.privacy.rawValue,
            portability: definition.portability.rawValue
        )
    }

    private func cliEligibility(
        action: RegisteredAction,
        availability: ActionAvailability
    ) -> CLIAvailabilityRecord {
        guard action.catalogEntry != nil else {
            return CLIAvailabilityRecord(isAvailable: false, reason: "Not published.")
        }
        guard action.definition.externalInvocationPolicy != .unavailable else {
            return CLIAvailabilityRecord(isAvailable: false, reason: "External invocation is disabled.")
        }
        guard pluginHost.actionRegistry.exposurePolicy(
            for: action.catalogEntry!.reference,
            on: .cli
        ) != .excluded else {
            return CLIAvailabilityRecord(isAvailable: false, reason: "CLI invocation is disabled.")
        }
        return CLIAvailabilityRecord(
            isAvailable: availability.isAvailable,
            reason: availability.reason
        )
    }

    private func runAction(
        _ payload: CLIActionRunRequest,
        request: CLIRequestEnvelope,
        startedAt: Date
    ) async -> CLIResponseEnvelope {
        guard let catalogEntry = pluginHost.actionRegistry.catalogEntries.first(where: {
            $0.reference.key.providerID == payload.key.providerID
                && $0.reference.key.actionID == payload.key.actionID
        }),
        case let .success(registered) = pluginHost.actionRegistry.registeredAction(for: catalogEntry.reference)
        else { return unknown(request, startedAt: startedAt, noun: "action") }

        let definitions = Dictionary(
            uniqueKeysWithValues: registered.definition.parameters.map { ($0.id, $0) }
        )
        let responseReference = CLIActionReference(
            key: payload.key,
            schemaVersion: registered.definition.parameterSchemaVersion
        )
        if payload.inputSource == .arguments,
           payload.parameters.keys.contains(where: { definitions[$0]?.privacy == .sensitive }) {
            return .failure(
                request: request,
                outcome: .invalidInput,
                category: "sensitiveParameterInArguments",
                message: "Sensitive parameters must be read from standard input or a protected file.",
                actionReference: responseReference,
                startedAt: startedAt
            )
        }

        let parameterValues = payload.parameters.mapValues(actionParameterValue)
        let parameterSet: ActionParameterSet
        do {
            parameterSet = try ActionParameterSet(parameterValues)
        } catch {
            return .failure(
                request: request,
                outcome: .invalidInput,
                category: "invalidParameters",
                message: "The action parameters are invalid.",
                actionReference: responseReference,
                startedAt: startedAt
            )
        }
        let reference = ActionReference(
            key: registered.definition.key,
            schemaVersion: registered.definition.parameterSchemaVersion,
            parameters: parameterSet
        )
        let mode: ActionExecutionMode = registered.definition.capabilities.contains(.background)
            ? .background
            : .foreground
        let invocation = ActionInvocation(reference: reference, source: .cli, mode: mode)
        let suppliedValues = payload.parameters.values.map(printable)

        if payload.noWait {
            guard registered.definition.capabilities.contains(.reportsProgress) else {
                return .failure(
                    request: request,
                    outcome: .invalidInput,
                    category: "noWaitUnsupported",
                    message: "This action does not own durable progress.",
                    actionReference: responseReference,
                    startedAt: startedAt
                )
            }
            let result = await pluginHost.actionExecutor.startContinuingTrackingCompletion(
                invocation,
                expectedDefinition: registered.definition
            )
            switch result.outcome {
            case .started:
                return (try? response(
                    request,
                    startedAt: startedAt,
                    payload: ["accepted": true],
                    actionReference: responseReference,
                    outcome: .started,
                    message: "Action started.",
                    finishedAt: nil
                )) ?? .failure(
                    request: request,
                    outcome: .failed,
                    category: "responseEncodingFailed",
                    message: nil,
                    actionReference: responseReference,
                    startedAt: startedAt
                )
            case .cancelled:
                return terminal(
                    request,
                    startedAt: startedAt,
                    outcome: .cancelled,
                    message: nil,
                    actionReference: responseReference
                )
            case let .rejected(rejection):
                return rejectionResponse(
                    rejection,
                    request: request,
                    startedAt: startedAt,
                    sensitiveValues: suppliedValues,
                    actionReference: responseReference
                )
            }
        }

        let outcome = await pluginHost.actionExecutor.execute(invocation)
        switch outcome {
        case let .completed(.succeeded(message)):
            return terminal(
                request,
                startedAt: startedAt,
                outcome: .completed,
                message: redacted(message, values: suppliedValues),
                actionReference: responseReference
            )
        case let .completed(.failed(message)):
            return .failure(
                request: request,
                outcome: .failed,
                category: "actionFailure",
                message: redacted(message, values: suppliedValues),
                actionReference: responseReference,
                startedAt: startedAt
            )
        case .completed(.cancelled):
            return terminal(
                request,
                startedAt: startedAt,
                outcome: .cancelled,
                message: nil,
                actionReference: responseReference
            )
        case let .rejected(rejection):
            return rejectionResponse(
                rejection,
                request: request,
                startedAt: startedAt,
                sensitiveValues: suppliedValues,
                actionReference: responseReference
            )
        }
    }

    private func terminal(
        _ request: CLIRequestEnvelope,
        startedAt: Date,
        outcome: CLIOutcome,
        message: String?,
        actionReference: CLIActionReference?
    ) -> CLIResponseEnvelope {
        CLIResponseEnvelope(
            schemaVersion: 1,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            operation: request.operation,
            actionReference: actionReference,
            startedAt: startedAt,
            finishedAt: .now,
            outcome: outcome,
            message: message,
            rejection: nil,
            payload: nil
        )
    }

    private func rejectionResponse(
        _ rejection: ActionExecutionRejection,
        request: CLIRequestEnvelope,
        startedAt: Date,
        sensitiveValues: [String],
        actionReference: CLIActionReference
    ) -> CLIResponseEnvelope {
        let mapped: (CLIOutcome, String, String?)
        switch rejection {
        case .unknownAction: mapped = (.unknownTarget, "unknownAction", "The action was not found.")
        case let .invalidParameters(reason): mapped = (.invalidInput, "invalidParameters", reason)
        case let .unavailable(reason): mapped = (.unavailable, "actionUnavailable", reason)
        case .confirmationDenied: mapped = (.confirmationDenied, "confirmationDenied", nil)
        case .confirmationUnavailable: mapped = (.confirmationDenied, "confirmationUnavailable", nil)
        case .confirmationTimedOut: mapped = (.timedOut, "confirmationTimedOut", nil)
        case .executionTimedOut: mapped = (.timedOut, "executionTimedOut", nil)
        case .providerChanged: mapped = (.providerChanged, "providerChanged", nil)
        case let .providerFailure(message): mapped = (.failed, "providerFailure", message)
        case .backgroundExecutionUnsupported, .foregroundExecutionUnsupported,
             .automaticExecutionUnsupported, .confirmationRequiredForAutomaticExecution,
             .externalInvocationUnavailable, .systemExposureUnavailable, .actionAlreadyRunning:
            mapped = (.unavailable, "actionUnavailable", nil)
        }
        return .failure(
            request: request,
            outcome: mapped.0,
            category: mapped.1,
            message: redacted(mapped.2, values: sensitiveValues),
            actionReference: actionReference,
            startedAt: startedAt
        )
    }

    private func workflowRecord(_ workflow: WorkflowDefinition) -> CLIWorkflowRecord {
        let availability = pluginHost.actionRegistry.availability(for: workflow.actionReference)
        return CLIWorkflowRecord(
            id: workflow.id,
            name: workflow.name,
            isEnabled: workflow.isEnabled,
            stepCount: workflow.steps.count,
            actionReference: CLIActionReference(
                key: CLIActionKey(
                    providerID: workflow.actionKey.providerID,
                    actionID: workflow.actionKey.actionID
                ),
                schemaVersion: 1
            ),
            availability: CLIAvailabilityRecord(
                isAvailable: availability.isAvailable,
                reason: availability.reason
            )
        )
    }

    private func resolveWorkflow(_ nameOrID: String) -> WorkflowDefinition? {
        if let id = UUID(uuidString: nameOrID),
           let match = pluginHost.automationController.workflows.first(where: { $0.id == id }) {
            return match
        }
        let matches = pluginHost.automationController.workflows.filter { $0.name == nameOrID }
        return matches.count == 1 ? matches[0] : nil
    }

    private func ambiguousWorkflowMessage(_ name: String) -> String? {
        let matches = pluginHost.automationController.workflows.filter { $0.name == name }
        guard matches.count > 1 else { return nil }
        let identifiers = matches.map { $0.id.uuidString.lowercased() }.sorted()
        return "Workflow name is ambiguous. Use one of these IDs: \(identifiers.joined(separator: ", "))."
    }

    private func pluginRecord(_ item: PluginManagementItem) -> CLIPluginRecord {
        let state: String
        let diagnostic: String?
        switch item.state {
        case .available: state = "available"; diagnostic = nil
        case .localDevelopment: state = "localDevelopment"; diagnostic = nil
        case .installed: state = "installed"; diagnostic = nil
        case .updateAvailable: state = "updateAvailable"; diagnostic = nil
        case .restartRequired: state = "restartRequired"; diagnostic = nil
        case let .failed(message): state = "failed"; diagnostic = message
        case let .incompatible(message): state = "incompatible"; diagnostic = message
        case let .revoked(message): state = "revoked"; diagnostic = message
        }
        return CLIPluginRecord(
            id: item.id,
            title: item.title,
            summary: item.summary,
            version: item.version,
            state: state,
            diagnostic: diagnostic,
            requiresRestart: item.requiresRestartToFullyUnload,
            permissions: pluginHost.permissionCards
                .filter { $0.pluginID == item.id }
                .map {
                    CLIPluginPermissionRecord(
                        id: $0.permissionID,
                        title: $0.title,
                        isGranted: $0.statusTone == .positive,
                        status: $0.statusText
                    )
                },
            publishedActionCount: pluginHost.actionRegistry.catalogEntries.filter {
                $0.reference.key.providerID == item.id
            }.count
        )
    }

    private func actionParameterValue(_ value: CLIParameterValue) -> ActionParameterValue {
        switch value {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .double(value): .double(value)
        case let .boolean(value): .boolean(value)
        }
    }

    private func printable(_ value: CLIParameterValue) -> String {
        switch value {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .double(value): String(value)
        case let .boolean(value): String(value)
        }
    }

    private func redacted(_ message: String?, values: [String]) -> String? {
        guard var message else { return nil }
        for value in values where !value.isEmpty {
            message = message.replacingOccurrences(of: value, with: "<redacted>")
        }
        return message
    }

    private func capabilityNames(_ capabilities: ActionExecutionCapabilities) -> [String] {
        var names: [String] = []
        if capabilities.contains(.background) { names.append("background") }
        if capabilities.contains(.foregroundInteractive) { names.append("foregroundInteractive") }
        if capabilities.contains(.cancellable) { names.append("cancellable") }
        if capabilities.contains(.reportsProgress) { names.append("reportsProgress") }
        if capabilities.contains(.changesDisplayConfiguration) { names.append("changesDisplayConfiguration") }
        if capabilities.contains(.automatic) { names.append("automatic") }
        return names
    }
}
