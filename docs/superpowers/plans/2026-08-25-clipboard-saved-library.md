# Clipboard Saved Library Implementation Plan

## Product Boundary

Clipboard is one plugin with three related surfaces:

- **History** is automatically collected, searchable, and governed by retention limits.
- **Saved** is a user-owned library that remains available when History collection is paused. History retention and History clearing never remove Saved items.
- **Sequential Paste** consumes an immutable snapshot from History until it finishes or is canceled.

Saved clips and reusable text **Snippets** have distinct scopes and settings sections. Promotion preserves the captured item's stable identifier and payload rather than creating a second clip record. Snippets are authored separately, including through Create Snippet from Clip. Neither surface has a separate Favorites hierarchy.

## Storage

Captured items share one encrypted SQLite table and stable identity. History membership and optional Saved metadata determine which scopes show each item; All renders a captured item once even when both roles apply. Authored snippets use a separate table in the same database because their editable templates and expansion metadata have different semantics. A full unreadable-store reset cryptographically erases both domains and says so before confirmation.

Snippet metadata contains only bounded search text; the complete body remains in the lazy encrypted payload. A snippet may contain up to 5 MiB of UTF-8 text. Keyword-enabled snippets use an in-memory expansion cache capped at 16 MiB in total; exceeding either explicit limit is rejected without truncating content.

## Snippets

The Snippet editor supports a title, tags, and one optional unique expansion keyword,
content, and a deterministic preview. Saving any History item adds Saved metadata to that literal
captured item, including text and rich text, so source content that resembles a variable is never
interpreted. Its name and tags can be edited without changing the original payload. Snippets are created explicitly
when the user wants editable reusable text or paste-time variables.

Supported paste-time variables are:

- `{{date}}`, `{{time}}`, and `{{datetime}}`, with optional quoted date formats;
- `{{clipboard}}` for the current plain-text clipboard value;
- `{{cursor}}` for one post-insertion cursor location;
- `{{uuid}}` for a newly generated UUID.

Escaping `\{{` produces a literal `{{`. Unknown variables, invalid date formats, multiple cursor markers, whitespace-containing keywords, and duplicate keywords are rejected. Templates never execute shell commands, AppleScript, or network requests.

When keyword expansion is enabled, an unambiguous keyword expands immediately after its final character reaches the focused editor. A keyword that prefixes a longer keyword waits for whitespace or punctuation. The editor must expose a non-secure text selection and support replacement; focus and the exact keyword range are revalidated before mutation. Expansion uses Accessibility without clipboard round trips. Content-free diagnostics distinguish missing input, unsupported editors, stale context, unloaded templates, and failed replacement.

Paste Queue combines its primary Paste Next shortcut, HUD preferences, and optional queue-control shortcuts in one card. Only Paste Next is initially expanded; the remaining controls share one full-width disclosure. Saved clip clearing and snippet deletion remain separate, explicitly confirmed actions.

## Verification

Focused tests cover encrypted History/Saved independence, metadata and rich-text round trips, clearing boundaries, template expansion, keyword matching, duplicate validation, panel keyboard behavior, and localization completeness. Cross-module PluginKit changes also require script tests, a Debug build, and the CI-equivalent local validation.
