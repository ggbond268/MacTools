# Clipboard History Plugin Design

Date: 2026-08-19

## Summary

Issue [#306](https://github.com/ggbond268/MacTools/issues/306) adds an official `clipboard-history` plugin for searchable local history and pinned items. Because the plugin has not shipped, the first release adopts a representation-based model immediately: it preserves standard pasteboard representations for text, rich text, images, PDFs, media, links, colors, and grouped file references, encrypts payloads and file paths at rest, exposes a dedicated keyboard-first panel, and never uploads clipboard content.

## Competitive research

### Alfred

Alfred provides searchable text, image, and file history; configurable retention and maximum clip size; application exclusions; history clearing by time window; optional direct paste; clipboard merging; and conversion of a history item into a permanent snippet. Its separate snippet system adds collections, keywords, text expansion, dynamic placeholders, and import/export.

Sources:

- https://www.alfredapp.com/help/features/clipboard/
- https://www.alfredapp.com/help/features/snippets/
- https://www.alfredapp.com/help/features/clipboard/accessing-clipboard-history/

### Raycast

Raycast provides searchable and type-filtered history for text, images, files, links, email addresses, and colors. Advanced actions include copy, direct paste, paste as a selected representation, edit, rename, pin, save as snippet, OCR, QR decoding, AI handoff, recent-window deletion, and sequential paste. Settings cover retention, disabled applications, plain-text preference, result reordering, and the primary copy/paste action.

Source:

- https://manual.raycast.com/clipboard-history

### Paste

Paste emphasizes a visual timeline, content previews, source application and date metadata, full keyboard navigation, multi-selection, numbered quick paste, sequential Paste Stack, editing and labels, source/date/device/type filters, pinboards, iCloud sync, collaboration, and an opt-in local MCP server. Its privacy controls include application exclusions, producer-marked confidential or transient content, retention, and temporary pause.

Sources:

- https://pasteapp.io/help/paste-on-mac
- https://pasteapp.io/help/what-paste-captures
- https://pasteapp.io/help/search-and-filters

### Maccy

Maccy validates the value of a smaller native, keyboard-first surface. It provides local history, search, pinning, copy or optional direct paste, configurable polling, and explicit support for ignoring transient, concealed, and application-specific pasteboard types. Recent releases also add previews and on-device OCR, while keeping the app local and open source.

Source:

- https://github.com/p0deje/Maccy

### macOS 26

macOS Tahoe adds an opt-in searchable Clipboard view to Spotlight, with copy and clear-history actions. MacTools still targets macOS 14, and the plugin offers consistent retention, exclusions, encrypted storage, pause, pinning, and canonical actions that the system surface does not expose.

Sources:

- https://support.apple.com/en-euro/guide/mac-help/mchl40d5b86b/26/mac/26
- https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/

## Product decisions

| Capability | First release | Rationale |
| --- | --- | --- |
| Global shortcut through canonical actions | Yes | Fast access is universal across Alfred, Raycast, Paste, and Maccy. Pressing the shortcut again while the panel is active dismisses it; other action surfaces remain deterministic open operations. |
| Search text, image text, file names, and source-app metadata | Yes | Rich formats use their plain-text representation when present; Apple Vision indexes image text on-device into the encrypted record. |
| Keyboard navigation | Yes | Essential for a clipboard tool invoked while typing. |
| Copy selected item back to the pasteboard | Yes | Meets the issue without Accessibility permission or synthesized input. |
| Pin/unpin | Yes | Covers the durable-snippet use case with a small privacy surface. |
| Optional count and age limits plus byte-size bounds | Yes | Users can choose no item-count limit and no expiration while the aggregate encrypted-store budget keeps storage and latency predictable. |
| Pause with a visible state | Yes | Common privacy control and an explicit acceptance criterion. |
| Application exclusions | Yes | Common competitor safeguard; described as best-effort frontmost-app attribution. |
| Ignore transient/concealed producer markers | Yes | A low-cost, privacy-preserving safeguard demonstrated by Paste and Maccy. It is not secret detection. |
| Private Copy shortcut | Yes | Sends Command-C to the frontmost app after arming one-shot suppression, so selected sensitive text is neither read nor stored. Accessibility permission is optional and scoped to this shortcut. |
| Ignore next context-menu copy | Yes | A 15-second one-shot suppression covers mouse-driven copying that cannot invoke Private Copy directly. |
| Privacy HUD | Yes | A click-through, non-activating HUD shows the Ignore Next Copy countdown and confirms consumption, Private Copy success, expiration, or failure without changing application focus. |
| Encrypted local payload store | Yes | Release-blocking requirement in issue #306. The encryption key lives in Keychain. |
| Images, PDFs, rich text, links, colors, audio, and video | Yes | Preserve standard macOS pasteboard representations so copying an item back does not flatten it to text. |
| Grouped file references | Yes | Preserve multi-file clipboard items without duplicating file contents into the encrypted history. Finder-copied PDFs, images, audio, and video remain file references for paste, but also match their semantic type filter; a single supported file receives a bounded Quick Look thumbnail plus local format, size, and duration metadata when available. |
| Arbitrary application-private formats | No | Only standard or recognized image, audio, and movie representations are retained; private formats can carry undocumented or sensitive state. |
| OCR text recognition | Yes | Image text is indexed on-device, bounded in size, and kept in the same encrypted local record. |
| Automatic and plain-text paste | Yes | Return and Command-1 through Command-9 paste into the previously active app through the plugin's optional Accessibility path. Shift-Return converts the selected item to plain text first, including on-device recognized image text when available. The optional global plain-text shortcut also uses completed recognition from the still-current clipboard image and reports recognition-in-progress or no-text states through the HUD. |
| QR recognition | No | QR decoding is independent of text retrieval and remains out of scope. |
| Edit, rename, labels, or pinboard collections | Later | Useful once pinned-snippet portability and organization are designed. |
| Snippet keyword expansion | Later | Requires global keystroke observation and secure-input handling distinct from clipboard capture. |
| Sequential paste or clipboard merging | Later | Valuable power workflow, but independent of trustworthy capture and storage. |
| Cloud/iCloud sync, collaboration, or export | No | Conflicts with the local-only first-release privacy boundary. |
| AI or MCP access | No | Clipboard history must not become externally accessible without a separate consent and threat model. |

## Defaults

- Maximum stored items: 500 total, including pins; users may choose 100, 250, 500, 1,000, or no item-count limit.
- Expiration: 30 days for unpinned history; users may choose 1, 7, 30, or 90 days, or no expiration.
- Maximum embedded payload: 5 MiB per item by default; users may choose 1, 5, 20, or 50 MiB. Oversized items are skipped and reported through the HUD.
- Maximum retained payload data: 64 MiB across all items, including pins, even when count and expiration are unlimited.
- File clipboard items store encrypted URL/path references and metadata, not copies of the referenced files.
- Pinned items do not expire by age, but still count toward configured count and aggregate byte limits.
- Collection starts enabled after the plugin is installed.
- Apple Passwords, Keychain Access, 1Password, and Bitwarden are excluded by default. Users can add or remove applications.

The aggregate bound remains mandatory because images and other embedded representations can be much larger than text. Retention prioritizes pinned items, then the newest unpinned items.

## Architecture

### `ClipboardChangeMonitoring`

Polls `NSPasteboard.general.changeCount` on a modest interval. It reports ownership transitions without persisting content, suppresses changes created when the plugin copies a selected item back to the pasteboard, and consumes one-shot privacy suppression before reading pasteboard types, source context, or payload representations.

### `ClipboardCapturePolicy`

Applies pause, supported-type, producer privacy marker, exclusion, empty-value, exact rich-payload or normalized plain-text consecutive deduplication, and aggregate representation byte-limit checks. Filtering occurs before persistence.

Normalization is used only for plain-text empty and consecutive-duplicate decisions. Original standard representations and pasteboard-item grouping are retained exactly. Standard file URLs are retained as references; unsupported and application-private representations are discarded.

### `ClipboardSourceContextProviding`

Snapshots `NSWorkspace.shared.frontmostApplication` at capture time. The UI describes this as the observed frontmost application, never guaranteed provenance.

### `EncryptedClipboardHistoryStore`

Encodes the bounded representation-based item array as a versioned JSON envelope, seals it with AES-GCM, and atomically writes one plugin-private file. A random 256-bit key is stored as a device-only Keychain generic password. Pending snapshot saves coalesce to the newest revision and flush when the plugin stops. An existing encrypted file with a missing key or failed authentication produces a blocking error; there is no plaintext fallback. The initial rich-content schema intentionally does not migrate unreleased development-only text stores.

### `ClipboardHistoryController`

Owns the in-memory snapshot, retention, persistence revisions, copy/delete/pin operations, and monitoring lifecycle. Panel and settings getters read its snapshot and do not scan the pasteboard or filesystem.

### `ClipboardHistoryPanelController`

Owns a floating SwiftUI-backed borderless `NSPanel` that follows the global Command Palette design language through shared PluginKit search, surface, selected-row, toolbar-control, and adaptive keycap components. A compact grip and open/closed-hand cursor expose window dragging without restoring a title bar. The shared search implementation is focused on every presentation and preserves the same IME, arrow-navigation, clearing, and accessibility behavior as the Command Palette, while type filtering and panel actions remain separate, comfortably sized controls. The selected filter uses a quiet accent tint so the solid selected-result treatment remains the primary emphasis. Compact rows use the palette's shared radius, padding, icon column, and content spacing with type-specific leading icons instead of redundant badges. The top-right holds the Command-1 through Command-9 quick-paste position, while the bottom-right aligns relative time and the bottom-left retains only source context. One subtle divider separates history from a detail preview that consumes all remaining space. Detail metadata shows the exact localized timestamp first, followed by a single-unit relative value and one compact content-information line. Text length and line count, image dimensions, PDF page count, file count and non-recursive size, media duration and dimensions, format, and link host are derived only for the selected item in cancellable background work; results are cached for the panel session. Rich text renders its stored formatting, while images scale within a bounded transparency-aware canvas so white edges, transparent regions, and extreme aspect ratios remain legible. Return pastes the selection; Shift-Return pastes a plain-text conversion; arrow keys or Control-P/Control-N navigate while search remains focused; Command-1 through Command-9 paste the corresponding visible result; Command-Delete removes it; Command-P toggles pinning; Escape closes the panel.

Search preserves ordinary case-insensitive substring matching for meaningful queries, treats whitespace-separated query terms as independent word prefixes, and accepts compact word fragments across separators without degrading into an unrestricted character subsequence. For example, `fo baz`, `foba`, `fbaz`, `oobaz`, and `oo baz` match `foo bar baz`, while low-signal fragments such as `oo` alone do not. Search covers clipboard text, on-device image OCR text, source-app metadata, bundle identifiers, and file paths.

### `ClipboardPrivacyHUDController`

Owns a click-through, non-activating panel on the pointer's active display. Ignore Next Copy shows a live countdown until the copy is consumed or the 15-second window expires. Private Copy shows success only after the controller suppresses a pasteboard change and reports failure if no change arrives.

### `ClipboardHistoryPlugin`

Publishes the primary panel, form-based settings page, and the six canonical actions from issue #306. The settings page starts with a persistent, dismissible setup checklist that confirms encrypted storage is ready, points users to the Open Clipboard History action shortcut, and explains the optional sensitive-copy workflows. Shortcut settings use three groups: Open Clipboard History and the plugin-private Paste Current Clipboard as Plain Text command together as the primary group, the two sensitive-copy workflows, and optional advanced controls that combine collection state with confirmed clearing operations. Collection status states explicitly that history lives in an encrypted local file and only the encryption key lives in Keychain; blocking storage errors expose a confirmed reset path instead of leaving an unexplained disabled switch.

The host-owned action shortcuts remain visible alongside a privacy-shortcut group whose controls are individually labeled Private Copy Now and Ignore Next Copy. The former sends Command-C immediately, while the latter arms a 15-second window for a later context-menu or keyboard copy. The Open Clipboard History global shortcut is source-aware: it dismisses a visible key history panel, brings an inactive visible panel forward, and otherwise opens it. A separate optional Paste Current Clipboard as Plain Text shortcut rewrites the clipboard from its existing plain-text representation or completed recognition from the image captured at the same still-current pasteboard change, then sends Command-V without opening history. Pending recognition and completed recognition without text produce distinct HUD feedback; a later clipboard change invalidates the image association so stale recognized text cannot be pasted. Native plain-text conversion remains available while collection is paused. These focus-dependent shortcuts remain plugin-specific, keeping input synthesis out of Unified Search, Automation, Action Grid, Run Links, and unattended invocation. The plugin never creates actions or Unified Search entries for clipboard payloads.

Rich-text document import never runs from a SwiftUI view builder. The preview loads asynchronously, skips formatted import for rich representations above 128 KB, and bounds formatted layout to 12,000 characters; larger content uses a clearly labeled, bounded plain-text preview instead.

## Privacy and failure behavior

- Clipboard representations, derived searchable text, and file paths never appear in logs, action descriptions, diagnostics, settings backup, or canonical action parameters.
- Exclusions and producer privacy markers are evaluated before a payload is passed to the store.
- One-shot suppression is consumed before the plugin asks for pasteboard types, source application, or payload representations.
- Expired items are removed from the encrypted file, not just hidden.
- Clearing history rewrites or removes the encrypted store immediately.
- Failed clears keep the visible snapshot intact, and Clear All can reset an unreadable encrypted store and its key.
- Uninstall invalidates pending persistence, removes the encrypted file, and deletes the Keychain key.
- Missing keys, authentication failures, corrupt envelopes, and unavailable support storage stop collection and show a user-facing error.
- Pinned snippets remain local-only and are excluded from portable preferences backup.

## Deferred design questions

- Whether pinned snippets should become a separate library with names, collections, editing, and import/export.
- Whether sequential paste should be a separate canonical action or its own focused plugin.
- Whether macOS 26 should offer a migration or conflict notice when Spotlight Clipboard history is also enabled.
