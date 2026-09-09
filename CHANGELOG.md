# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

Pending release notes live in `changes/unreleased/*.md` and are compiled during
the app and plugin release processes.

## [v1.3.0] - 2026-09-09

### Added

- Added “Run MacTools Action” to Shortcuts, Siri, and Spotlight so supported actions can run without opening Settings.
- Added automatic local backups of portable app and plugin settings, with storage limits, backup status, and a safety snapshot before imports.
- Preferences restore preselects available missing plugins, preserves choices, and adds bulk selection and installation progress. It flags plugins needing a restart and another import to restore settings.
- Added Marketplace detail pages with localized features, actions, requirements, privacy disclosures, and setup guidance available before installation.
- Added a separate Nightly channel with isolated settings, matching app and plugin builds, and an optional signed and notarized CLI download.
- Added a Permissions page that groups shared macOS access, lists affected plugins, and refreshes status after returning from System Settings.

### Changed

- Removed the redundant Enable caption beside the command-line switch; the title and status description identify its purpose.
- Command Palette now shows recent successful actions when search is empty and ranks typed results by relevance.
- MacTools now uses GPL-3.0-only. App and Nightly CLI downloads include the license, with applicable third-party notices included in the app.
- Imported icons and animations with transparent backgrounds now adapt to the menu bar appearance. Opaque imports show guidance, while existing opaque artwork retains its colors.
- MacTools 1.3 uses PluginKit v6 and checks for compatible updates before loading installed plugins. Older packages remain disabled until updated.
- Settings now remembers collapsed sidebar sections, assigns Command-1 through Command-9 to visible rows, and uses Command-F for the current page's search.
- Dashboard detail panels now offer more space, Escape-key dismissal, reliable metric switching, and lower CPU usage.
- Window actions keep their intended target when opened from MacTools command surfaces and report failures without stealing focus.

### Removed

- Removed the persistent plugin sidebar filter and its Command-Shift-F shortcut.

### Fixed

- Changes to plugin confirmation requirements and Run Link permissions now take effect immediately.
- Fixed stale Command Palette queries and inconsistent search focus after reopening.
- Enabling Keep Awake no longer stretches feature-panel content or clips its duration options.
- Mac Settings no longer reverts successful changes while live state is refreshing, and unavailable controls can open the relevant plugin or Marketplace.
- Fixed preference export crashes involving saved action shortcuts or Run Links, and kept import controls accessible when many plugins are missing.
- The built-in display is now restored after wake when the external display was disconnected during sleep.
- Permission guidance now opens the correct System Settings destination, preserves the current plugin page, and shows the draggable helper for Full Disk Access.

### Security

- Removing plugin private data now shows a dedicated warning and blocks reinstallation until cleanup finishes, protecting newly installed data.

## [plugins-1.3.0] - 2026-09-09

### Added

- Added Apple Shortcuts to browse and run the system shortcut library, view folders, stop running shortcuts, and control confirmation and Run Link access.
- Added Clipboard with encrypted local history, saved clips, reusable snippets, OCR, and rich-text or plain-text paste.
- Clipboard supports paste queues, app exclusions, Private Copy, and export or sharing of saved items.
- Device Battery now supports battery readings from compatible MCHOSE mice, including the A7 V3 Ultra+.
- Added Hide Active App on Dock Click to hide the frontmost app by clicking its Dock icon while preserving other Dock interactions.
- Added Mac Settings with searchable macOS controls, pinned favorites, and a Zen profile to hide the Dock, menu bar, desktop items, and widgets.
- Mac Settings profiles support selective application, portable import and export, change history, Undo, and recovery of incomplete changes.
- Restored Hide Menu Bar Icons with draggable icon layouts and a panel for hidden icons.
- Right Click can now create CSV, YAML, XML, HTML, CSS, JavaScript, TypeScript, Shell, and Python files.
- Trackpad Gestures and Custom Shortcuts can now send individual keys and distinguish left and right modifier keys.
- Added Power Actions to sleep the Mac or open macOS confirmation dialogs for log out, restart, and shut down.
- Added System Soft Restart to restart macOS user services, preserve the Dock layout, and reopen supported apps.
- System Status now offers a menu-bar overview with detail charts, pinned readings, selectable time ranges, and an optional global shortcut.
- System Status menu-bar metrics now support per-metric display styles, configurable values, layout choices, and drag reordering.
- Added Window Layouts with grid placement, adjustable gaps, layout cycling, incremental width and height controls, display movement, custom layouts, shortcut presets, and Run Links.
- Optional modifier-key dragging moves windows beneath the pointer without clicking or changing focus, with a configurable status indicator and smoother movement when apps are busy.

