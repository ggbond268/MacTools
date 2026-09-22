import Foundation
import MacToolsPluginKit

enum CalendarAlternateCalendar: String, CaseIterable, Sendable {
    case none
    case chinese

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .none: localization.string("settings.alternateCalendar.none", defaultValue: "无")
        case .chinese: localization.string("settings.alternateCalendar.chinese", defaultValue: "农历")
        }
    }
}

/// Keeps language defaults and region-specific holiday eligibility in one place.
/// Rendering consumes the saved selection and never infers it from a region.
enum CalendarDisplayPolicy {
    static func defaultAlternateCalendar(languageIdentifier: String? = nil) -> CalendarAlternateCalendar {
        let language = languageIdentifier ?? PluginRuntimeLocalization.preferredLanguages.first ?? "en"
        return Locale(identifier: language).language.languageCode?.identifier == "zh" ? .chinese : .none
    }

    static func showsMainlandHolidayBadges(in systemLocale: Locale) -> Bool {
        // The bundled schedule covers mainland China's days off and makeup workdays.
        systemLocale.region?.identifier == "CN"
    }
}
