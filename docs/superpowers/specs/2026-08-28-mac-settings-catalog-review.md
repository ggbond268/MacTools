# Mac Settings release scope and deferred backlog

Review date: 2026-08-28

Reviewed branch: `codex/issue-325-mac-settings`, starting at `ab823a0b`

## Accepted scope

Include **44 settings in the first release**, defer **7 settings**, and permanently remove **0**. The original 39/8 decision was accepted on 2026-08-28. The menu-bar policy was promoted after replacing its Boolean model with all four native modes, and four independent desktop item/widget controls were added as items 48–51. The original numbering below remains stable for future discussions.

The production catalog enforces this scope. All 51 definitions remain in source, but deferred adapters are excluded from catalog lookup, palette search, favorites, actions, new profile drafts, and built-in templates. Their definitions remain available only for profile validation. Valid deferred values from an earlier profile remain preserved with warnings and are never executed; local-only paths remain prohibited in portable profiles. Deferral here does not remove independent plugins such as Night Shift.

- **Keep** means include in the first-release scope, subject to the release gates below. It does not mean that unit tests have established live macOS compatibility or that every implementation condition below is complete.
- **Defer** means keep the feature in the backlog, but do not expose it in this plugin's first release. These entries have no placeholder controls; a future guided link needs its own review.
- **Remove** would mean no longer pursuing the feature. None of these 47 settings warrants that permanent decision; the problems are mostly incomplete models, hardware coverage, permissions, or unverified runtime behavior.

Prioritize validation of the newly included accessibility, input, and Finder controls because they closely match the original discovery use case. Profiles should remain secondary and should contain only settings with verified read, write, and rollback semantics.

## Per-setting decisions

