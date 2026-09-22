# US-plugins-calendar-today-details — Review Recent Calendar Events

Last verified: 2026-09-17

| Field | Value |
| ----- | ------ |
| ID | `US-plugins-calendar-today-details` |
| Status | `ready` |
| Domain | `plugins` |
| Actor | `MacTools user` |

## User Story

> As a MacTools user, I want to review events around today under the month grid, with a configurable range and clear date groups, so that I can check recent and upcoming arrangements without changing the displayed month.

## Acceptance

- A new configuration shows events for today and the next two days.
- The user can choose Past, Future, or Past + Future and 1–7 total calendar days. Every range includes today; a three-day bidirectional range means yesterday, today, and tomorrow.
- Settings persist across restarts, and the previous hidden-today-details preference keeps the new agenda hidden.
- Disabling the agenda immediately hides it and restores the compact month height; range controls become disabled without losing their values.
- Dates with events form chronological groups with the selected alternate calendar's date context. Each event shows its title, time, and calendar; clicking opens the corresponding date.
- The Alternate Calendar menu offers None and Chinese lunar calendar. The initial choice follows app language (Chinese selects Chinese lunar calendar; other languages select None), then persists independently of language and region changes. Earlier explicit visibility choices migrate without being overwritten.
- The month grid, agenda, hover details, and accessibility descriptions use the same saved alternate calendar. None removes alternate-date rows without leaving empty lines. Mainland holiday and makeup-workday badges appear only in the CN system region, independently of this selection.
- The month and agenda use one continuous card with no gap. Long lists scroll within a bounded area; no events means the original month-only appearance and height.
- Initial loading does not add an empty agenda section. Permission and failure states retain compact guidance and retry actions.
- Calendar changes and day boundaries refresh the visible agenda. Hidden components stop observing changes.
- Browsing another month does not alter the agenda range, query intervening years, or duplicate cross-day events.
- Rapid month navigation preserves the loaded agenda and its height while requests are pending. Late cancelled results cannot resize it, and only a confirmed empty result removes the footer. Short lists use their intrinsic height immediately; long lists stay bounded and scroll.

## References

| Type | Source |
| ---- | ------ |
| Issue | [#17](https://github.com/ggbond268/MacTools/issues/17) |
| Feature | `docs/features/calendar-selected-day-details.md` |
| Code | `Plugins/Calendar/Sources/CalendarComponentViewModel.swift` |
| Settings | `Plugins/Calendar/Sources/CalendarSettings.swift` |
| Tests | `Plugins/Calendar/Tests/` |

## History

| Date | Type | Previous | New | Source |
| ---- | ---- | -------- | --- | ------ |
| 2026-09-14 | created | — | Fixed-today details and default-on visibility | PR #368 |
| 2026-09-16 | changed | Fixed-today details | Configurable recent agenda with bounded grouped lists | Issue #17 |
