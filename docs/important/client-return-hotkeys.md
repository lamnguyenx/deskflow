# Maintaining client-return hotkeys

**Status:** Local fork patch; built and verified against the Mac/pp pair.

This fork adds client-side `Super+Ctrl+1…4` hotkeys that ask the server to move
the active cursor back to the primary computer. It is intentionally separate
from the server-side `keystroke(...)` hotkeys.

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

## Build and trust

The patched app is installed separately:

```text
/Applications/Deskflow Dev.app
```

It is ad-hoc signed and must be granted:

- Accessibility for the app
- Accessibility for `Contents/MacOS/deskflow-core`
- Screen Recording for the app

The notarized `/Applications/Deskflow.app` (1.27.0) does **not** handle `CSWP`.
Do not use it with a client that sends `CSWP`.

Rebuilding the inner core changes its signature and can invalidate the
Accessibility grant. After a rebuild, re-add the core (or the dev app) in
System Settings → Privacy & Security → Accessibility.

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

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Grabs log as registered but nothing happens | Check the `m_isPrimary` guard around the root-window hotkey path. |
| Only some keys work | Another X11 client owns the combination (KDE Wacom `Map to screen 1/2` are common). Check `~/.config/kglobalshortcutsrc`. |
| Core exits at startup | Displays asleep, or Accessibility missing. Wake displays; grant Accessibility to the dev app and core. |
| Switch takes seconds | Compare clocks on both machines first; check the `CSWP` flush only if the message is genuinely delayed. |
| GUI/core version-mismatch warning | The patched core was placed in the 1.27.0 app. Run the matching `Deskflow Dev.app` build instead. |
| Keys act while on the Mac | The `m_active` guard is missing or `m_active` was not reset; check `Client::enter`/`leave`. |

## References

- [2026-11-16 module session record](../plans/2026/11/16/2026-11-16-client-return-hotkeys.md)
- [2026-11-17 scroll-scale session record](../plans/2026/11/17/2026-11-17-x11-fractional-scroll-scale.md)
- [Parent session record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/16/2026-11-16-deskflow-client-return-hotkeys.md)
- [Parent scroll-scale + outage record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/17/2026-11-17-pp-scroll-scale-and-orphan-fd-fix.md)
- [Parent runbook](file:///Users/lamnt45/git/hacker-workspace-automator/docs/important/deskflow-client-return-hotkeys.md)
- [Module README](../Readme.md)
