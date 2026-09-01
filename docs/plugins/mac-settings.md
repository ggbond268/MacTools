# Mac Settings Plugin

Mac Settings is a workspace plugin for searching, changing, comparing, and transporting a curated set of settings for the current Mac. The Phase 0 feasibility and safety decisions are recorded in [the catalog audit](../superpowers/specs/2026-08-23-mac-settings-feasibility-audit.md).

## User surfaces

Workspace labels, catalog titles and choices, status and error text, profile tools, recovery guidance, and accessibility descriptions follow the language selected in MacTools. The plugin's `MacSettings.xcstrings` catalog provides English and Simplified Chinese; untranslated locales fall back to English. Catalog models retain English source keys and resolve display text at read time, so switching languages does not recreate adapters or change settings. English and Chinese names remain searchable in either language. User-authored profile names, paths, IDs, desired values, and existing recorded messages are not translated or rewritten.

- **Settings palette:** starts with a focused global search field and keeps live controls directly in the results. With an empty query it shows pinned settings first, followed by the remaining catalog under lightweight category headings, without duplicate rows. Typing switches to one flat ranked result list that remains directly below the search field even when only a few settings match. Category actions populate this visible search instead of adding a removable category strip, while exact-setting actions scroll to and keyboard-focus the target row. The whole row reveals details, menus share a fixed trailing column, and keyboard focus uses a subtle background instead of a heavy outline.
- **Workspace navigation:** a persistent segmented control switches directly among Settings, Profiles, and History while preserving the current search and Settings view. The stable All/Pinned slot does not move neighboring controls as pins change, and each row exposes a visible pin action whose filled state immediately follows the ordered favorite source of truth. Recently Changed, Needs Attention, and manual refresh remain contextual actions in the overflow menu.
- **Profile transfer:** import and export are profile-management operations, not a separate workspace. The Profiles header imports portable files, validated imports appear as an inline preview before anything changes, and each saved profile exposes Export in its action menu. Compare & Apply is the only action that starts comparison. Suggested filenames are sanitized, including control characters.
- **Feature Panel:** exposes up to four ordered favorite controls plus an Open All Settings action.
- **Actions:** opens the workspace, searches a category, or focuses an exact setting; searches settings; performs explicit Boolean changes through the same verified adapter path; opens a saved profile's compare/apply preview; and rolls back the most recent eligible change.

Rows distinguish loading, applying, exceptional verification states, settings that apply on the next relevant use, provider/hardware/permission unavailability, restart or logout requirements, and unsupported settings. Category metadata appears in search and special scoped results but is omitted when the category heading already supplies that context. Descriptions, implementation details, favorite ordering, and System Settings links live in each row's expandable details. Pinning moves a setting to the top of the palette and exposes the first four pins in the Feature Panel; it never changes the setting itself.

System Settings links use the opaque `x-apple.systempreferences:com.apple.…-Settings.extension?AX_…` format with allowlisted native pane IDs and Accessibility anchor tokens. Unknown panes or anchors produce no link. Finder and Screenshot settings do not have corresponding System Settings extensions, so those rows offer no misleading generic shortcut. Permission guidance remains separate from optional setting-navigation links. Deep links are OS-dependent and must be rechecked before release.

Inline controls and keyboard changes are disabled while a profile is being prepared, applied, or rolled back. A single controller owns operation state and notifies the host at every transition, including completion and cancellation, so cached favorite controls and palette rows agree. Favorites store only ordered setting IDs, not independent setting values. A rejected slider commit discards its unsaved draft and returns to the controller's value. Unavailable provider-backed rows show the provider's reason and an explicit View Plugin action; this opens its MacTools settings or the plugin marketplace, while the separate System Settings link keeps its native destination.

Three-finger drag, pointer size, keyboard zoom, scroll-gesture zoom, and its Control/Option/Command modifier are direct, profile-eligible controls. The zoom controls dynamically validate Apple's high-level Universal Access runtime functions, which update shortcut and HID gesture state immediately. macOS protects the persisted cursor-size preference, so pointer size requires Full Disk Access and an app relaunch after the one-time authorization. Mac Settings declares Full Disk Access through the common plugin permission contract and derives the card's affected-setting list from every catalog record that declares that requirement; the host renders the same permission section for form and workspace plugins and deduplicates shared capabilities in the General settings permission overview. MacTools disables affected controls and routes both the shared card and inline row actions through one handler until access is available. It then writes and reads back one fixed allowlisted preference key, synchronizes the Universal Access runtime, rebuilds the cursor, and treats WindowServer's active scale as authoritative; this prevents transient-only changes and stale caches from resetting the control. The controls fail closed if persistence or the private runtime implementation changes. Three-finger drag uses the same runtime-validated trackpad backend as System Settings for an immediate hardware update, then verifies both built-in and Bluetooth preference domains.

