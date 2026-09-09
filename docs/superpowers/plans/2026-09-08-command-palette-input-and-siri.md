# Command Palette Text Input and Siri Integration

Status: Implemented for draft review. The initial plugin exposes new conversations; continuation remains gated. See the validation record below for completed checks and remaining manual coverage.

Baseline: MacTools checkout `47c95d8c`, inspected on 2026-09-08. Recheck the affected APIs before implementation if the branch has advanced.

## Outcome

Users can open the MacTools command palette and either type `ask siri <message>` followed by Return, or select a Siri action and compose its message in a dedicated input step. MacTools handles opening Siri, finding the destination, entering the message, and confirming submission. Siri displays the answer in its own app.

Build two layers:

1. Host-owned text input, with explicit command aliases and a select-and-compose flow, that any explicitly participating action provider can use.
2. A focused Siri plugin that implements and validates Siri's particular interaction sequence.

The first release includes shared palette input and these Siri actions:

- **Ask Siri — New Conversation:** start a separate conversation and send the entered message.
- **Continue Current Siri Conversation:** send to the conversation selected when the input session is prepared, provided that destination can still be verified at submission.

Continuation is a separate acceptance gate. If the destination cannot be identified reliably, ship the new-conversation action first and leave continuation unavailable; do not silently send to whichever conversation is selected later.

## Scope

Included:

- One required free-text field per participating action, with optional provider-prepared destination context.
- Explicit provider-declared aliases for inline input, starting with `ask siri <message>` for a new Siri conversation, submitted with one Return and no intermediate action-selection step.
- Keyboard and mouse entry into the same input flow.
- Shared validation, execution admission, cancellation, and error presentation.
- Siri discovery, Accessibility permission guidance, app opening, conversation targeting, text entry, and submission verification.
- Focused automated coverage and real interaction validation from the built MacTools app.

Deferred:

- A user-configurable automation editor, macro recorder, coordinate-based clicking, or arbitrary app automation.
- Adding text input to Apple Shortcuts and Saved Scripts. They are intended later consumers of the shared contract, not dependencies of this release.
- Searching or selecting arbitrary past Siri conversations, persistent conversation bookmarks, attachments, voice input, and response streaming into MacTools.
- Fuzzy inference of command/message boundaries, user-editable aliases, direct hotkeys for input actions, Action Grid input forms, Run Links, CLI, App Intents exposure, and unattended automation for these actions.
- A shared Accessibility automation framework. Keep Siri-specific helpers inside its plugin until another implemented integration demonstrates what should be shared.

## Evidence and limits

The authorized feasibility test used the installed Siri AI app on macOS 27.0 build `26A5425a`:

| Observation | Implementation consequence |
| --- | --- |
| Siri AI identifies as `com.apple.campo`. | Resolve and verify the installed app by bundle identity. Do not confuse it with the older Siri launcher or agent. |
| Its bundled App Intents action list was empty and no AppleScript dictionary was found. | No verified native Shortcuts action or scripting command exists for this workflow. |
| The app registers `siri:`, but no supported prompt/conversation URL contract was verified. | Do not depend on invented or undocumented URL parameters. |
| Accessibility exposes `newChatButton`, `promptViewTextField`, and the field's `AXConfirm` action. | Use these controls, with role, ancestry, availability, and action validation. |
| Directly setting the field value and invoking `AXConfirm` submitted messages successfully. | Clipboard replacement, simulated typing, and a visible Send button are not required for the successful repeat path. |
| Four harmless prompts received the expected replies across three test conversations. | Basic new-chat delivery and continuation of the selected test chat are feasible on this build. |
| After a normal quit, a Siri process existed without a usable message field. | A process-presence check is insufficient. Explicitly open the app and wait for a usable window. |
| AppleScript access to System Events was denied with error `-1743`. | The Apple Shortcuts/AppleScript route remains unverified. Use native Accessibility APIs for the plugin. |

The initial test included simulated typing while investigating the controls. Subsequent successful tests used direct Accessibility text entry and submission. The tests did not establish a public Apple compatibility guarantee, true cold-process behavior, arbitrary conversation lookup, multiple-window handling, resistance to simultaneous user interaction, or operation from the built MacTools plugin.

