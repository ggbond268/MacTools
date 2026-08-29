---
release: plugin
type: fixed
area: Clipboard
---

Speed up Clipboard opening by preparing large history indexes off the main thread, avoiding transient loading flashes, and reusing bounded image previews.

Keep the Clipboard layout stable while selecting rows, and allow choices to appear inside an already-visible filter strip without adding or moving filter rows.
