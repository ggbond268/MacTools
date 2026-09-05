import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSnippetKeywordNoticeTests: XCTestCase {
    func testNoticeTracksActualToggleRatherThanListenerReadiness() throws {
        let suite = "ClipboardSnippetKeywordNoticeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardHistorySettingsStore(storage: UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults
        ))
        let notice = ClipboardSnippetKeywordNotice(
            settings: settings, localization: PluginLocalization(bundle: .main)
        )
        XCTAssertTrue(notice.isExpansionDisabled)
        settings.isKeywordExpansionEnabled = true
        settings.setKeywordExpansionStatus(.accessibilityRequired)
        XCTAssertFalse(notice.isExpansionDisabled, "Permission failure is not a disabled toggle")
        settings.setKeywordExpansionStatus(.ready)
        settings.isKeywordExpansionEnabled = false
        XCTAssertTrue(notice.isExpansionDisabled, "A stale listener status must not hide the off notice")
        settings.isKeywordExpansionEnabled = true
        XCTAssertFalse(notice.isExpansionDisabled)
    }
}