The exploratory scripts in the session's temporary directory are evidence, not production dependencies. Reimplement the small supported sequence with explicit ownership, cancellation, bounded waits, and tests.

## Existing architecture to preserve

- `Sources/MacToolsPluginKit/ActionModels.swift` already defines typed parameters, privacy and portability, execution capabilities, exposure policies, and cancellation handles.
- `Sources/Core/Actions/ActionRegistry.swift` validates complete references. Its catalog rejects entries missing required parameters, and the default plugin catalog omits parameterized definitions.
- `Sources/App/MacToolsSearch.swift` currently represents executable results as complete `ActionReference` values. Search text is a filter, not action input.
- `Sources/App/UnifiedSearchPaletteView.swift` owns selection and execution entry. The host must continue owning the input UI rather than delegating a custom palette to Siri.
- `Sources/App/ActionGridOverlayController.swift` contains `ActionSurfaceExecutionSupport`; coordinate changes here with the palette's existing execution lifecycle.
- `Sources/Core/Actions/ActionExecutor.swift` owns execution admission, exact-definition revalidation, and surface-independent execution. Its concurrency coordinator keys by the entire reference, including parameter values.
- `Sources/App/CommandPaletteRecentStore.swift` persists only parameter-free references. Preserve that restriction for this release.
- `Sources/Core/Plugins/PluginHost.swift` owns provider registration and runtime bridging. Add input discovery alongside existing action registration, without replacing canonical execution.

## User interaction

### Inline command and message

The quick path is:

```text
Open palette → type "ask siri suggest three ideas for dinner" → Return
```

This resolves to **Ask Siri — New Conversation**, with the exact message `suggest three ideas for dinner`. It uses the same provider session, validation, and execution path as selecting that action and composing separately.

1. While the user types an ordinary query, show normal search results.
2. When the input begins with the registered alias `ask siri` followed by a space, visibly identify **Ask Siri · New Conversation** and distinguish the remaining message from the command prefix. Stop using the message suffix to filter search results. Recognition does not execute, open Siri, or create a conversation.
3. Return submits the message directly; there is no intermediate selection Return. Mouse Send does the same thing. An empty or whitespace-only suffix cannot submit.
4. Typing only `ask siri` and pressing Return opens the full editor with an empty message. Ordinary fuzzy search, such as searching for `Siri` and selecting a result, also remains available.
5. Provide an explicit Compose control to move the suffix into the full editor unchanged, for longer or multiline messages. Returning from that editor restores the inline draft within the current palette session.
6. Keep the raw input editable without rewriting its text or moving the caret when recognition occurs. Editing/removing the prefix reparses the input and returns to ordinary search when it no longer matches. Escape exits inline mode to ordinary search with the raw text retained and recognition suppressed until the next text edit; another Escape closes the palette.
7. Do not recognize a new prefix or submit while marked-text composition is active. Return first commits IME composition. Once recognized, search-result Command-number shortcuts must not execute an unrelated result.

Both input paths must show the same destination and submit semantics. A temporarily unavailable or invalidated recognized action remains visibly unavailable; pressing Return must not fall through to execute a different search result.

### Alias matching rules

- Aliases are an explicit opt-in field of the input action descriptor, independent of display titles, search keywords, and localized fuzzy matching. The initial Siri alias is `ask siri`; do not implicitly introduce `siri` or aliases for continuation.
- Match at the start of the raw query, case-insensitively, with an exact alias boundary. An alias alone opens the editor on Return; an alias followed by one ASCII space starts inline message input. `ask siriously` and `please ask siri ...` are ordinary searches.
- Consume the alias and exactly one separator space. Preserve the remainder byte-for-byte as the message, including additional spaces, casing, punctuation, Unicode, and pasted line breaks. Apply the message-size limit to this suffix, not the alias. Do not shell-parse, interpolate, trim, or normalize the message.
- Localized aliases can be declared explicitly and pass the same validation. Keep `ask siri` available regardless of UI language. Do not derive aliases automatically from translated titles.
- Reject empty aliases, aliases with leading/trailing whitespace or control characters, and ambiguous bindings. Exact collisions or aliases that prefix another alias at a space boundary across different actions disable the affected inline bindings; both actions remain discoverable through ordinary selection. Report descriptor diagnostics instead of choosing by registration order or search rank.
- Parse with source ranges into the original string so case-insensitive matching cannot corrupt the suffix offset. Cover Unicode case-folding and grapheme boundaries even though the initial alias is ASCII.

