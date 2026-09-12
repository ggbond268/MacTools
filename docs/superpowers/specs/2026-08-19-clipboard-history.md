# Clipboard Plugin Design

Date: 2026-08-19
Updated: 2026-09-02

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

Source attribution distinguishes an application, Universal Clipboard, and unknown origin. The `com.apple.is-remote-clipboard` marker takes precedence and displays Other Device in rows and Universal Clipboard in details. Otherwise a valid `org.nspasteboard.source` identifier supplies the declared app; an empty, invalid, unreadable, or conflicting declaration is unknown. Unmarked copies retain the observed foreground app as a best-effort estimate. Source-marker values are read by the bounded pasteboard helper and discarded with stale clipboard revisions. Declared origins never bypass existing foreground or recent-app privacy exclusions. Optional encrypted source metadata preserves legacy application records; no existing attribution is rewritten. AirDrop is not inferred from the Universal Clipboard marker.

Collection can be paused and applications excluded. Producer-marked transient or concealed content is skipped. Private Copy Now and Ignore Next Copy suppress sensitive copies before the plugin reads pasteboard types, content, or source context.

### Saved Library

Saved is a durable role on a captured item, not a copied payload. Saving a History item preserves
the same stable identifier, encrypted payload, source metadata, OCR, and search index while adding
Saved metadata. A captured item may be visible in both History and Saved; All still renders it once.
A **Snippet** is a separate authored item created explicitly when the user wants editable reusable
text or paste-time variables. This keeps literal captured text such as `{{name}}` unchanged.

Saved clips have a name, tags, and usage time. Snippets additionally have an optional expansion keyword. Saving replaces the former pin model; there is no History pin capacity or automatic Saved eviction.

Snippet templates expand `{{date}}`, `{{time}}`, `{{datetime}}`, `{{clipboard}}`, and `{{cursor}}` at paste time. Date variables accept an optional quoted format. Templates do not run shell commands, AppleScript, or network requests. Optional keyword expansion requires Accessibility, ignores secure text fields, and revalidates the focused editor and insertion point before replacement. Unambiguous keywords expand immediately; a keyword that prefixes a longer configured keyword waits for a delimiter. Expansion verifies direct Accessibility replacement and uses a guarded, clipboard-preserving paste fallback for incompatible editors. Unsupported editors fail safely. Ephemeral diagnostics describe the last expansion attempt without retaining typed text or editor contents. Accessibility is also used for direct paste and private copy, independently of keyword expansion.

### Sequential Paste

An explicit queue is an immutable ordered snapshot of the selected History, Saved clips, and Snippets. The Paste Next shortcut can also create a bounded implicit snapshot of recent History. Snippet variables resolve when their queue step is pasted. Rapid shortcut presses are buffered and processed in order. A movable transient HUD shows progress, the pasted and next items, image previews when applicable, previous, skip, restart, close, and separate cancel controls.

## Panel and Actions

Opening or refocusing the panel targets the display under the pointer. Each display defaults to the center of its visible work area on every presentation until the user moves the panel there. Moved positions persist separately by display identity, using screen-local offsets so rearranging displays does not transfer positions between them. Restored frames fit inside the current work area; automatic placement and display-topology adjustments do not overwrite remembered positions.

The panel always exposes All, History, and Snippets in a native segmented control. A compact
filter menu contains Saved Only, Type, and Content filters. Active secondary filters remain visible
beside the menu and can be cleared together, including when their last matching item disappears.
Control-Tab and Control-Shift-Tab cycle the three scopes; Control-1 through Control-3 select them
directly. Command-1 through Command-9 remains quick paste. Type and content choices use the
existing presentation snapshot and stay stable while searching.

The search toolbar contains no collection or close button. The footer starts with Clipboard
Settings, the collection toggle, and the shortcut guide. Collection always uses a clipboard icon
with a cross badge, neutral when enabled and highlighted with the system accent color when disabled. One divider separates these controls
from the shortcut hints, which have no internal dividers. Multi-selection keeps its combined-copy
button without a separate status sentence. Escape still closes the panel. Opening settings
closes the floating panel without returning focus to the previously active app. History, Actions,
and the sequential paste HUD share a nearly opaque native frosted backdrop that keeps text clear
over busy desktops, with a fully opaque surface when Reduce Transparency is enabled.

Quick paste, mixed clip/snippet multi-selection, export, native sharing, plain-text conversion,
Delete, and Save actions remain available when applicable. Per-item Delete removes the selected
record everywhere; Unsave only removes its Saved status. Snippets retain creation, editing,
keyword status, tags, and template preview.

Captured clips remain ordered by capture time in History and All; usage bookkeeping does not reorder that chronology. Snippets use their authored or edited chronology. Multi-selection preserves the order in which items were marked, independently of display order.

Clipboard-window commands resolve through one binding map. Configurable commands cannot silently
claim fixed navigation, quick-paste, or filter keys, and configurable conflicts offer Swap,
Replace, or Cancel. The footer, overflow guide, Actions window, and inline controls all display
the effective bindings from that same map.

