import XCTest
import MacToolsPluginKit
@testable import DisplaySleepPlugin

@MainActor
final class DisplaySleepPluginTests: XCTestCase {
    func testPluginContract() {
        let plugin = DisplaySleepPlugin()

        XCTAssertEqual(plugin.metadata.id, "display-sleep")
        XCTAssertEqual(plugin.rowDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.rowDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.rowState.isEnabled)
        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertEqual(plugin.commandDefinitions.count, 1)
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["execute"])
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(plugin.actionDefinitions.first?.confirmation)
        XCTAssertTrue(plugin.actionDefinitions.first?.capabilities.contains(
            .changesDisplayConfiguration
        ) == true)
    }

    func testRunLinkConfirmationSwitchesLanguageWithoutRecreatingPlugin() throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let resource = try makeLocalizationBundle()
        defer { try? FileManager.default.removeItem(at: resource.directory) }
        let plugin = DisplaySleepPlugin(
            localization: PluginLocalization(bundle: resource.bundle)
        )

        PluginRuntimeLocalization.source.setPreference("en")
        XCTAssertEqual(
            try XCTUnwrap(plugin.actionDefinitions.first?.confirmation).title,
            "Put Displays to Sleep?"
        )

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(
            try XCTUnwrap(plugin.actionDefinitions.first?.confirmation).confirmButtonTitle,
            "سكون"
        )
    }

    func testCanonicalActionReportsDisplaySleepFailure() async throws {
        let plugin = DisplaySleepPlugin(
            presentationPreparation: {},
            displaySleepRequest: { false }
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "display-sleep", actionID: "execute")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected display sleep failure, got \(result)")
        }
    }

    private func makeLocalizationBundle() throws -> (bundle: Bundle, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("DisplaySleepTests.bundle", isDirectory: true)
        for (language, values) in [
            "en": [
                "action.confirmation.title": "Put Displays to Sleep?",
                "action.confirmation.confirm": "Sleep",
            ],
            "ar": [
                "action.confirmation.title": "وضع شاشات العرض في السكون؟",
                "action.confirmation.confirm": "سكون",
            ],
        ] {
            let languageURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
            try values.map { "\"\($0.key)\" = \"\($0.value)\";" }
                .joined(separator: "\n")
                .write(
                    to: languageURL.appendingPathComponent("Localizable.strings"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        return (try XCTUnwrap(Bundle(url: bundleURL)), directory)
    }
}