| # | Stable setting ID | Setting | Decision | Reason / release condition |
| --- | --- | --- | --- | --- |
| 1 | `accessibility.three-finger-drag` | Three-finger drag | Keep | Validate the private backend, supported trackpads, and independent built-in/Bluetooth rollback before release. |
| 2 | `accessibility.pointer-size` | Pointer size | Keep | Full Disk Access must remain optional and affect only this control. Verify persistence after relaunch, active pointer size, denial, and the System Settings fallback. |
| 3 | `accessibility.keyboard-zoom` | Keyboard shortcuts to zoom | Keep | Validate the private setter and actual shortcuts across supported macOS versions; preserve the user's existing zoom configuration. |
| 4 | `accessibility.scroll-zoom` | Scroll gesture to zoom | Keep | Treat enabling zoom and its modifier as a coordinated feature; verify live gestures and rollback on each supported OS. |
| 5 | `accessibility.scroll-zoom-modifier` | Scroll-zoom modifier | Keep | Ship alongside scroll zoom, with dependency handling and tests that preserve the existing modifier when zoom is disabled. |
| 6 | `accessibility.full-keyboard-access` | Full Keyboard Access | Defer | Private runtime support and recovery need live keyboard-only testing; a broken control can interfere with the user's primary navigation. |
| 7 | `accessibility.sticky-keys` | Sticky Keys | Defer | Retain the feature, but test modifier state, existing options, and an accessible exit path before shipping the private setter. |
| 8 | `accessibility.slow-keys` | Slow Keys | Defer | A Boolean without acceptance-delay context can make typing appear broken; add delay explanation, recovery, and runtime validation. |
| 9 | `input.secondary-click` | Secondary click | Defer | Verify hardware availability and both gesture fields; restore the original combination on partial failure. |
| 10 | `input.scroll-speed` | Trackpad scroll speed | Keep | The private raw-speed mapping needs measured behavior and connected-device validation, not only numeric read-back. |
| 11 | `input.mouse-scroll-speed` | Mouse scroll speed | Keep | Test Apple and third-party mice and avoid presenting backend availability as proof that the connected mouse is supported. |
| 12 | `input.tap-to-click` | Tap to click | Keep | Validate device detection and preserve distinct built-in/Bluetooth preferences during rollback. |
| 13 | `input.natural-scrolling` | Natural scrolling | Keep | Useful everyday control. Explain the shared system effect and test both mouse and trackpad behavior, including external changes. |
| 14 | `input.mouse-tracking-speed` | Mouse tracking speed | Keep | Clearly label the current logout requirement; do not imply an immediate change unless a live setter is implemented and verified. |
| 15 | `input.trackpad-tracking-speed` | Trackpad tracking speed | Keep | Validate the private runtime range, connected hardware, and active speed before release. |
| 16 | `keyboard.key-repeat` | Key repeat rate | Keep | Useful durable preference. Label slow/fast meaning instead of exposing an unexplained raw number; clearly disclose logout requirements. |
| 17 | `keyboard.initial-key-repeat` | Delay until repeat | Keep | Keep with key repeat rate; label short/long delay and make the pending-logout state explicit. |
| 18 | `keyboard.function-keys` | Use F1/F2 as standard function keys | Defer | Validate supported keyboard models and Fn/Globe behavior; global preference read-back does not establish device behavior. |
| 19 | `finder.show-all-extensions` | Show all filename extensions | Keep | Global-domain writes, legacy Finder override handling, and exact-key Undo are implemented. Verify visible filenames and restoration in Finder and native file dialogs; stored-value verification alone is insufficient. |
| 20 | `finder.warn-extension-change` | Warn before changing an extension | Keep | Useful explicit preference. Keep warnings on in built-in templates and call attention to profiles that disable them. |
| 21 | `finder.warn-empty-trash` | Warn before emptying Trash | Keep | Useful explicit preference. Preserve the safe default and clearly flag disabling the confirmation in profile previews. |
| 22 | `finder.folders-first` | Keep folders on top when sorting by name | Keep | Clear, reversible preference. Clarify the sorting condition and Finder restart requirement. |
| 23 | `finder.show-path-bar` | Show Finder path bar | Keep | Strong everyday value. Verify on real Finder windows and offer clear restart guidance without restarting Finder automatically. |
| 24 | `finder.show-status-bar` | Show Finder status bar | Keep | Useful space/item feedback. Verify real Finder windows and retain clear restart guidance. |
| 25 | `finder.search-scope` | Default Finder search scope | Keep | A small meaningful choice. Label all three scopes and verify the next actual Finder search. |
| 26 | `finder.new-window-target` | New Finder window destination | Keep | Recents/iCloud/custom-folder handling, paired-key snapshots, and local-path profile restrictions are implemented. Verify actual new Finder windows, custom-folder Undo, disconnected folders, and iCloud availability on supported systems. |
| 27 | `dock.auto-hide` | Automatically hide the Dock | Keep | Reuse the existing canonical provider; verify Automation denial and the live Dock state. |
| 28 | `dock.size` | Dock size | Keep | High-value visual control. Keep bounded values and validate live size, not only the subsequently written preference. |
| 29 | `dock.position` | Dock position | Keep | Simple, useful three-way choice. Test live movement and provider/Automation failure handling. |
| 30 | `dock.magnification` | Dock magnification | Keep | Keep with magnification size and explain when the dependent size control has an effect. |
| 31 | `dock.magnification-size` | Dock magnification size | Keep | Useful companion control. Preserve the saved size while magnification is off and verify the active maximum size. |
| 32 | `dock.minimize-effect` | Minimize-window effect | Keep | Small reversible customization. Use friendly names and test both animation choices. |
| 33 | `dock.show-recents` | Show recent apps in the Dock | Keep | Useful decluttering option. Explain that pinned apps are unaffected and verify Dock refresh. |
| 34 | `dock.minimize-into-application` | Minimize windows into application icon | Keep | Useful durable layout preference; verify with an actual minimized window. |
| 35 | `dock.animate-opening-applications` | Animate opening applications | Keep | Small, reversible setting; explain that it controls launch animation rather than all system motion. |
| 36 | `dock.show-open-indicators` | Show indicators for open applications | Keep | Clear control with low complexity; verify indicators on running applications. |
| 37 | `screenshots.format` | Screenshot format | Keep | Strong practical value. Prefer common PNG/JPEG choices and validate every offered format using a new capture. |
| 38 | `screenshots.floating-thumbnail` | Show screenshot floating thumbnail | Keep | Useful workflow preference; verify on the next screenshot and check interaction with the Screenshot app. |
| 39 | `screenshots.window-shadow` | Include window shadow | Keep | Useful for documentation and design captures. Explain that it affects window captures, not all screenshot types. |
| 40 | `screenshots.destination` | Screenshot destination | Defer | Validate an existing writable directory immediately before saving, handle removal/unmounting, and preserve native destinations such as Clipboard; keep it out of portable profiles. |
| 41 | `appearance.dark-mode` | System appearance | Keep | Reuse the provider's typed Auto / Light / Dark policy action, independently of the currently rendered theme. Profiles and Undo preserve Auto; older Boolean profile values retain their explicit Light/Dark intent. |
| 42 | `appearance.show-scroll-bars` | Show scroll bars | Keep | Useful accessibility/discoverability preference with a small choice set; verify behavior in supporting apps. |
| 43 | `appearance.scroll-bar-click-jumps-to-spot` | Click scroll bar to jump to spot | Keep | Clear reversible behavior; explain jump-to-spot versus page scrolling and verify in a native scroll view. |
| 44 | `display.true-tone` | True Tone | Keep | Reuse the existing provider and hardware availability. Clarify display scope and verify that provider presentation state refreshes after a change. |
| 45 | `display.night-shift` | Night Shift | Defer | Separate a temporary override from the saved schedule and color temperature before treating it as a portable configuration value. |
| 46 | `desktop.menu-bar-auto-hide` | Automatically hide the menu bar | Keep | Uses the canonical provider's Always, On Desktop Only, In Full Screen Only, and Never modes. Apply and rollback preserve the exact policy instead of flattening it to a Boolean; verify visible behavior in desktop and full-screen spaces before release. |
| 47 | `desktop.stage-manager` | Stage Manager | Keep | Reuse the existing provider and verify its live state. Keep this as an explicit enable/disable action without changing related window options. |
| 48 | `desktop.show-items-on-desktop` | Show items on desktop | Keep | Independent inverted WindowManager preference with immediate change notifications and stored-value verification; verify Finder icons appear and disappear without relaunching. |
| 49 | `desktop.show-items-in-stage-manager` | Show items in Stage Manager | Keep | Preserve this separately from standard desktop items and Stage Manager enablement; verify while Stage Manager is active. |
| 50 | `desktop.show-widgets-on-desktop` | Show widgets on desktop | Keep | Independent WindowManager preference with immediate change notifications; verify existing desktop widgets without changing widget placement. |
| 51 | `desktop.show-widgets-in-stage-manager` | Show widgets in Stage Manager | Keep | Preserve this separately from standard desktop widgets; verify while Stage Manager is active. |

