# Menu Bar Panel Theme — Research & Design

## Status

Research/design only. No implementation in this document. The goal is to decide
on a token model, an appearance-declaration model, and an import strategy before
any plugin-kit or host code is written.

## Summary

MacTools currently has exactly one appearance concept: `AppAppearancePreference`
(`Sources/App/AppAppearancePreference.swift`) — 自动/深色/浅色 — which only
toggles `NSApp.appearance` between `nil` / `.darkAqua` / `.aqua`. All panel
colors are semantic SwiftUI colors (`Color.primary`, `Color.secondary`,
`Color.accentColor`, `Color.primary.opacity(...)`) or system materials
(`NSVisualEffectView(material: .popover)`), so "theme" today only means "which
system aqua variant is active." There is no user-selectable color palette
anywhere in the app, and `PluginSettingsTheme`
(`Sources/MacToolsPluginKit/PluginSettingsTheme.swift`) is a **settings-page**
design-token enum (fonts/spacing/radius + a fixed light/dark hex palette), not a
themeable, user-facing color system.

This document proposes a **menu-bar-panel-scoped color theme** system:

- a small, semantic color-token palette purpose-built for the popover chrome
  (not a full IDE/terminal token set),
- a declaration model where a theme states it supports `dark`, `light`, or
  both, modeled on how Windows Terminal pairs `light`/`dark` color schemes and
  how VS Code ships separate dark/light variants under one theme family,
- reuse of the existing `AppAppearancePreference` resolution instead of adding
  a second, competing "follow system" toggle,
- a handful of built-in, well-known palettes converted ahead of time into the
  native schema, and
- an import pipeline that accepts the two most portable, most widely
  redistributed community formats (iTerm2 `.itermcolors`, Base16/Base24 YAML)
  plus a native JSON schema, with VS Code theme import treated as a
  lower-fidelity, phase-2 addition.

## Goals (Phase 1)

- Let users pick a color theme for the menu-bar popover (main panel + the
  sliding secondary panel), independent from, but coordinated with, the
  existing 深色/浅色/自动 appearance preference.
- Ship several built-in, visually distinct themes.
- Let users import an externally authored color scheme file.
- A theme can declare it supports only `dark`, only `light`, or both. A
  both-variant theme automatically switches with the resolved
  `AppAppearancePreference`; a single-variant theme stays fixed regardless of
  that preference.
- Settings UI lives under the existing 外观 (Appearance) section, one level
  below the current 深色/浅色/自动 row.

## Non-Goals (Phase 1)

- Theming any window other than the menu-bar popover (Settings window,
  secondary feature windows such as the disk-clean detail window, Launchpad,
  calendar windows, etc. stay on system semantic colors).
- Per-plugin custom theming hooks or a `contributes.colors`-style extension
  point for plugins (plugins keep using `Color.primary`/`.secondary`, and
  continue to declare only `iconTint`).
- Syntax/token-level theming (there is no code editor surface in the panel).
- Full VS Code theme-file compatibility (VS Code's `colors` map has 300+ keys
  with inconsistent coverage across themes; treated as phase 2, best-effort).
- A theme marketplace/gallery browsing experience; phase 1 import is local
  file only.

## Prior Art Survey

