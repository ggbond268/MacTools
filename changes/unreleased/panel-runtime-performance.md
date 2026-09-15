---
release: app
type: fixed
---
Reduce delays when switching large panels and removing widgets. Repeated widgets share foreground lifecycle events, including when deleting a panel returns its widgets to a visible default panel.