### Search and compose

1. The user searches for a Siri action. Selecting it opens the input step; it does not launch a request.
2. The input step shows the action title, a concise destination description, a message editor, a Send button, and a Back control.
3. The new-conversation action clearly names a new Siri conversation as the destination.
4. The continuation action prepares a read-only destination snapshot and displays its title when reliably available. Otherwise display a precise unavailable state rather than a generic promise to continue the latest chat.
5. Return sends; Shift-Return inserts a newline. During Chinese/Japanese or other marked-text composition, Return commits composition and must not submit. Mouse Send uses the same validation and execution path.
6. Escape goes back from the input step; another Escape closes search. Restore the prior search query and selection. Keep the draft only within the current palette session, and clear it when that session closes.
7. Command-number result shortcuts must not invoke search results while the editor owns input. Do not steal ordinary editing shortcuts.

For both input paths, reject empty or whitespace-only messages. Preserve the exact nonempty input, including Unicode, punctuation, and line breaks. Set a documented initial cap of 4,096 UTF-8 bytes to match the existing action-string limit, with matching provider validation; do not describe this as Siri's own limit.

### Execution and feedback

- Submission is a deliberate user action. These local Siri commands should not add a second generic confirmation dialog after Send. Existing confirmation-required actions must retain their usual policy when using the shared input infrastructure.
- Disable repeated submission as soon as execution is admitted.
- While admission is pending, show progress in the palette. After acceptance, hand progress and cancellation ownership to the provider's host-rendered status surface, then dismiss the palette so Siri can be shown.
- Use concise stages: opening Siri, preparing the conversation, entering the message, and sending.
- Success means the exact message appeared as a new user message in the selected conversation. It does not mean Siri completed its answer or carried out any requested downstream task.
- If submission might have happened but cannot be confirmed, show an explicit uncertain result and direct the user to Siri. Do not offer an automatic retry that might duplicate the message.
- Cancellation before submission prevents sending. Once submission has been invoked, cancellation cannot promise to retract it; report the actual phase and verify the outcome where possible.

## Shared input contract

### Additive PluginKit capability

Introduce a separate optional protocol, provisionally `PluginActionInputProviding`, with new models in `Sources/MacToolsPluginKit/ActionInputModels.swift`. Keep existing `MacToolsPlugin` and `PluginActionProviding` requirements and existing public value layouts unchanged wherever possible.

The capability needs to provide:

- An explicit list of input action descriptors keyed by an existing canonical `ActionKey` and parameter schema version.
- The message parameter ID, localized label and placeholder, submit label, multiline presentation, and length constraint.
- Optional explicit command aliases, including localized variants, resolved and validated by the host rather than parsed independently by plugins.
- A bounded preparation operation returning an ephemeral input session: destination summary, fixed parameters if needed, and a session identity.
- A session-release operation for Back or dismissal before execution, provider unload, terminal execution, and expiry. On execution acceptance, transfer ownership to the running invocation so closing the palette cannot invalidate its destination token.

The first version supports exactly one editable string parameter. Provider-prepared parameters are immutable in the editor and must conform to the canonical action schema. Unsupported or malformed descriptors are rejected with diagnostics; they do not partially appear as runnable commands.

Preparation must not send a message or create a new conversation. For Siri continuation it may inspect the running app's selected conversation. If no existing destination is available, report that condition and let the user select the new-conversation action.

Names and exact signatures should be finalized in the first implementation change, with a small fake provider proving the entire contract before the Siri plugin consumes it.

### Discovery and execution