### Changed

- Auto Input can now show its HUD near the pointer and offer adaptive reminders. Editable fields in Google Docs, Raycast, and MacTools are recognized more reliably.
- Official plugins now provide localized Marketplace descriptions, actions, requirements, privacy disclosures, and setup instructions.
- Cloudflare R2 Upload now follows the selected app language across setup, uploads, status, and errors.
- Disk Cleanup now explains its optional Full Disk Access requirement and continues to skip protected locations when access is unavailable.
- Dock Lock can now be toggled directly from its settings page.
- Official plugin archives now declare GPL-3.0-only and include their license and applicable third-party notices.
- New plugin packages use PluginKit v6 and require MacTools 1.3.0 or later. Catalogs for older app versions remain unchanged.
- System Status settings now support preferences export, import, and automatic backups.
- Trackpad Gestures now provides clearer practice feedback, including finger roles and separate TipTap contact and click status.

### Fixed

- Plugins that require Automation access now indicate that macOS asks for permission on demand instead of showing access as already granted.
- Fixed Battery Charge Limit failing to switch compatible Macs to battery power while connected to a power adapter.
- Device Battery now reports AirPods and other Apple headphone battery levels and charging states more reliably, with fewer duplicate or stale readings.
- Custom Shortcuts now explains recorder startup failures, preserves the previous mapping, and offers permission guidance or a retry.
- Middle Click no longer navigates the current page when opening a link in a new tab.
- Night Shift now reports toggle failures safely when the required macOS controls are unavailable or incompatible.
- Nightly plugins now keep privileged helpers, saved credentials, and Activity Bar AI hooks separate from stable MacTools.
- Corrected System Status battery temperature, time estimates, and chart statistics, with faster charts and stable pinned readings.
- Fixed System Status process monitoring getting stuck on “Collecting” when many processes are running.
- Trackpad Gestures now recognizes staggered multi-finger taps and repeated TipTaps more reliably, including with idle external or virtual pointers.
- Fixed duplicate or leaked native clicks during trackpad tap actions, and restored normal dragging and recognition after failed gestures.
- Window Switcher now includes eligible windows from all macOS Spaces, keeps each window separately selectable, and focuses windows directly during keyboard navigation.
- Improved inline editing stability for large zsh configuration files.

## [v1.2.0] - 2026-08-17

### Added

- Added a shared action system with global shortcuts, reusable workflows, automatic rules, secure Run Links, and selective portable backups.
- Menu-bar panels now support independent Light and Dark themes, ten built-in palettes, live previews, System Default, and accessible iTerm2 or Base16/Base24 theme imports.

### Changed

- About now keeps app details and update controls visible above a scrollable offline history of the 10 most recent App and Plugin releases.
- Actions and workflows now preview runs, simplify step editing, reject overlapping work by default, limit unattended concurrency, and enforce per-action deadlines. Step delays also state when each wait begins.
- MacTools now appears in the Dock while its Settings window is open.
- Menu-bar panels and their attachment arrows now use a consistent opaque background in Light and Dark appearance without reducing the content area.
- Settings now uses one resizable sidebar for app, management, and plugin pages, with consistent search, headers, and keyboard navigation. Unified Search preserves the sidebar position while open.
- Plugin pages can be ordered by localized name, installation date, or drag and drop. The saved order is included in backups without changing menu-bar layouts.

### Fixed

