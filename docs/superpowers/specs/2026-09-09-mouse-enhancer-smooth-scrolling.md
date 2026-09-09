# Mouse Enhancer Smooth Scrolling Engine

Date: 2026-09-09

## Summary

Mouse Enhancer can already invert scroll direction (#400) and tune scroll step and speed (#406), but the wheel still moves content in discrete native jumps. This spec adds an opt-in smooth scrolling engine for mouse-classified scroll events: wheel ticks are intercepted, accumulated, and re-emitted as a continuous, interpolated pixel stream paced by the display refresh rate, modeled on Mos. Trackpad input is never re-emitted.

## Background

Issue [#400](https://github.com/ggbond268/MacTools/issues/400) asked for scroll feel tuning. PR [#406](https://github.com/ggbond268/MacTools/pull/406) added in-place step/gain adjustment, which fixes "too fast / too slow" but cannot fix jumpiness: a lifted 40 px step still lands as one discrete jump. The remaining feel gap versus Mos is the interpolation engine. Mos itself ties step and speed into its smoothing pipeline; without re-emission, amplified steps feel stepper, not smoother.

## Reference Research

[Mos](https://github.com/Caldis/Mos) (GPLv3, same license as MacTools) is the reference implementation. Its engine:

- Intercepts mouse wheel events in a CGEventTap and swallows them.
- Accumulates `step × speed` into a per-axis target buffer; same-direction ticks accumulate, an opposite tick resets the buffer.
- On a CVDisplayLink frame loop, emits `(target − current) × durationFraction` as `isContinuous` pixel deltas on a mutated clone of the original event.
- Posts with `CGEventPostToPid` to the event's original target process (Mos PR #523): avoids re-entry into the tap chain, keeps momentum from following the cursor, and avoids proxy crashes.
- Marks synthetic events via `eventSourceUserData` so its own tap ignores them.
- Guards stale frames with a generation counter and a 5 s TTL on the posting snapshot.
- Detects zombie CVDisplayLinks (5 s health check, >2 s silence → recreate, with cooldown) and self-corrects a link bound to a lower refresh-rate display (verify at 2/4/8 s, recreate when nominal < 70% of the max active display rate; issue #958).
- Sends a zero-delta terminal event to Chromium targets on stop so browser scroll does not stick.
- Bypasses smoothing for already-smoothed remote-control events and (pre-macOS 26) while Launchpad is active.

What we skip for MVP: per-application overrides, dash/toggle/block hotkeys, and trackpad phase simulation (`scrollPhase`/`momentumPhase` emulation). Phase simulation changes how browsers rubber-band and is the highest-risk compatibility surface; it can be a follow-up behind its own toggle.

## Product Model

New Mouse Enhancer settings (mouse section only; trackpads are natively smooth):

- **Smooth scrolling** toggle, default off. When on, mouse wheel scrolling animates instead of jumping.
- **Scroll duration** slider (fast–slow), controlling how long one tick's motion takes to finish. Reuses the existing step and gain values: each tick adds `step-adjusted, gain-applied` distance to the animation target.

Direction reversal and the remote-control bypass from #406 keep working: reversal is applied when the target is computed, and remote-smoothed events never enter the engine.

## Architecture

New `MouseScrollSmoother` inside the MouseEnhancer plugin, driven by the existing tap session:

1. **Capture** — the tap callback classifies the event as today. Mouse-classified discrete/phaseless wheel events with smoothing enabled are swallowed (return `nil`) after the session records a posting template: a copy of the event plus `eventTargetUnixProcessID`.
2. **Accumulate** — apply reverse/step/gain to the tick, then add to the per-axis buffer; direction reversal resets the opposite axis and restarts the animation. Trackpad-classified, remote-smoothed, and synthetic (self-posted) events pass through untouched.
3. **Emit** — a CVDisplayLink frame loop computes `lerp(current, buffer, durationFraction)` per axis, posts the frame delta as a continuous event on a `userInteractive` dispatch queue via `CGEventPostToPid`, and stops the link when the buffer drains (after the Chromium terminal event).
4. **Recover** — the session's existing wake/secure-input recovery tears the engine down with the taps; the buffer resets so wake never resumes a stale glide.

The accumulator, decay math, and buffer/reset semantics are pure value types, unit-testable without a display link. The display-link poster is a thin shell around them.

## Risks and Mitigations

- **Continuous-event compatibility** — some apps (games, CAD, remote clients) mishandle synthetic continuous events. The feature defaults off, applies only to mouse wheel events, and the remote-control bypass keeps remote sessions native. A per-app bypass list can follow if reports arrive.
- **Feedback loops** — self-posted events carry an `eventSourceUserData` marker and are ignored by the tap; posting goes directly to the target PID instead of the tap chain.
- **Stale frames after focus change** — generation counter + TTL drop frames queued for a previous target.
- **Zombie/mis-locked display links** — port Mos's health check and refresh-rate self-correction.
- **Latency perception** — the first frame emits immediately (`durationFraction` of the whole tick), so response stays instant while the tail glides.

## Testing

- Unit tests: accumulator semantics (same-direction accumulation, reversal reset, drain), decay math bounds, template generation/TTL, bypass conditions.
- Session tests: engine starts/stops with configuration changes, resets on wake recovery, survives config updates mid-glide.
- Manual matrix: Chrome/Safari/Firefox terminal behavior, Xcode, Figma, terminals, games, mixed-Hz multi-display, sleep/wake, mid-glide direction reversal, remote-control sessions.

## Rollout

Single plugin release fragment (`release: plugin`, `type: added`), README and plugin docs update. Off by default; no migration. Upstream issue filed for design feedback before the implementation PR.
