# Apple Feedback 草稿 — macOS 27 beta (26A5353q) 第三方 NSStatusItem 事件投递缺陷

> 用 Feedback Assistant 提交,分类:macOS → AppKit。建议附 sysdiagnose + 下述最小复现。
> 另一个独立缺陷(log show predicate 被 --process 吞)见审计文档 standby 节,单独提。

## Title

Third-party NSStatusItem on macOS 27 beta 1: right-clicks never delivered (even menu-backed), forwarded actions are laggy/lossy with stripped modifiers

## Description (EN)

On macOS 27 beta 1 (26A5353q), with the menu bar rehosted into a single
window-server-owned window, third-party NSStatusItems exhibit the following
regressions (all reproduced on 26A5353q, Apple Silicon, external 5K main
display):

1. **Right-clicks are never delivered, on any channel — including
   first-party SwiftUI.** An action-based item
   (`button.sendAction(on: [.leftMouseUp, .rightMouseUp])`) never
   receives a `rightMouseUp` action. A menu-backed item
   (`NSStatusItem.menu != nil`) does not open its menu on physical
   right-click either — left-click opens it natively. An item with an
   `expandedInterfaceDelegate` (the new macOS 27 API) receives no
   `didBeginExpandedInterfaceSession` for a physical right-click — left
   clicks begin sessions normally. A SwiftUI `MenuBarExtra` with
   `.menuBarExtraStyle(.window)` does not present on physical
   right-click either (left-click presents normally). NSEvent global
   monitors in the owning app see no right-mouse events in the menu bar
   band at all. The right-click is swallowed by the menu bar host before
   any app-visible surface, AppKit or SwiftUI.

2. **Forwarded left-click actions arrive with modifiers stripped.** The
   `NSApp.currentEvent` seen in the action handler is a synthesized
   `leftMouseUp` whose `modifierFlags` is always 0, even when the user
   physically holds Option/Control. (Workaround: query the `NSEvent.modifierFlags`
   class property at action time.) Its `eventNumber` is also unrelated to
   the physical mouse-down's event number.

3. **Forwarded actions are slow and lossy.** Click-to-action latency is
   0.9–1.4s (measured against a CGEventTap-free global monitor timestamp).
   Intermittently the item enters a state where clicks stop being forwarded
   entirely (no action, no monitor delivery) until the app is relaunched;
   the first 1–2 clicks after item creation are also dropped.

These make pointer-based secondary interactions impossible for third-party
menu bar apps (no right-click, no documented alternative), and primary
clicks feel broken (latency + drops). We found no documented channel for a
secondary action: NSStatusItem/NSStatusBarButton docs and the 27.0 SDK
headers contain no mention of secondary/right-click for status items, and
the new `NSStatusItemExpandedInterfaceSession` API carries no event
information.

**Questions:** Are (1)–(3) beta-1 defects or intended behavior? If
intended, what is the supported channel for secondary actions on
third-party status items?

## Steps to Reproduce

1. Build a minimal app: one NSStatusItem with
   `button.sendAction(on: [.leftMouseUp, .rightMouseUp])` + target/action
   logging `NSApp.currentEvent.type/modifierFlags/eventNumber`; a second
   NSStatusItem with an attached `NSMenu` and a menu delegate logging
   `menuWillOpen`.
2. Physically right-click both items → no action fires; no menu opens.
3. Physically Option+left-click the action item → action fires with
   `modifierFlags == 0`.
4. Left-click the action item repeatedly (1s cadence) → observe 0.9–1.4s
   click-to-action latency and intermittent total drops.

## Expected

Right-clicks reach third-party status items (menu-backed items open their
menu; action items receive `rightMouseUp` per their sendAction mask);
forwarded events preserve modifier flags; click forwarding is prompt and
lossless.

## Actual

As described: right-click black hole, stripped modifiers, ~1s latency,
intermittent drops requiring app relaunch.

## 中文备注(给自己)

- 证据日志:/tmp/mactools-statusitem-diag.log(armed eventNumber=6845 ↔ action 不相关号、modifiers 恒 0)、/tmp/menuprobe.log(菜单型 item 左键 menuWillOpen、物理右键无回调)
- 探针:scripts/beta-probes/(每个新 seed 重跑)
- 已落地的 app 侧缓解:几何优先判定、防回弹抑制器(位置身份)、实时键盘修饰键、激活路径武装(commits ce4cab2/f007646/3f812d5/6040e51/8f4dad8)