| Product | Declares light/dark? | Color model | Distribution / import |
|---|---|---|---|
| **iTerm2** (`.itermcolors`) | No explicit flag; each file is one palette (a `Dark_Theme` boolean exists only in the community *template* metadata used by `mbadolato/iTerm2-Color-Schemes`, not in the file itself) | Flat plist: `Background Color`, `Foreground Color`, `Cursor Color`, `Cursor Text Color`, `Selection Color`, `Selected Text Color`, `Bold Color`, `Badge Color`, `Link Color`, `Ansi 0…15 Color` (RGB components as `0–1` floats) | Import/export single files via Preferences → Profiles → Colors; the community catalog `mbadolato/iTerm2-Color-Schemes` mirrors ~300 popular schemes in this exact format, plus generated variants for other terminals |
| **VS Code** | `contributes.themes[].uiTheme`: `vs` (light) / `vs-dark` / `hc-black` / `hc-light`; a theme *family* (e.g. "One Dark Pro"/"One Light") is just two separately registered theme entries with a shared naming convention — VS Code does not auto-pair them | `"colors"` is a flat `{ themeColorId: "#hex" }` map keyed by ~300+ semantic workbench IDs (`editor.background`, `sideBar.background`, `statusBar.background`, `focusBorder`, …); user overrides via `workbench.colorCustomizations`, optionally scoped per theme name with `"[Theme Name]": {...}` | Marketplace extensions (`.vsix`), or raw theme JSON committed to a repo; no single-file "drop this in" import for end users without packaging as an extension |
| **Windows Terminal** | Native pairing: a profile's `colorScheme` property accepts either a single scheme name or `{ "light": "...", "dark": "..." }`, and Terminal auto-selects based on `applicationTheme`/OS theme | Flat JSON: `background`, `foreground`, optional `cursorColor`/`selectionBackground`, plus the 16 ANSI slots (`black`, `red`, `green`, `yellow`, `blue`, `purple`, `cyan`, `white`, `bright*`) | `schemes` array in `settings.json`; community scheme collections are plain JSON snippets, trivial to paste in |
| **Base16 / Base24** (tinted-theming) | `variant: "dark"` \| `"light"` field in the modern schema (legacy flat files omit it) | 16 (Base16) or 24 (Base24) roles `base00`…`base0F` (`…base17` for Base24) with **fixed semantic meaning**: `base00/01/02` = background shades, `base03` = muted/comments, `base04/05/06/07` = foreground shades, `base08` = red/error, `base09` = orange, `base0A` = yellow/warning, `base0B` = green/success, `base0C` = cyan/info, `base0D` = blue/accent, `base0E` = magenta, `base0F` = brown | YAML scheme files, one per palette; a "builder" renders them into templates for hundreds of target apps. This is the largest cross-tool palette corpus (Solarized, Gruvbox, Dracula, Nord, Catppuccin, Tokyo Night, etc. all publish Base16/Base24 scheme files) |
| **Alacritty / Kitty / Ghostty** | No; separate config files per palette, occasionally split into `*-light`/`*-dark` file pairs by convention | Flat key-value (TOML/plain text): `background`, `foreground`, `cursor`, `selection`, `normal.*`/`bright.*` ANSI slots | Config snippets / includes; same semantic shape as Windows Terminal |

**Takeaways for a menu-bar popover (not a terminal, not a code editor):**

1. None of the terminal formats (iTerm2, Windows Terminal, Alacritty-family)
   are a great *native* fit because their palette is ANSI-slot-shaped, not
   UI-chrome-shaped — but their color *values* are exactly what users want to
   reuse ("give me Nord/Dracula colors in this app too"), so they are worth
   supporting as **import sources with a semantic mapping**, not as the native
   schema.
2. VS Code's model — a semantic, named-role → hex map, declared as belonging to
   a light or dark "kind" — is the right *shape* for a small popover chrome,
   just with a much smaller key set (~20–30 keys instead of 300+).
3. Base16/Base24's fixed-role palette (`base00`…`base0F`) is the best import
   target for volume: it already assigns unambiguous semantic meaning to each
   slot (bg shades, fg shades, accent/status hues), which maps cleanly onto a
   small UI palette, and it is the format most popular community palettes
   (Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, One
   Dark/Light, Monokai) already publish in.
4. Windows Terminal's `{ "light": ..., "dark": ... }` pairing on a single
   logical setting — rather than VS Code's "two independently selectable
   theme entries" — is the closest existing precedent for "one theme name,
   two variants, auto-switch with the app's light/dark state," which matches
   what was asked for here.

## Recommended Native Token Model

A `MenuBarPanelTheme` is a **named, appearance-scoped, semantic color map**,
sized for the popover chrome that already exists in `MenuBarPanelPresenter.swift`
/ `MenuBarContent.swift`, not for a generic app-wide theme. Proposed token set,
derived directly from the current hardcoded/semantic usages found in
`MenuBarContent.swift` (hover fills, icon wells, toolbar capsule, action
button, status text) and `PluginSettingsTheme.Palette`'s existing
light/dark-hex pattern:

| Token | Current implementation (untheme d) | Role |
|---|---|---|
| `panel.background` | `NSPopover` system chrome / `NSVisualEffectView(.popover)` | Root popover + secondary panel backdrop |
| `panel.border` | none today | Optional 1px outline for non-material themes |
| `toolbar.background` | implicit (`.popover` material) | Top tab bar backing |
| `toolbar.pillBackground` | `Color.primary.opacity(0.06)` | Tab capsule idle fill |
| `toolbar.pillSelectedBackground` | `Color.primary.opacity(0.10)` | Tab capsule selected fill |
| `text.primary` | `Color.primary` | Row titles, feature names |
| `text.secondary` | `Color.secondary` | Subtitles, descriptions |
| `text.tertiary` | `Color.secondary` (dimmer use sites) | Status text, hints |
| `text.error` | `Color.red` | Plugin error subtitle |
| `accent` | `Color.accentColor` | Switch on-state, slider fill, links |
| `accent.foreground` | `.white` | Text/icon drawn on top of `accent` fills |
| `control.actionBackground` | `Color.accentColor` | Primary action row button |
| `control.iconWellBackground` | `Color.primary.opacity(0.08)` | Icon container behind feature icons |
| `row.hoverBackground` | `Color.primary.opacity(0.06)`\* | `MenuBarHoverStyle.fill` |
| `row.selectedBackground` | `MenuBarHoverStyle.navigationSelectedFill` | Selected list/navigation row |
| `separator` | `Color.primary.opacity(...)` / system separator | Dividers between sections |
| `badge.background` | `Color.primary.opacity(0.07)` | Count/status capsules |
| `status.success` | (unused today) | Reserved for future success indicators |
| `status.warning` | (unused today) | Reserved |
| `status.info` | (unused today) | Reserved |

\*Exact opacity constants live in `MenuBarHoverStyle`
(`Sources/App/MenuBarContent.swift:318`) and `MenuBarPanelLayout`; they will
need to become theme-driven values instead of literals once implementation
starts — out of scope for this research doc.

This is intentionally **much smaller than VS Code's ~300 keys**: the panel has
a toolbar, rows, one primary action affordance, and status text — not tabs,
gutters, minimaps, and diff editors. Every token above must have a light and a
dark value even if the *theme itself* only declares one appearance — a
single-appearance theme just uses the same value for both slots internally so
downstream code never special-cases "missing dark value."

## Appearance Declaration & Resolution Model

```
enum ThemeAppearance: String, Codable { case dark, light }

struct MenuBarPanelTheme: Codable, Identifiable {
    let id: String                 // stable slug: "nord", "solarized", "user-<uuid>"
    var name: String                // display name, e.g. "Nord"
    var author: String?
    var sourceFormat: ThemeSourceFormat   // .native / .base16 / .iterm2 (see Import)
    var variants: [ThemeAppearance: PanelColorPalette]   // 1 or 2 entries
}
```

- **Two-variant theme** (e.g. Solarized, Catppuccin, One Dark/Light, Tokyo
  Night): both `dark` and `light` are present. The *active* variant is
  whichever one matches the app's currently resolved appearance — i.e. it
  reuses `AppAppearancePreference` exactly as it exists today (自动 → follow
  `NSApp.effectiveAppearance`; 深色/浅色 → force that variant). **No new
  per-theme "follow system" toggle is introduced**; the existing 外观 row
  already is that toggle, and the theme just supplies the two color sets to
  switch between.
- **Single-variant theme** (e.g. Nord, Dracula, Gruvbox Dark, Monokai): only
  one entry exists. That palette is used unconditionally, and — this is the
  one behavioral nuance worth calling out — the *popover's own*
  `NSAppearance` should also be pinned to that theme's declared polarity via
  the existing `AppAppearancePreference.apply(to: NSPopover)` mechanism
  (`Sources/App/AppAppearancePreference.swift:40`), scoped to the popover
  only. Otherwise native SwiftUI controls (switches, sliders, segmented
  pickers) would keep rendering in the *app-wide* light/dark style while
  custom-painted rows use the theme's opposite-polarity colors, which reads as
  broken rather than intentional. This keeps the "系统默认" (no custom theme)
  path byte-for-byte unchanged: it is simply the case where no
  `MenuBarPanelTheme` is selected, and all tokens above resolve to today's
  semantic colors.
- A user can never end up with an inconsistent state: `variants` always has at
  least one entry, and picking a theme is a single action, not "pick a theme"
  + "pick a variant."

This directly satisfies the requirement: *"主题应该可以声明支持明暗两种，如果
设置的跟随系统就根据明暗自动切换。如果没有声明明暗，就固定一种"* — by treating
"跟随系统" as the pre-existing 外观 preference rather than inventing a second,
overlapping concept.