The initial catalog exposes 44 settings, including Dock size, launch animation, open-app indicators, Finder safety warnings and folder ordering, Appearance scroll-bar behavior, the exact menu-bar visibility policy, and independent desktop item/widget controls for standard and Stage Manager desktops. True Tone reuses its live canonical provider. Trackpad and mouse scroll speeds use separate hardware backends; mouse tracking speed explicitly requires logout. The compact Feature Panel uses a complete selection list for controls with more than three choices.

Full Keyboard Access, Sticky Keys, Slow Keys, secondary click, standard function keys, screenshot destination, and Night Shift are deferred in this workspace. Their definitions and implementations remain in source, but their adapters are excluded from the production catalog. This also excludes them from search, favorites, actions, new profile drafts, and built-in templates; it does not disable independent plugins that already provide some of these features. The [deferred backlog](../superpowers/specs/2026-08-28-mac-settings-catalog-review.md#deferred-backlog) records each stable ID, reason, and evidence required for a future version.

Wi-Fi power and Low Power Mode are intentionally omitted because they are ordinary transient, device-related controls with easy access in macOS Control Center and do not belong in durable Mac configuration profiles.

The built-in Zen profile combines Dock auto-hide, menu-bar mode Always, hidden recent Dock apps, and hidden desktop items and widgets for both standard and Stage Manager desktops. It does not enable or disable Stage Manager. Compare & Apply reads every current value first and lets the user exclude any individual change before applying the profile.

Three-finger drag and tap-to-click rollback snapshots preserve built-in and Bluetooth preferences independently, including missing keys and Boolean/integer representations, along with the live runtime state. Undo and failed-write recovery restore those snapshots instead of copying one device's value across every domain. Recovery attempts every component, even when an earlier component cannot be restored, and verifies the complete final snapshot. Undo skips history entries whose settings are no longer in the active catalog or are currently unavailable.

Because this feature is unreleased, local history starts fresh under `change-history-v2`; there is no migration or attempt to reconstruct incomplete development-era snapshots. The old `change-history` bytes remain untouched. Profiles, favorites, and actual macOS values are unchanged, and the portable profile type is unchanged.

## Finder controls

Show All Filename Extensions writes `AppleShowAllExtensions` in the global preference domain. Reads honor an existing Finder-specific override; an explicit change removes that override so it cannot shadow the global setting. Local snapshots preserve both domains, including absent keys, for exact Undo. No filenames or per-file extension flags are changed. Persistence is verified, but Finder may need relaunching; the plugin does not restart Finder automatically or claim to have checked visible filenames.

New Finder Window Destination supports Recents, Home, Desktop, Documents, Computer, iCloud Drive, and a custom folder. It reads and snapshots `NewWindowTarget` and `NewWindowTargetPath` together. Unknown native targets are displayed without becoming writable choices, and existing custom paths remain readable even when the folder is disconnected. New selections validate local directory URLs and directory availability immediately before writing. iCloud Drive requires the local iCloud folder to be available. Verification checks both stored fields; Undo restores their original values or absence without reconstructing the old path.

Only named destinations may enter portable profiles. Custom paths remain in local state/history; profile drafts do not copy them, the profile editor offers named choices only, and import/export/execution reject local URLs or unknown destination codes. Preview and execution also check paired-path state before declaring a match. New local history and profile rollback points retain complete snapshots across serialization; restoration rejects incomplete snapshots instead of guessing a path or original key presence.

The native preference store uses exact-domain Core Foundation reads and writes rather than launching `defaults` processes. This follows Apple's [exact-domain preference API](https://developer.apple.com/documentation/corefoundation/cfpreferencescopyvalue(_:_:_:_:)) and [global application domain](https://developer.apple.com/documentation/corefoundation/kcfpreferencesanyapplication). The [nix-darwin Finder implementation](https://github.com/nix-darwin/nix-darwin/blob/master/modules/system/defaults/finder.nix) provides implementation precedent for destination codes and the paired path, not a guarantee of compatibility on every macOS release.

## Profiles

Profiles use the exported `cc.ggbond.mactools.settings-profile` JSON type. Inclusion is independent from a value: an excluded Boolean and an included Boolean whose desired value is `false` are different states.

Before showing a comparison, the plugin reads the profile's current values asynchronously; cached defaults are not used as evidence of a match. It skips matches, lets the user select individual changes, and creates an immutable plan. The comparison header keeps its Profiles return action beside the title instead of presenting it as a detached trailing action. Selectable rows use clear square selection marks and the entire row is clickable; matched rows use a green completion mark instead of resembling disabled checkboxes. Matches are checked again at execution time: a changed value requires another preview and is never silently selected. Execution reports verified, pending logout/restart, skipped, cancelled, unavailable, unsupported, verification-unavailable, or failed-and-rolled-back results per setting. A successful plan retains a rollback point for eligible values.

Inline rows expose reading, applying, verifying, and restoring phases. Profile operations show completed/total progress, the active setting and phase, and per-setting results before the batch finishes. Stop and deactivation cancel pending work; an in-flight mutation settles through verification or recovery before the next setting is skipped. A failure that restores successfully can continue to independent settings; an incomplete restoration stops subsequent writes.

After a partial profile application, Retry Unfinished Items creates a fresh preview and requires explicit Apply; it preserves the rollback point for earlier successes. Undo Applied Items restores only eligible successful changes and skips previously restored or explicitly kept entries. Verified profile restorations are recorded in local history.

Incomplete restoration is an explicit recovery state, not an ordinary refresh error. The original snapshot and last observation are stored locally under `pending-recovery-v1`, excluded from portable preferences, and retained across refreshes and relaunches. The workspace shows current/original differences and offers Retry Restoration or a confirmed Keep Current Values action. Keeping values discards only the pending recovery record; it does not write macOS preferences. Unresolved recoveries block new edits. Reloaded observations are treated as unknown until read again, and storage failures remain visible with a retry action rather than silently claiming durable recovery.

The decoder accepts only the versioned document schema, stable setting IDs, catalog-approved typed values, and bounded metadata. It rejects files larger than 1 MiB, more than 200 entries, arbitrary JSON fields, sensitive settings, and nonportable catalog entries. Unknown future IDs and valid deferred entries remain in imported profiles with warnings but are never executed. Editing the available controls preserves those entries. Deferred definitions still enforce value and portability restrictions, so hiding screenshot destination does not make local paths portable. A profile file always contains the profile's explicit included items and desired values; it is not an implicit capture of every current setting. Portable plugin preferences include pinned settings and profiles; the legacy density field remains serialized for compatibility, while history and local runtime state are excluded.

Portable restore preflights the complete merged profile set, including the 100-profile storage limit, before replacing any existing profile. Matching IDs are replaced and other local profiles are retained. Favorites preserve backup order; failed persistence restores the previous profiles and metadata before returning failure. The profile editor opens with explicit preparation progress, disables invalid drafts, and keeps validation or storage feedback in a fixed-height status region without dismissing or shifting the draft.

## Provider reuse

System Appearance uses a native segmented Auto / Light / Dark picker. The stable `appearance.dark-mode` ID now stores a typed choice; older profile Boolean values decode to explicit Dark or Light, never Auto. The Appearance provider's `set-mode` action reads the selected policy separately from the rendered theme, delegates scheduling to macOS, and verifies native and persisted state after applying. It dynamically resolves SkyLight entry points and fails closed when unavailable; Mac Settings does not duplicate the write. The existing quick-toggle actions remain available. New profiles and Undo retain Auto rather than freezing whichever color scheme was visible at capture time.

The source manifest publishes the upstream catalog's localized product, privacy, setup, and action descriptors. Its eight stable action definitions are covered by the shared manifest/runtime consistency test. Full Disk Access is conditional on pointer-size persistence and is explained in setup guidance rather than declared as a requirement for every action; provider-backed controls retain their providers' own permission checks.

Dark Mode, Dock auto-hide, menu-bar visibility, Stage Manager, and True Tone writes are delegated to their existing canonical action providers. The menu-bar provider exposes all four macOS policies through `set-mode`; its two underlying preferences are applied and verified together, and a partial failure restores the exact previous policy. The four desktop item/widget settings write their independent WindowManager preferences and broadcast both distributed and Darwin preference-change notifications before verification. Night Shift remains deferred. `PluginActionExecutionHostContext` supports live action lookup, guarded execution, and explicit provider-settings navigation through the host. Verification reads the provider's current presentation snapshot without waiting for the host's debounced UI rebuild. Availability comes from the canonical action's current policy, not merely the presence of its provider.

The bridge first ships in host 1.2.1, so Mac Settings requires at least that host version even though the PluginKit version remains 5. Its public bridge types are included in the minimum-host compatibility inventory. Explicit Automation permission buttons open System Settings; passive permission guidance retains the current page.

The [release review](../superpowers/specs/2026-08-28-mac-settings-catalog-review.md) records the accepted 44-included/7-deferred scope, the backlog for future planning, and outstanding live-validation gates. The Finder implementations and exact rollback model are now in place. Inclusion and passing automated tests are not proof of live macOS compatibility; visible filenames and actual new-window destinations still need the recorded checks before release.

Profile-backed action references declare `requiresPluginPreferences` during preferences backup. Navigation and explicit typed setting actions are self-contained; history-based Undo is excluded because history is intentionally local and nonportable.

## Development and verification

Generate the project after adding or moving plugin files:

```bash
make generate
```

Build the dynamic plugin target:

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacSettingsPlugin -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet
```

Run the focused coverage:

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test -quiet \
  -only-testing:MacToolsTests/SystemSettingCatalogTests \
  -only-testing:MacToolsTests/SystemSettingAdapterTests \
  -only-testing:MacToolsTests/MacSettingsControllerTests \
  -only-testing:MacToolsTests/SystemSettingsProfileTests \
  -only-testing:MacToolsTests/MacSettingsPluginTests \
  -only-testing:MacToolsTests/MacSettingsReviewRegressionTests \
  -only-testing:MacToolsTests/MacSettingsOperationTests \
  -only-testing:MacToolsTests/PluginHostActionExecutionContextTests
```