Settings groups Clipboard History, Snippets, and Paste Queue into native form sections. History starts with Privacy & Storage and its Setup Guide, followed by collection, Open History, and Paste as Plain Text; its Advanced disclosure contains retention limits and collection-control shortcuts. Snippets shows its library and keyword-expansion switch, with its expanded-text limit under Advanced. Paste Queue shows Paste Next and keeps HUD options and queue-control shortcuts under Advanced. A shared Advanced section follows for excluded apps, Private Copy shortcuts, and window shortcuts. Shortcut groups are embedded in their owning feature instead of separate shortcut cards; settings search reveals the corresponding disclosure. Local Data remains last with direct History, Saved Clips, and Snippets cleanup rows and storage recovery actions.

Clipboard payloads never become Unified Search results, action descriptions, logs, diagnostics, or preference-backup content. Focus-dependent item operations remain inside the plugin panel. Canonical parameter-free actions cover opening Clipboard, collection state, clearing History, and sequential-paste controls.

Rich-text previews initially follow the app appearance. The local light/dark button selects the opposite canvas; switching back resumes following the app, and selecting another item or reopening the panel clears the local override. Both appearances are prepared once per preview load. Low-contrast foreground and decoration colors are adjusted against the canvas or explicit run background while readable colors, fonts, links, and highlights remain intact. Original clipboard payloads are unchanged. The preview card aligns with the detail header. Payload reads and RTF-only imports run on a worker; HTML imports use the main thread as required by AppKit, retain the external-resource denial policy, and share the existing 128 KiB import and 12,000-character formatted-preview bounds. Oversized or unreadable documents keep their existing plain-text fallback and retry behavior.

## Storage and Privacy

Captured items use one table and one stable identity in the SQLite database; History membership and Saved metadata are persisted on that record. Authored snippets use their own table because they have editable template content and expansion metadata rather than captured pasteboard provenance. Searchable metadata and payloads are independently AES-GCM encrypted; large payloads decrypt lazily. One device-local 256-bit key is stored in Keychain. iCloud Keychain is not required.

History clearing removes History membership and deletes only captured records that are not Saved. Clear Saved Clips removes Saved metadata and deletes captured records that are no longer in History; it never deletes snippets. Delete All Snippets affects only authored snippets. A confirmed unreadable-store reset cryptographically erases the shared key and database, so its warning explicitly includes both History and Saved. Uninstall removes the entire private database and key.

Grouped files remain references rather than copied file contents. Unsupported application-private pasteboard types are discarded. OCR runs on-device and its bounded searchable text is encrypted with the item.

## Defaults

- History count: 500, with explicit presets through the supported maximum of 10,000. The configured age and storage limits still apply.
- History expiration: 30 days, configurable through Never.
- Embedded payload: 5 MiB per item, configurable through 50 MiB.
- Aggregate History payload: 64 MiB, configurable through 5 GiB and available disk space.
- Saved Library: no automatic retention or silent count cap.
- Expanded snippet output: 5 MiB by default, configurable to 1, 5, 20, or 50 MiB. Oversized output is rejected without truncation or clipboard changes.
- Default exclusions: Apple Passwords, Keychain Access, 1Password, and Bitwarden.

## Architecture

- `ClipboardHistoryController` owns capture, retention, lazy History payloads, OCR, and History persistence.
- `ClipboardHistoryController` also owns Saved metadata for captured items, ensuring Save, recapture, OCR, retention, and deletion all preserve one identity.
- `ClipboardSavedLibraryController` owns authored snippets, template validation and expansion, and snippet persistence.
- `IncrementalEncryptedClipboardHistoryStore` persists captured History/Saved state; `IncrementalEncryptedClipboardSavedLibraryStore` persists only authored snippets in the same encrypted database.
- `ClipboardSnippetKeywordExpander` observes key-down events only while enabled and replaces text through Accessibility without using clipboard round trips.
- History capture and snippet expansion use independent lazy pasteboard-reader helper processes, so a blocked or cancelled snippet read cannot stall or reset capture work.
- `ClipboardHistoryPanelController` owns the floating History/Saved panel and restores the previous application for paste.
- The panel caches its bounded initial page against monotonic History and Snippet revisions, allowing constant-time unchanged reopens while rebuilding asynchronously whenever either source changes.
- `ClipboardSequentialPasteCoordinator` owns immutable explicit mixed-item snapshots and implicit History snapshots, and protects queued History rows from retention until completion or cancellation.

## Verification

Focused tests cover encrypted History/Saved independence, metadata and rich-text round trips, retention and clearing boundaries, template expansion, keyword matching, duplicate validation, panel keyboard behavior, queue lifecycle, and localization completeness. Cross-module PluginKit changes also require repository script tests, a Debug plugin build, and the CI-equivalent validation before review.

## Deferred Work

- Snippet collection import/export and sync need a separate portability and privacy design; exporting individual snippet text is supported.
- Shell, network, AppleScript, AI, and MCP template variables remain intentionally unsupported.
- Explicit queues preserve ordered mixed selections of History, Saved clips, and Snippets. Implicit queues remain bounded snapshots of recent History.
