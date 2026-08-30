# Feature — Input Remapping

Last verified: 2026-08-14

Status: in-progress
Source of truth: yes

## Summary

- Separate plugin for remapping keyboard, mouse, and precise trackpad gestures.
- Scope: keyboard keys, mouse click/double-click/long-press, scroll wheel, and the precise gestures already recognized by Trackpad Gestures. Outputs include shortcuts and atomic single-key taps with distinct left/right modifiers.
- Out of scope: shell commands, macros, profiles, per-app or per-device conditions.

## User flow

- User grants Accessibility and Input Monitoring.
- User adds, enables, edits, or removes a persisted rule.
- A new rule starts as a disabled draft with direct input recording and a neutral output selector. Selecting Shortcut reveals its recorder; each captured value is then shown in its normal editor.
- To select a trigger, the user starts recording and presses a key, a mouse button, or scrolls; the recorded sequence is consumed without executing a rule.
- Recording first shows a brief preparation state so the click that opened the recorder cannot become the trigger; it then shows an explicit listening state.
- A matching click, key, or scroll executes the action. Mouse double-click and long-press keep the original click available to avoid unsafe event replay.
- When the action is a shortcut, the user can record the output combination directly; the recorded key-down and key-up are consumed.
- When the action is a single key, the user chooses it from a categorized list without generating a physical key press that another global listener could intercept.
- Each rule presents its Input, Output, and Context in three stable columns. Context is currently global; per-app and per-device conditions remain out of scope.
- A missing rule, failed action, or event carrying the Input Remapping marker passes through unchanged.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Physical mouse buttons: 0 through 32 | This document | `InputRemappingRulePolicy` | Rule model, matcher, recorder |
| Capture accepts keyboard, mouse buttons, and scroll and consumes the recorded event | This document | `InputRemappingCapturedInput` | Settings editor, CGEvent tap |
| Recording arms after its opening click and distinguishes preparation from active listening | This document | `InputRemappingButtonCaptureCoordinator` | Input and shortcut recorders |
| Shortcut output can be recorded directly and consumes its key pair | This document | `InputRemappingButtonCaptureCoordinator` | Shortcut action editor, CGEvent tap |
| Single-key output accepts ordinary macOS virtual keys except Caps Lock and system media keys while preserving left/right modifier identity | This document | `KeyboardKeyTap`, `KeyboardKeyTapEventPoster` | Trackpad Gestures, Custom Shortcuts, future plugins |
| Single-key output is selected from a shared categorized picker instead of recorded from live input | This document | `PluginKeyTapPicker` | Trackpad Gestures, Custom Shortcuts, future plugins |
| Exact modifier set required across a full compound mouse gesture | This document | `InputRemappingEventProcessor` | Event processor |
| A consumed down consumes its matching up | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| Events carrying the Input Remapping synthetic marker always pass through | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| Current and legacy MacTools synthetic-input markers pass through mixed plugin versions | This document | `MacToolsSyntheticInputEvent` | Input Remapping and Trackpad Gestures event taps |
| Failed or inapplicable actions fail open | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| An unsafe trigger (a keyboard key without modifiers or primary mouse button) is saved disabled and requires explicit confirmation before it can be enabled | This document | `InputRemappingRule` | Rule editor, event processor |
| Control-Option-Command-Escape always cancels recording and disables every unsafe trigger | This document | `InputRemappingEventTap`, `InputRemappingStore` | Global event tap, warning copy |
| An enabled precise trackpad gesture belongs to the plugin where it was activated most recently, including after restart, never both; conflicting mappings remain saved but inactive | This document | `TrackpadGestureBridge`, `TrackpadGestureOwnershipStore` | Plugin host, both plugins |
| Rule context is global only | This document | Rule editor layout | Context column |
| New rules remain disabled until input and output are configured | This document | `InputRemappingRule` configuration state | Rule editor, matcher |
| Recording is cancelled when the settings page is hidden | This document | `InputRemappingButtonCaptureCoordinator` | Settings page visibility handler |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-13 | Mission Control and Spaces use standard Control shortcuts | Match configurable macOS shortcuts without private APIs | Mission Control and space navigation |
| 2026-08-13 | Media and volume use macOS auxiliary `systemDefined` events | Function keys are not media keys on every keyboard or configuration | Play/pause and volume actions |
| 2026-08-13 | Failed or inapplicable rule keeps the original event | Preserve native mouse behavior | Fail-open behavior |
| 2026-08-13 | Permission checks are injected behind plugin seams | Cards and activation use the same real OS state and remain testable | Accessibility and Input Monitoring |
| 2026-08-13 | Synthetic-event protection is limited to the private Input Remapping marker | Public CoreGraphics source fields describe state tables or process metadata, not a reliable physical-versus-generated category | Unmarked third-party generated events can match a rule |
| 2026-08-13 | Modifier-free keyboard triggers are allowed after a warning | User requires full flexibility while being informed of global typing risk | Rule remains disabled until confirmation |
| 2026-08-14 | Trackpad gesture ownership is exclusive, persisted, and non-destructive | A single Multitouch listener must arbitrate gestures without deleting user configuration | The host restores the most recent owner; conflicting mappings remain inactive |
| 2026-08-13 | Unsafe mappings have a keyboard emergency stop | Both primary mouse buttons can otherwise make pointer-based recovery impossible | Control-Option-Command-Escape disables unsafe mappings and cancels recording |