- Maintain a distinct input descriptor collection and a distinct search action such as `.collectActionInput(...)`. Do not create incomplete `ActionReference` catalog entries or weaken required-parameter validation.
- Build a host-owned alias resolver from that descriptor collection, returning a resolved action identity and a message source range, an ordinary search, or an unavailable/ambiguous binding. Rebuild it with provider and locale changes. Keep parsing independently testable, provisionally in `Sources/App/CommandPaletteAliasResolver.swift`.
- Identify descriptors by action key and schema, never by the user's message. Preserve normal ranking, localization, and selection behavior.
- Inline recognition and select-and-compose converge on one input-session state model. Recognizing an alias creates only local input state; perform bounded provider preparation when the user submits or explicitly opens Compose. Revalidate that the prepared destination matches the destination shown before executing. The initial new-conversation alias has a fixed destination description; continuation has no inline alias in this release.
- Validate the descriptor against the live registered definition and provider generation when opening input and again when submitting.
- Only after input and prepared parameters are complete, build an ordinary `ActionReference` and `ActionInvocation`, with source `.unifiedSearch` and foreground execution mode. Execute through `ActionExecutor`.
- Provider replacement, removal, schema changes, and revoked permissions invalidate the prepared session. Keep error presentation understandable and require a newly prepared session before another attempt.
- Do not add these incomplete input templates to Action Grid, shortcut assignments, Run Links, CLI, or system action exposure. Existing complete parameterized catalog actions must continue working unchanged.

### Privacy and compatibility

- Declare message text and any destination token `.sensitive` and `.localOnly`.
- Do not record prompt text, conversation titles, destination tokens, or response text in recent actions, logs, telemetry, backups, exported preferences, presets, or URLs.
- Treat a raw inline query containing an action message as sensitive input as well. Do not leak it through search-query logging, restored query storage, diagnostic descriptions, or alias-parser errors. Keep the raw query, editor draft, and parsed message in memory for the current session only.
- Retain only the active input/execution data in memory. A bounded provider status snapshot may retain phase, time, and a generic error, but not message or response content.
- Preserve `CommandPaletteRecentStore`'s current parameter-free restriction. Adding input-action identities to recents is separate future work.
- Register each new public symbol in the minimum-host compatibility inventory. Set Siri's `minHostVersion` to the first host release actually shipping this API; the rebased implementation uses the upcoming `1.3.0` / PluginKit v6 line.
- Run the existing PluginKit v6 binary compatibility validation. An optional protocol is the preferred approach, not proof that compatibility is preserved. Resolve any required ABI/catalog version changes before packaging.

## Siri plugin design

Add `Plugins/Siri/` with stable plugin ID `siri` and canonical action IDs `ask-new-conversation` and `continue-current-conversation`.

Suggested implementation files:

| File | Responsibility |
| --- | --- |
| `Sources/SiriPlugin.swift` | Plugin registration, action/input descriptors, permission and exposure policies, status notifications. |
| `Sources/SiriController.swift` | Invocation-wide ownership, state machine, cancellation, deadlines, destination sessions. |
| `Sources/SiriApplicationClient.swift` | Bundle discovery, explicit app opening, process identity and window lifecycle. |
| `Sources/SiriAccessibilityClient.swift` | Bounded semantic AX lookup, exact text entry, `AXConfirm`, and submission evidence. |
| `Sources/SiriModels.swift` | Phases, destination snapshots, errors, and injectable client contracts. |
| `Tests/` | Adjacent controller, plugin interaction, targeting, and failure-path coverage. |
| `Bundle/`, `plugin.json`, optional `project.yml` | Normal generated plugin integration and only necessary build deltas. |

### Availability and permissions

- Keep the host's macOS 14 minimum. The plugin can load and explain unavailability on unsupported systems, with runtime gates for the tested macOS 27 Siri app and required capabilities.
- Resolve by bundle ID and verify the intended installed application. Revalidate the process incarnation and AX handles after opening or relaunching.
- Use native Accessibility permission checks and the existing host permission-card pattern. Do not require Screen Recording or System Events Automation for the chosen implementation.
- Cache availability for getters; refresh asynchronously on activation, relevant workspace launch/termination events, return from permission settings, explicit refresh, and every execution preflight. Coalesce `onStateChange?()` notifications.
- Treat onboarding, sign-in requirements, service errors, or an unexpected UI as unavailable states with guidance. Do not change Siri settings automatically.

### Conversation identity

