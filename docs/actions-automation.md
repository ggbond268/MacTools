# Actions, Automation, Run Links, and Action Grid

MacTools exposes one host-owned action platform to every invocation surface. Plugins publish stable action definitions and catalog entries; the host owns lookup, migration, availability, shortcut registration, confirmation, and execution.

## Ownership

- `ActionRegistry` owns revisioned in-memory definition/catalog indexes and live availability invalidation.
- `ActionExecutor` is the only execution gate. It validates parameters and execution mode, applies confirmation policy, revalidates the exact approved request, provider, and availability, enforces a deadline for every action, and calls provider cancellation when supported. Definitions also declare how overlapping invocations behave: reject by default, serialize, or allow concurrent execution.
- `ShortcutAssignmentService` owns ordinary global-action bindings, conflicts, migration, persistence, and Carbon registration state. Actions & Shortcuts is the canonical editor for these bindings; plugin settings retain only specialized plugin shortcuts that are not ordinary action assignments.
- Automation owns workflow definitions, rules, conditions, and bounded privacy-conscious history. Steps store versioned `ActionReference` values and execute serially through `ActionExecutor`.
- `AppURLRouter` owns one strict, ordered, bounded route queue. Run Links resolve to `ActionReference` values before execution.
- Action Grid owns only its versioned tree of folders, each containing up to nine positioned references. Catalog discovery, owner navigation, migration, availability, execution, shortcut assignment, and Run Link generation remain host-owned.
- `PluginActionExecutionHostContext` is the narrow composition bridge for a plugin that needs to invoke another provider's canonical action. Its live lookup and execution closures still enter `ActionRegistry` and `ActionExecutor`; it does not expose provider instances or create a parallel dispatch path. The host refreshes consumers after catalog revisions and clears the context when isolating a plugin.

Unavailable references are retained by shortcut assignments, workflows, presets, and Action Grid. A provider returning with a compatible migration can restore them without recreating user configuration.

Portable imports distinguish unavailable providers from configuration-defined actions. A plugin payload that defines action identities must validate and report successful restoration before the host admits dependent workflows, shortcuts, Run Links, Trackpad mappings, or Action Grid entries. Workflows restore before those consumers; if provider or workflow persistence fails, the import reports a warning and drops the affected imported dependency chain instead of creating dangling state. Current backups treat an explicitly empty action-shortcut section as authoritative, while older backups bridge only the legacy assignments they actually contain and preserve unrelated destination assignments.

## Automation boundaries

Workflows can be created, renamed, duplicated, enabled or disabled, reordered, previewed, run, stopped, and deleted. Preview Before Running is enabled by default and shows the ordered steps, current availability, waits, confirmation requirements, and the lack of automatic rollback before a manual run starts. Automatic rules are managed separately; deleting a workflow first cancels its active runs and explicitly removes its attached rules so neither an unreachable run nor enabled orphan trigger remains hidden. Manual runs ignore rule-specific conditions. Enabled workflows publish stable `automation/workflow.<uuid>` actions, so Unified Search, global shortcuts, Run Links, and Action Grid need no workflow-specific dispatch path.

The workflow editor keeps action identity and parameters together: changing an action uses the shared action picker and replaces its parameters with a valid reference. Step names, waits, and failure policy live under Advanced Options. Text and numeric drafts are debounced before persistence, while structural changes such as adding, replacing, moving, or deleting steps are saved immediately and rebuild the published catalog only when action identity changes.

Workflow actions publish durable progress through Automation. Action Grid and Unified Search complete validation, availability checks, provider-generation revalidation, and any confirmation before handing the run to Automation and closing; the menu-bar running indicator, Automation run history, and Stop control then own its lifecycle. Ordinary actions still keep the invoking surface open until they return a terminal result, and nested workflow steps always await their child action so ordering, failure policy, recursion limits, and cancellation remain deterministic.

Automatic rules use one trigger and zero or more conditions:

```text
When: schedule, calendar, application, power, display, or network event
If:   frontmost app, power/battery, connected display, time range, or network state
Run:  reusable workflow
```

Trigger delivery is debounced, serialized per rule, and bounded. MacTools starts a trigger provider only while at least one enabled rule uses that trigger family, limits automatic runs globally, and never overlaps a second run of the same workflow. Providers must explicitly opt an action into unattended execution with the `.automatic` capability; background support alone is not sufficient. Calendar offsets, crossed battery thresholds, and network-interface transitions are carried as exact event identities so adjacent rules cannot cross-fire; positive calendar offsets retain ended events across provider refreshes. Skipped rules record a concise reason. Workflow recursion and execution depth are bounded; history recovers unfinished runs as interrupted after a restart. Advanced branches, loops, variables, folders, and application-specific Action Grid profiles are intentionally outside this release.

Run Link controls copy the canonical direct URL when an action is externally invocable. If a parameterized action needs a durable preset, preset creation remains an internal compatibility mechanism instead of a second user-facing link type.

## Automated verification

Use focused tests while developing, then the full suite for cross-module changes:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet
```

The test suite covers registry revisions and migration; parameter validation; executor safety, confirmation, cancellation, and timeout behavior; shortcut persistence/conflicts/registration/reentrancy and unavailable-provider visibility; Run Link parsing, queue bounds, presets, feedback, and privacy; workflow editing, ordering, rule cleanup, recovery, cancellation, execution, recursion, startup sequencing, and history; all trigger/condition families with injected providers; and Action Grid storage, migration, geometry, keyboard mapping, distinct accessible controls, repeat presentation, unavailable actions, and shared execution.