## Known limitation

- Input Remapping-generated events carry a private marker and cannot loop back into remapping.
- macOS exposes no reliable public category for every generated event.
- A third-party generated, unmarked mouse event in the 0...32 range can match and execute a rule.

## Plan

- [x] P001 — Define scope and acceptance contract.
- [x] P002 — Add persisted rule model, CGEvent tap, and action execution.
- [x] P003 — Add localized rule editor and real permission state/actions.
- [x] P004 — Cover matching, down/up lifecycle, fail-open behavior, persistence, and plugin state.
- [x] P005 — Address first review findings.
- [x] P006 — Address second review findings and narrow unsupported synthetic-event claims.
- [x] P007 — Replace numeric trigger selection with a direct mouse-button recorder.
- [x] P008 — Generalize triggers to keyboard, mouse click/double-click/long-press, scroll, and precise trackpad gestures.
- [x] P009 — Add shared trackpad gesture arbitration and migration from Trackpad Gestures.
- [x] P010 — Redesign the rule editor around Input, Output, and Context columns.
- [x] P011 — Present each mapping as a card following When I press → Run → Where.
- [x] P012 — Match the approved card positioning and native control hierarchy.
- [x] P013 — Keep the mapping workspace within the host's standard readable-width guide.
- [x] P014 — Offer mapping deletion only once, in the card footer.
- [x] P015 — Keep the trigger controls in a mapping column visually aligned.
- [x] P016 — Keep card management controls together in the footer.
- [x] P017 — Center mapping-column labels over their respective control areas.
- [x] P018 — Start new mappings with direct input recording and output selection.
- [x] P019 — Keep recorded shortcut labels compact in the Run selector.
- [x] P020 — Guide users from the empty state to the Add Mapping control.
- [x] P021 — Localize all Input Remapping copy in every MacTools-supported language.
- [x] P022 — Name keyboard, mouse, and trackpad support in the primary-panel title.

## Acceptance / DoD

- [x] Rules can be enabled, edited, removed, and persisted.
- [x] Trigger supports physical button 0 through 32 and the exact optional modifier set.
- [x] Actions: shortcut, back/forward/middle, Mission Control, left/right space, media, and volume up/down.
- [x] Media and volume actions emit auxiliary system events, not ordinary F8/F11/F12 keystrokes.
- [x] Accessibility and Input Monitoring cards report real state and expose working actions.
- [x] Successful remapping consumes both down and matching up.
- [x] Failed actions, unmatched events, unpaired up events, and Input Remapping-marked events pass through.
- [x] Every plugin deactivation stops the event tap.
- [x] Returning to MacTools after System Settings revalidates both permissions and reapplies tap state.
- [x] User-facing plugin copy resolves through `PluginLocalization` and `Localizable.xcstrings`.
- [x] Settings use a validated `.workspace`, theme tokens, labels, and explicit control sizing.
- [x] Trigger selection uses a cancellable direct button recorder instead of a numeric stepper.
- [x] Adjacent targeted tests cover the behavioral seams.
- [x] Keyboard keys, mouse buttons, and scroll can be recorded as a trigger from the rule editor.
- [x] Modifier-free keyboard triggers show a warning and require confirmation before activation.
- [x] A trackpad gesture cannot remain active in both plugins; conflicts never delete mappings.
- [x] The most recently activated trackpad owner is restored after an app restart.
- [x] The rule editor separates Input, Output, and global Context into three columns.
- [x] Unmodified keyboard triggers persist disabled until their explicit confirmation.
- [x] Mouse double-click actions preserve the native click pair.
- [x] Shortcut recording exposes preparation and active-listening states.
- [x] Each mapping card exposes its trigger, action, and global context in the requested flow layout.
- [x] A new mapping presents direct input recording and a neutral Run selector; Shortcut reveals its recorder and each completed value persists in its editor.
- [x] Incomplete, hidden, and unsafe mappings fail open and cannot leave input interception armed.
- [x] Control-Option-Command-Escape remains available during recording and disables every unsafe mapping.
- [x] An external TipTap claim consumes its corresponding native click before dispatching its action.
- [x] The primary-panel title lists keyboard, trackpad, and mouse as supported input sources.