- Actions and Run Links now reject duplicate, recursive, stale, or unsafe requests, preserve cancellation, and explain failures. Imports and backups reject corrupt data and roll back safely.
- Automatic rules preserve unattended execution through nested or delayed steps and reject newly interactive actions instead of opening MacTools.
- Long-running workflows launched from Action Grid, Unified Search, or Run Links now continue in Automation after the originating surface closes.
- Actions & Shortcuts, Run Links, and Automation now follow the selected app language across controls, status messages, errors, and accessibility labels.
- Automation keeps its resizable workflow list stable and readable, with reliable reordering and action replacement in narrow layouts.
- Actions & Shortcuts filters remain stable, and Run Link copying is available from expanded action details.
- Text completion, global shortcuts, and system callbacks no longer crash MacTools when actions open windows, rebuild menu-bar items, or change displays. Unified Search restores the previously active app when it closes.
- Relaunching MacTools now brings Settings forward in the single running instance and preserves deep links received during startup.
- Auto Input now activates or releases saved input-source shortcuts as sources are enabled or disabled, without requiring a relaunch.
- Scheduled workflows now adjust to system clock and time-zone changes, and live-state listeners remain active while enabled rules depend on them.
- Plugin settings controls and footers now align consistently, and descriptions update immediately when the app language changes.

### Maintenance

- Allowed release preparation to publish a predeclared app version while advancing its build number.

## [plugins-1.2.0] - 2026-08-17

### Added

- Added Action Grid, an accessible 3×3 launcher with nested folders, drag-and-drop and keyboard editing, live action state, and multi-display placement. Foreground actions retain focus, and repeated opens reuse the grid.
- Auto Input now offers per-source actions, global shortcuts, and a configurable HUD near the focused field or centered on the active display. The HUD stays visible while hovered and cycles on repeated clicks.
- Added a Cloudflare R2 uploader with guided setup, secure credential storage, pre-upload renaming, conflict handling, cancellable progress, shortcuts, and optional public-link copying.
- Added Dock Lock to prevent the Dock from moving between displays accidentally, with reusable actions for Action Grid, Automation, and guarded Run Links.
- Added Custom Shortcuts for mapping keyboard, mouse, scroll, and precise trackpad input to shortcuts, mouse navigation, and common macOS actions, with guarded recording and conflict handling.
- Middle Click returns with three-, four-, and five-finger trackpad taps and a live-state action for shortcuts, Action Grid, workflows, and search.
- Added reusable actions across display, audio, system, cleanup, app, input, Homebrew, battery, and fan tools. Long operations retain progress, cancellation, and safety checks.
- Added live-state toggle actions for appearance, mute, Night Shift, Stage Manager, auto-hide, True Tone, Hide Notch, and Auto Input.
- Added Saved Scripts with explicit interpreters, timeouts, cancellation, bounded output, opt-in source backups, and actions for shortcuts, gestures, Action Grid, workflows, and confirmation-protected Run Links.

### Changed

- Dashboard components now use shared, appearance-aware colors and surfaces for cards, charts, badges, controls, and progress, while preserving calendar event and AI tool brand colors.
- IP Check now presents speed-test results in a more compact card layout.
- Automatic workflows now run only plugin actions that explicitly support unattended execution. Overlapping runs are rejected by default, and every action uses a consistent deadline.

### Removed

- Hide Menu Bar Icons is no longer distributed by MacTools.

### Fixed

- Action Grid settings, availability messages, VoiceOver controls, and live-state actions are now localized in every supported language.
- Activity Stats no longer reports impossible single-day AI coding durations when tracked sessions overlap, span midnight, or end without a final event.
- The Calendar widget's localized Today button now remains readable within the month header.
- Opening Dashboard no longer becomes unresponsive while Bluetooth battery monitoring starts.
- Device Battery updates no longer install on MacTools versions that lack the required component appearance support.
- Trackpad Gestures and Mouse Enhancer now recover reliably across display, device, sleep, wake, and plugin lifecycle changes, including external Magic Trackpads over USB or Bluetooth.
- Middle Click and Trackpad Gestures now arbitrate overlapping gestures, and Middle Click resumes automatically after a conflict is resolved.
- IP Check settings once again provide controls to hide IP addresses and refresh all checks.
- Plugin actions now verify outcomes, roll back partial changes, and stop Homebrew processes when cancelled. Sidecar Run Links resolve aliases safely, and older hosts retain a compatible catalog.
- Fan Control, Sidecar, and Trackpad settings now roll back incomplete imports or failed hardware updates.
- The Quit Apps selection panel now closes automatically when focus moves elsewhere.
- Sidecar and restored third-party actions now use visible fallback icons when their preferred system symbol is unavailable on the current macOS version.

