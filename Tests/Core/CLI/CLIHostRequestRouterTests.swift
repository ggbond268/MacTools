import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class CLIHostRequestRouterTests: XCTestCase {
    func testParameterizedPresetsProduceOneDefinitionLevelRecordWithAggregateAvailability() async throws {
        let plugin = CLIParameterizedActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let router = CLIHostRequestRouter(pluginHost: host, serviceStatus: { "enabled" })

        let listResponse = await router.handle(try request(
            operation: .actionsList,
            payload: CLIActionListRequest(runnableOnly: false, continuationToken: nil)
        ))
        let page = try decode(CLIPage<CLIActionRecord>.self, from: listResponse)
        let matching = page.records.filter { $0.reference.key.id == plugin.cliKey.id }

        let record = try XCTUnwrap(matching.first)
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(record.title, plugin.definition.title)
        XCTAssertEqual(record.subtitle, "Test presets")
        XCTAssertEqual(record.parameters.map(\.id), ["enabled"])
        XCTAssertTrue(record.availability.isAvailable)
        XCTAssertTrue(record.cliEligibility.isAvailable)

        let runnableResponse = await router.handle(try request(
            operation: .actionsList,
            payload: CLIActionListRequest(runnableOnly: true, continuationToken: nil)
        ))
        let runnable = try decode(CLIPage<CLIActionRecord>.self, from: runnableResponse)
        XCTAssertEqual(
            runnable.records.filter { $0.reference.key.id == plugin.cliKey.id }.count,
            1
        )

        let doctorResponse = await router.handle(try request(operation: .doctor))
        let doctor = try decode(CLIDoctorRecord.self, from: doctorResponse)
        XCTAssertEqual(doctor.actionCount, page.records.count)
    }

    func testParameterizedRunUsesSubmittedReferenceInsteadOfRepresentativePreset() async throws {
        let plugin = CLIParameterizedActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let router = CLIHostRequestRouter(pluginHost: host, serviceStatus: { "enabled" })

        let response = await router.handle(try request(
            operation: .actionsRun,
            payload: CLIActionRunRequest(
                key: plugin.cliKey,
                parameters: ["enabled": .boolean(false)],
                inputSource: .arguments,
                noWait: false
            )
        ))

        XCTAssertEqual(response.outcome, .completed)
        XCTAssertEqual(plugin.invocations.count, 1)
        XCTAssertEqual(plugin.invocations[0].reference.parameters["enabled"], .boolean(false))
    }

    func testActionExecutionReceivesBrokerIssuedInvocationContext() async throws {
        let plugin = CLIParameterizedActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let router = CLIHostRequestRouter(pluginHost: host, serviceStatus: { "enabled" })
        let context = CLIInvocationContext(chainID: UUID(), depth: 0)

        let response = await router.handle(try request(
            operation: .actionsRun,
            payload: CLIActionRunRequest(
                key: plugin.cliKey,
                parameters: ["enabled": .boolean(false)],
                inputSource: .arguments,
                noWait: false
            ),
            invocationContext: context
        ))

        XCTAssertEqual(response.outcome, .completed)
        XCTAssertEqual(
            plugin.invocationContexts,
            [PluginCLIInvocationContext(chainID: context.chainID, depth: context.depth)]
        )
    }

    private func request<Payload: Encodable>(
        operation: CLIOperation,
        payload: Payload,
        invocationContext: CLIInvocationContext? = nil
    ) throws -> CLIRequestEnvelope {
        CLIRequestEnvelope(
            protocolVersion: CLIProtocolVersion.current,
            requestID: UUID(),
            operation: operation,
            sentAt: .now,
            invocationContext: invocationContext,
            payload: try CLIProtocolCodec.encodeRequest(payload)
        )
    }

    private func request(operation: CLIOperation) throws -> CLIRequestEnvelope {
        CLIRequestEnvelope(
            protocolVersion: CLIProtocolVersion.current,
            requestID: UUID(),
            operation: operation,
            sentAt: .now,
            payload: nil
        )
    }

    private func decode<Record: Decodable>(
        _ type: Record.Type,
        from response: CLIResponseEnvelope
    ) throws -> Record {
        XCTAssertEqual(response.outcome, .completed)
        return try CLIProtocolCodec.decodeResponse(
            type,
            from: try XCTUnwrap(response.payload)
        )
    }
}

@MainActor
private final class CLIParameterizedActionTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginActionExposureProviding
{
    let metadata = PluginMetadata(
        id: "cli-parameterized",
        title: "CLI Parameterized",
        iconName: "switch.2",
        iconTint: .blue,
        order: 1,
        defaultDescription: "CLI parameterized action tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var invocations: [ActionInvocation] = []
    private(set) var invocationContexts: [PluginCLIInvocationContext?] = []

    let definition = ActionDefinition(
        key: ActionKey(providerID: "cli-parameterized", actionID: "set-enabled"),
        title: "Set Test Mode",
        description: "Sets a test mode deterministically.",
        systemImage: "switch.2",
        parameters: [
            ActionParameterDefinition(id: "enabled", title: "Enabled", kind: .boolean),
        ],
        externalInvocationPolicy: .allowed,
        capabilities: [.background]
    )

    var cliKey: CLIActionKey {
        CLIActionKey(
            providerID: definition.key.providerID,
            actionID: definition.key.actionID
        )
    }

    var actionDefinitions: [ActionDefinition] { [definition] }
    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: reference(enabled: true),
                title: "Enable Test Mode",
                subtitle: "Test presets"
            ),
            ActionCatalogEntry(
                reference: reference(enabled: false),
                title: "Disable Test Mode",
                subtitle: "Test presets"
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        reference.parameters["enabled"] == .boolean(false)
            ? .available
            : .unavailable("The enable preset is unavailable in this fixture.")
    }

    func exposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        reference.parameters["enabled"] == .boolean(false) ? .automatic : .excluded
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        invocations.append(invocation)
        invocationContexts.append(PluginActionExecutionContext.cliInvocation)
        return ActionExecutionHandle { .succeeded() }
    }

    private func reference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: definition.key,
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }
}
