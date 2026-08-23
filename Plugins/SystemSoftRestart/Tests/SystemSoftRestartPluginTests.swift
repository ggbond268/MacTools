import AppKit
import Foundation
import XCTest
import MacToolsPluginKit
@testable import SystemSoftRestartPlugin

@MainActor
final class SystemSoftRestartPluginTests: XCTestCase {
    func testDefaultsPreserveDockAndReopenApplications() throws {
        let storage = SystemSoftRestartMemoryStorage()
        let plugin = makePlugin(storage: storage)
        let settingsPage = try XCTUnwrap(plugin.settingsPage)
        guard case let .form(sections) = settingsPage.body,
              case let .rows(rows) = sections.first?.content
        else {
            return XCTFail("Expected a declarative settings form")
        }

        XCTAssertTrue(toggleValue(id: "reopens-applications", rows: rows))
        XCTAssertTrue(toggleValue(id: "preserves-dock-layout", rows: rows))
    }

    func testPanelActionPresentsConfirmationBeforeRunning() async throws {
        let runner = FakeSystemSoftRestartRunner()
        let presenter = FakeSystemSoftRestartPresenter()
        let applicationURL = URL(fileURLWithPath: "/Applications/Example.app")
        let plugin = makePlugin(
            runner: runner,
            presenter: presenter,
            applicationURLs: [applicationURL]
        )

        plugin.handleAction(.invokeAction(controlID: "execute"))

        XCTAssertEqual(presenter.confirmationPlans.count, 1)
        XCTAssertEqual(presenter.confirmationPlans.first?.applicationURLs, [applicationURL])
        XCTAssertTrue(runner.plans.isEmpty)

        presenter.confirmHandler?()
        for _ in 0..<10 where runner.plans.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(runner.plans.count, 1)
        XCTAssertEqual(presenter.completedResults, [SystemSoftRestartResult(warningCount: 0)])
    }

    func testConfirmationRequiresSavedWorkAcknowledgement() {
        let viewModel = SystemSoftRestartWindowViewModel(
            plan: SystemSoftRestartPlan(
                applicationURLs: [],
                reopensApplications: true,
                preservesDockLayout: true
            ),
            localization: PluginLocalization(bundle: .main),
            mode: .confirmation
        )

        XCTAssertFalse(viewModel.confirm())
        XCTAssertTrue(viewModel.canDismiss)

        viewModel.hasSavedWork = true
        XCTAssertTrue(viewModel.confirm())
        XCTAssertFalse(viewModel.canDismiss)
    }

    func testCompletionKeepsOnlyCurrentRunDiagnosticsInViewModel() {
        let viewModel = SystemSoftRestartWindowViewModel(
            plan: SystemSoftRestartPlan(
                applicationURLs: [],
                reopensApplications: true,
                preservesDockLayout: true
            ),
            localization: PluginLocalization(bundle: .main),
            mode: .running(.restartingServices)
        )
        let diagnostic = SystemSoftRestartDiagnostic(
            kind: .launchdJob,
            subject: "com.example.agent",
            message: "Operation not permitted"
        )
        let result = SystemSoftRestartResult(
            warningCount: 1,
            diagnostics: [diagnostic]
        )

        viewModel.complete(result: result)

        XCTAssertEqual(viewModel.mode, .succeeded(result))
    }

    func testRestartEventRoundTripsDiagnostics() throws {
        let diagnostic = SystemSoftRestartDiagnostic(
            kind: .applicationReopen,
            subject: "Example",
            message: "The application could not be opened."
        )
        let event = SystemSoftRestartEvent(
            phase: .completed,
            applicationCount: 2,
            warningCount: 1,
            diagnostics: [diagnostic]
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SystemSoftRestartEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    func testCanonicalActionIsInteractiveConfirmedAndUnavailableToRunLinks() throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.actionID, "restart-user-services")
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertNotNil(definition.confirmation)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertTrue(definition.capabilities.contains(.foregroundInteractive))
        XCTAssertTrue(definition.capabilities.contains(.reportsProgress))
        XCTAssertFalse(definition.capabilities.contains(.automatic))
        XCTAssertFalse(definition.capabilities.contains(.background))
        XCTAssertEqual(definition.concurrencyPolicy, .rejectWhileRunning)
    }

