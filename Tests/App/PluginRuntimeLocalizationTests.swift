import XCTest
@testable import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginRuntimeLocalizationTests: XCTestCase {
    private let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
    private var originalPreference: String?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        PluginRuntimeLocalization.source.setPreference(originalPreference)
    }

    override func tearDown() {
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        originalPreference = nil
        super.tearDown()
    }

    func testFixedPreferenceOverridesProcessPreferredLanguages() {
        setRuntimePreference("ar")

        XCTAssertEqual(PluginRuntimeLocalization.preferredLanguages, ["ar"])
        XCTAssertEqual(PluginRuntimeLocalization.locale.language.languageCode?.identifier, "ar")
    }

    func testFixedPreferenceThenSystemUsesTheSystemLanguageSnapshot() {
        let source = makeLocaleSource(
            systemLanguages: ["en-GB"],
            currentLocale: Locale(identifier: "en_DE@calendar=gregorian")
        )

        source.setPreference("fr")
        XCTAssertEqual(source.preferredLanguages, ["fr"])
        XCTAssertEqual(source.locale.language.languageCode?.identifier, "fr")
        XCTAssertEqual(source.locale.region?.identifier, "DE")

        source.setPreference("system")
        XCTAssertEqual(source.preferredLanguages, ["en-GB"])
        XCTAssertEqual(source.locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(source.locale.region?.identifier, "DE")
    }

    func testWindowAndMenuBarTitlesFollowTwoRuntimeSwitches() {
        setRuntimePreference("en")
        XCTAssertEqual(AppWindowRouter.settingsWindowTitle, "Settings")
        XCTAssertEqual(MenuBarPanelTab.components.accessibilityTitle, "Components Panel")
        XCTAssertEqual(MenuBarPanelTab.features.accessibilityTitle, "Features Panel")

        setRuntimePreference("zh-Hans")
        XCTAssertEqual(AppWindowRouter.settingsWindowTitle, "设置")
        XCTAssertEqual(MenuBarPanelTab.components.accessibilityTitle, "组件面板")
        XCTAssertEqual(MenuBarPanelTab.features.accessibilityTitle, "功能面板")

        setRuntimePreference("en")
        XCTAssertEqual(AppWindowRouter.settingsWindowTitle, "Settings")
        XCTAssertEqual(MenuBarPanelTab.components.accessibilityTitle, "Components Panel")
    }

    func testFeatureSurfacesSwitchLanguageAndFormattingAtRuntime() {
        let expectations: [(language: String, actions: String, automation: String)] = [
            ("en", "Actions & Shortcuts", "Automation"),
            ("de", "Aktionen und Tastenkürzel", "Automatisierung"),
            ("ar", "الإجراءات والاختصارات", "الأتمتة"),
            ("zh-Hans", "操作与快捷键", "自动化"),
        ]

        for expectation in expectations {
            setRuntimePreference(expectation.language)
            XCTAssertEqual(FeatureL10n.string("操作与快捷键"), expectation.actions)
            XCTAssertEqual(FeatureL10n.string("自动化"), expectation.automation)
        }

        setRuntimePreference("en")
        XCTAssertEqual(
            FeatureL10n.format("%d 个步骤 · %d 条规则 · %@%@", 3, 2, "Enabled", ""),
            "3 steps · 2 rules · Enabled"
        )

        setRuntimePreference("ar")
        XCTAssertEqual(
            PluginRuntimeLocalization.locale.language.characterDirection,
            .rightToLeft
        )
    }

    func testCLINotarizationRecoveryGuidanceFollowsRuntimeLanguage() {
        let expectations = [
            ("en", "CLI notarization could not be confirmed. Check your network and retry, or update Nightly."),
            ("ar", "تعذّر تأكيد توثيق CLI لدى Apple. تحقق من اتصال الشبكة وحاول مجددًا، أو حدّث Nightly."),
            ("zh-Hans", "无法确认 CLI 的公证状态，请检查网络后重试，或更新 Nightly。"),
            ("zh-Hant", "無法確認 CLI 的公證狀態，請檢查網路後重試，或更新 Nightly。"),
        ]
        for (language, message) in expectations {
            setRuntimePreference(language)
            XCTAssertEqual(CLIInstallError.notarization.localizedDescription, message)
        }
    }

    func testCLIInstallerCopyAndExistingFailureSwitchLanguagesAtRuntime() {
        setRuntimePreference("zh-Hans")
        let error = CLIInstallError.download
        let phase = CLIInstallPhase.failed(error.localizedDescription)
        XCTAssertEqual(CLIInstallCopy.confirmTitle.text, "安装 Nightly CLI？")
        setRuntimePreference("en")
        XCTAssertEqual(CLIInstallCopy.confirmTitle.text, "Install Nightly CLI?")
        XCTAssertEqual(CLIInstallCopy.status(phase, error: error),
            "CLI operation failed: CLI download failed or exceeded the size limit. Check your network and retry.")
        XCTAssertEqual(CLIInstallCopy.paths.format("/tmp/install", "/tmp/command"),
            "Installation directory:\n/tmp/install\n\nCommand path:\n/tmp/command")
        setRuntimePreference("ar")
        XCTAssertEqual(CLIInstallCopy.confirmTitle.text, "هل تريد تثبيت Nightly CLI؟")
        XCTAssertEqual(CLIInstallCopy.status(.installed), "CLI مثبّت")
        setRuntimePreference("zh-Hant")
        XCTAssertEqual(CLIInstallCopy.confirmTitle.text, "安裝 Nightly CLI？")
        XCTAssertEqual(CLIInstallCopy.retry.text, "重試")
        setRuntimePreference("en")
        XCTAssertEqual(CLIInstallCopy.remove.text, "Remove")
    }

    func testWorkflowStepTimingCopyExplainsSequentialWaits() {
        let expectations: [(language: String, label: String, explanation: String)] = [
            (
                "en",
                "Wait before step",
                "A step waits before it runs. The wait starts after the previous step finishes; the first starts when the workflow begins."
            ),
            (
                "de",
                "Vor Schritt warten",
                "Ein Schritt wartet vor der Ausführung. Die Wartezeit beginnt nach Abschluss des vorherigen Schritts; beim ersten Schritt beginnt sie mit dem Workflow."
            ),
            (
                "zh-Hans",
                "步骤前等待",
                "步骤会在运行前等待。等待时间从上一步完成后开始；第一步从工作流开始时计算。"
            ),
            (
                "zh-Hant",
                "步驟前等待",
                "步驟會在執行前等待。等待時間從上一步完成後開始；第一步從工作流程開始時計算。"
            ),
        ]

        for expectation in expectations {
            setRuntimePreference(expectation.language)
            XCTAssertEqual(FeatureL10n.string("步骤前等待"), expectation.label)
            XCTAssertEqual(
                FeatureL10n.string("步骤会在运行前等待。等待时间从上一步完成后开始；第一步从工作流开始时计算。"),
                expectation.explanation
            )
        }
    }

    private func makeLocalizedTestBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("Test.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        for (language, value) in [("en", "Menu Bar Icon"), ("zh-Hans", "菜单栏图标")] {
            let lprojURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: true)
            try "\"menu.title\" = \"\(value)\";\n".write(
                to: lprojURL.appendingPathComponent("Settings.strings"),
                atomically: true,
                encoding: .utf8
            )
        }

        let englishStrings = bundleURL
            .appendingPathComponent("en.lproj", isDirectory: true)
            .appendingPathComponent("Settings.strings")
        let existingStrings = try String(contentsOf: englishStrings, encoding: .utf8)
        try (existingStrings + "\"fallback.title\" = \"Base Language\";\n").write(
            to: englishStrings,
            atomically: true,
            encoding: .utf8
        )

        return bundleURL
    }

    private func setRuntimePreference(_ preference: String?) {
        if let preference {
            UserDefaults.standard.set(preference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        PluginRuntimeLocalization.source.setPreference(preference)
    }

    private func makeLocaleSource(
        systemLanguages: [String],
        currentLocale: Locale
    ) -> PluginRuntimeLocaleSource {
        let suiteName = "PluginRuntimeLocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PluginRuntimeLocaleSource(
            userDefaults: defaults,
            systemPreferredLanguages: { systemLanguages },
            currentLocale: { currentLocale }
        )
    }
}
