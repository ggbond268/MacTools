# Suite Enhancements Design (Battery / Menu Bar / System Status)

Date: 2026-08-10  
Status: approved (user OK)  
Branch context: continue on `feat/window-layout` or follow-on commits to same fork

## Goal

Complete the remaining Better365-like suite work locally without Mac verification: enhance existing plugins rather than new apps. Mobile companion remains deferred.

## Scope

### BatteryChargeLimit
- Low-battery floor reminder (notify when below threshold while unplugged; no auto resume charge)
- Display cycle count + health / max capacity when readable
- Thermal protection: stop charging above temperature threshold; optional “don’t remind today”
- Sleep charging policy preference: continue vs inhibit while asleep (best-effort via existing SMC helper paths)
- Out of scope: dedicated system menu-bar battery icon replacing macOS battery item

### MenuBarHidden
- Improve aggregate / reveal popup UX for hidden icons (closer to iBar)
- Clearer settings copy for visible / hidden / always-hidden sections
- Out of scope: rewriting the drag/layout engine

### SystemStatus
- Make menu-bar metrics more useful by default (configurable set; sensible defaults)
- Surface uptime (and related already-sampled fields) more clearly in panel/settings
- Align fan/temperature presentation where data already exists
- Out of scope: phone companion apps

## Approach

Extend existing plugins in place; prefer store + settings form + panel subtitle/detail; add adjacent XCTest; update README + `changes/unreleased` fragments.

## Success (local)

Code + tests + docs land on the branch. Compile/AX verification deferred until Mac is available.
