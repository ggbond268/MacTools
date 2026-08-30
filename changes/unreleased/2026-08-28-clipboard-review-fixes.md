---
release: plugin
type: fixed
area: Clipboard
---

Improve Clipboard capture, paste, sharing, and snippet-save reliability, including excluded-app startup privacy, shared storage recovery, snippet search, exports, and text selection.

Explicit paste queues now preserve encrypted, immutable ordered selections that mix History, Saved clips, and Snippets, while implicit queues remain short-lived History snapshots.

Snippet keywords ignore secure or unverified fields without slowing ordinary typing.
