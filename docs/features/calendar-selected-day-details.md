# Feature — Calendar Today Details

Last verified: 2026-09-14

Status: in-review
Source of truth: yes

## Summary

Addresses issue #280 by showing today's full lunar date, holiday context, and agenda below the monthly calendar. Festival labels remain compact in the grid without hiding the full lunar month and day in date details.

## User flow

- Open Calendar to see the month grid and today's details. The details setting is enabled by default.
- Hover an individual date to see its existing popover. Selecting or hovering another date does not change the lower area, which stays on today.
- Turn off **Show Today Details** in Calendar settings to hide the lower area immediately and restore the compact component height. Turning it on restores the details and their space.
- Reopening the component after a day boundary refreshes today's date and agenda.
- The visibility setting persists across application restarts.

## Implementation

- `CalendarDayModel.lunarDateText` preserves the full lunar date separately from compact festival labels.
- `CalendarComponentViewModel.todayDay` supplies the lower detail area independently of the selected date.
- `CalendarComponentView` observes `CalendarSettingsStore` so cached component views reflect setting changes.
- `CalendarPlugin.descriptor` derives the component height from the same visibility setting.
- Event loading queries the 42-day month grid and, only when today lies outside it, one additional day. Each result is grouped only for the dates requested by that query, so a cross-day event returned by both queries appears once per day.
- Cancellation is checked after each event query before publishing results.

## Scope

- Reuses existing EventKit authorization, event rows, holiday data, and per-date popovers.
- Adds no permissions, dependencies, solar-term data source, or PluginKit contract.
- Preserves month navigation, date selection, and opening dates in the system Calendar application.

## Validation

Focused Calendar tests cover default and persisted visibility, updates to a cached rendered view, compact and expanded component heights, fixed-today behavior, refresh across a day boundary, bounded queries for distant months, cross-day event grouping, and full lunar dates on festival days.

```sh
make generate
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/CalendarComponentViewModelTests \
  -only-testing:MacToolsTests/CalendarSettingsStoreTests \
  -only-testing:MacToolsTests/CalendarMonthModelBuilderTests \
  -only-testing:MacToolsTests/CalendarPluginIntegrationTests \
  -only-testing:MacToolsTests/CalendarEventGrouperTests
```

## References

- [Issue #280](https://github.com/ggbond268/MacTools/issues/280)
- [PR #368](https://github.com/ggbond268/MacTools/pull/368)
- [Calendar today details user story](../user-stories/plugins/calendar-today-details.md)
