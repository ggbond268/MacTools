<div align="center">
  <img src="docs/assets/logo-mactools-rounded.png" width="96" height="96" alt="MacTools logo">
  <h1>A free and open-source collection of native macOS menu bar tools</h1>
  <p><a href="README.zh-CN.md">[中文]</a> [English]</p>

  <p>
    <a href="https://github.com/ggbond268/MacTools/stargazers"><img src="https://img.shields.io/github/stars/ggbond268/MacTools?style=social" alt="GitHub stars"></a>
    <a href="https://github.com/ggbond268/MacTools/blob/main/LICENSE"><img src="https://img.shields.io/github/license/ggbond268/MacTools" alt="License"></a>
    <a href="https://github.com/ggbond268/MacTools/releases"><img src="https://img.shields.io/github/v/release/ggbond268/MacTools" alt="Latest release"></a>
    <a href="https://hellogithub.com/repository/ggbond268/MacTools" target="_blank"><img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=6cddbd75f09848fb8848b58510394a5c&claim_uid=g4n28zqFcD0Vhw3&theme=small" alt="Featured｜HelloGitHub" /></a>
  </p>

  <p>MacTools brings frequently used system actions together in a lightweight, fast, and unobtrusive menu bar app. Built with SwiftUI + AppKit for macOS 14.0 and later.</p>
</div>

## Screenshots

<img src="docs/assets/screenshots/readme-hero-en-dark.png" alt="MacTools menu bar panels in dark mode">

## Features

