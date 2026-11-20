# Live cursor position on jump to a client

**Date:** 2026-11-20
**Status:** Implemented and built; live verification pending the Mac-side
relaunch (this session ran over a background launchd session without
WindowServer access, so the server core could not be started from it).

## Problem

With the Mac as server and pp (`VTCC-TULM7`) as the client, pp has its own
USB mouse. While pp was inactive, that mouse could move pp's real X cursor
anywhere. The next jump to pp — `Cmd+Ctrl+``` on the Mac or `Super+Ctrl+1…4`
back from pp — landed on the **saved** jump position (`BaseClientProxy::
m_x/m_y` recorded when pp was last left), not where pp's cursor actually was.

The user-visible report: "when I use the native real mouse of the pp and do
sth, when I Cmd+Ctrl+` again move mouse from mac to pp, it reused the old
saved position, but not the position of the native mouse".

## Root cause

`Server::jumpToComputer()` read the target's position from
`getJumpCursorPos()` — the position cached when that computer was last left.
For *this* Mac (primary), the cached position tracks reality because the
primary's mouse moves are all seen by the server. For a client, local input
is invisible to the server: `ClientProxy1_0::getCursorPos()` returns
`m_info.m_mx/m_my`, the cursor position from the last `kMsgDInfo` (sent at
connect or on shape change) — both stale while pp is inactive.

The protocol already had the right primitive: `kMsgQInfo` asks the client to
re-send `kMsgDInfo`, and the client's `queryInfo()` reads the cursor position
live (`XQueryPointer` on X11) before replying. The server simply never asked.

## Change

Server side only (`src/lib/server/`); pp's client binary needs no rebuild.

- `BaseClientProxy::queryInfo()` (new virtual, default no-op) — ask the
  computer to re-send its info. `ClientProxy1_4` and later inherit
  `ClientProxy1_0::queryInfo()`, which writes `kMsgQInfo`.
- `Server::jumpToComputer()`:
  - primary targets are unchanged and synchronous (`getJumpCursorPos`);
  - client targets go through `startPendingJump()`: send `kMsgQInfo`, wait
    for the reply.
- `Server::handleShapeChanged()` (the handler for the client's `kMsgDInfo`):
  when a pending jump waits on that client, jump to the **live** position
  just received (after it is validated/clamped by `recvInfo`). If the client
  became active some other way while waiting (user crossed the edge), drop
  the request instead of teleporting.
- `Server::handlePendingJumpTimeout()` (500 ms): fall back to the saved jump
  position, so a silent client can never block switching. Logged at WARN.
- Cancellation: `removeClient()` drops a pending jump to a disconnecting
  client (pointer safety); the destructor cleans the timer; a newer jump
  request replaces an older one (`startPendingJump` cancels first).

## Why query instead of push

The alternative — the client spontaneously sending `kMsgDInfo` on local
cursor motion while inactive — would spam the server, confuse the
shape-change semantics (the server treats `DINF` as a resolution event), and
needs rate limiting. `QINF`-on-demand reuses the existing info round-trip,
including the server's shape re-clamp + `CIAK` acknowledgment, and costs one
loopback (typically < 5 ms on this LAN) only when a jump is requested.

## Trials and errors

- The first full build (`cmake --build build-mac2 --target Deskflow
  deskflow-core`) failed at link with `error: unknown architecture` /
  `arm64e.x1-macos` in every framework `.tbd`. The `MacOSX.sdk` symlink was
  re-pointed to the new `MacOSX27.2.sdk` (Nov 18) whose stubs this clang's
  tapi cannot parse. Pinning `SDKROOT=/Library/Developer/CommandLineTools/
  SDKs/MacOSX26.5.sdk` builds cleanly. No source change involved.
- The rebuilt app + core were deployed to `/Applications/Deskflow Dev.app`
  and (necessarily) re-signed ad-hoc, which invalidates the TCC
  Accessibility grant tied to the old CDHash — the same rule the 2026-11-16
  record documents for core swaps. A re-grant for the app and the inner
  `deskflow-core` is expected on the next launch in the console session.
- Ad-hoc signing then caused macOS to re-prompt "Control this Mac and access
  data" on **every** launch even after re-adding the grant: the requirement
  is pinned to the cdhash, which changes each time. Fixed the same day by
  introducing the stable self-signed `Deskflow Local` identity
  (`tools/macos-dev-signing.sh`), so the requirement becomes
  `identifier … and certificate leaf = H"…"` and survives rebuilds. One
  final re-grant (after removing the stale ad-hoc entries) is required.
- This session's shell is in a **Background** launchd session
  (`launchctl managername` → `Background`): the core dies with `failed to
  initialize computer shape` even with all four displays awake
  (`system_profiler SPDisplaysDataType` lists them; the notarized stock core
  dies identically from this context), AppleEvents time out, and `open`
  launches the GUI only into the dead background context. Deskflow must be
  relaunched from the console session; it cannot be started from here.

## Verification plan (console session)

1. Relaunch `/Applications/Deskflow Dev.app` on the Mac. If the core exits
   with `assistive devices does not trust this process`, re-grant
   Accessibility for the app **and** `Contents/MacOS/deskflow-core`
   (remove + re-add if the toggle appears already on), then restart the app.
2. On pp: `start_deskflow` if the client has given up retrying; otherwise it
   reconnects on its own.
3. Mac → pp (`Cmd+Ctrl+```), move pp's USB mouse somewhere unmistakable,
   return with `Super+Ctrl+1`, jump again with `Cmd+Ctrl+``` — the cursor
   must land where the USB mouse left it, not at the previous exit point.
4. Server log at DEBUG shows the new lines:
   `waiting for live cursor position from "VTCC-TULM7" before jumping`, and
   the following `switch from ... at x,y` carries the live coordinates.
5. Regression guard: unplug nothing, just jump Mac → pp → Mac twice in a row
   without moving pp's mouse — behavior matches the old save/restore path
   after the (sub-perceptible) query round-trip; a paused/verbose client
   demonstrates the 500 ms fallback via
   `did not report its cursor position; using saved position`.

## Invariants

- Jumps initiated toward the **primary** stay synchronous — never delay the
  pp → Mac return on a network round-trip.
- The saved-position fallback must stay: a client that cannot answer
  `QINF` still gets a working switch.
- A pending jump must never fire into a disconnected client or teleport a
  user who crossed the screen edge manually during the wait.
- `queryInfo()` must keep the no-op default for primary proxies; only real
  network clients speak `QINF`.

## References

- [Operating guide update](../../important/client-return-hotkeys.md)
- Parent session record: `hacker-workspace-automator/docs/plans/2026/11/20/`
- [2026-11-16 client-return hotkeys](../16/2026-11-16-client-return-hotkeys.md) — the `CSWP` jump being fixed here