### Maintenance

- Rebuilt the plugin line on PluginKit 5 for MacTools 1.2 while preserving the PluginKit 4 catalog for earlier app versions.

## [v1.1.6] - 2026-08-10

### Added

- Added navigation-only deep links for Settings, installed plugin settings, Dashboard, Feature Panel, and search.
- Command Palette can now set the app appearance, manage Launch at Login, and show or hide installed plugins on each supported surface.
- An optional global shortcut can now open a standalone Command Palette from any app.

### Changed

- Dashboard and Feature Panel context menus can now move plugins to either end of the list and show or hide them on the current surface.
- Settings pages now use native macOS backgrounds, appearance-aware sidebars and cards, consistent spacing, responsive widths, compact shortcuts, and live slider readouts; General preferences retain a readable width.
- Common application shortcuts can now be used after confirming their global effect.
- Plugin updates now install and validate Trackpad Gestures before Mouse Enhancer retires legacy middle-click behavior, with rollback on failure and a compatibility fallback for temporary app downgrades.

### Fixed

- Plugin settings now use a lighter sidebar surface in Light appearance.

## [plugins-1.1.6] - 2026-08-10

### Added

- Calendar now lets you choose any weekday as the start of the week, with Sunday as the default.
- Added a dedicated Trackpad Gestures plugin with configurable TipTap, three- to five-finger taps, double taps, and long touches that can trigger keyboard shortcuts or middle clicks.
- TipTap actions can repeat for each additional-finger tap while fixed fingers remain on the trackpad, and can consume matching native clicks.
- Adjustable typing protection is enabled by default to prevent palm-triggered gestures while using the keyboard.
- Responsive mapping controls provide focused editing, unique gesture choices, visible deletion, guidance, accessibility labels, and a safe no-action test mode.
- Automatic updates install Trackpad Gestures before migrating affected Mouse Enhancer middle-click settings; Mouse Enhancer then focuses on scrolling.

### Changed

- App Hotkey now asks before assigning a common application shortcut globally.
- Keep Awake now offers three modes: allow display sleep, keep the display on, or keep screen tools active. Screen Tools can prevent automatic locking and support closed-lid use on power; manual locking still works.
- All plugins now use a unified settings layout with native forms, adaptive system cards for complex managers, single-line shortcut controls, compact menus for long choices, and tick-free stepped sliders.
- Window Switcher and Physical Clean Mode shortcut fields no longer repeat their row labels, while Display Brightness keeps compact direction icons and aligns both shortcut fields beside the description.
- Sidecar now asks before assigning a common application shortcut globally.

### Fixed

- Fan Control now reports an error when its helper is not running with administrator privileges or when macOS does not apply the requested SMC fan value, instead of showing an unapplied speed change as successful.
- Launch Items settings now adapt to smaller windows without clipping filters, lists, details, or scan progress.
- Mouse Enhancer now preserves separate mouse and trackpad scroll directions after screen locking, sleep and wake, or external-display changes.
- Sidecar's two global shortcut fields now show their actions beside the recorder, making connect-first and disconnect-all settings easy to distinguish.
- Translator settings now show their section title in every supported app language.

## [v1.1.5] - 2026-08-03

### Added

- Press Command-K or use the Plugins sidebar to search app destinations, settings, plugins, and supported commands in one accessible palette. Results support number-key selection, exact navigation, and protected shortcuts.

### Changed

