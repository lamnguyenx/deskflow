# Client-side return hotkeys in Deskflow

**Date:** 2026-11-16
**Status:** Implemented in the local fork, built, and verified against the live Mac/pp pair.
**Module:** Deskflow source — Mac checkout `/Users/lamnt45/git4/deskflow` and Linux client checkout `/home/lamnt45/git4/deskflow`.

## Component changes

| Component | Final change |
| --- | --- |
| `src/lib/deskflow/ProtocolTypes.h` / `.cpp` | New `kMsgCSwitchToPrimary` message code `"CSWP"`; direction is client → server, no parameters |
| `src/lib/client/ServerProxy.h` / `.cpp` | `switchToPrimary()` writes `CSWP` and calls `m_stream->flush()` |
| `src/lib/client/Client.h` / `.cpp` | Registers `Super+Ctrl+1…4` on connect, unregisters on cleanup, handles `PrimaryComputerHotkeyDown`, sends `CSWP` only while `m_active` |
| `src/lib/platform/XWindowsComputer.cpp` | Root-window hotkey handling moved outside the `m_isPrimary` guard so secondary clients see their own grabs |
| `src/lib/server/ClientProxy1_4.h` / `.cpp` | `parseMessage()` override; handles `CSWP` and calls `Server::switchToPrimary()` |
| `src/lib/server/Server.h` / `.cpp` | `switchToPrimary()` jumps to the primary computer when another client is active |

No wire-format change was made to existing messages. The new code is only sent
by patched clients and only understood by patched servers.

## Protocol message

```cpp
const char *const kMsgCSwitchToPrimary = "CSWP";
```

- Direction: secondary → primary.
- Parameters: none.
- Meaning: move the active cursor to the primary computer.
- No-op when the primary is already active.

`ServerProxy::switchToPrimary()` must flush after writing:

```cpp
void ServerProxy::switchToPrimary()
{
  ProtocolUtil::writef(m_stream, kMsgCSwitchToPrimary);
  m_stream->flush();
}
```

The flush is a defensive rule so delivery does not depend on the next stream
event. The seven-second gap in the first test was later found to be clock skew,
not buffering; keep the flush anyway.

## Client hotkeys

Registration happens after the handshake, when the client is enabled:

```cpp
void Client::handshakeComplete()
{
  m_ready = true;
  m_computer->enable();
  ...
  registerClientHotkeys();
  sendEvent(EventTypes::ClientConnected);
}
```

`registerClientHotkeys()` is X11-only (`#if WINAPI_XWINDOWS`), and registers
`'1'…'4'` with `KeyModifierSuper | KeyModifierControl`:

```cpp
static const KeyID keys[kClientHotkeyCount] = {0x31, 0x32, 0x33, 0x34};
const auto id = m_computer->registerHotKey(keys[i], KeyModifierSuper | KeyModifierControl);
```

The IDs are stored in `m_clientHotkeyIDs`; `cleanupComputer()` calls
`unregisterClientHotkeys()` before deleting the server proxy, and the
constructor/destructor install/remove the `PrimaryComputerHotkeyDown` handler.
The handler only acts while the client is active:

```cpp
if (!m_active) {
  return;
}
LOG_INFO("client hotkey requested switch to primary computer");
m_server->switchToPrimary();
```

The `m_active` guard makes the keys a no-op when the Mac already has the
cursor. It also avoids sending a switch request from a background client.

## X11 secondary hotkey fix

Before, `XWindowsComputer::handleSystemEvent()` processed all key events inside
`if (m_isPrimary)`. A secondary client registered the grabs but never saw the
events. The hotkey check is now outside the primary block:

```cpp
if (xevent->type == KeyPress || xevent->type == KeyRelease) {
  if (xevent->xkey.window == m_root) {
    // this is a hot key, on either a primary or secondary computer
    onHotKey(xevent->xkey, isRepeat);
    return;
  }

  if (m_isPrimary) {
    if (!m_isOnComputer && onHotKey(xevent->xkey, isRepeat)) {
      return;
    }

    bool down = (isRepeat || xevent->type == KeyPress);
    KeyModifierMask state = m_keyState->mapModifiersFromX(xevent->xkey.state);
    m_keyState->onKey(xevent->xkey.keycode, down, state);
  }
}
```

Repeat detection remains primary-only. Normal key forwarding remains
primary-only; only the root-window hotkey path is shared.

## Server handling

`ClientProxy1_4` has the `Server*` pointer, so it owns the new parser override:

```cpp
bool ClientProxy1_4::parseMessage(const uint8_t *code)
{
  if (memcmp(code, kMsgCSwitchToPrimary, 4) == 0) {
    LOG_DEBUG("client \"%s\" requested switch to primary", getName().c_str());
    getServer()->switchToPrimary();
    return true;
  }

  return ClientProxy1_3::parseMessage(code);
}
```

The server method is deliberately small:

```cpp
void Server::switchToPrimary()
{
  if (m_active != m_primaryClient) {
    LOG_INFO("switching to primary computer on client request");
    jumpToComputer(m_primaryClient);
  }
}
```

`jumpToComputer()` records the outgoing client's cursor position, restores the
primary's saved position, and calls the existing `switchComputer()` path.

## Build and deployment

### Mac server

```bash
cd /Users/lamnt45/git4/deskflow
cmake -S . -B build-mac2 \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/qt;/opt/homebrew/opt/openssl@3" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3
cmake --build build-mac2 --target Deskflow deskflow-core -j4
```

The installed notarized app is `/Applications/Deskflow.app` (1.27.0); it was
left untouched. The patched build is installed as
`/Applications/Deskflow Dev.app` (GUI and core, ad-hoc signed), because TCC
grants are tied to the signed binary. The original installed core backup is
`~/Library/Deskflow/deskflow-core.orig.1.27.0`.

