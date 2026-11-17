# Deskflow fork: make client scroll scale real on X11

**Date:** 2026-11-17
**Status:** Implemented, built on pp (`cmake --build build --target deskflow-core`), and verified live with counted XTest clicks. Final pp setting: `[client] yScrollScale=0.1`.
**Scope:** `src/lib/deskflow/ISecondaryComputer.h`, `src/lib/platform/XWindowsComputer.{h,cpp}`. Uncommitted local patch on top of `766e8c51b` (Mac) / the pp checkout.

---

## Problem

The documented client setting `yScrollScale` (clamp 0.1–10.0, read from
`[client]` in the client's `Deskflow.conf` at platform-computer construction)
was silently ineffective on X11 for ordinary wheel events:

```cpp
delta = applyScrollModifier(delta);   // 120-unit wire delta × scale
int32_t axisDelta = ...;
while (axisDelta > 0) {               // any nonzero remainder still clicks
  XTestFakeButtonEvent(...);          // once
  axisDelta -= s_scrollDelta;         // 120
}
```

A single-click wire delta (120 units) scaled by `0.5` became 60 and still
emitted exactly one XTest click — the same as scale `1.0`. Only multi-click
deltas (e.g. the 157-unit events this Mac server produce per line unit, from
`1 + com.apple.scrollwheel.scaling = 1.3125`) could shrink at all, and even
then never below one click per event. The user-visible complaint: scrolling on
pp felt unchanged after setting `0.5`.

## Change

`XWindowsComputer::fakeMouseWheel` now scales in **click units** and carries
the fractional remainder across events:

1. Convert the raw wire delta to clicks with ceiling division
   (`(abs + 119) / 120`), matching the historical per-event click count at
   scale 1.0.
2. Multiply the click count by `yScrollScale()` / `xScrollScale()` (new
   accessors on `ISecondaryComputer`; the settings members stay private).
3. Accumulate into `m_scrollRemainder{X,Y}`; emit only whole clicks
   (truncation toward zero); a **direction change discards** the remainder so
   opposite sub-clicks do not cancel.
4. `invertY/XScroll` still flips the final direction (as `applyScrollModifier`
   did); the generic helper is no longer used by this path so the scale is not
   quantized away.

Also added: `LOG_DEBUG("scroll scale: y=%.2f x=%.2f")` at construction and
`LOG_VERBOSE("wheel %s raw=%+d scale=%.2f -> %+d clicks (remainder=%.2f)")` per
event. `EiComputer` (Wayland/libei) is untouched — its smooth-scroll path
already accumulates fractional wheel clicks for exactly this reason; the X11
secondary path was the one missing it.

## Measured results (Mac server → pp client)

Synthetic Mac line-unit wheel events (one CG line = 157 wire units at this
server's `com.apple.scrollwheel.scaling = 0.3125`), clicks counted with
`xinput test-xi2 --root` on pp:

| pp `yScrollScale` | Wire units/event | Clicks/event (observed) |
| --- | --- | --- |
| 1.0 (patched) | 157 | 2 |
| 0.5 (patched) | 157 | 1 |
| 0.5 (patched) | 120¹ | 0.5 (one click every 2nd event) |
| 0.1 (patched) | 157 | 0.2 (one click every 5th event) |

¹ produced by temporarily setting the Mac's `com.apple.scrollwheel.scaling` to
`0` (restored afterwards).

Known limitation: the Mac trackpad emits a **high-rate stream** of small
line-delta events (each its own 157-unit message), so even `0.1` moves quickly
during momentum gestures — per-event scaling cannot beat the event rate. If a
lower floor is needed: reduce the `std::clamp(0.1, 10.0)` bound in
`ISecondaryComputer` (e.g. to `0.01`), or forward the CG pixel delta
(`kCGScrollWheelEventPointDeltaAxis1`) from `OSXComputer` instead of line
units so scroll distance follows the finger. Neither is done yet.

## Trials and errors

- Confirmed the setting ships in the binary with `strings -e l` before
  touching code: plain `strings` finds nothing because `QStringLiteral`
  stores UTF-16.
- First restart after editing the config connected fine and still showed no
  speed change — the misleading part. The DEBUG scale line (added by this
  patch) proves the value is read; only click counting at the X server proves
  it is *applied*.
- Truncation vs floor matters in two places: emit clicks with truncation
  toward zero (floor of a negative accumulator would fire a spurious opposite
  click, the same trap `EiComputer` documents), and keep the remainder in
  float, not int, between events.
- Client restarts raced the server's release of the client name
  (`server already has a connected client…`) — largely a red herring caused by
  the pp keyboard strip inheriting the old client socket (fixed separately in
  the workspace helpers on 2026-11-17); still, wait a few seconds between
  stopping and starting the pair.

## Rebuild / operate

```bash
# pp
cd ~/git4/deskflow && cmake --build build --target deskflow-core -j20
# then restart the client
ssh -tt -o ClearAllForwardings=yes pp2e 'bash -ic "start_deskflow"'

# tune (client-side only; requires restart to take effect)
# ~/.config/Deskflow/Deskflow.conf
# [client]
# yScrollScale=0.1

# observe
# - startup DEBUG line in ~/deskflow.log (set log/level=DEBUG)
# - per-event VERBOSE wheel lines (log/level=VERBOSE)
```

## References

- [Parent workspace session record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/17/2026-11-17-pp-scroll-scale-and-orphan-fd-fix.md)
- [Operating guide — client-return hotkeys (scroll section)](../../../../important/client-return-hotkeys.md)
- [Upstream config docs for yScrollScale](../../../../Configuration.md)
- Prior fork session: [2026-11-16 client-return hotkeys](../16/2026-11-16-client-return-hotkeys.md)
