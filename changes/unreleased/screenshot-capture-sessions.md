---
release: plugin
type: fixed
area: Screenshot
---

- Fix recording and scrolling startup failures caused by undiscovered control windows, and keep controls reachable on the selected display.
- Keep slow recording saves in progress until the file finishes, and prevent unmatched scrolling frames from corrupting long screenshots.
- Match active recording and scrolling controls to the start-confirmation bar, with consistent glass capsules, button sizing, and padding.
- Show a click-through region outline during recording without including it in the video, keeping screen-edge selections visible.