- New conversation: explicitly open Siri, resolve a unique target window, preserve any existing unsent draft, invoke `newChatButton`, then verify that the chosen conversation is new and empty before writing.
- Continuation: prepare a session token bound to the process incarnation, window, and selected conversation. Retain the token-to-destination mapping only in plugin memory and expire it after five minutes or when the provider/session closes.
- The continuation definition requires both the message and the prepared destination token. The token enters the complete invocation as a sensitive, local-only parameter; never expose a conversation database ID or title as a portable reference.
- Do not use a title alone as identity. If AX provides no reliable conversation identity, detect relevant selection/window changes with supported observations and invalidate conservatively. Prove this works before enabling continuation.
- Revalidate the destination immediately before writing and submitting. If the user selects another conversation, closes the window, or edits the draft concurrently, stop without sending to the replacement destination.
- With multiple Siri windows, use an unambiguous focused/main window and pin that choice. If ambiguity remains, ask the user to select the intended Siri window; do not choose the first result from a recursive search.
- Never traverse or print the entire chat-history sidebar during ordinary execution. Read only the selected destination and the submission evidence needed for this request.

### Execution state machine

`idle → opening → resolvingDestination → preparingConversation → enteringText → submitting → verifyingSubmission → sent / failed / submissionUncertain / cancelled`

For each invocation:

1. Acquire a plugin-wide exclusive operation lease covering both actions and all prompt values. Reject additional runs while busy. The host's full-reference concurrency key alone does not protect the shared Siri UI.
2. Validate permission, action schema, input size, destination session, and app availability.
3. Call the standard macOS app-opening API even if a process already exists. Wait for the required window and controls.
4. Resolve controls by identifier, expected role, ancestor context, supported actions, and enabled/settable state. Never use screen coordinates or an unvalidated first matching text field.
5. Prepare and verify the destination. If a nonempty draft exists, preserve it and return guidance. Never replace a user's draft to complete this command.
6. Set the exact message via AX, then read back and compare it. Recheck destination ownership and cancellation before submitting.
7. Capture a pre-submit conversation baseline, then invoke `AXConfirm` once. A successful AX return is not sufficient proof of delivery.
8. Require a newly appearing user-message occurrence containing the exact input in the pinned conversation, together with the draft clearing. This must distinguish a new occurrence from an identical older prompt.
9. If evidence is ambiguous after submit, finish as `submissionUncertain`. Do not invoke submit again or automatically retry after cancellation, timeout, or app restart.
10. Release the operation lease and input session on every terminal path.

Use async, cancellable polling or AX notifications with bounded traversal and messaging timeouts. Keep potentially blocking AX calls off the main thread on an appropriately serialized worker. Main-actor work should publish snapshots and coordinate AppKit lifecycle, not block waiting for Siri.

Initial deadlines: 15 seconds for app opening, 10 seconds for destination preparation, 5 seconds for text verification, and 15 seconds for submission evidence, bounded by a 45-second overall operation deadline. Tune from measured behavior, with injected time in tests. The deadline does not include waiting for an AI answer.

After cancellation or a pre-submit failure, do not attempt broad cleanup. A draft may be cleared only when it is still exactly the automation's text in the unchanged owned destination; otherwise leave it intact and explain the state. Never delete conversations as cleanup.

### Host integration and settings

- Use foreground interactive execution and cancellability. Exclude Run Links, unattended automatic rules, and App Intents/system exposure for these actions.
- Use `.reportsProgress` only when the plugin actually publishes progress and cancellation outside the palette, through a declarative primary panel and a small settings status section.
- Settings should contain concise availability, last attempt status, and permission/help guidance. Use `PluginSettingsPage.form` and `PluginSettingsTheme`, with host-owned headers and permission cards.
- Keep native AX implementation details out of ordinary app copy. Follow existing localization coverage; Chinese source copy should remain concise, and code/comments/documentation should be English.
- Add logging through the existing `AppLog`/plugin runtime logging conventions. Log phase and generic error categories, never prompt contents or conversation identifiers.

## Implementation sequence

### 1. Input contract and registration

Implement additive input models/protocol, descriptor and alias validation, host registration, provider lifecycle invalidation, and a fake provider. Cover descriptor/schema mismatches, alias collisions and prefix overlaps, valid session completion, provider replacement, and unchanged complete-reference validation. Update compatibility inventory immediately.

Exit condition: a fake provider can expose an input action and execute only after a complete, validated invocation is assembled. Existing plugins require no changes.

### 2. Palette input experience

Add a focused input state model, alias resolver, and editor view rather than expanding all behavior inside the existing palette view. Wire ordinary search, inline action/message recognition, visible destination feedback, one-Return submission, Compose handoff, selection, session preparation, marked-text handling, validation, execution feedback, Back/Escape, and provider invalidation. Preserve existing search result behavior and privacy rules.