    func testCanonicalActionRunsThroughHelperAndShowsProgress() async throws {
        let runner = FakeSystemSoftRestartRunner()
        let presenter = FakeSystemSoftRestartPresenter()
        let plugin = makePlugin(runner: runner, presenter: presenter)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            )
        )
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded(message: "系统软重启已完成"))
        XCTAssertEqual(runner.plans.count, 1)
        XCTAssertEqual(presenter.progressPlans.count, 1)
        XCTAssertEqual(presenter.events.map(\.phase), [.restartingServices])
        XCTAssertEqual(presenter.completedResults.count, 1)
    }

    func testSettingsCanDisableApplicationAndDockRecovery() throws {
        let storage = SystemSoftRestartMemoryStorage()
        let presenter = FakeSystemSoftRestartPresenter()
        let plugin = makePlugin(storage: storage, presenter: presenter)

        plugin.handleSettingsAction(.setBoolean(controlID: "reopens-applications", value: false))
        plugin.handleSettingsAction(.setBoolean(controlID: "preserves-dock-layout", value: false))
        plugin.handleAction(.invokeAction(controlID: "execute"))

        let plan = try XCTUnwrap(presenter.confirmationPlans.first)
        XCTAssertFalse(plan.reopensApplications)
        XCTAssertFalse(plan.preservesDockLayout)
        XCTAssertTrue(plan.applicationURLs.isEmpty)
    }

    func testUnavailableHelperDisablesPanelAndAction() throws {
        let runner = FakeSystemSoftRestartRunner()
        runner.isAvailable = false
        let plugin = makePlugin(runner: runner)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
        XCTAssertFalse(plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable)
    }

    func testApplicationScannerReopensRegularAndStandaloneMenuBarApps() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let regularApp = try makeApplicationBundle(
            named: "Regular.app",
            in: temporaryDirectory,
            info: [:]
        )
        let menuBarApp = try makeApplicationBundle(
            named: "MenuBar.app",
            in: temporaryDirectory,
            info: ["LSUIElement": true]
        )
        let backgroundApp = try makeApplicationBundle(
            named: "Background.app",
            in: temporaryDirectory,
            info: ["LSBackgroundOnly": true]
        )
        let scanner = SystemSoftRestartApplicationScanner(
            applicationDirectories: [temporaryDirectory]
        )

        XCTAssertTrue(scanner.isEligibleForManualReopen(
            activationPolicy: .regular,
            bundleURL: regularApp
        ))
        XCTAssertTrue(scanner.isEligibleForManualReopen(
            activationPolicy: .accessory,
            bundleURL: menuBarApp
        ))
        XCTAssertFalse(scanner.isEligibleForManualReopen(
            activationPolicy: .prohibited,
            bundleURL: regularApp
        ))
        XCTAssertFalse(scanner.isEligibleForManualReopen(
            activationPolicy: .accessory,
            bundleURL: backgroundApp
        ))
    }

    func testApplicationScannerLeavesSystemAccessoryAppsToMacOS() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let systemApp = try makeApplicationBundle(
            named: "SystemMenuBar.app",
            in: temporaryDirectory,
            info: ["LSUIElement": true]
        )
        let scanner = SystemSoftRestartApplicationScanner(
            applicationDirectories: [temporaryDirectory],
            accessoryApplicationDirectories: []
        )

        XCTAssertTrue(scanner.isEligibleForManualReopen(
            activationPolicy: .regular,
            bundleURL: systemApp
        ))
        XCTAssertFalse(scanner.isEligibleForManualReopen(
            activationPolicy: .accessory,
            bundleURL: systemApp
        ))
    }

    func testApplicationScannerRejectsNestedHelperBundles() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let hostApp = temporaryDirectory.appendingPathComponent("Host.app", isDirectory: true)
        let helperDirectory = hostApp
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        let helperApp = try makeApplicationBundle(
            named: "Host Helper.app",
            in: helperDirectory,
            info: [:]
        )
        let scanner = SystemSoftRestartApplicationScanner(
            applicationDirectories: [temporaryDirectory]
        )

        XCTAssertFalse(scanner.isEligibleForManualReopen(
            activationPolicy: .accessory,
            bundleURL: helperApp
        ))
    }

    private func makePlugin(
        storage: PluginStorage? = nil,
        runner: FakeSystemSoftRestartRunner? = nil,
        presenter: FakeSystemSoftRestartPresenter? = nil,
        applicationURLs: [URL] = []
    ) -> SystemSoftRestartPlugin {
        SystemSoftRestartPlugin(
            storage: storage ?? SystemSoftRestartMemoryStorage(),
            runner: runner ?? FakeSystemSoftRestartRunner(),
            presenter: presenter ?? FakeSystemSoftRestartPresenter(),
            applicationURLProvider: { applicationURLs }
        )
    }

    private func toggleValue(id: String, rows: [PluginSettingsRow]) -> Bool {
        guard let row = rows.first(where: { $0.id == id }),
              case let .toggle(isOn) = row.control
        else {
            XCTFail("Missing toggle \(id)")
            return false
        }
        return isOn
    }

    private func makeApplicationBundle(
        named name: String,
        in directory: URL,
        info: [String: Any]
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent(name, isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var bundleInfo = info
        bundleInfo["CFBundleIdentifier"] = "cc.ggbond.tests.\(UUID().uuidString)"
        bundleInfo["CFBundlePackageType"] = "APPL"
        let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let data = try PropertyListSerialization.data(
            fromPropertyList: bundleInfo,
            format: .xml,
            options: 0
        )
        try data.write(to: infoURL)
        return bundleURL
    }
}