## Implementation journal

- 2026-08-13 — Contract, MVP scope, plan, feature index, and changelog fragment added.
- 2026-08-13 — Initial plugin added with JSON rule persistence, CGEvent tap, permission cards, and settings editor.
- 2026-08-13 — Review P1 fixed: tap now observes both `otherMouseDown` and `otherMouseUp`; `InputRemappingEventProcessor` consumes an up only after the matching down executed successfully, while preserving synthetic-event protection and fail-open behavior.
- 2026-08-13 — Review P1 fixed: permission cards now use injected Accessibility and IOHID state providers; actions prompt for Accessibility or open the Input Monitoring system pane; unknown permission IDs are never reported as granted.
- 2026-08-13 — Review P2 fixed: play/pause and volume actions now post `NX_KEYTYPE_*` auxiliary system events; rule bounds are centralized; storage decode/encode failures are logged; all user-facing plugin strings use plugin localization; settings use the host form/theme conventions.
- 2026-08-13 — Tests expanded for matching, bounds, down/up lifecycle, fail-open and synthetic events, persistence, permissions, activation, deactivation, and settings validation.
- 2026-08-13 — Checks passed: Swift parse for plugin sources and tests, string catalog JSON parse, and scoped `git diff --check`. Targeted XCTest could not run because the generated local Xcode project does not yet contain the `InputRemappingPlugin` scheme; generating project files is outside this agent's assigned files.
- 2026-08-13 — Review 2 fixed: auxiliary event data encodes down/up state once; persisted and copied button values normalize to 0...32; matching uses typed `CGEventFlags`; application activation revalidates both permissions with observer cleanup on deactivation; the Add action moved to the host section header and editor rows use edge-to-edge list chrome.
- 2026-08-13 — Synthetic-event contract narrowed to Input Remapping-marked events after checking the public CoreGraphics event-source APIs; unmarked third-party generated events remain a documented risk.
- 2026-08-13 — Review follow-up: incomplete rules are never runnable; recording consumes key repeats and scroll momentum until quiescence; hidden settings cancel capture; unsafe primary-button triggers require confirmation; and Trackpad bridge callbacks retain plugins weakly.
- 2026-08-13 — Review follow-up checks passed: plugin build, source/test parse, string-catalog JSON parse, and `git diff --check`. Targeted XCTest is blocked locally because the generated MacTools project references two App Instance Recovery files from an unapplied branch.
- 2026-08-13 — Review 2 checks passed: Swift parse, source module emission, test typecheck, both JSON parses, tracked `git diff --check`, and whitespace checks for untracked feature files. No project lint command or user pre-commit hook is configured. Targeted XCTest remains unavailable because the generated local Xcode project has no `InputRemappingPlugin` scheme.
- 2026-08-13 — UX refined: each rule now records the physical extra mouse button directly. The recorder has an explicit cancel action and lets the captured click pass through, avoiding accidental remapping during selection.
- 2026-08-13 — Verification: generated the project, built `InputRemappingPlugin`, and passed `MacToolsTests/InputRemappingModelsTests`. Existing DiskClean Swift-concurrency warnings remain outside this feature.
- 2026-08-13 — User expanded the contract to keyboard, mouse click/double-click/long-press, scroll, and the precise Trackpad Gestures catalog. Modifier-free keys require confirmation; trackpad ownership is exclusive and must be brokered through the host.
- 2026-08-13 — Implemented universal capture and persisted keyboard, mouse, scroll, and trackpad triggers. Double-click executes on the second down; long-press executes on release; both retain the source click to avoid buffering and replaying native input.
- 2026-08-14 — Review fix: the host now keeps stable non-destructive trackpad gesture ownership. Both plugins retain conflicting saved mappings, while only the current owner receives recognition.
- 2026-08-14 — Review follow-up: both mapping settings surfaces identify a saved enabled gesture that is inactive because another plugin currently owns it.
- 2026-08-13 — Recording now consumes the captured event and matching key-up or mouse-up; a successful keyboard remap also consumes both key-down and matching key-up. macOS no longer receives the source input after capture or remapping.
- 2026-08-13 — Added a dedicated shortcut-output recorder. It captures the next keyboard combination and consumes its full key pair.
- 2026-08-13 — Redesigned the rule editor into stable Input, Output, and Context columns. The input column reveals only source-specific controls; Output keeps action and shortcut recording together; Context contains scope, enablement, safety guidance, and deletion. Global scope is explicit while conditional contexts remain out of scope.
- 2026-08-13 — Fixed accidental input capture: the recorder waits briefly after the Record button action before arming. The UI communicates “Preparing recording” then “Listening for an input”; regression coverage proves the opening mouse click is ignored.
- 2026-08-13 — Replaced repeated rule cards with a master-detail workspace: a compact selectable `Input → Output` rule list on the left and one three-column selected-rule editor on the right. Selection safely falls back to the first rule after additions or deletions.
- 2026-08-13 — Reverted the master-detail workspace at user request. Rules again render directly in the settings list; the three-column Input, Output, and Context editor remains for each rule.
- 2026-08-13 — Review fixes: unmodified keyboard triggers now centrally persist disabled until confirmation; double-click actions preserve their native click pair; shortcut recording renders preparation and listening states; universal matcher, interaction, and trackpad-claim paths have targeted coverage; universal copy and human-readable localized trackpad gesture titles replace stale button-only and raw identifiers.
- 2026-08-13 — Checks passed: generated project, `InputRemappingPlugin`, `TrackpadGesturesPlugin`, and `MacTools` Debug builds; targeted Input Remapping XCTest passed through the MacTools scheme; localization JSON parse and `git diff --check` passed. The plugin scheme has no test action.
- 2026-08-13 — Kept the mapping workspace within the host's readable-width guide; responsive column minimums preserve all three controls in a narrow detail pane without overflowing the sidebar.
- 2026-08-13 — Removed the redundant header overflow menu; the card footer is now the single deletion control.
- 2026-08-13 — Set the same fixed label width inside the native trigger and interaction menu buttons so their visible control bounds align.
- 2026-08-13 — Removed the redundant trigger heading and grouped enablement with deletion in the card footer.
- 2026-08-13 — Centered the When I press, Run, and Where labels across their mapping columns.
- 2026-08-13 — New mappings persist as disabled drafts. Input recording is direct; Run first asks the user to choose an action, and Shortcut then reveals its recorder. Legacy rules decode as fully configured.
- 2026-08-13 — Removed the redundant command icon before a recorded shortcut in the Run selector; system-action icons remain visible.
- 2026-08-13 — Replaced the empty-state sentence with a centered first-mapping prompt that explicitly directs users to Add Mapping.
- 2026-08-13 — Added all supported MacTools locales to the plugin string catalog and package metadata.
- 2026-08-13 — Corrected the Run column label in every locale to mean execute an action rather than physical running.
- 2026-08-13 — Kept Input Remapping-generated events out of both input recorders, declared its system frameworks locally, and added the feature to the Simplified Chinese README.
- 2026-08-13 — Renamed the user-facing feature to Custom Shortcuts and harmonized its creation, deletion, and empty-state copy in every supported locale.
- 2026-08-13 — Refresh the plugin title and subtitle whenever the app language changes, matching the localized editor controls.
- 2026-08-13 — Confirmed modifier-free keyboard rules persist their acknowledgement; external trackpad claims remove conflicting local gestures in either editing order.
- 2026-08-13 — Reworked the mappings list into individual cards matching the approved When I press → Run → Where flow. The page subtitle is “Create shortcuts from keyboard/trackpad/mouse”; enablement and destructive actions moved to the card header/footer.
- 2026-08-13 — Removed the enclosing Form section card. The settings page now uses its task-oriented workspace shell, leaving only the individual mapping cards visible.
- 2026-08-13 — Aligned mapping cards with the approved reference: bordered control fields, one shortcut value field rather than duplicated output controls, and the exact conditional Run presentation for shortcuts versus predefined actions.
- 2026-08-13 — Fixed the empty settings page: the dynamic-plugin manifest now declares the workspace layout used at runtime; its localized marketplace summary now matches the multi-device mapping scope.
- 2026-08-13 — Refined the approved card layout: full-width native menu buttons for Input, interaction, Run, and Where; recording moved into the Input menu; shortcut output uses one selectable value field plus a full-width recording action; secondary modifier controls are hidden from the primary scan path.
- 2026-08-13 — Review 3 fixed: confirmed modifier-free keyboard rules persist their acknowledgement; the Core trackpad bridge observes both plugins and removes conflicting local mappings in either editing order; its provider/consumer seam is covered by an adjacent integration test.
- 2026-08-13 — Review 4 fixed: Trackpad Gestures mapping mutations notify the Core bridge, so adding or re-enabling a gesture already claimed by Custom Shortcuts removes the conflicting local mapping immediately.
- 2026-08-13 — Review 5 fixed: ownership now follows the most recently activated mapping in either plugin; disabled or incomplete Custom Shortcuts drafts do not claim gestures; double-click and long-press require stable modifiers across their full sequence; the settings contract now records the approved workspace layout. No manifest, registry, or inventory update was required.
- 2026-08-13 — Auto-grill hardening: unsafe confirmation is persisted under a domain-specific key with legacy migration; capture drains the complete keyboard, mouse, or scroll sequence before the tap can stop; native dual-click controls replace checkbox emulation; removed Trackpad bridge participants are explicitly disconnected; Control-Option-Command-Escape cancels capture and disables every unsafe mapping.
- 2026-08-13 — Verification after auto-grill: targeted `InputRemappingModelsTests` and `TrackpadGestureBridgeTests` pass; the Input Remapping plugin scheme builds; source parsing, localization JSON parsing, and whitespace validation pass. Existing Disk Clean Swift-concurrency warnings remain outside this feature.
- 2026-08-14 — Review fixes: external TipTap claims consume the native click; the emergency stop resets recorder UI even while arming; recorder startup activates the emergency tap before the preparation delay. The release helper is documented to rebuild and bump affected plugin packages after the shared PluginKit API change.
- 2026-08-14 — P022 complete: the primary-panel title now carries localized keyboard, mouse, and trackpad indicators using the existing compact-indicator contract. Code: `Plugins/InputRemapping/Sources/InputRemappingPlugin.swift`; tests: `Plugins/InputRemapping/Tests/InputRemappingModelsTests.swift`.
- 2026-08-14 — Review follow-up: corrected the Portuguese Trackpad label and documented the title indicators in both README variants.
- 2026-08-14 — User superseded the compact badges: the localized title itself now ends with `⌨️𝌕🖱️`; the compact-indicator implementation and its unrelated Portuguese-label correction were removed.
- 2026-08-14 — User superseded the title symbols because they did not render. The localized title now names keyboard, trackpad, and mouse directly; the Portuguese Trackpad label was corrected for this visible title.
- 2026-08-14 — Aligned the full localized title in runtime metadata, the string catalog, settings-title copy, and `plugin.json` marketplace metadata.
- 2026-08-14 — Replaced the redundant source-list subtitle everywhere with localized “Map inputs to actions” copy.
- 2026-08-14 — Updated the Custom Shortcuts plugin icon to `arrow.left.arrow.right`.
- 2026-08-14 — Review fix: persisted precise-trackpad ownership in Core and restore it after restart.

## Files

- `Plugins/InputRemapping/`
- `Sources/Core/Plugins/TrackpadGestureBridge.swift`
- `Sources/Core/Plugins/TrackpadGestureOwnershipStore.swift`
- `docs/features/input-remapping.md`
- `docs/features/INDEX.md`
- `changes/unreleased/input-remapping.md`

## Test / QA commands

- `swiftc -parse Plugins/InputRemapping/Sources/*.swift Plugins/InputRemapping/Tests/*.swift`
- `ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' Plugins/InputRemapping/Resources/Localizable.xcstrings`
- `xcodebuild -project MacTools.xcodeproj -scheme InputRemappingPlugin -configuration Debug -derivedDataPath build/DerivedData test -quiet`

## History

<!-- Read only for bugs, regressions, audits, or explicit requests. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