## Deferred backlog

All seven items below are **deferred, unassigned, and unscheduled**. Revisit them when planning the next plugin version after the initial release; that is a review checkpoint, not a promise to ship all seven then. Record the proposed version, owner, evidence, and decision here when work resumes. Keep the original IDs and numbering.

| # | Stable setting ID | Reason for deferral | Required evidence before inclusion |
| --- | --- | --- | --- |
| 6 | `accessibility.full-keyboard-access` | Changing primary keyboard navigation needs a tested recovery path. | Keyboard-only and VoiceOver enable/disable/recovery tests; supported-macOS runtime matrix; preserve related options and verify rollback. |
| 7 | `accessibility.sticky-keys` | A Boolean omits modifier behavior and related options. | Test latched/locked modifiers, existing options, shortcut interactions, and an accessible exit path; verify rollback without stuck modifiers. |
| 8 | `accessibility.slow-keys` | An unexplained acceptance delay can make typing appear broken. | Show delay context; provide recovery that does not rely on affected typing; test the runtime setter and restore delay/options. |
| 9 | `input.secondary-click` | Hardware support and multiple gesture fields are not fully validated. | Built-in and external trackpad tests; verify two-finger/corner combinations; inject partial failures and restore every original field. |
| 18 | `keyboard.function-keys` | A global preference does not establish behavior on every keyboard. | Test built-in and external keyboards, Fn/Globe interactions, device removal, and actual F-key behavior; disclose unsupported hardware. |
| 40 | `screenshots.destination` | Local paths and native destinations need a richer model. | Revalidate directory existence/writability before writes; test unmount/removal and Clipboard/native destinations; keep paths out of portable profiles. |
| 45 | `display.night-shift` | Temporary override, schedule, and color temperature have different semantics. | Model override versus saved schedule explicitly; preserve schedule/temperature during apply and rollback; test provider availability and display scope. |

For each proposed reintroduction:

- [ ] Assign an owner and proposed version; record the user workflow and exact scope.
- [ ] Complete that item's evidence requirements above and the shared gates below.
- [ ] Recheck profile eligibility, permissions, unsupported-state fallback, and rollback fidelity.
- [ ] Remove its ID from `MacSettingsCatalogFactory.deferredSettingIDs`, update scope tests and user documentation, and add a changelog entry in the same change.
- [ ] Record the final decision and link the implementation/test evidence here. A change in numbering or a hidden runtime override is not a substitute for this review.

