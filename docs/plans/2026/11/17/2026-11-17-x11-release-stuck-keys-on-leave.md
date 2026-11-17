# Deskflow fork: release keys the X client still holds on leave

**Date:** 2026-11-17
**Status:** Implemented, built on pp (`cmake --build build --target deskflow-core -j20`), restarted with `start_deskflow`, and verified live with a real Mac→pp→Mac round trip (`INFO: released 1 key(s) the X server still reported pressed`).
**Scope:** `src/lib/deskflow/IKeyState.h`, `PlatformComputer.{h,cpp}`, `Computer.cpp`, `src/lib/platform/XWindowsKeyState.{h,cpp}`. Uncommitted local patch on top of `c4eb0426f` (pp) / `94fb1422f` (Mac).

---

## Problem

An X11 client could keep a modifier down after the cursor left it:

1. Press `Ctrl` on the Mac while the cursor is on pp → pp receives the key-down.
2. Move back to the Mac and release `Ctrl` there → the key-up goes to the
   primary, not to pp.
3. `Computer::leaveSecondary()` calls `fakeAllKeysUp()`, but
   `KeyState::fakeAllKeysUp()` only walks `m_syntheticKeys` — keys the client
   still believes it pressed. Once pp's X server reports a key down, a later
   press of that key is skipped as "already down", so the key never becomes
   synthetic and is never released.

The client then kept `Ctrl`/`Super` down for pp's own shortcuts (clicks select,
`Super` opens the launcher) until a manual `xdotool keyup …`. `XWindowsKeyState`
had no `clearStaleModifiers()` override, and the libei one resets local XKB
bookkeeping rather than the X server's key state.

Live evidence on pp: keycode 206 (`NoSymbol Super_L NoSymbol Super_L`, in
`mod4`) was down with `mods=0x0000`. `xdotool keyup Super_L` resolves only
keycode 133, so the manual list could not clear it.

## Change

`IKeyState` gains an optional hook with a default no-op:

```cpp
virtual void releasePressedKeys() {}
```

- `PlatformComputer::releasePressedKeys()` forwards to the key state.
  `MSWindowsKeyState` and `EiKeyState` inherit the no-op; only X11 overrides it.
- `XWindowsKeyState::releasePressedKeys()` polls `XQueryKeymap`, sends
  `XTestFakeKeyEvent(..., False, ...)` for every pressed keycode, `XSync`s, then
  calls `updateKeyState()` to resync the shadowed state and logs
  `INFO: released %zu key(s) the X server still reported pressed` when the set
  was non-empty.
- `Computer::leaveSecondary()` calls it right after `fakeAllKeysUp()`.

Deliberate choices:

- **Not** implemented as `clearStaleModifiers()`: `KeyState::updateKeyState()`
  calls that on every keyboard-mapping change, where injecting releases would
  cancel keys the user is holding (and would release the very keys it just
  recorded as down).
- Only called on leave: the call injects input for keys this process never
  pressed, including keys the user may still be holding locally.
- Keycodes, not keysyms: pp's `mod4` maps `Super_L` to 133 **and** 206, and a
  keysym lookup resolves one. A stuck letter is released too.
- Locked modifiers are untouched: `XkbGetState` still reports Caps/Num/Scroll
  locks; only pressed keys are released, same policy as
  `EiKeyState::clearStaleModifiers()`.

## Build and install

```bash
# on pp (ethernet alias ppe)
cd ~/git4/deskflow
cmake --build build --target deskflow-core -j20
exit
ssh -tt -o ClearAllForwardings=yes ppe 'bash -ic "start_deskflow"'
```

The six changed files were copied from the Mac checkout; none of them carried
local pp changes (`git diff --name-only HEAD -- <files>` was empty), and the
files are identical between pp's `c4eb0426f` and the Mac's `94fb1422f`.

## Verification (live switch)

Triggered a real round trip: a synthetic cursor move walked the Mac's virtual
cursor past the leftmost display edge (`x=-1156`, beyond the `-1080` boundary),
pp became active, then:

```bash
# pp, while active
xdotool keydown Scroll_Lock                     # simulate a key the core never tracked
deskflow-release-keys -n                        # pressed=1, only Scroll_Lock
xdotool key Super_L+Control_L+1                 # native CSWP return hotkey
```

Client log on leave:

```text
INFO: client hotkey requested switch to primary computer
INFO: leaving computer
INFO: released 1 key(s) the X server still reported pressed
```

The key was cleared by the core (`leaveSecondary()` runs before the exit
command), and the workspace hook's release that follows found a clean server:

```text
clean: no keys down (locked=0x0000)
```

The workspace `deskflow-switch` hook stays installed as the safety net for a
core that is already out of sync (older binary, crash mid-press); it does no
work once this patch has run.

## References

- [Client-return hotkey operating guide](../../important/client-return-hotkeys.md#stuck-key-release-on-leave-x11-2026-11-17)
- [Parent workspace session record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/17/2026-11-17-pp-stuck-modifier-release.md)
- [Parent tools record](file:///Users/lamnt45/git/hacker-workspace-automator/tools/docs/plans/2026/11/17/2026-11-17-release-keys-helper.md)
- [Scroll-scale session record](2026-11-17-x11-fractional-scroll-scale.md)