- MacTools now explains its local-only System Audio Recording use when an installed plugin provides per-app volume controls.
- Plugin settings now use an adaptive, resizable native sidebar with focused keyboard navigation and no extra focus outlines. Settings keeps a usable window size and adds Back and Forward toolbar controls.

### Fixed

- The Settings sidebar search field now opens search when clicking anywhere inside its visible bounds.

## [plugins-1.1.5] - 2026-08-03

### Added

- Added App Volume controls for adjusting and remembering the volume of each app currently playing audio on macOS 15 or later.
- Added Auto Input to remember the last input source used in each app and apply fixed per-app input sources.
- Keep Awake can create a built-in virtual display while a powered MacBook's lid is closed, allowing screen sharing, remote control, and desktop automation without an external display.
- Display Brightness and Prevent Sleep expose direct setting destinations, while Display Sleep and Lock Screen opt in to safe command discovery.

### Changed

- Disk Cleanup now scans system caches, developer artifacts, and leftover installers faster. Cleanup moves items to Trash by default and blocks protected, incomplete, locked, or overly broad targets.

### Fixed

- Device Battery command sampling no longer stalls when a spawned helper leaves output pipes open, and preserves partial output when a command times out.

## [v1.1.4] - 2026-07-25

### Added

- MacTools now checks quietly for app updates once per day and surfaces an Update action in the menu-bar panel when a new version is available.

### Changed

- The website About page now tells the MacTools story through an immersive, skippable galactic opening crawl.
- The website plugin page now provides an interactive, responsive preview of the Marketplace and plugin settings.

### Fixed

- Restored loading for plugins installed before MacTools 1.1.3.

## [plugins-1.1.4] - 2026-07-25

### Fixed

- Rebuilt every plugin package for compatibility with the current MacTools PluginKit runtime.

## [plugins-1.1.3] - 2026-07-24

### Added

- Keep Awake can optionally keep a Mac laptop running with its lid closed. The preference can be enabled on battery, waits for external power, and activates automatically when power connects.

### Changed

- IP Check now performs a lightweight local and public IPv4 refresh whenever its Feature Panel or settings page opens.

### Fixed

- Sidecar device settings now keep connection options and shortcuts readable in narrow Settings windows.

## [v1.1.3] - 2026-07-24

### Added

- General Settings now offers optional global shortcuts to toggle Dashboard and Feature Panel.
- The Feature Panel now copies button and switch subtitles, including either inline IP Check address, on double-click and briefly confirms successful copies.
- Settings now provides Back and Forward navigation with ⌘[ and ⌘], including exact restoration of Plugin subpages.
- Menu-bar panels and Settings now support standard local shortcuts for dismissal, Settings, and search.

### Fixed

- Grouped shortcut controls now stay readable and inside their settings card when labels are long or many actions are shown.

## [v1.1.2] - 2026-07-20

### Added

- Use Command-number shortcuts to switch menu-bar panels and jump among the main Settings pages.
- Show, hide, and reorder Dashboard components and Feature Panel actions independently. Hiding affects only that surface and does not stop a plugin’s background behavior.
- Manage installation, updates, and removal in Marketplace, or open plugin settings and uninstall directly from a layout row. Repeated uninstall confirmations can be paused for the current Settings session.
- Existing global layouts and older backups migrate safely to both surfaces. New backups preserve independent layouts while retaining a conservative legacy projection for older app versions.
- Plugins previously disabled from Installed load after upgrade but remain hidden on supported surfaces. Downgrading cannot restore the former disabled lifecycle state, so uninstall plugins you do not want running.
- The online icon gallery now includes a curated set of static icons across every category and marks animated icons with a clear badge for easier browsing.

### Changed

- Background-aware plugins can now pause nonessential work while the session is locked or the Mac is asleep.
- Animated items in the online icon gallery now use a compact play indicator that leaves more of each icon visible.
- Menu bar icon settings now show the current selection in a compact preview, play animations at their default speed, and omit playback controls, contrast warnings, and the recent-icons list.

### Fixed

