# Trackpad Gestures manual hardware verification

This checklist covers behavior that requires physical trackpad hardware and real macOS input settings. Automated tests do not replace these checks.

Status for PR #359 and issue #375: **Not run**. Record the tested Mac model, trackpad model, macOS version, result, and any notes before release.

## Core matrix

| Scenario | Variants to verify | Expected result | Status |
| --- | --- | --- | --- |
| Built-in MacBook trackpad | macOS 14 and each newer supported major version | Configured three- to five-finger taps and long touches recognize once; every distinct TipTap release recognizes while its fixed fingers remain down; disabled mappings do nothing | Not run |
| Magic Trackpad | USB and Bluetooth when available | Recognition matches the built-in trackpad and remains isolated per physical device | Not run |
| Tap to click enabled | Built-in and Magic Trackpad | A recognized TipTap performs exactly its mapped action and does not activate the link, button, or text field under the pointer; a failed gesture preserves the original click | Not run |
| Tap to click disabled | Built-in and Magic Trackpad | TipTap does not run a mapped action without an exact native click to correlate; other gesture families remain available | Not run |
| Physical clicks | Map two- and three-finger clicks to a shortcut, MacTools action, and middle click | Each physical press fires exactly once, suppresses or rewrites its matching native click, and does not also recognize as a tap when the fingers lift | Not run |
| Secondary click | Two-finger click and corner-click configurations | The two-finger conflict warning is visible; assigning that gesture deliberately replaces its matching secondary click, while unrelated clicks outside an active gesture candidate remain usable | Not run |
| External mouse or virtual pointer | Connect another mouse or virtual HID pointer, then try both that pointer and a click-producing trackpad gesture | The settings warning is visible; native clicks pass through unchanged and click-producing trackpad mappings fail open instead of claiming an uncertain source | Not run |
| Typing protection | Built-in keyboard and an external keyboard; 0.2, 0.4, and 1.0 second delays | Ordinary key events still reach the frontmost app, gestures stay inactive while a key is held and during the configured delay, and recognition rearms only after every trackpad contact lifts | Not run |
| Typing protection disabled | Built-in keyboard with protection switched off | Keyboard activity does not pause configured gestures | Not run |
| Three-finger dragging | Enabled and disabled | Conflicting three-finger mappings fail safely; native dragging remains usable | Not run |
| Test Gestures | Switch between Test All and Practice One; start and stop while contacts are active; switch directly to another plugin page; test three-, four-, and five-finger double taps | The virtual trackpad follows live contacts without exposing internal contact IDs, Practice One shows the full selected gesture name plus its production guide and current mapping, TipTap distinguishes a detected contact pattern from native-click-correlated recognition, no configured action executes, and testing stops automatically when the plugin page is no longer selected | Not run |
| Test Gestures devices | Use a built-in trackpad and Magic Trackpad together | Devices appear separately, the most recently active device is selected by default, explicit selection remains pinned, and contacts from different devices are never combined | Not run |
| Settings accessibility | VoiceOver; minimum window width; increased text size | Typing controls have meaningful names and values, recognized test gestures are announced, compact header controls remain usable, and the mapping editor scrolls without hiding its action footer | Not run |
| Sleep and wake | Sleep with the listener active, then wake | Recognition resumes once without a stale or duplicate listener | Not run |
| External device changes | Connect, disconnect, and reconnect a Magic Trackpad | Device discovery recovers; removed devices stop producing state; other devices continue working | Not run |
| Permission changes | Revoke and restore Accessibility and Input Monitoring | Listeners stop on revocation, guidance is clear, and recognition resumes only after permission is restored | Not run |

## Gesture sampling

On each available device, sample every initial gesture twice: once with a configured keyboard shortcut and once with the middle-click action:

- TipTap Left and Right with one fixed finger.
- TipTap Left, Middle, and Right with two fixed fingers.
- Three-, four-, and five-finger tap.
- Three-, four-, and five-finger double tap.
- Three-, four-, and five-finger long touch.
- Two- and three-finger physical click.

For physical clicks, keep the required fingers touching and press until the trackpad clicks. Test each with a keyboard shortcut, a MacTools action, and middle click, including one press held for more than five seconds before release. Expect one action and no native click-through or unmatched release; after release, the same contact episode must not also fire a tap or long touch. Confirm an unconfigured finger count and an external mouse click pass through unchanged. When two-finger click is configured, verify the UI warning makes clear that it replaces the matching macOS secondary click.

For each double tap, touch and fully release twice in quick succession; expect its configured action exactly once on the second release. Repeat in Test Gestures and confirm the first release reports the ordinary single tap while the second release reports only the double tap. A gap longer than about 320 ms, excessive movement, an overlong contact, or a finger rebound before full release must not recognize a double tap.

For every TipTap variant, keep the fixed fingers down and tap the additional finger five times; expect exactly five actions. Configure sibling regions together and alternate between them without lifting the fixed fingers. Holding the additional finger must not auto-repeat.

Repeat the TipTap sample with the pointer over a link, a button, and a text field. Each recognized gesture must execute its shortcut exactly once without clicking or focusing the item below the pointer. While the fixed fingers stay stable, separately fail one added-finger episode by making it too brief, too long, too far-moving, in the wrong region, and briefly adding another contact. After each failure, lift only added contacts and complete another valid TipTap; it must recognize once and the failed episode's native click must still reach the item. Moving or lifting a fixed finger must continue to require every contact to reset.

In Practice One, inspect every gesture family. TipTap guides must follow the initial fixed-finger anchors and distinguish fixed squares from the circular tapping finger. Tap guides must show the required finger count and production movement halos, double taps must show their second-tap interval, long touches must show hold progress, and physical clicks must show the required contact count and press cue. Repeat with Reduce Motion and Increase Contrast enabled, then with VoiceOver and keyboard-only controls; the textual next step and recognized result must remain available without relying on color or animation.

For every middle-click mapping—including all TipTap, multi-finger tap, and long-touch variants—confirm that one recognition produces exactly one middle click when only trackpad pointer services are present. Connect an external mouse or virtual HID pointer and repeat: native clicks must pass through unchanged, and the click-producing mapping must fail open without running. Disconnect the competing pointer and confirm recognition resumes without restarting MacTools.

With “Ignore Gestures While Typing” enabled, rest part of the palm on the built-in trackpad while continuously typing normal letters, holding a key, and using key repeat. No mapped gesture should fire and the typed characters must remain unchanged. Stop typing but keep the same trackpad contacts down past the configured delay; gestures must remain blocked. Lift every contact, then perform a deliberate TipTap and confirm it works. Repeat at 0.2, 0.4, and 1.0 seconds, and confirm modifier-only presses do not start the delay.

Also confirm that excessive movement, long taps, extra fingers, and ambiguous TipTap placement do not trigger an action, and that moving or lifting a fixed finger ends the repeated session until all contacts reset.

## Result record

| Date | Tester | Mac / trackpad | macOS | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| — | — | — | — | Not run | — |