| Feature | Description |
| ------- | ----------- |
| Display Resolution | View connected displays and switch each display to an available resolution. |
| Display Brightness | Quickly adjust built-in and DDC/CI external display brightness, with shortcuts that can follow the mouse or control all displays together, plus Gamma/Shade fallbacks. |
| True Tone | Automatically adapt display colors to ambient light on MacBooks and compatible displays. |
| Display Sleep | Put all displays to sleep immediately, then wake them with mouse movement or keyboard input. |
| Dark Mode | Toggle the system light and dark appearances, with live state sync when the system theme changes. |
| Night Shift | Toggle Night Shift to reduce blue light and warm the screen colors at night. |
| Prevent Sleep | Keep the system awake while idle, optionally keep the display on by default from plugin settings with an active-session indicator, and stop automatically after 30 minutes, 1 hour, 2 hours, or 5 hours. |
| Clean Mode | Show a full-screen black overlay and temporarily disable input for cleaning the screen, keyboard, or trackpad. |
| Mouse Enhancer | Enhance mouse and trackpad controls, with separate horizontal and vertical scroll reversing plus trackpad-tap middle-click simulation. |
| Hide Notch | Mask the top notch area on built-in notch displays without modifying the original wallpaper. |
| Hide Menu Bar Icons | Hide icons to the left of a menu bar divider, with drag-based layout for visible, hidden, and always-hidden areas. |
| Auto Hide Menu Bar | Automatically hide the menu bar to make more screen space available. |
| Auto Hide Dock | Automatically hide the Dock for a cleaner desktop. |
| Stage Manager | Toggle Stage Manager to focus the current window and place other windows on the side. |
| System Mute | Mute or restore system audio output through CoreAudio on the default output device, with automatic restoration when the plugin is disabled. |
| Microphone Mute | Mute or restore the default microphone input through CoreAudio without requesting recording permission. |
| Disk Cleanup | Scan caches, developer caches, and browser caches, with path safety checks and sensitive data protection before deletion. |
| Xcode Cleanup | Scan DerivedData, device support files, archives, simulators, and preview caches by category; deletion is disabled while Xcode is running and only runs inside allowlisted roots. |
| Eject Disks | Eject all removable disks in one click, automatically skipping system and non-ejectable volumes and reporting when no disk can be ejected. |
| Empty Trash | Show the number of Trash items and empty Trash through Finder; the action is disabled when Trash is empty. |
| Clear Clipboard | Clear the current clipboard content to protect privacy and avoid accidental paste. |
| IP Check | View domestic/international egress IP, local LAN IP, location, ISP, ASN, and macOS network quality results, with copy support for single fields or the full result. |
| Translator | Translate the currently selected text with a global shortcut; the first version supports OpenAI-compatible services, automatic language selection, and a source editor whose actions stay clear of multi-line text. |
| Window Switcher | Replace or customize the window-switching shortcut with direct cycling or a fixed key-selection window for running windows; click a key hint to record a stable letter, digit, or Command-key binding. |
| App Shortcuts | Bind global shortcuts to common apps; pressing a shortcut opens or activates the app, and hides it if it is already frontmost. |
| Launchpad | Summon an app grid in fullscreen or a compact window, with instant search, horizontal paging, keyboard navigation, drag-to-stack folders with inline rename (click an open folder's title, or right-click a folder to rename/dissolve), an adjustable glass background (clear/standard/deep presets or a custom material + dimming, with a live preview in settings), adjustable appearance (icon size 48–96 pt with rows/columns adapting, optional icons-only mode that hides app names, label appearance presets (color: automatic/light/dark/accent, weight, and a size tier that scales with the icon — shared by app names and the open-folder title), and a compact-window size slider — the compact panel now scales with the screen instead of capping at 960×680, so any display whose usable area exceeds ~1333×829 pt renders a larger panel than before, including modern built-in laptop screens (~13% on a 14″ MacBook Pro); all previewed live by a layout thumbnail in settings that mirrors the real grid math), a global shortcut, and IME-composition safety. |
| Finder Right Click | Add Finder context menu actions: new folder, new file (.txt / .md / .json), open in Terminal, open with a configurable app list, and copy file names / absolute / relative / shell-escaped paths / file:// URLs — each item toggleable in Settings. |
| Lock Screen | Lock the screen immediately, equivalent to Cmd+Ctrl+Q. |
| Launch Items | Browse LaunchAgent/LaunchDaemon entries with search, field explanations, and user-level enable/disable controls. |
| Calendar Widget | View a monthly calendar, lunar calendar data, holidays, and today's events in the component panel. |
| System Status | Show 1-hour charts for CPU, GPU, memory, disk, network, battery, and high-usage processes. |
| Activity Stats | Track keyboard, mouse, scroll, and foreground app usage, with install/update and uninstall actions for Claude Code, Cursor, and Codex activity hooks. |
| Device Battery | Aggregate battery levels for the Mac, trusted iPhone/iPad/Apple Watch devices over USB or Wi-Fi, Bluetooth peripherals, AirPods/Beats split batteries and charging state, and Rapoo VT series mice, with multiple widget layouts and optional low-battery notifications. |
| Fan Control | Manage fan speed presets with automatic, full-speed, and custom fixed-RPM modes; installs the bundled helper and requests administrator authorization on first control. |
| Battery Charge Limit | Limit battery charging to a chosen cap, defaulting to 80%; charging stops at the cap and does not automatically resume below it unless the user chooses to continue or force discharge. |
| Fix Damaged Apps | Remove quarantine attributes to resolve "damaged and can't be opened" prompts by selecting a .app in a file panel and running the fix with administrator privileges. |
| Quit Apps | Select and quit running apps, or quit all at once; reverse selection helps quickly choose the target set. |
| zsh Config | View and edit zsh configuration files such as .zshrc and .zshenv inside the app, with syntax highlighting, common snippets, and automatic backup before saving. |
| Plugins & Settings | Install, update, and batch-update plugins in the plugin marketplace (filter by category/search; sort by not-installed first, installed first, or name using the selected app language); manage permissions, shortcuts, and plugin-specific settings; and export/import portable app preferences, plugin display settings, and shortcut customizations as JSON. |
| Menu Bar Icon Customization | Use local images or lightweight GIF/MP4 animations as the menu bar icon, download animated icons from the online gallery, remove backgrounds, adjust playback speed, restore the default icon, and preview every source with the same standard icon height and content inset as the default. |
| Localization | Follow the system language by default, or choose a fixed app language in Settings > General > Appearance; the picker shows each language in the system language and its native spelling. |

> **Preferences backup:** Import restores only portable host preferences, plugin display settings, and shortcut customizations. Missing plugins are never installed automatically: the preview lets you explicitly select catalog-verified plugins to install, while unavailable or unselected plugins and their shortcuts are skipped.

> **Right-click action:** You can use Option + left-click on the MacTools icon to trigger the right-click action.

## Supported Languages

MacTools supports Simplified Chinese, Traditional Chinese, English, Spanish, French, Russian, Portuguese, German, Japanese, Korean, and Arabic.

## Install

```bash
brew install --cask mactools
```

## Upgrade

```bash
brew update
brew upgrade --cask --greedy mactools
```

The in-app update dialog separates App Updates from Plugin Updates and includes plugin releases published since the previous app version.

If Homebrew still reports that the cask is already up to date, check the locally resolved cask version first:

```bash
brew info --cask mactools
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing, plugin development, and release workflows.

## License

MacTools is open source under the [Apache License 2.0](LICENSE).

## Acknowledgements

- Third-party assets, dependencies, and implementation references are listed in [Sources/Resources/ThirdPartyNotices](Sources/Resources/ThirdPartyNotices).
- Contributors

  <a href="https://github.com/ggbond268/MacTools/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=ggbond268/MacTools&max=120&columns=12" width="480" alt="contributors">
  </a>