- Feature-panel switches now update reliably after being clicked on macOS 27.
- Importing menu bar icons now preserves their original colors and transparency, preventing white artwork on transparent PNGs from disappearing.
- Monochrome icons from the online gallery now automatically adapt to light and dark menu bar backgrounds while colorful icons keep their original appearance.

## [plugins-1.1.2] - 2026-07-20

### Changed

- Use clear visibility controls when choosing System Status metrics for the panel or menu bar.

### Fixed

- Device Battery now avoids unnecessary Bluetooth scans when its widget and low-battery alerts are inactive.
- Keep Fan Control’s faster refresh limited to its visible, expanded panel, and keep Hide Menu Bar Icons running when it is hidden from a layout.

## [plugins-1.1.1] - 2026-07-17

### Added

- Connect nearby Sidecar-compatible displays with direct actions and status indicators. Switching disconnects the current display before connecting another.
- Save per-display connection priorities and shortcuts, with a priority-aware shortcut that connects the first available display.
- Request wired-only transport without falling back to Wi-Fi. Automatic Sidecar controls remain available when wired-only transport is unsupported.
- Sidecar shortcuts now use MacTools-wide conflict validation, imported settings are normalized, and unavailable states stay distinct from connectable displays. Panel feedback clears on close or before it becomes stale.

### Fixed

- Eject Disks now detects all visible ejectable mounts when the panel opens, including disk images, fixed external drives, and network volumes.
- Homebrew, Mouse Enhancer, Activity Bar, System Status, and Window Switcher controls now use the selected app language.
- Quit Apps now groups multiple running instances of the same app into one entry, preventing blank or misplaced cells while still quitting every instance selected.
- Finder Right Click now offers path-copy actions on window backgrounds and copies the current folder instead of requiring a selected item.

## [v1.1.1] - 2026-07-16

### Added

- MacTools preferences can be exported and imported as a versioned JSON backup, including app preferences, plugin display settings, and shortcuts. During import, missing plugins can be installed from the verified catalog.
- The website now provides a bilingual privacy policy explaining MacTools' local-first data handling, system permissions, and network-dependent features.

### Changed

- The feature and component panel switcher is now centered in a capsule-shaped toolbar control, with matching hover shapes for toolbar actions.
- Plugin Marketplace name sorting now follows the language selected in MacTools, with localized ascending and descending labels.
- MacTools can now assign a global shortcut to open its Settings window, and the menu-bar panel no longer shows a misleading dashboard focus outline while viewing features.
- Portable plugin settings can now opt in to preference backup and restore, including Sidecar display priority and shortcut configuration.

### Fixed

- Secondary menu-bar lists now open on the available side of the panel and switch to an in-panel view when screen space is limited.
- Feature-panel action buttons now match switch widths, preserve label spacing, and expose full long labels in tooltips.
- Plugin update progress now advances after each plugin finishes during automatic and manual bulk updates.
- Language names in Settings now remain readable instead of being truncated.
- Right-clicking the menu bar icon now opens the intended panel reliably on macOS 27 without briefly showing the primary panel or closing immediately.
- Shortcut recording now accepts F1-F12 as standalone shortcuts, including the shortcut for opening Settings, and explains when other keys require a modifier.
- The website download now points to the latest stable MacTools DMG instead of a plugin batch release. The Homebrew install command adapts to light and dark appearance and keeps its copy action compact on phones.

## [v1.1.0] - 2026-07-12

### Added

- The plugin marketplace can sort by install status (not installed first, or installed first with updates prioritized) or by name (A–Z / Z–A).

### Changed

- Placed plugin-specific settings between permission and shortcut sections for a more natural configuration flow.
- The in-app update dialog now includes plugin changes released since the previous app version.
- Changing the app language now refreshes all Settings and plugin controls immediately without requiring a restart.
- The language picker now shows each option in the system language alongside its native name.
- New app versions use a PluginKit-versioned plugin catalog and update installed plugins before loading them, while older app versions continue using the legacy catalog.

### Fixed

