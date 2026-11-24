# Maintaining client-return hotkeys

**Status:** Local fork patch; built and verified against the Mac/pp pair. The
hotkeys are X11-only; jackal (Wayfire) uses the wlroots backend and does not
register them (see [jackal-wayfire-client.md](jackal-wayfire-client.md)).

This fork adds client-side `Super+Ctrl+1…4` hotkeys that ask the server to move
the active cursor back to the primary computer. It is intentionally separate
from the server-side `keystroke(...)` hotkeys.

## Jump target: live cursor position (2026-11-20)

A jump to a client used the position cached when that client was last left.
A client with its own mouse (pp's USB mouse) moves its real cursor while
inactive, so the jump landed on a stale position. `jumpToComputer()` now asks
the client for a live position before jumping:

- the server sends the existing `kMsgQInfo`; the client's reply `kMsgDInfo`
  carries its current pointer position (read live, e.g. `XQueryPointer`);
- the pending jump waits up to **500 ms** (`m_pendingJumpTimeout`); on
  timeout it falls back to the saved jump position (WARN log);
- the reply handler only switches if the client is still inactive — if the
  user crossed the screen edge during the wait, the request is dropped
  rather than teleporting;
- jumps toward the primary remain synchronous (no round-trip on the
  `Super+Ctrl+1…4` return path);
- a pending jump is cancelled when its client disconnects or a newer jump
  replaces it.

Invariants:

- Keep the fallback: a client that cannot answer `QINF` must still get a
  working (saved-position) switch.
- `BaseClientProxy::queryInfo()` stays a no-op default for primary proxies.
- The shape-change clamp in `ClientProxy1_0::recvInfo()` still validates the
  position before the jump uses it.

Diagnostics: `waiting for live cursor position from "..." before jumping`
(DEBUG) and `did not report its cursor position; using saved position`
(WARN) in the server log.

## Message and flow

```text
Linux client (pp)
  Super+Ctrl+1..4
    -> Client::handleClientHotkey()
    -> ServerProxy::switchToPrimary()
    -> CSWP + flush
Mac server
  ClientProxy1_4::parseMessage()
    -> Server::switchToPrimary()
    -> jumpToComputer(m_primaryClient)
```

The message is:

```cpp
const char *const kMsgCSwitchToPrimary = "CSWP";
```

No parameters. No-op when the primary is already active.

## Client invariants

- Register the four grabs after `handshakeComplete()`, when the client is
  connected and the X display is ready.
- Unregister in `cleanupComputer()`; remove the
  `PrimaryComputerHotkeyDown` handler in the `Client` destructor.
- Keep the `m_active` guard. The keys are a return action, not a general
  remote-control channel.
- Keep `registerClientHotkeys()` behind `#if WINAPI_XWINDOWS` until Wayland
  global-hotkey behavior is designed and tested.
- Use keys `0x31…0x34` with `KeyModifierSuper | KeyModifierControl`.
- Flush the stream after writing `CSWP` so delivery does not depend on the next
  unrelated stream event. The seven-second log gap was clock skew, not proof of
  a missing flush; keep the flush as a defensive rule.

## X11 platform invariant

`XWindowsComputer::handleSystemEvent()` must process root-window hotkeys for
both primary and secondary computers. The current shape is:
```cpp
if (xevent->type == KeyPress || xevent->type == KeyRelease) {
  if (xevent->xkey.window == m_root) {
    onHotKey(xevent->xkey, isRepeat);
    return;
  }

  if (m_isPrimary) {
    ... normal key forwarding ...
  }
}
```

Do not move normal key forwarding outside `m_isPrimary`; that would make a
secondary client send its local keyboard to the server. Only the hotkey path is
shared. Repeat detection remains primary-only.

## Client scroll scale (X11, 2026-11-17)

The client setting `yScrollScale` / `xScrollScale` (`[client]` in the client's
`Deskflow.conf`, clamp 0.1–10.0) is applied in `XWindowsComputer::
fakeMouseWheel`, **in click units, not wire units**: convert the 120-unit wire
delta to whole clicks first (ceiling division — matches the historical click
count at scale 1.0), multiply the click count by the scale, and carry the
fractional remainder in `m_scrollRemainderX/Y` to the next event. A direction
change discards the remainder. Upstream scaled the wire delta and then looped
`while (axisDelta > 0)`, which quantized any sub-1.0 scale back up to one click
per event.

Invariants:

- Keep the remainder in floating point between events; truncate toward zero
  when emitting (floor of a negative accumulator fires a spurious opposite
  click — same trap the EiComputer smooth-scroll code documents).
- Keep `invertY/XScroll` flipping the final direction.
- Accessors on `ISecondaryComputer` (`yScrollScale()` etc.) keep the settings
  members private; do not duplicate reads.
- `LOG_DEBUG("scroll scale: …")` at construction and `LOG_VERBOSE("wheel …")`
  per event are the diagnostics; counting clicks with `xinput test-xi2 --root`
  on the client is the only real proof the scale is applied.
- If a floor below 0.1 is ever needed, lower the clamp in `ISecondaryComputer`
  (e.g. 0.01) or forward the CG pixel delta from the macOS server instead of
  line units; the trackpad's high event rate defeats per-event scaling
  otherwise.

## Stuck key release on leave (X11, 2026-11-17)

A modifier can stay down on the X11 client after a switch: press `Ctrl` on the
server, move back and release it there, and the release never reaches the
client. `Computer::leaveSecondary()` already calls `fakeAllKeysUp()`, but
`KeyState::fakeAllKeysUp()` only walks `m_syntheticKeys`; once the X server
reports a key down, a later press is skipped as "already down", so the key
never becomes synthetic and is never released. `XWindowsKeyState` has no
`clearStaleModifiers()` override, and the libei one only resets local XKB
bookkeeping, not the server's key state.

`Computer::leaveSecondary()` now calls the new
`m_computer->releasePressedKeys()` right after `fakeAllKeysUp()`:

```cpp
void XWindowsKeyState::releasePressedKeys()
{
  KeyButtonSet pressedKeys;
  pollPressedKeys(pressedKeys);          // XQueryKeymap
  if (pressedKeys.empty()) return;
  for (const auto &key : pressedKeys)
    XTestFakeKeyEvent(m_display, key, False, CurrentTime);
  XSync(m_display, False);
  updateKeyState();                     // resync shadowed state
  LOG_INFO("released %zu key(s) the X server still reported pressed", pressedKeys.size());
}
```

Invariants:

- `releasePressedKeys()` is a default no-op on `IKeyState` and forwarded by
  `PlatformComputer`; only the X11 key state overrides it. Do not override
  `clearStaleModifiers()` instead — `KeyState::updateKeyState()` calls that on
  every keyboard-mapping change, where injecting releases would cancel keys the
  user is holding.
- Call it only from `leaveSecondary()`: it injects input for keys this process
  never pressed, including keys the user is holding locally.
- Unmapped keycodes are fine: releases are keyed by `XQueryKeymap` keycode, not
  keysym. The X11 `mod4` map on this host carries `Super_L` at two keycodes
  (133 and 206), which is why a `keyup Super_L` reset misses one.
- Locked modifiers (Caps/Num/Scroll) are not touched — they are real keyboard
  state, not switch debris.
- The workspace `deskflow-switch` hook still runs `deskflow-release-keys` on
  both boundaries. It is the safety net for a core that is already out of sync
  (before this patch, or after a crash mid-press), not the primary fix.

## Server invariant

Handle the message in a proxy class that has a `Server*` (`ClientProxy1_4` or
later). `ClientProxy1_0` does not have one. Keep the parser override delegating
to the previous version for all other messages:

```cpp
bool ClientProxy1_4::parseMessage(const uint8_t *code)
{
  if (memcmp(code, kMsgCSwitchToPrimary, 4) == 0) {
    getServer()->switchToPrimary();
    return true;
  }
  return ClientProxy1_3::parseMessage(code);
}
```

`Server::switchToPrimary()` must check `m_active != m_primaryClient` before
calling `jumpToComputer()`.

## Wayfire/Wayland client (jackal, 2026-11-24)

jackal (`jk`) runs Wayfire and connects through the wlroots backend
(`master-lamnt45-02-wlroots`). The `Super+Ctrl+1…4` grabs live behind
`#if WINAPI_XWINDOWS` in `Client::registerClientHotkeys()` and are therefore
**not registered** by the wlroots client. The X11 fallback
(`~/bin/deskflow-start-x11`) still has them, but it cannot move the real
Wayfire cursor.

Practical consequence: to leave jackal, move the cursor off its left edge
(the server grid is `VTCC-TULM7 | Mac | jackal`). Do not assume `CSWP` will
arrive from jackal. The server-side `switchToScreen()` hotkeys still work
while the Mac is active.

The wlroots backend also disables clipboard sharing because Wayfire has no
`ext-data-control`. Neither limitation is a regression in the X11 path: pp
keeps the hotkeys, scroll scale, stuck-key release and clipboard behavior
described above.

## Build and trust

The patched app is installed separately:

```text
/Applications/Deskflow Dev.app
```

It is signed with the stable local `Deskflow Local` identity (2026-11-20),
not ad-hoc. Ad-hoc signatures pin the cdhash, so every rebuild invalidated the
TCC grants and macOS kept re-prompting (“Control this Mac and access data”)
no matter how often the entry was re-added. The identity’s certificate makes
each requirement stable:

```text
identifier "org.deskflow.deskflow" and certificate leaf = H"16c5…"   (app)
identifier "deskflow-core"         and certificate leaf = H"16c5…"   (core)
```

Set up once, then re-sign after every rebuild (quit the app first):

```bash
tools/macos-dev-signing.sh setup     # create + import the identity (idempotent)
tools/macos-dev-signing.sh sign      # signs core then app; verifies the seal
tools/macos-dev-signing.sh status    # show identity + designated requirements
```

Grant once after the identity is in place (remove stale ad-hoc entries first):

- Accessibility / “Control this Mac and access data” for the app
- Accessibility for `Contents/MacOS/deskflow-core` (own TCC subject)
- Screen Recording for the app

With the stable requirements these survive rebuilds; only a changed
*identifier* or a new certificate forces a re-grant. The private key lives in
`~/.config/deskflow/signing/` (never commit it).

The notarized `/Applications/Deskflow.app` (1.27.0) does **not** handle `CSWP`.
Do not use it with a client that sends `CSWP`.

Rebuilding with the `Deskflow Local` identity keeps the TCC grants. Only a
signature made with a different certificate (or a changed identifier) forces
a re-grant; re-running `tools/macos-dev-signing.sh sign` after
`cmake --build` does not.

## Runtime preconditions

- The Mac session must be **unlocked** for Carbon hotkeys to fire.
- The displays must be **awake** before starting the core. If
  `CGGetActiveDisplayList()` returns zero, the core throws
  `failed to initialize computer shape`. Wake with `caffeinate -u -t 5`.
- The Linux clock may be behind the Mac; check `date` on both sides before
  interpreting a switch as slow.

## Verification

Build:

```bash
# Mac
cmake --build build-mac2 --target Deskflow deskflow-core -j4

# Linux client
cd /home/lamnt45/git4/deskflow
cmake --build build --target deskflow-core -j4
```

On pp, use the canonical start command:

```bash
start_deskflow
```

Switch the Mac to pp with `Cmd+Ctrl+``, then press `Super+Ctrl+1` on pp. The
server log should show:

```text
INFO: switching to primary computer on client request
INFO: switch from "VTCC-TULM7" to "lamnt45s-MacBook-Pro.local"
INFO: entering computer
```

The client should stay connected. Repeat for keys 2–4.

Stuck-key release: leave a modifier pressed on pp, return with `Super+Ctrl+1`,
and the client log must show the release (the key is cleared by the core, before
the exit hook runs):

```text
INFO: leaving computer
INFO: released 1 key(s) the X server still reported pressed
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Grabs log as registered but nothing happens | Check the `m_isPrimary` guard around the root-window hotkey path. |
| Only some keys work | Another X11 client owns the combination (KDE Wacom `Map to screen 1/2` are common). Check `~/.config/kglobalshortcutsrc`. |
| Core exits at startup | Displays asleep, or Accessibility missing. Wake displays; grant Accessibility to the dev app and core. |
| Switch takes seconds | Compare clocks on both machines first; check the `CSWP` flush only if the message is genuinely delayed. |
| GUI/core version-mismatch warning | The patched core was placed in the 1.27.0 app. Run the matching `Deskflow Dev.app` build instead. |
| Keys act while on the Mac | The `m_active` guard is missing or `m_active` was not reset; check `Client::enter`/`leave`. |
| `Ctrl`/`Super` stuck on the client after a switch | The client core must include the `releasePressedKeys()` patch (`INFO: released N key(s)…` at leave). Older cores only release synthetic keys; the workspace `deskflow-switch` hook clears the rest. |

## References

- [2026-11-16 module session record](../plans/2026/11/16/2026-11-16-client-return-hotkeys.md)
- [2026-11-20 live-cursor-position session record](../plans/2026/11/20/2026-11-20-live-cursor-position-on-jump.md)
- [2026-11-17 scroll-scale session record](../plans/2026/11/17/2026-11-17-x11-fractional-scroll-scale.md)
- [2026-11-17 stuck-key release session record](../plans/2026/11/17/2026-11-17-x11-release-stuck-keys-on-leave.md)
- [2026-11-24 jackal/Wayfire session record](../plans/2026/11/24/2026-11-24-jackal-wayfire-client.md)
- [Jackal Wayfire client guide](jackal-wayfire-client.md)
- [Parent session record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/16/2026-11-16-deskflow-client-return-hotkeys.md)
- [Parent scroll-scale + outage record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/17/2026-11-17-pp-scroll-scale-and-orphan-fd-fix.md)
- [Parent runbook](file:///Users/lamnt45/git/hacker-workspace-automator/docs/important/deskflow-client-return-hotkeys.md)
- [Module README](../Readme.md)