@MainActor
private final class FakeSystemSoftRestartRunner: SystemSoftRestartRunning {
    var isAvailable = true
    var isRunning = false
    var result = SystemSoftRestartResult(warningCount: 0)
    var error: Error?
    private(set) var plans: [SystemSoftRestartPlan] = []

    func run(
        plan: SystemSoftRestartPlan,
        onEvent: @escaping @MainActor (SystemSoftRestartEvent) -> Void
    ) async throws -> SystemSoftRestartResult {
        plans.append(plan)
        isRunning = true
        defer { isRunning = false }
        onEvent(SystemSoftRestartEvent(phase: .restartingServices, applicationCount: plan.applicationCount))
        if let error { throw error }
        return result
    }
}

@MainActor
private final class FakeSystemSoftRestartPresenter: SystemSoftRestartPresenting {
    var isPresenting = false
    private(set) var confirmationPlans: [SystemSoftRestartPlan] = []
    private(set) var progressPlans: [SystemSoftRestartPlan] = []
    private(set) var events: [SystemSoftRestartEvent] = []
    private(set) var completedResults: [SystemSoftRestartResult] = []
    private(set) var failures: [String] = []
    private(set) var dismissCount = 0
    var confirmHandler: (() -> Void)?

    func presentConfirmation(
        plan: SystemSoftRestartPlan,
        anchorRect: NSRect?,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        confirmationPlans.append(plan)
        confirmHandler = onConfirm
        isPresenting = true
    }

    func presentProgress(plan: SystemSoftRestartPlan, anchorRect: NSRect?) {
        progressPlans.append(plan)
        isPresenting = true
    }

    func update(event: SystemSoftRestartEvent) {
        events.append(event)
    }

    func complete(result: SystemSoftRestartResult) {
        completedResults.append(result)
    }

    func fail(message: String) {
        failures.append(message)
    }

    func dismiss() {
        dismissCount += 1
        isPresenting = false
    }
}

@MainActor
private final class SystemSoftRestartMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else { return }
        values[key] = value
    }
}