- Custom and gallery menu bar icons now use one standard height and content inset with consistent settings previews.

## [plugins-1.1.0] - 2026-07-12

### Added

- Device Battery can show trusted iPhone, iPad, iPod touch, Vision Pro, and paired Apple Watch battery and charging status over USB or Wi-Fi.
- Keep Awake can optionally keep the display on for every session through its plugin settings and shows an indicator while that mode is active.

### Changed

- Refined the native window switcher overlay and added editable, stable single-key app shortcuts.
- Device Battery now refreshes Apple mobile devices less often while the component panel is hidden.
- All plugin packages are rebuilt for PluginKit 3 and published together in a versioned catalog so they remain compatible with the new app runtime.

### Fixed

- Eject Disks no longer treats internal system or non-ejectable volumes as removable disks.
- Translator source text no longer overlaps the copy and speech actions when the text spans multiple lines.

## [v1.0.31] - 2026-07-09

### Changed

- Improved the menu bar icon settings previews so uploaded and online icons are easier to inspect.

## [plugins-1.0.32] - 2026-07-09

### Added

- System Status now includes settings for arranging component-panel metrics and optional compact menu bar metrics.
- Added Window Switcher for shortcut-driven window switching with direct cycling, key-based selection, configurable ordering, stable key hints, and hover quit buttons.

### Fixed

- Activity Bar now includes Cursor coding activity in AI work summaries and coding tool trends.
- Activity Bar now listens for installed AI hooks independently of Input Monitoring tracking.
- Activity Bar can now uninstall the AI activity hooks it adds for Claude Code, Cursor, and Codex.
- Battery Charge Limit now prefers the system charge ceiling path when available, uses the correct macOS 26 charging key, and verifies SMC writes to reduce USB-C display disconnects when charging stops at the limit.
- System Status now reports total GPU usage from the accelerator's total activity metric instead of pipeline-specific counters, avoiding false 100% history samples.
- Translator service order and enabled-state changes now persist immediately.

## [v1.0.30] - 2026-07-07

### Fixed

- Reduce unnecessary menu bar refresh work when plugins report state changes, keeping panels steadier during frequent updates.

## [plugins-1.0.31] - 2026-07-07

### Added

- Add a Homebrew management plugin for browsing packages, installing and upgrading formulae, and running diagnostics from the menu bar and settings.

### Fixed

- Hide Menu Bar Icons no longer quits after Accessibility is granted before Screen Recording is approved.
- Hide Menu Bar Icons now keeps the divider where you drag it instead of snapping it back next to the MacTools icon.
- Keep Awake now restores permanent sessions after restarting MacTools.

## [v1.0.29] - 2026-07-05

### Fixed

- Kept panel position stable and feature panel height accurate as controls expand.

## [plugins-1.0.30] - 2026-07-05

### Changed

- Stop Battery Charge Limit background monitoring while the charging limit is disabled.
- Pause Menu Bar Hidden background observers when the feature is hidden or not actively in use.
- Reduce System Status background sampling to lower idle energy use while keeping foreground updates responsive.

### Fixed

- Prevent repeated low-battery notifications when device battery readings switch sources or briefly disappear.
- Refresh Empty Trash availability when opening the feature panel.
- Fixed Mouse Enhancer settings switches rendering incorrectly on first open.
- Avoid administrator password prompts on quit when Fan Control or Battery Charge Limit did not apply SMC changes.

## [v1.0.28] - 2026-07-03

### Fixed

- Finder right-click menu items now stay hidden while the Right Click plugin is disabled.

### Maintenance

- App release notes now come from concise changelog fragments that are compiled into CHANGELOG.md during release.

## [plugins-1.0.29] - 2026-07-03

### Added

- Added Mouse Enhancer, a mouse and trackpad controls plugin with separate horizontal and vertical scroll reversing plus trackpad-tap middle-click simulation.

### Fixed

- Right Click now keeps Finder extension menu visibility aligned with the plugin's enabled state.

### Maintenance

- Plugin batch release notes now come from plugin changelog fragments compiled into CHANGELOG.md during release.