Exit condition: both `alias <message> → Return` and `search → select → compose → Return` execute the same complete invocation with the fake provider. Verify mouse and keyboard parity, cancellation, exact message preservation, and zero prompt persistence through either path.

### 3. Siri new-conversation integration

Add the plugin skeleton, native app/AX clients, permission handling, plugin-wide lease, bounded execution state machine, and status surfaces. Implement new-conversation submission first. Verify from the actual Debug MacTools process and packaged plugin, not just a helper script.

Exit condition: new-chat submission succeeds through both palette input paths, including `ask siri <message>` with a single Return, from open and closed-window states. Both paths stop safely for drafts, missing permission, changed controls, concurrency, cancellation, and uncertain delivery.

### 4. Siri continuation

Implement read-only destination preparation and binding, then extend the controller to continuation. Exercise selection changes, same-title conversations, closed/reopened windows, multiple windows, and app restart while the palette remains open.

Exit condition: the submitted message reaches the prepared destination or the action stops with a clear error. If this cannot be demonstrated, record the blocker and withhold continuation without delaying an accepted new-chat-only release.

### 5. Packaging, documentation, and acceptance

Update `README.md`, `CONTRIBUTING.md`, `docs/plugins/action-provider-coverage.md`, and add `docs/plugins/siri.md` describing both input paths, the `ask siri <message>` alias, permissions, supported behavior, and limitations. Update `docs/plugins/local-native-plugins.md` for the shared input and alias contract as appropriate.

When implementation is complete, add distinct English changelog fragments: an app `added` entry for palette text input and a plugin `added` entry for Siri actions. A documentation-only plan does not need those fragments now.

Generate plugin targets with `make generate`; do not use `make setup` on this worktree because it also renames the branch and can rewrite remotes. Keep locally generated catalogs/project configuration out of commits. Do not publish catalog artifacts manually as part of implementation.

Exit condition: focused tests, compatibility checks, CI-equivalent validation, and the real interaction matrix below pass, with any remaining release limitation stated explicitly. The user subsequently authorized implementation and a draft PR. Release, notarization, and production publication remain separate.

## Automated verification

Use adjacent test files, temporary stores, fake AX trees, and injected clocks. Tests must assert observable behavior, not merely reproduce the implementation.

| Area | Required coverage |
| --- | --- |
| Input registration | Explicit opt-in; unknown actions; missing/wrong parameter types; invalid prepared values; schema/generation changes; old providers unchanged. |
| Alias resolution | Exact start/boundary matching; bare alias; case variants; localized aliases; Unicode source ranges; exactly one consumed separator; no fuzzy inference; collisions/prefix overlaps; removed providers; exact suffix preservation. |
| Palette | Search-to-input and inline transitions; one-Return submission; bare-alias editor entry; Compose handoff and query restoration; prefix edits and Escape; unavailable aliases cannot execute another result; mouse/keyboard parity; IME composition; multiline Unicode; size limit; duplicate Return; errors and cancellation. |
| Privacy | No raw inline query/message/token/title in recents, defaults, portable settings, Run Links, presets, parser/search diagnostics, or recorded execution diagnostics. |
| Lifecycle | Provider unload/reload; permission revocation; session expiry; palette dismissal; surface-independent completion and progress ownership. |
| Siri targeting | Running process without window; multiple windows; wrong-ancestry input; changed conversation; identical titles; stale process/AX objects; protected user drafts. |
| Siri delivery | Exact text verification; one submission only; repeated identical messages; delayed message appearance; submit succeeds but evidence times out; no automatic retry. |
| Siri concurrency | Different message values and different Siri actions cannot overlap; all failure/cancellation paths release the plugin lease. |
| Status | Host-derived panel/settings availability, busy state, permission guidance, error feedback, and cancellability reflect real controller state. |

Relevant existing suites include `ActionModelsTests`, `ActionRegistryTests`, `PluginHostActionRegistryTests`, `ActionExecutorTests`, `MacToolsSearchTests`, `CommandPaletteRecentStoreTests`, `ActionRunLinkServiceTests`, and dynamic runtime action snapshot tests. Add `Tests/App/CommandPaletteAliasResolverTests.swift`, focused input-session suites, and `Plugins/Siri/Tests/SiriControllerTests.swift`, `SiriAccessibilityClientTests.swift`, and `SiriPluginTests.swift`.

