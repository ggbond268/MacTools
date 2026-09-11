# Window Switcher redesign

Tracks #414 (roadmap), #415 (reliability), and #416 (navigation). This branch implements stages 1–2: tracking and the searchable list chooser. Multiple simultaneous previews and native Command-Tab augmentation remain follow-ups. Stages 1–2 are prepared for draft review with the validation and manual acceptance limits below. No signed release was installed. Upstream integration is required before the draft can be considered merge-ready.

## Interaction contract

- New installations preserve actual macOS Command-Tab. Option-Tab cycles all windows; Command-backtick cycles the current application's windows. Existing configurations retain inherited Command-Tab until explicit migration. The recommended preset changes inherited defaults only; custom and cleared bindings stay authoritative.
- The host resolves and validates shortcuts, including dynamic default changes. The plugin's phase-aware listener consumes those resolved bindings. An explicit scope shortcut takes precedence over the other scope's implicit Shift-to-reverse variant. Host validation includes implicit reverse chords when checking other plugins and actions; a conflicting canonical assignment suppresses the listener with a settings error until resolved. Deploy the host conflict fix with the plugin redesign; an older host does not provide the new conflict suppression.
- Hold/cycle/release uses cached windows with a 140 ms presentation delay. Initially empty discovery has a two-second bound, waits for the initial process snapshots, and preserves every forward/reverse cycle press received while waiting. Canonical actions open a persistent chooser using the host's pre-palette application target and report a discovery timeout as failure.
- Entering search, changing scope, or invoking a window action keeps the chooser open after modifier release. Clearing search does not re-enable release-to-switch. Typing from a held-modifier cycle session removes the invocation modifiers until their release, then restores ordinary editing modifiers. Native text editing owns paste, selection, and IME composition. Escape during composition belongs to the input method; otherwise it cancels.
- The nonactivating panel preserves the foreground app. The bounded list reveals the selection on navigation or filter changes and preserves manual scrolling during background metadata refreshes. Stable window identity preserves selection through metadata changes; ordering remains frozen within a session, with new arrivals appended.
- Search matches all app/title terms. Exact titles and prefixes rank before app matches and substrings; ties preserve session order. Matched terms are highlighted in both title and subtitle. Chinese input is supported; advanced pinyin and learned ranking are deferred.
- Close Window and Quit App are separate explicit commands. Requests are not reported as completed disappearance. Save/cancel dialogs remain owned by the target app. Old occurrence-based letter assignments remain stored but are no longer active.
- New chooser, preview, action, and settings strings use the plugin localization catalog, with English and Simplified Chinese translations.

## Tracking and previews

Each process owns a serial AX worker, lifetime token, and a window identity registry based on AX equality. A confirmed foreground app without windows uses its app-only entry as the current recency anchor, including activation outside the chooser. An unknown foreground target clears the anchor without erasing recency. Notifications trigger asynchronous scans with a one-second polling fallback. Per-process work coalesces; short AX timeouts and scan budgets prevent an unresponsive app from blocking the main thread or other workers.

Failed reads are distinct from confirmed empty windows. Known entries survive failures as unavailable. An application root returned as a window is invalid data. Actions revalidate identity and verify focus. Unhiding and application activation wait for observed visibility and foreground state before window focus commands. Deminiaturization waits for read-back readiness, and final focus verification allows bounded settling without repeating the action; cancellation prevents subsequent commands. Uncertain actions are never automatically resubmitted.

Optional preview capture is off by default, never saved to disk, and limited to one in-flight capture plus the latest pending request. Stale results and results after permission revocation are discarded. A unique process/geometry candidate is accepted despite AX/capture title differences; multiple candidates require a unique title match. Ambiguity produces no preview. This metadata match is only a preview compatibility heuristic, never the identity used for activation.

Scope covers windows exposed by macOS Accessibility across Spaces. Display filters use display IDs, with names for presentation; identically named monitors remain distinct. Offscreen, minimized, and hidden states do not establish Space membership. No current-Space filter is advertised without a reliable source.

## Validation evidence, 2026-09-10