## Outstanding work for included settings

Items 19 and 26 now have dedicated adapters and complete local rollback snapshots. Their implementation blockers are addressed; live visible-effect verification remains open. For item 19, test files with different per-file extension flags, the Finder preference checkbox, native file dialogs, relaunch behavior, and Undo. For item 26, open new Finder windows after each named/custom choice, then verify exact custom-folder Undo, disconnected destinations, and iCloud availability. These checks must record the OS version and restore the original preferences afterward. Input settings still need separate-device restoration checks, and private accessibility APIs need real OS/hardware evidence. Do not mark controls release-ready solely because they remain in the catalog or automated tests pass.

## Shared release gates

1. Test the actual visible behavior on macOS 14, 15, 26, and any newer release claimed as supported. The local automated run uses macOS 27 beta and does not establish compatibility on older systems.
2. Capture before/apply/verify/rollback evidence. A successful write followed by reading the same preference key is not proof that Dock, Finder, input hardware, or a provider changed its active behavior.
3. Move blocking process and AppleScript execution off the main actor with bounded completion and cancellation. Keep snapshots and view updates on the main actor.
4. Test denied Automation/Full Disk Access, missing providers, hardware removal, settings changed outside MacTools, and cancellation while an operation is pending. Do not require broad permissions for settings that do not need them.
5. Do not treat approximate aggregate values as full rollback snapshots for multiple devices, appearance schedules, or menu-bar modes.
6. Validate the compact Feature Panel against the whole choice schema. Controls with more than three choices now use a complete selection list; verify all options remain reachable at supported window sizes and through keyboard navigation.
7. Run visual, keyboard-only, and VoiceOver verification before publishing. Make pinning discoverable and keep descriptions, effective state, permission guidance, and errors understandable.

## Evidence and limits

Finder follow-up on 2026-08-28: dedicated adapters now use exact-domain native preferences, distinguish absent keys, preserve legacy overrides and paired destination paths, and keep local paths out of portable profiles. The 79-test focused suite passed, and the unsigned dynamic bundle built successfully. A separate read-only probe of the built plugin accepted this Mac's current extension visibility and Recents destination without applying or restoring settings. Actual Finder-window behavior, visible filename changes, and UI/VoiceOver checks remain unperformed; the live checks above are still required before release.

Scope-change verification on 2026-08-28: 52 focused XCTest tests passed on macOS 27 beta, 196 repository script tests passed, and the unsigned Mac Settings dynamic bundle built successfully. On 2026-08-29, the catalog expanded to 51 definitions: 44 included and seven deferred. Focused tests cover the four-state menu-bar mapping, partial-write restoration, provider routing, and the added catalog schemas. Live desktop/full-screen and Stage Manager behavior still requires the recorded release checks.

The catalog/adapters were inspected in [SystemSettingCatalog.swift](../../../Plugins/MacSettings/Sources/Catalog/SystemSettingCatalog.swift) and [SystemSettingAdapters.swift](../../../Plugins/MacSettings/Sources/Adapters/SystemSettingAdapters.swift). Adapter-specific concerns above come from that implementation; they are not claims of Apple-documented support for private symbols or preference domains. The five review fixes and their deterministic regression tests are separate from this release recommendation.

Apple documents three-finger drag as a trackpad capability and describes its System Settings route; this supports keeping a guided entry while validating the backend. [Apple: three-finger drag](https://support.apple.com/en-us/102341)

Apple's keyboard accessibility guidance describes Full Keyboard Access, Sticky Keys, and Slow Keys together with their associated options. That is why the recommendation requires recovery and option context before shipping isolated toggles. [Apple: keyboard accessibility](https://support.apple.com/en-ie/guide/mac-help/mchlae61a6de/mac)

The Dock items above correspond to native settings, and the screenshot items should be verified through a real capture and its destination/options. Apple documents these user workflows, but does not certify this plugin's write mechanisms. [Apple: Desktop & Dock](https://support.apple.com/en-euro/guide/mac-help/mchlp1119/mac), [Apple: screenshots](https://support.apple.com/en-euro/guide/mac-help/mh26782/mac)