Start with the smallest changed suite, for example:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer make generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/SiriControllerTests
```

Confirm generated test target membership before using the new class name. Run `make script-tests` for all newly consumable PluginKit APIs. After building the updated Debug framework, run `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/plugins/verify-plugin-kit-v6-binary-compatibility.sh build/DerivedData/Build/Products/Debug`. Before pushing this cross-module change, run `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer make ci`.

## Real interaction acceptance

Run the packaged Debug plugin through the real MacTools palette. Record macOS build, Siri version, MacTools commit/package, scenario, submission count, and observed result. Keep evidence free of unrelated conversation contents.

- New conversation while Siri is open on an existing conversation.
- Type `ask siri suggest three ideas for dinner` and press Return once; verify the exact suffix appears in a new Siri conversation. Repeat via select-and-compose and compare the delivered text.
- Type the bare alias and open the editor; test an empty suffix, multiple separator spaces, prefix edits, Escape, Compose handoff, and pasted multiline text. Recognition alone must not open Siri or submit.
- With a recognized alias, remove or disable the provider or revoke permission; Return must show the relevant error rather than execute a fallback search result.
- Reopen after closing its window and after a normal quit; separately establish a true not-running launch if that state can be obtained normally.
- Repeated use, including identical messages, without duplicate submission or destination drift.
- Continue the prepared conversation and verify both messages remain together.
- Switch conversation or close/reopen the destination while composing in MacTools; expect a safe stop.
- Multiple Siri windows and an ambiguous destination.
- Existing unsent draft, user typing during execution, and focus moving to another app.
- Missing/revoked Accessibility permission, unavailable Siri, onboarding, and unsupported AX controls.
- Cancellation before text entry, after text entry, and around submission; report uncertainty accurately.
- Chinese IME, emoji, multiline input, whitespace-only input, and the configured size boundary.
- Palette dismissal followed by delayed completion/error; progress remains discoverable and cancellation semantics remain accurate.
- Unsupported macOS: plugin discovery/settings degrade cleanly without affecting existing plugins.

The four feasibility replies from this conversation are not substitutes for this matrix. Automated tests, native interaction on a particular OS build, and compatibility with future Siri versions must be reported separately.

## Implementation validation (2026-09-08)

- Before rebasing to current upstream, `make ci` passed: 195 repository script tests, 3,082 Xcode tests, and the PluginKit v5 binary compatibility client. `make ci` passed on the rebased branch: 245 script tests, 4,359 Xcode tests, and the frozen PluginKit v6 binary compatibility client.
- Native AppKit/SwiftUI palette tests exercised a full alias plus Return and a bare alias plus composer plus Return, including exact Unicode/multiline text, completion ownership, and absence of prompt content in recents.
- The production `SiriAccessibilityClient` was compiled into a temporary native harness and exercised twice on macOS 27.0 (26A5425a). Each run prepared a new conversation, entered the exact harmless test prompt, submitted once, and verified the visible user message plus an empty input field. The final run includes the bounded, cancellable application-launch wait.
- Registry tests cover preparation timeout and late-session cleanup, provider replacement, invalid parameters, empty/oversized input, and composer dismissal. Siri controller tests cover concurrent requests, draft protection, cancellation before entry, and uncertain delivery without retry.
- The updated upstream base already fixes the locale-dependent manifest assertion observed during initial validation; its fix is preserved.
- The packaged Debug-app interaction check could not run because no configured local signing settings were available. The previous Debug app was reopened after the attempted check. Native palette integration and the live Siri adapter were verified separately; the installed host-to-plugin path still needs manual acceptance.
- The broader manual matrix below remains a release checklist, particularly IME input, multiple windows, changed selection, permission revocation, cancellation around submission, and future macOS beta updates. No continuation action is exposed.

The upstream rebase also preserves the single query owner and palette styling introduced in the recent palette fix. A host-specific native field reuses shared search command handling and retains ordinary search normalization, bypassing normalization only for explicitly recognized action input so message whitespace remains exact. Existing public v6 palette type layouts remain unchanged.