- Final repository validation: `make ci DERIVED_DATA=build/WindowSwitcherRedesign` completed script tests, XCTest, and PluginKit v5 binary compatibility. The Xcode result bundle reports **3,015 passed, zero failed or skipped**; all **87 script tests** passed. The compatibility step now honors the configured build directory. Non-failing runtime QoS warnings remain in existing process, backup, disk-clean, and shared presentation code.
- The unsigned `WindowSwitcherPlugin` bundle builds successfully, including localized resources. Changelog validation, JavaScript syntax validation, and whitespace checks pass.
- The full run includes **82 Window Switcher tests**. Automated coverage includes stable identity/selection, duplicate titles, window recency, search ranking/highlighting, scrolling, shortcut migration/conflicts, cold discovery, cancellation, permission failures, unavailable AX snapshots, independent workers, delayed restoration/focus, and bounded preview capture.
- Nine regression tests added after independent review cover manual scrolling, held-modifier search and key equivalents, queued discovery presses and cancellation, missing or windowless foreground targets, explicit Shift shortcuts, and cross-plugin/action conflicts. The three reviewers rechecked their fixes without additional findings.
- The real AppKit search field editor passed Chinese paste from an isolated pasteboard, selection replacement, clearing, and marked-text Return/Escape ownership. These checks do not change the user's clipboard or establish physical IME candidate behavior.
- The final native diagnostic passed **1/10/30/60 identical-title Chrome windows** with exact counts and stable IDs. It verified selected-window capture, exact A→B→A activation/recency, recency from a focus change outside the catalog, minimized restoration with verified focus, hidden-app restoration, and closing precisely the selected window. The post-review run passed these assertions without experimental accessibility initialization.
- Showing and cancelling the real nonactivating chooser twice over the 60-window fixture preserved the foreground Chrome app and exact focused window. Final panel presentation measurements were approximately **59 ms** and **25 ms**; these exclude process startup and are not end-to-end hotkey latency.
- Earlier native runs exposed transient invalid Chrome AX data: an application-role element appeared in the windows array. A separate read-only probe observed the same aliases outside the plugin. Regression coverage now rejects these entries and preserves known snapshots as unavailable. This is a handled platform-data limitation, not a claim that MacTools repairs Chrome or macOS accessibility. No experimental/private accessibility initialization is present in production or the normal diagnostic.

The reproducible [native diagnostic](../../../scripts/diagnostics/window-switcher/README.md) uses a verified temporary Chrome profile and synthetic pages. Its assertions and cleanup are part of the review material; it is not a release smoke test. The final run exited successfully and confirmed fixture cleanup.

## Manual acceptance before release

Physical Chinese IME candidate selection and alternate input sources, physical shortcut delivery, mouse-driven external focus changes, save-dialog cancellation, fullscreen, and multiple physical displays/Spaces remain manual acceptance checks. Automated marked-text, external AX focus, permission, geometry, and lifecycle tests do not establish those results. A hung-app worker fixture proves process isolation, not measured responsiveness of every real application. No packaged signed release was installed for this work.

These gaps do not block review of stages 1–2, but must stay visible when evaluating release readiness. Multiple simultaneous previews, native Command-Tab augmentation, browser-tab search, pinyin/learned ranking, and persistent workspace features remain later work.

## Draft integration status

The implementation and validation above use base `835a78a3`. At draft preparation, upstream `main` was `c3b4fabf` and included a separate Window Switcher tracking rewrite and PluginKit v6. A trial merge identified overlapping changes in the catalog, models, chooser, plugin, shortcut listener, Makefile, and README. That trial was aborted to preserve the reviewed implementation; this branch does not yet incorporate current upstream.

Before marking the PR ready, reconcile the upstream tracking behavior and PluginKit compatibility, resolve the conflicts, and rerun repository and native validation on the integrated revision. The existing test totals do not establish compatibility with current `main`.

## Dev audit fixes, 2026-09-10

