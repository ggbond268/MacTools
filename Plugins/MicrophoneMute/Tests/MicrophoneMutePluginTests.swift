import XCTest
import MacToolsPluginKit
@testable import MicrophoneMutePlugin

@MainActor
final class MicrophoneMutePluginTests: XCTestCase {
    private final class MockController: MicrophoneControlling {
        var muteState: Bool
        var setMuteResult: Bool

        init(muteState: Bool, setMuteResult: Bool = true) {
            self.muteState = muteState
            self.setMuteResult = setMuteResult
        }

        func readMuteState() -> Bool { muteState }
        func setMuteState(_ muted: Bool) -> Bool {
            if setMuteResult {
                muteState = muted
            }
            return setMuteResult
        }
    }

    func testPanelStateReflectsMuteState() {
        let unmuted = MicrophoneMutePlugin(controller: MockController(muteState: false))
        let muted = MicrophoneMutePlugin(controller: MockController(muteState: true))

        XCTAssertFalse(unmuted.rowState.isOn)
        XCTAssertEqual(unmuted.rowState.subtitle, "未静音")
        XCTAssertTrue(muted.rowState.isOn)
        XCTAssertEqual(muted.rowState.subtitle, "已静音")
    }

    func testSwitchUpdatesStateAndNotifiesHost() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertEqual(notificationCount, 1)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = MicrophoneMutePlugin(
            controller: MockController(muteState: false, setMuteResult: false)
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testFailureRelocalizesAndClearsOnSamePluginInstance() async throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let (localization, directory) = try makeLocalization([
            "en": ["error.muteFailed": "Failed to mute microphone."],
            "ar": ["error.muteFailed": "فشل كتم صوت الميكروفون."],
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MockController(muteState: false, setMuteResult: false)
        let plugin = MicrophoneMutePlugin(
            controller: controller,
            localization: localization
        )

        PluginRuntimeLocalization.source.setPreference("en")
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(plugin.rowState.errorMessage, "Failed to mute microphone.")

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(plugin.rowState.errorMessage, "فشل كتم صوت الميكروفون.")
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let failure = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(failure, .failed(message: "فشل كتم صوت الميكروفون."))

        controller.setMuteResult = true
        plugin.handleAction(.setSwitch(true))
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testActionCatalogProvidesIdempotentMuteChoicesAndRunLinkConfirmation() async throws {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(
            plugin.actionCatalogEntries.map(\.title),
            ["恢复麦克风", "麦克风静音", "恢复麦克风"]
        )
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(plugin.actionDefinitions.first?.confirmation)
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.rowState.isOn)
    }

    func testRunLinkConfirmationSwitchesLanguageWithoutRecreatingPlugin() throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("MicrophoneMuteTests.bundle", isDirectory: true)
        for (language, values) in [
            "en": [
                "action.confirmation.title": "Confirm Microphone Change",
                "action.confirmation.confirm": "Continue",
            ],
            "ar": [
                "action.confirmation.title": "تأكيد تغيير حالة الميكروفون",
                "action.confirmation.confirm": "متابعة",
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
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = MicrophoneMutePlugin(
            controller: MockController(muteState: false),
            localization: PluginLocalization(bundle: try XCTUnwrap(Bundle(url: bundleURL)))
        )

        PluginRuntimeLocalization.source.setPreference("en")
        XCTAssertEqual(
            try XCTUnwrap(plugin.actionDefinitions.first?.confirmation).confirmButtonTitle,
            "Continue"
        )

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(
            try XCTUnwrap(plugin.actionDefinitions.first?.confirmation).title,
            "تأكيد تغيير حالة الميكروفون"
        )
    }

    private func makeLocalization(
        _ valuesByLanguage: [String: [String: String]]
    ) throws -> (PluginLocalization, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("MicrophoneMuteTests.bundle", isDirectory: true)
        for (language, values) in valuesByLanguage {
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
        return (
            PluginLocalization(bundle: try XCTUnwrap(Bundle(url: bundleURL))),
            directory
        )
    }
}