## Built-in Themes (Phase 1 proposal)

Converted ahead of time (offline, not at runtime) from each project's official
palette into the native `MenuBarPanelTheme` JSON, bundled as app resources:

| Theme | Variants shipped | Source of truth |
|---|---|---|
| 系统默认 (no override) | follows `AppAppearancePreference` | current semantic colors, always present, not deletable |
| Nord | dark only | nordtheme.com palette (also ships an official `.itermcolors`) |
| Dracula | dark only | draculatheme.com spec palette |
| Solarized | dark + light | Ethan Schoonover's original 16-color spec — the canonical "one family, two variants" example |
| Gruvbox | dark + light | gruvbox palette (has an official light variant) |
| One (Atom) | dark + light | One Dark / One Light |
| Catppuccin | dark (Mocha) + light (Latte) | catppuccin.com official palette |
| Tokyo Night | dark (Night) + light (Day) | tokyo-night palette |

Rationale for this specific set: it mixes single-variant "mood" themes (Nord,
Dracula, Gruvbox-as-dark) with true light/dark families (Solarized, One,
Catppuccin, Tokyo Night) so the resolution model above is exercised by the
built-ins themselves, not only by imports.

## Import Formats

Phase 1 supports three input formats for "导入主题…", detected by content/extension:

1. **Native JSON** — a `MenuBarPanelTheme` (or a bare `variants` palette,
   defaulting `name` to the filename) authored by hand or exported from
   another MacTools install. This is the lossless, round-trippable format.
2. **iTerm2 `.itermcolors`** — an Apple binary/XML property list. Decode with
   `PropertyListDecoder` into a small `Codable` struct mirroring the flat key
   set (`Background Color`, `Foreground Color`, `Ansi 0…15 Color`, `Selection
   Color`, `Cursor Color`, …; each a dict of `Red/Green/Blue[/Alpha]
   Component` floats in `0–1`). This alone unlocks the ~300-scheme
   `mbadolato/iTerm2-Color-Schemes` catalog and most "official" per-project
   iTerm2 exports. Mapping to the native token set:
   - `Background Color` → `panel.background`
   - `Foreground Color` → `text.primary`
   - `Selection Color` → `row.selectedBackground`
   - `Selected Text Color` → `text.primary` (fallback if absent)
   - `Ansi 1` (red) → `text.error` / `status` red hint
   - `Ansi 2` (green) → `status.success`
   - `Ansi 3` (yellow) → `status.warning`
   - `Ansi 6` (cyan) → `status.info`
   - `Ansi 4` (blue) — used as `accent` by default, since blue is the most
     common accent hue across these palettes; the import UI should let the
     user re-pick which Ansi slot becomes `accent` from a small swatch picker
     before confirming, since "which hue is the accent" is inherently
     ambiguous when converting a 16-slot terminal palette.
   - Single file = single variant; the declared polarity is inferred from
     background luminance (simple relative-luminance threshold on
     `Background Color`), since `.itermcolors` has no explicit light/dark
     flag.
3. **Base16 / Base24 YAML** — the modern schema's `variant: dark|light` field
   gives an explicit polarity for free, and the fixed role assignment gives an
   unambiguous mapping:
   - `base00`/`base01` → `panel.background` / `toolbar.pillSelectedBackground`
   - `base03` → `text.tertiary`
   - `base05` → `text.primary`
   - `base04` → `text.secondary`
   - `base02` → `row.hoverBackground` / `row.selectedBackground`
   - `base08` → `text.error` / status red
   - `base0A` → `status.warning`
   - `base0B` → `status.success`
   - `base0C` → `status.info`
   - `base0D` → `accent`
   - This needs a YAML reader. Because Base16/Base24 scheme files are a
     narrow, flat subset of YAML (`key: "value"` pairs plus one nested
     `palette:` map, no anchors/multi-doc/complex types), a small
     purpose-built parser limited to that subset is a lower-risk choice than
     adding a general-purpose YAML SwiftPM dependency, consistent with
     `AGENTS.md`'s "explain the reason before adding a third-party
     dependency" guidance. If real-world scheme files turn out to need more
     YAML surface than expected, revisit adding a vetted dependency (e.g.
     Yams) at that point instead of over-building the bespoke parser
     up front.

