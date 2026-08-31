# Feature — Calendar Selected-Day Details

Last verified: 2026-08-31

Status: in-review
Source of truth: yes

## Summary

- Fix issue #280.
- Add a selected-day detail area below the monthly calendar grid.
- Show the selected date, full lunar month/day, existing holiday metadata, and existing EventKit events.
- Keep compact festival labels in the grid without letting them hide the underlying lunar day in the detail area.

## User flow

- User opens the Calendar component; the current day remains selected by default.
- User points to or selects a day in the monthly grid.
- The detail area updates to the selected day.
- A day with a festival label still shows its full lunar month/day in the detail area.
- Existing event rows remain available when EventKit authorization and event data permit it.

## Scope boundaries

- No new Calendar settings, views, or EventKit permissions.
- No new solar-term data source; the feature preserves the lunar day already available from the system Chinese calendar.
- No change to the existing compact grid labels or month navigation behavior.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| The selected day is the source for the detail area | This record | `CalendarComponentViewModel.selectedDay` | Calendar component detail view |
| Festival labels must not replace the full lunar month/day in date details | This record | `CalendarDayModel.lunarDateText` | Calendar grid popover and selected-day detail view |
| Existing event visibility and authorization behavior remains unchanged | This record | `CalendarComponentViewModel` and `CalendarEventService` | Calendar event rows |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-31 | Keep `lunarText` for the compact grid and add `lunarDateText` for full date details | Festival labels such as `中秋` currently replace the lunar day in the compact cell | Calendar model, popover, and selected-day detail only |
| 2026-08-31 | Reuse the existing localized date, holiday, and event presentation | The issue asks for missing selected-date context, not a second localization or event model | Calendar component presentation only |
| 2026-08-31 | Reserve five component height rows for the detail area | The current three-row component is sized for the calendar grid alone, and the detail can contain three event rows plus wrapped metadata | Calendar component descriptor and integration coverage |

## Plan

- [x] P001 — Revalidate issue #280, upstream state, open PRs, and the shared GitButler workspace.
- [x] P002 — Define the selected-day detail contract and scope boundaries.
- [x] P003 — Add the detail view, full lunar date model field, and focused regression tests.
- [x] P004 — Run available focused checks, record the global XCTest blocker, and complete a separate review.
- [x] P005 — Commit the isolated change and open one pull request.

## TODO

- [x] F001 — Preserve the full lunar month/day separately from compact festival labels — files: `Plugins/Calendar/Sources/CalendarModels.swift` — status: done
- [x] F002 — Render selected-day date metadata and existing events below the grid — files: `Plugins/Calendar/Sources/CalendarComponentView.swift` — status: done
- [x] F003 — Allocate component height for the detail area — files: `Plugins/Calendar/Sources/CalendarPlugin.swift`, `Plugins/Calendar/Tests/CalendarPluginIntegrationTests.swift` — status: done
- [x] F004 — Add model and presentation regression coverage — files: `Plugins/Calendar/Tests/CalendarMonthModelBuilderTests.swift`, `Plugins/Calendar/Tests/CalendarComponentViewModelTests.swift` — status: done
- [x] F005 — Verify, review, and publish the isolated change — files: `Plugins/Calendar/`, this feature record — status: done

## Acceptance / DoD

- [x] The selected-day detail area is visible below the monthly grid.
- [x] Selecting or hovering a day updates the displayed date details.
- [x] Festival days show both the festival label and the underlying lunar month/day in date details.
- [x] Existing event rows continue to use the current EventKit authorization and loading behavior.
- [x] Existing month navigation, day opening, permissions, and compact grid behavior remain unchanged.
- [ ] Focused Calendar XCTest passes; the global test target is currently blocked by unrelated TrackpadGestures compilation errors.
- [x] The Calendar plugin build, script tests, changelog validation, JSON validation, and whitespace checks pass.
- [x] Separate Standards and Specification reviews find no actionable issue after the layout/test follow-up.
- [x] One focused draft pull request closes issue #280.

## Implementation journal

- 2026-08-31 — Selected issue #280 after read-only triage. The bounded outcome is a selected-day detail area below the Calendar grid; unrelated open issues and existing Window Switcher WIP remain out of scope.
- 2026-08-31 — Contract established: preserve the compact festival label while exposing a separate full lunar month/day value for details and the existing event presentation.
- 2026-08-31 — Implemented the selected-day detail card, updated the shared date subtitle to retain festival labels beside the full lunar date, and increased the component descriptor to five rows so wrapped metadata and three event rows remain visible.
- 2026-08-31 — Added regression coverage for the Mid-Autumn full lunar date and festival subtitle, selected-day detail source updates, model construction, and the component descriptor height.
- 2026-08-31 — Verification passed: `make build-plugin PLUGIN=Calendar`, `make script-tests` (196 tests), `python3 scripts/changelog.py validate`, `jq empty`, `git diff --check`, and untracked-file whitespace validation. The focused Calendar XCTest invocation could not reach Calendar because the global target fails first on unrelated `TrackpadGestures` symbols (`MacToolsSyntheticInputEvent` and `KeyboardKeyTap`).
- 2026-08-31 — Separate Standards and Specification reviews completed with no actionable findings after increasing the layout budget and adding presentation/selection regression coverage. Manual UI acceptance remains pending because the test target cannot build.
- 2026-08-31 — Manual UI acceptance was attempted. The freshly generated Calendar package is present, but the local Debug app artifact has no executable after the global build interruption, so Computer Use could not open an app to inspect the component.
- 2026-08-31 — Commit `2a8e138a` created and draft PR [#368](https://github.com/ggbond268/MacTools/pull/368) opened for issue #280. The branch contains only the Calendar implementation, tests, README entry, feature record, index entry, and changelog; focused XCTest and manual UI acceptance remain pending as recorded above.

## Files

- `Plugins/Calendar/Sources/CalendarModels.swift`
- `Plugins/Calendar/Sources/CalendarComponentView.swift`
- `Plugins/Calendar/Sources/CalendarPlugin.swift`
- `Plugins/Calendar/Tests/CalendarMonthModelBuilderTests.swift`
- `Plugins/Calendar/Tests/CalendarComponentViewModelTests.swift`
- `Plugins/Calendar/Tests/CalendarPluginIntegrationTests.swift`
- `README.md`
- `docs/features/INDEX.md`
- `changes/unreleased/calendar-selected-day-details.md`

## Test / QA commands

- `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/CalendarMonthModelBuilderTests -only-testing:MacToolsTests/CalendarComponentViewModelTests -only-testing:MacToolsTests/CalendarPluginIntegrationTests`
- `make build-plugin PLUGIN=Calendar`
- `make script-tests`
- `python3 scripts/changelog.py validate`
- `jq empty Plugins/Calendar/Resources/Localizable.xcstrings`
- `git diff --check`
- Manual: open the Calendar component, hover and select a normal day and a festival day, confirm the detail metadata updates, and confirm an authorized day with events still shows its event rows.