### Linux client

```bash
cd /home/lamnt45/git4/deskflow
cmake --build build --target deskflow-core -j4
```

The user's `start_deskflow` function starts
`/home/lamnt45/git4/deskflow/build/bin/deskflow-core client` with `DISPLAY=:0`
and `XAUTHORITY=/run/user/1001/gdm/Xauthority`, logging to `~/deskflow.log`.

## Trials and errors

### Hotkeys registered but no events on the client

The client logged four successful X11 grabs but pressing the keys did nothing.
The root-window hotkey check was inside the `m_isPrimary` block in
`XWindowsComputer::handleSystemEvent()`. Moving it outside fixed the client
while preserving primary key forwarding. This is the most important code
lesson of the session.

### The first design placed the handler in the wrong class

The initial idea was to add the `CSWP` case to `ClientProxy1_0`, but that class
has no `Server*`. `ClientProxy1_4` is the first proxy with `getServer()`, and
the parser chain calls it. The override was added there and delegates to
`ClientProxy1_3` for everything else.

### `m_active` guard

Without the guard, the hotkey disconnected the client even when the Mac was
already active. The guard makes the four keys a no-op outside the client's
active period and avoids needless switch requests.

### Flush after `CSWP`

The first native-message test appeared to take seven seconds. We added
`m_stream->flush()` so delivery does not depend on the next stream event. The
gap was later explained by clock skew, not by a missing flush; the flush remains
a defensive rule, and the two machines' clocks should be compared before
blaming the code.

### TCC blocks a rebuilt core

Swapping the patched core into the notarized `/Applications/Deskflow.app`
produced:

```text
FATAL: a runtime error occurred: assistive devices does not trust this process,
allow it in system settings.
```

The patched binary has a different code signature, so the existing
Accessibility grant does not cover it. The working deployment uses the separate
ad-hoc-signed `/Applications/Deskflow Dev.app`, with Accessibility granted for
the app and `Contents/MacOS/deskflow-core`, plus Screen Recording for the app.
The notarized app remains installed as a server fallback but does not understand
`CSWP`; the current client sends it, so reverting to the notarized app also
requires rebuilding the client with the earlier disconnect fallback.

### Display sleep and the standalone core

Launching either core directly while the displays were asleep produced:

```text
FATAL: a display invalid exception error occurred: failed to initialize computer shape
```

`CGGetActiveDisplayList()` returned zero. `caffeinate -u -t 5` woke the displays
and the same binary started. This is an environment precondition, not a build
failure. The GUI-launched core inherits the same requirement.

### Version alignment

The installed app is 1.27.0; the patched source is HEAD and reports
`1.26.0.541 (c4eb0426)`. Swapping a HEAD core into the 1.27.0 GUI triggers the
GUI/core IPC version-mismatch warning. The dev app ships its matching HEAD GUI
and core, so the running pair has no mismatch.

### macOS GUI hotkey labels are swapped

For the Mac → pp hotkey the generated line is
`keystroke(Control+Alt+`)`, which the GUI displays as if it were Ctrl+Option.
On macOS, Deskflow's hotkey registration maps internal `Alt` to Carbon Command
and internal `Control` to Carbon Control. The physical shortcut is
`Cmd+Ctrl+``. The same modifier mapping is documented in the earlier cursor
hotkey record.

### Clock skew masqueraded as latency

The Linux client was 7.43 seconds behind the Mac (`timedatectl` reported no
synchronization). Client and server logs therefore appeared seven seconds apart
even after the flush was added. Check `date` on both sides before changing
timing code; enable NTP on pp for readable logs.

## Invariants for future changes

1. Keep `CSWP` no-argument and no-op when the primary is already active.
2. Flush the stream immediately after writing `CSWP`.
3. Register client hotkeys after the handshake, unregister in
   `cleanupComputer()`, and remove the event handler in the destructor.
4. Keep the `m_active` guard; the keys are a return-to-primary action, not a
   general remote-control channel.
5. Keep normal key forwarding primary-only. Only the root-window hotkey path
   belongs outside `m_isPrimary`.
6. Keep the client hotkey registration X11-only until Wayland hotkey semantics
   are explicitly designed and tested.
7. Keep the server handler in `ClientProxy1_4` (or later) where `getServer()` is
   available; do not duplicate state in the proxy.
8. Do not ship a rebuilt core inside the notarized app without re-granting
   Accessibility. Prefer a separate ad-hoc-signed dev app for local builds.
9. Wake displays before starting the macOS server; display sleep is a hard
   precondition for the shape query.
10. Check desktop shortcut ownership before assuming an `XGrabKey` failure is a
    Deskflow bug.

## Verification

- Both checkouts build with the patch.
- The dev app's GUI and core are running with matching versions.
- The client registers all four hotkeys and connects to the Mac server.
- `Super+Ctrl+1`, `2`, `3`, and `4` each produced the server log:

```text
INFO: switching to primary computer on client request
INFO: switch from "VTCC-TULM7" to "lamnt45s-MacBook-Pro.local"
INFO: entering computer
```

- The client did not disconnect or reconnect after any of the four switches.
- The Mac → pp direction still works with `Cmd+Ctrl+``.

## References

- [Parent session record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/16/2026-11-16-deskflow-client-return-hotkeys.md)
- [Deskflow operating guide](../../../../important/client-return-hotkeys.md)
- [Parent runbook](file:///Users/lamnt45/git/hacker-workspace-automator/docs/important/deskflow-client-return-hotkeys.md)
- [Module README](../../../../Readme.md)
