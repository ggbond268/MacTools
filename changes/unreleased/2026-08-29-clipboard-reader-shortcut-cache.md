---
release: plugin
type: fixed
area: Clipboard
---

Keep Clipboard capture responsive while snippets read the pasteboard, make Clipboard-window shortcut conflicts explicit with Swap and Replace choices, and prevent unchanged warm reopens from rescanning the full library.

Remove the unreleased Favorites layer so Saved clips and Snippets remain the only durable library concepts.

Keep delayed Private Copy content out of History, and keep Swap or Replace from leaving incompatible shortcut owners behind.

Paste saved clips and snippets, including mixed multi-item selections, without waiting for background usage-order bookkeeping, while preserving their newest ordering after concurrent edits.
