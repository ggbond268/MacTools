# Clipboard Plugin Design

Date: 2026-08-19
Updated: 2026-08-25

## Summary

Issue [#306](https://github.com/ggbond268/MacTools/issues/306) adds the official `clipboard` plugin. It combines encrypted local History, a durable Saved Library, and sequential paste without uploading clipboard content. Because the plugin has not shipped, this first release adopts the final identity and database layout directly rather than carrying a migration from the unreleased `clipboard-history` prototype.

## Competitive Research

- **Alfred** separates automatic clipboard history from permanent snippets, including keyword expansion and dynamic placeholders.
- **Raycast** combines type-filtered history, OCR, item actions, snippets, and sequential paste in a keyboard-first surface.
- **Paste** emphasizes rich previews, multi-selection, labels, pinboards, and a visual sequential Paste Stack.
- **Maccy** validates a small native local-history surface with transient/concealed-type safeguards.
- **macOS 26** adds opt-in Spotlight clipboard history, while MacTools continues to support macOS 14 with consistent encryption, Saved content, exclusions, and automation boundaries.

References:

- https://www.alfredapp.com/help/features/clipboard/
- https://www.alfredapp.com/help/features/snippets/
- https://manual.raycast.com/clipboard-history
- https://pasteapp.io/help/paste-on-mac
- https://github.com/p0deje/Maccy
- https://support.apple.com/en-euro/guide/mac-help/mchl40d5b86b/26/mac/26

## Product Model

### History

History automatically captures supported standard pasteboard representations for text, rich text, images, PDFs, files, links, colors, audio, and video. It is searchable by content, file name, source-app context, semantic link/email/color traits, and on-device OCR. Retention can limit count, age, aggregate encrypted payload bytes, and per-item bytes. Clearing History never removes Saved content.

Collection can be paused and applications excluded. Producer-marked transient or concealed content is skipped. Private Copy Now and Ignore Next Copy suppress sensitive copies before the plugin reads pasteboard types, content, or source context.

### Saved Library

Saved is a durable role on a captured item, not a copied payload. Saving a History item preserves
the same stable identifier, encrypted payload, source metadata, OCR, and search index while adding
Saved metadata. A captured item may be visible in both History and Saved; All still renders it once.
A **Snippet** is a separate authored item created explicitly when the user wants editable reusable
text or paste-time variables. This keeps literal captured text such as `{{name}}` unchanged.

Saved clips have a name, tags, and usage time. Snippets additionally have an optional expansion keyword. Saving replaces the former pin model; there is no History pin capacity or automatic Saved eviction.

Snippet templates expand `{{date}}`, `{{time}}`, `{{datetime}}`, `{{clipboard}}`, `{{cursor}}`, and `{{uuid}}` at paste time. Date variables accept an optional quoted format. Templates do not run shell commands, AppleScript, or network requests. Optional keyword expansion requires Accessibility, ignores secure text fields, and revalidates the focused editor and insertion point before replacement. Unambiguous keywords expand immediately; a keyword that prefixes a longer configured keyword waits for a delimiter. Unsupported editors fail safely. Ephemeral diagnostics describe the last expansion attempt without retaining typed text or editor contents. Accessibility is also used for direct paste and private copy, independently of keyword expansion.

### Sequential Paste

An explicit queue is an immutable ordered snapshot of selected History items. The Paste Next shortcut can also create a bounded implicit snapshot of recent History. Rapid shortcut presses are buffered and processed in order. A movable transient HUD shows progress, the pasted and next items, image previews when applicable, previous, skip, restart, close, and separate cancel controls.

## Panel and Actions

Filter groups use a fixed two-row region: Scope, Type, and Content summaries above the active
group's options. Only groups that can produce a smaller nonempty subset appear. Empty, single-item,
and uniform collections omit that region entirely so results and previews reclaim its height.
Available groups and option order are captured on opening, never recalculated during search, OCR,
copying, saving, or deletion; the next opening refreshes them. Control-Tab and Control-Shift-Tab
cycle available groups without changing their filter values. Control-1 through Control-9 selects
the corresponding visible option in the active group, with no gaps for absent types. Option-number
bindings are not intercepted. Footer hints and tooltips reflect the active group's visible options;
Command-1 through Command-9 remains quick paste.

The floating keyboard-first panel shares the Command Palette visual language. All, History, Saved, and Snippets are explicit scopes with one shared search field. Type and semantic filters, quick paste, mixed clip/snippet multi-selection, export, native sharing, plain-text conversion, Delete, and Save actions remain available when applicable. Per-item Delete removes the selected record everywhere; Unsave only removes its Saved status. Snippets have their own creation, editing, keyword status, tags, and template preview, without a separate Favorites hierarchy.

Settings starts with a concise, non-collapsible Privacy & Storage summary, storage status, Setup Guide, and optional details. Primary shortcuts follow collection. Paste Queue is one section: Paste Next stays visible, while HUD options and previous/skip/restart/cancel shortcuts share one initially collapsed disclosure. Saved Clips and Snippets have separate cards and separate clearing boundaries. Infrequent retention, exclusions, and shortcut controls collapse behind full-width clickable headers.

Clipboard payloads never become Unified Search results, action descriptions, logs, diagnostics, or preference-backup content. Focus-dependent item operations remain inside the plugin panel. Canonical parameter-free actions cover opening Clipboard, collection state, clearing History, and sequential-paste controls.

## Storage and Privacy

Captured items use one table and one stable identity in the SQLite database; History membership and Saved metadata are persisted on that record. Authored snippets use their own table because they have editable template content and expansion metadata rather than captured pasteboard provenance. Searchable metadata and payloads are independently AES-GCM encrypted; large payloads decrypt lazily. One device-local 256-bit key is stored in Keychain. iCloud Keychain is not required.

History clearing removes History membership and deletes only captured records that are not Saved. Clear Saved Clips removes Saved metadata and deletes captured records that are no longer in History; it never deletes snippets. Delete All Snippets affects only authored snippets. A confirmed unreadable-store reset cryptographically erases the shared key and database, so its warning explicitly includes both History and Saved. Uninstall removes the entire private database and key.

Grouped files remain references rather than copied file contents. Unsupported application-private pasteboard types are discarded. OCR runs on-device and its bounded searchable text is encrypted with the item.

## Defaults

- History count: 500, with explicit presets through 10,000 and an Unlimited option. The configured age and storage limits still apply.
- History expiration: 30 days, configurable through Never.
- Embedded payload: 5 MiB per item, configurable through 50 MiB.
- Aggregate History payload: 64 MiB, configurable through 5 GiB and available disk space.
- Saved Library: no automatic retention or silent count cap.
- Snippets: 5 MiB of UTF-8 text per item; keyword-enabled snippet bodies: 16 MiB total in the expansion cache. Both limits reject saves explicitly and never truncate content.
- Default exclusions: Apple Passwords, Keychain Access, 1Password, and Bitwarden.

## Architecture

- `ClipboardHistoryController` owns capture, retention, lazy History payloads, OCR, and History persistence.
- `ClipboardHistoryController` also owns Saved metadata for captured items, ensuring Save, recapture, OCR, retention, and deletion all preserve one identity.
- `ClipboardSavedLibraryController` owns authored snippets, template validation and expansion, and snippet persistence.
- `IncrementalEncryptedClipboardHistoryStore` persists captured History/Saved state; `IncrementalEncryptedClipboardSavedLibraryStore` persists only authored snippets in the same encrypted database.
- `ClipboardSnippetKeywordExpander` observes key-down events only while enabled and replaces text through Accessibility without using clipboard round trips.
- `ClipboardHistoryPanelController` owns the floating History/Saved panel and restores the previous application for paste.
- `ClipboardSequentialPasteCoordinator` owns immutable explicit and implicit History snapshots and protects queued History rows from retention until completion or cancellation.

## Deferred Work

- Snippet collection import/export and sync need a separate portability and privacy design; exporting individual snippet text is supported.
- Shell, network, AppleScript, AI, and MCP template variables remain intentionally unsupported.
- Saved-item participation in sequential queues can be designed later with typed queue references; the first release keeps queues History-only.
