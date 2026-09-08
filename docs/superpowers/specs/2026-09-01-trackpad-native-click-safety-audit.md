# Trackpad Native-Click Safety Audit

## Status

This document records the Trackpad Gestures native-click safety audit completed on September 1, 2026. The recommended episode-scoped model was subsequently approved and implemented on the combined development branch.

Focused automated coverage now exercises exact contact episodes, unsafe-inventory operation, native click consumption, and double-tap transactions. The physical-hardware matrix in `Plugins/TrackpadGestures/MANUAL_TESTING.md` remains unrun.

## Original safety goal

Raw multitouch frames identify the originating trackpad, but public Core Graphics mouse events do not identify their originating HID device. MacTools therefore has to correlate two independent streams:

- trackpad contact frames containing a trackpad device ID; and
- native left- or right-button events without a reliable hardware device ID.

The safety policy was added to prevent MacTools from claiming an unrelated native click as part of a trackpad gesture. When attribution is uncertain, the code fails open: it lets the native click pass through and declines to run the mapping.

This protects users from several high-impact failures:

- rewriting an external mouse click as a middle click;
- swallowing an external mouse click while running a shortcut or MacTools action;
- pairing a mouse-down from one device with a mouse-up from another;
- leaving a synthetic middle button down or creating an unintended drag;
- consuming a failed gesture's original tap-to-click event instead of replaying it;
- recursively claiming process-generated mouse events; and
- assigning a native click to the wrong trackpad when multiple devices or gesture candidates overlap.

The conservative policy is appropriate when MacTools is about to suppress or rewrite an existing native click and cannot establish ownership.

## Why the audited policy was too broad

The audited implementation reduced the complete HID topology to one Boolean, `allowsContactInference`. It was false whenever any mouse-capable HID entry was unrelated to a detected trackpad, when inventory enumeration was incomplete, during asynchronous topology refresh, or when continuous monitoring was unavailable.

That Boolean is then used for operations with different risk profiles:

- attributing and rewriting an existing native click;
- recognizing a physical trackpad click;
- synthesizing a new middle click from an already-qualified contact gesture; and
- deciding whether an admitted gesture may finish after the inventory changes.

As a result, installing or connecting an unrelated pointer can permanently disable mappings even when that pointer is idle and there is no competing native click. Karabiner's virtual pointing device demonstrates this failure on the current development machine.

## Confirmed pre-fix findings

### 1. Unrelated pointers disable multiple gesture families

An unsafe inventory rejects ordinary tap and long-touch middle clicks before synthesis. It also leaves two- and three-finger physical clicks unattributed, preventing their shortcut, MacTools-action, and middle-click mappings from running. The same failures can occur briefly after any HID topology notification while the inventory cache refreshes.

Qualified TipTap now has a narrower exception: an exact, short-lived TipTap episode can correlate its native tap-to-click event even when broad inventory is unsafe, while process-owned events remain excluded.

### 2. Double-tap middle click has no candidate path

The middle-click contact-count helper includes physical clicks, ordinary taps, long touches, and TipTap, but omits `doubleFingerTapCount`. Three-, four-, and five-finger double taps can be assigned to middle click in the UI but cannot complete the middle-click arbiter path.

A correct implementation must buffer the first tap's native click, discard both native tap pairs after a successful double tap, and replay the first pair unchanged if the double-tap interval expires.

### 3. Ordinary tap actions can leak their native click

Only TipTap and physical-click mappings receive a consume resolution for keyboard shortcuts and MacTools actions. On systems where an ordinary multi-finger tap produces a native tap-to-click event, the mapped action can run while the original left click also reaches the application under the pointer.

### 4. Test mode and production admission can disagree

Test mode reports contact recognition but does not exercise the complete production delivery path for ordinary taps and double taps. It can therefore report success while production rejects a middle-click mapping. Native tap-to-click events may also interact with the testing UI. Physical-click testing remains degraded by unsafe inventory.

### 5. Fail-closed cache transitions are silent

The inventory cache immediately changes its verdict to false on HID invalidation and refreshes asynchronously. No live status distinguishes a disabled mapping, a recognized-but-unattributed click, and an ordinary recognition failure.

### 6. Deferred event-tap shutdown has an unbounded wait

After MacTools consumes or converts a mouse-down, it retains terminal ownership until the exact matching mouse-up arrives. This preserves button-pair correctness, but if the mouse-up never arrives the event tap can remain installed after the plugin is disabled.

## Recommended safety model

Replace the global Boolean admission rule with evidence-scoped decisions:

1. **Contact-only actions:** Long touches and other actions that do not claim a native click should not depend on HID inventory.
2. **Qualified tap episodes:** Ordinary taps should use a bounded, per-device contact episode. A successful mapping consumes its correlated native tap; a failed episode replays it.
3. **Qualified double-tap episodes:** Track both tap episodes explicitly and buffer or replay their native pairs as one transaction.
4. **Physical-click candidates:** Permit a narrow fallback when the required contacts are active on exactly one trackpad and the native down occurs inside that candidate window, even if an unrelated pointer is installed.
5. **TipTap episodes:** Retain the exact-episode correlation and process-owned-event exclusion already implemented.
6. **Broad inventory:** Use inventory only as fallback evidence when no exact gesture episode is available. Do not use it to cancel a pure contact action or an already-established ownership decision.
7. **Testing:** Run the production admission and correlation path with a disabled action sink. Show contact recognition, native-click correlation, and action readiness separately.
8. **Diagnostics:** If any operation remains degraded, show the current reason and the relevant pointing device instead of silently dropping the mapping.

## Implemented resolution

The approved implementation addresses findings 1 through 4:

- recognition deliveries carry a stable contact-episode ID from the raw frame through native-click resolution;
- a unique, unambiguous episode can correlate its native click even when broad HID inventory is unsafe, while process-owned and overlapping input remains fail-open;
- ordinary tap shortcuts and MacTools actions consume their correlated native click;
- double taps without a matching single-tap mapping buffer two native pairs as one transaction, discard them after success, and replay them after failure or timeout;
- matching single- and double-tap mappings preserve the documented single-then-double action sequence; and
- Test Gestures uses the same native-click resolution path for ordinary taps and double taps while keeping its action sink disabled.

The live diagnostic enhancement in finding 5 and the terminal-ownership shutdown bound in finding 6 remain separate follow-up work. They are not required to remove the overly broad inventory veto, and changing terminal ownership deserves its own failure-injection verification.

## Required verification matrix

Cover every gesture family against shortcut, MacTools action, single-key output, and middle click with:

- only the built-in trackpad;
- Magic Trackpad over USB and Bluetooth;
- Karabiner or another persistent virtual pointer;
- an external mouse idle and clicking simultaneously;
- tap to click enabled and disabled;
- native click before and after recognition delivery;
- two active trackpads and overlapping candidates;
- topology changes during pending recognition; and
- sleep, wake, permission loss, configuration changes, and missing mouse-up events.

The core invariant should be: MacTools must never suppress or rewrite an unrelated native click, but the mere presence of another pointer must not disable a gesture supported by exact trackpad evidence.
