# Feature — Calendar Recent Agenda

Last verified: 2026-09-17

Status: in-review
Source of truth: yes

## Summary

Addresses issue #17 by replacing the fixed-today details area with an optional agenda grouped by date. The default range includes today and the next two days. Date groups include the selected alternate calendar and applicable holiday context.

## Settings and range semantics

The Recent Events section contains a visibility switch, a segmented Past / Future / Past + Future picker, and a 1–7 day count picker. The count is always the total number of calendar days, including today:

- Future: today through N − 1 days ahead.
- Past: N − 1 days ago through today.
- Past + Future: centered on today; even counts allocate the extra day to the future. Three days means yesterday, today, and tomorrow.
- One day means today in every direction.

All preferences persist. An existing Show Today Details preference migrates to agenda visibility, preserving an explicit hidden setting. Range controls remain visible but disabled while the agenda is hidden.

## Alternate calendars and regional holidays

The Alternate Calendar menu offers None and Chinese lunar calendar. On first configuration, a Chinese app language (Simplified or Traditional) selects Chinese lunar calendar; other languages select None. The resolved choice persists, so subsequent language or region changes do not replace it. Region, time zone, and the system's primary calendar do not choose an alternate calendar. Earlier explicit Show and Hide preferences migrate to Chinese lunar calendar and None; an earlier Automatic preference resolves using the current app language.

The saved selection applies to the month grid, agenda date subtitles, hover details, and accessibility descriptions. None leaves no empty subtitle rows, and month titles use localized month names and ordering. The settings page uses a menu rather than separate visibility and calendar controls.

Bundled statutory holidays and makeup workdays apply only to the CN system region, independently of app language or alternate calendar selection. Other regions retain their EventKit calendar events, including subscribed holidays, without receiving mainland work schedules. Lunar festivals do not repeat in leap months. Region changes refresh holiday badges without changing the alternate calendar selection, and reopening applies changes made while hidden.

Apple separates optional alternate calendars from region-based holiday subscriptions. MacTools follows this separation and supplies its own language-based initial choice. See [Apple alternate calendars](https://support.apple.com/guide/calendar/a-chinese-hebrew-islamic-lunar-calendar-icl263c22bef/mac) and [Apple holiday calendars](https://support.apple.com/en-ie/guide/calendar/iclead4e0ec3/mac).

## Panel behavior

- Dates sit directly on the shared card without permanent tile backgrounds. Today uses an accent outline, and hover adds a temporary fill. Date numbers remain centered when the alternate calendar is None; event dots occupy a separate bottom overlay and never shift the date text. Changing the alternate calendar preserves the measured panel height until the content actually resizes. The month header uses compact previous and next icons around a localized Today text button, with localized help and accessibility labels.
- Hover surfaces use the component theme's control-hover token. Today uses primary text and the same theme outline in the month and agenda, including weekends; accent colors identify the date without replacing readable small text. Holiday and makeup-workday badges use distinct theme palette hues with subtle tinted fills. Their text colors retain the category hue while meeting small-text contrast in standard and increased-contrast appearances; opaque fills keep this contrast stable on hover. Event markers preserve their source calendar colors, including on adjacent-month dates.
- Only dates with events appear as groups, ordered chronologically. Today has a highlighted date badge; yesterday and tomorrow use relative labels.
- Each event shows its title, time or all-day label, calendar name, and original calendar color. Clicking an event opens the group's date in system Calendar.
- The month and agenda share one continuous card with a subtle internal divider and no gap or separate rounded background. The list grows with its content up to 480 points, enough for about ten regular events; date groups and wrapped titles affect the visible count. Longer lists scroll without visible scrollbars, and no events are truncated.
- With no events, the agenda header, divider, and list disappear, preserving the original month appearance and height. Initial loading also keeps the month compact; an existing agenda stays visible while refreshing. Missing permission and query failures retain compact guidance and retry actions inside the shared card.
- Month navigation and date hover do not change the agenda range. Hover popovers use one theme background across the body and attachment arrow, with event content constrained to the native safe area.
- Month navigation, returning to today, and changing the first weekday retain the last loaded events while refreshing. A complete successful result replaces the snapshot; cancelled requests cannot overwrite it. A confirmed empty agenda removes the footer. Retry guidance remains visible until the retry resolves.
- Calendar changes, day boundaries, and returning to the application refresh visible data through debounced observers. Observers stop when the component is hidden.

## Implementation

- `CalendarDisplayPolicy` is the single entry point for the language-based default and mainland holiday eligibility. `CalendarSettingsStore` resolves and persists the initial selection; views never repeat these rules.
- `CalendarAlternateCalendar` defines stable selection IDs and localized menu options. `CalendarMonthModelBuilder.alternateDateText` dispatches formatting for the saved selection; generic alternate-calendar fields feed every display surface. Additional calendars extend the enum and formatter without changing view-level conditions.
- `CalendarAgendaRange` computes bounded calendar-day ranges using calendar arithmetic, including across daylight saving transitions.
- `CalendarSettingsStore` persists visibility, direction, and count, and migrates the previous visibility key.
- `CalendarComponentViewModel` queries the 42-day month grid and, when required, a separate range of at most seven agenda dates. Results from the second query fill only dates outside the grid, preventing duplicate cross-day events.
- Cancellation is checked after each query before publishing a snapshot. Disabled agendas never query distant dates.
- `CalendarAgendaView` selects intrinsic content or a 480-point scrolling viewport in the same layout pass, avoiding an estimated list height followed by asynchronous measurement. `CalendarComponentView` measures the complete intrinsic content before the host frame; `CalendarPlugin.descriptor` rounds up to the host's 8-point grid and notifies the host. The fixed six-row month content is 298 points (304 points after grid rounding). Library previews do not resize live widgets.
- Uses the existing EventKit event permission and Calendar opening path. No reminder completion or priority states are inferred from calendar events.

## Validation

Focused tests cover preference migration and persistence, all counts and directions, year boundaries, daylight saving time, month-independent groups, cross-day grouping, event-store notification debounce and teardown, permission and error handling, settings actions, cached views, bounded scrolling, and rendered snapshots, including identical month-only rendering when the agenda is empty or disabled.

```sh
make generate
make validate-changelog
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/CalendarAgendaRangeTests \
  -only-testing:MacToolsTests/CalendarComponentViewModelTests \
  -only-testing:MacToolsTests/CalendarSettingsStoreTests \
  -only-testing:MacToolsTests/CalendarMonthModelBuilderTests \
  -only-testing:MacToolsTests/CalendarPluginIntegrationTests \
  -only-testing:MacToolsTests/CalendarEventPopoverTests \
  -only-testing:MacToolsTests/CalendarDisplayPolicyTests \
  -only-testing:MacToolsTests/CalendarLayoutStabilityTests \
  -only-testing:MacToolsTests/CalendarEventGrouperTests
```

## References

- [Issue #17](https://github.com/ggbond268/MacTools/issues/17)
- [Original today-details issue #280](https://github.com/ggbond268/MacTools/issues/280)
- [Calendar agenda user story](../user-stories/plugins/calendar-today-details.md)