**Deferred to phase 2:** VS Code theme JSON import. VS Code's `colors` map is
large, optional-everywhere, and inconsistently populated across community
themes (many rely on `include`d base themes or omit keys entirely), so a
faithful mapping needs a fallback chain per token that is more work than the
value justifies for a first version. Base16/Base24 already covers most of the
same popular palettes with far less ambiguity.

## Data Model Sketch (for later implementation)

```swift
struct PanelColorPalette: Codable, Equatable {
    var panelBackground: HexColor
    var panelBorder: HexColor?
    var toolbarPillBackground: HexColor
    var toolbarPillSelectedBackground: HexColor
    var textPrimary: HexColor
    var textSecondary: HexColor
    var textTertiary: HexColor
    var textError: HexColor
    var accent: HexColor
    var accentForeground: HexColor
    var controlIconWellBackground: HexColor
    var rowHoverBackground: HexColor
    var rowSelectedBackground: HexColor
    var separator: HexColor
    var badgeBackground: HexColor
    var statusSuccess: HexColor
    var statusWarning: HexColor
    var statusInfo: HexColor
}

enum ThemeSourceFormat: String, Codable { case native, base16, iterm2 }

struct MenuBarPanelTheme: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var author: String?
    var sourceFormat: ThemeSourceFormat
    var variants: [ThemeAppearance: PanelColorPalette]
}

@MainActor
final class PanelThemeStore: ObservableObject {
    @Published private(set) var builtInThemes: [MenuBarPanelTheme]
    @Published private(set) var importedThemes: [MenuBarPanelTheme]
    @Published var selectedThemeID: String?   // nil == 系统默认

    func resolvedPalette(for appearance: AppAppearancePreference) -> PanelColorPalette? { ... }
    func importTheme(from url: URL) throws -> MenuBarPanelTheme { ... }
    func deleteImportedTheme(id: String) throws { ... }
}
```

`HexColor` is a thin `Codable` wrapper (string `"#RRGGBB"`/`"#RRGGBBAA"`)
convertible to `Color`/`NSColor`, matching the hex-driven pattern
`PluginSettingsTheme.Palette` already uses internally
(`pluginSettingsThemeRGB`), just made `Codable` instead of baked into compiled
Swift.

## Persistence

- Built-in themes ship as bundled JSON resources generated offline (a small
  conversion script, not part of the runtime), analogous to how plugin
  catalogs are generated today.
- Imported themes are copied into Application Support next to other
  MacTools-owned state (same pattern family as `PluginPackageStore`'s
  per-plugin storage), one JSON file per theme, storing the resolved native
  palette **plus** the original source file and format for re-export/debugging.
- The selected theme ID is a `UserDefaults` string key, following the same
  `AppAppearancePreference.userDefaultsKey` convention, and should be included
  in `PreferencesBackupStore`'s backup/restore set alongside
  `appearancePreference` — same as how the existing appearance key is already
  backed up.

## Settings UI Placement

Insert one new row directly under `AppearanceSettingsRow` inside the existing
外观 `Section` in `Sources/App/SettingsView.swift`
(`Sources/App/SettingsView.swift:308-322`), not a new top-level section —
this matches the prompt's own suggestion ("在当前的深色浅色切换下面加个主题设置
就行") and keeps 外观 as one coherent group: *system appearance* → *panel
theme*.