The Dev audit matched the installed plugin to local integration `13b1ebb7654c`, rather than the original draft head. That integration could discard usable AX identities when several CG windows shared their bounds, admit unconfirmed unnamed helper surfaces, and ignore available window IDs during preview capture.

- Retain confirmed AX windows during ambiguous CG matching. Keep canonical identities and recent-window order when a known window moves out of and back into AX discovery. Window actions still target the current worker's AX handle and verify focus.
- Use an optional, dynamically resolved `_AXUIElementGetWindow` read to obtain exact system window IDs after checking the AXWindow role. This is an undocumented macOS API, isolated in the AX adapter, with no accessibility initialization or hard symbol dependency. If unavailable, ordinary AX activation remains usable and preview matching falls back conservatively. This API identity bridge is also described in [AltTab's system wrapper](https://github.com/lwouis/alt-tab-macos/blob/master/src/macos/api-wrappers/ApplicationServices.HIServices.framework.swift); no third-party implementation is bundled.
- Match previews by process and exact window ID first, and retry transient capture failures at most three times. Do not substitute another window when a known ID disappears.
- Wait for fresh, uniquely matched window state after a Space transition without replaying activation. Previously confirmed untitled windows remain supported; unconfirmed unnamed offscreen CG surfaces are excluded. macOS can still withhold windows or capture content.
- Label All Windows and Current App shortcut recorders separately. Chooser-local Command-1/2 changes scope, Command-D opens the display menu, Command-P toggles preview, and Command-F focuses search. These controls make the session persistent and respect native marked-text handling.
- Match the palette/clipboard surface with continuous 14-point corners, semantic background and border colors, and reduced-transparency/increased-contrast support.

Validation results for these fixes are separate from the original draft totals above. Physical multi-display/Space interaction and IME candidate selection still require manual acceptance.

Fix validation: 142 Window Switcher tests passed against the Dev integration (zero failures or skips), and 87 repository script tests passed on the draft branch. The isolated 1/10/30/60-window Chrome diagnostic passed against both builds, with the final integration run additionally asserting native search/Enter activation and exact-ID preview capture among 60 same-title windows. Light and dark chooser surfaces were rendered with synthetic titles and inspected. The integration fixes preserve its PluginKit v6 host routing; no release was published.

### Standalone review corrections

Only exact system window IDs link AX and CG records for identity and actions. Geometry and title matching remain preview-only heuristics. One publication transaction registers fallback identities before AX discovery and retains recent history using the same canonical IDs consumed by selection and actions. A failed CG scan preserves cached rows as unavailable, cannot authorize a fallback action, and does not discard identity mappings; a successful empty scan can remove closed fallback windows.

Review-fix validation: all 148 Window Switcher tests passed on the Dev integration, including six regressions for identity assignment, late AX discovery, recency, and failed scans. The isolated 1/10/30/60-window Chrome diagnostic passed again, including exact activation, native search/Enter, preview capture, restoration, and close verification.

## Main reconciliation, 2026-09-11

Merged main at `c39b5f45` after the fixes at `a45e6989`. This supersedes the draft conflict note above. The chooser and canonical identity publication remain authoritative, with main's Accessibility revocation handling, legacy shortcut compatibility, PluginKit v6 manifest, and both scoped actions preserved. Main's panel-layout check remains in CI, and binary compatibility now validates PluginKit v6 against the selected build output. The prior all-Spaces catalog is retained for its existing compatibility tests; the active plugin uses the asynchronous catalog and shared window-record reader.

Merge validation: 254 script tests and all 4,676 XCTest cases passed, with zero test failures or skips; PluginKit v6 binary compatibility also passed. `make ci` stopped at the dashboard LTR native panel-drag fixture after all three attempts returned a cancelled drag. All eight fixture inputs are byte-identical to main, and the same failure was recorded in the prior integration. This remains a local CI limitation, separate from Window Switcher acceptance.

The merged-branch Chrome diagnostic could not complete: on both attempts, the isolated fixture application returned unsupported Accessibility attributes and discovery remained unavailable. Both temporary profiles were cleaned up. The prior successful 60-window runs remain historical evidence; native acceptance of this merged revision is not claimed.