The row itself should **not** be a segmented control or inline picker — with
8+ built-ins plus arbitrary imports, and a need to show live color swatches so
users can recognize a theme before applying it, this needs the same "row that
opens a dedicated manager view" pattern already used for other multi-item
settings (`FanControlPresetManagerView` is the closest visual precedent per
`AGENTS.md`'s settings-UI guidance). Proposed shape:

- Row: "菜单栏主题" title, current theme name as trailing value, `chevron.right`
  disclosure, matching the row styling other disclosure rows already use.
- Destination: `PanelThemeGalleryView` — a grid of theme cards. Each card
  shows a small swatch preview (background chip + 3–4 token dots: text,
  accent, one status color) rendered for whichever appearance the card
  currently represents, a name, and a checkmark when selected. "系统默认" is
  always the first card. A bottom "导入主题…" button opens `NSOpenPanel`
  filtered to `.json`, `.itermcolors`, `.yaml`/`.yml`.
- Imported theme cards get a trailing context action (right-click or a small
  ellipsis button) to remove them; built-in cards cannot be removed.
- Typography/spacing/radius for this new view should be built from
  `PluginSettingsTheme.Typography`/`Spacing`/`Radius`/`Palette` per the
  existing settings-UI guidelines, not new ad hoc constants.

## Architecture / Integration Points

```
Settings (外观 → 菜单栏主题)
  PanelThemeGalleryView -> PanelThemeStore.selectedThemeID (UserDefaults + backup)
                              │
                              ▼
Sources/App (host-owned)
  PanelThemeStore.resolvedPalette(for: AppAppearancePreference.stored())
      - .none  -> nil (fall through to today's semantic colors, zero behavior change)
      - .some  -> PanelColorPalette for the resolved variant
                              │
                              ▼
MenuBarPanelPresenter / MenuBarContent
  - read the resolved palette (environment value or injected dependency)
  - replace literal Color.primary/.secondary/.opacity(...) call sites listed
    in the token table above with palette lookups (falling back to the exact
    current literal when palette is nil)
  - single-variant theme also pins popover NSAppearance via
    AppAppearancePreference.apply(to: NSPopover), scoped to the popover only
```

Plugins are unaffected: they keep supplying `iconTint` and continue reading
`Color.primary`/`.secondary` inside any custom `PluginComponentPanel.makeView`
content, consistent with "plugins never touch menu-bar UI directly." Only the
host-owned chrome in `Sources/App` needs to become palette-aware.

## Risks / Open Questions

1. **Contrast safety for arbitrary imports.** An imported theme with poor
   foreground/background contrast could make the panel unreadable. Phase 1
   should compute basic WCAG-ish contrast on import and warn (not block) when
   `panel.background` vs `text.primary` contrast is too low.
2. **Native-control legibility under single-variant themes.** Pinning popover
   `NSAppearance` (see Resolution Model) mitigates but does not fully solve
   this — a dark-declared theme with an unusually light `panel.background`
   would still fight the OS-drawn dark controls. Worth a lint/warning at
   import time similar to (1), rather than a hard technical constraint.
3. **Hover/pressed state derivation.** Tokens like `row.hoverBackground` are
   currently opacity-over-`Color.primary`, which self-adapts to light/dark
   automatically. Once a custom palette sets an explicit `panel.background`,
   hover fills must be derived from the *palette's* text/accent color instead
   of `Color.primary`, or hover states will look wrong on non-default
   backgrounds. This needs care during implementation, not just data-model
   design.
4. **Scope creep guardrail.** Because the popover's secondary panel currently
   relies on an actual `NSVisualEffectView` material for its blur, a fully
   custom `panel.background` color implies replacing that material with a
   solid/blended fill for themed states — acceptable, but should be called
   out explicitly as an implementation cost, not assumed to be free.

## Testing Strategy (once implemented)

- Unit tests for the Base16/YAML subset parser: valid minimal scheme, missing
  optional fields, `variant` inference when absent, rejection of malformed
  input.
- Unit tests for `.itermcolors` decoding: float→hex conversion parity against
  known values (e.g. the Nord `.itermcolors` background triple used in the
  research above), missing-key fallback behavior.
- Unit tests for `PanelThemeStore.resolvedPalette(for:)` covering: no theme
  selected, single-variant theme under all three `AppAppearancePreference`
  values, two-variant theme under all three values, imported theme deletion
  falling back to 系统默认 if it was selected.
- Snapshot/contrast-ratio tests for each shipped built-in theme's both
  variants, guarding against future edits accidentally shipping a
  low-contrast built-in.

## Summary of Decisions This Doc Makes

- Native schema: small, semantic, popover-shaped token map — not a terminal
  ANSI palette, not VS Code's full workbench color set.
- Appearance handled by **reusing** `AppAppearancePreference`, not by adding a
  second "follow system" switch; a theme only ever declares which variants it
  *has*.
- Import formats for phase 1: native JSON, iTerm2 `.itermcolors`, Base16/Base24
  YAML (via a small bespoke parser, not a new SPM dependency, unless proven
  insufficient). VS Code theme import is explicitly deferred.
- Built-ins: 系统默认 + 7 popular palettes, deliberately mixing single- and
  dual-variant examples.
- UI: one new disclosure row under the existing 外观 section, leading to a
  gallery/grid manager view, not an inline picker.
