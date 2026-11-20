# Live cursor position on jump to a client

**Date:** 2026-11-20
**Status:** Implemented, built, deployed, and **verified live** on the
Mac/pp pair (user-confirmed after the console-session relaunch).
**Commits:** `60644ac25` (code), `6d28daeed` (docs), `7994f8efb` (signing
tool + runbook) on `master-lamnt45-02`.

## Problem

With the Mac as server and pp (`VTCC-TULM7`) as the client, pp has its own
USB mouse. While pp was inactive, that mouse could move pp's real X cursor
anywhere. The next jump to pp — `Cmd+Ctrl+``` on the Mac (or any
`switchToScreen`/`switchInDirection`/`toggleComputer` hotkey) — landed on the
**saved** jump position (`BaseClientProxy::m_x/m_y`, recorded when pp was
last left), not where pp's cursor actually was.

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

## Build, deploy, and signing

Build (the default SDK symlink now points at `MacOSX27.2.sdk`, whose stubs
this clang cannot link — see Trials):

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  cmake --build build-mac2 --target Deskflow deskflow-core -j4
```

Deploy (quit the app first):

```bash
install -m 755 build-mac2/bin/Deskflow.app/Contents/MacOS/Deskflow \
  "/Applications/Deskflow Dev.app/Contents/MacOS/Deskflow"
install -m 755 build-mac2/bin/Deskflow.app/Contents/MacOS/deskflow-core \
  "/Applications/Deskflow Dev.app/Contents/MacOS/deskflow-core"
tools/macos-dev-signing.sh sign     # stable identity: core first, then bundle
```

`tools/macos-dev-signing.sh` was added in this session (`setup|sign|status`).
It creates/imports the self-signed `Deskflow Local` identity
(`~/.config/deskflow/signing/`) and produces stable requirements:

```text
identifier "deskflow-core"         and certificate leaf = H"16c5…"   (core)
identifier "org.deskflow.deskflow" and certificate leaf = H"16c5…"   (app)
```

## Trials and errors

- **SDK link failure.** The first full build failed at link with
  `error: unknown architecture` / `arm64e.x1-macos` in every framework
  `.tbd`. The `MacOSX.sdk` symlink was re-pointed to the new
  `MacOSX27.2.sdk` (Nov 18) whose stubs this clang's tapi cannot parse.
  Pinning `SDKROOT=…/MacOSX26.5.sdk` builds cleanly. No source involvement.
- **Ad-hoc signing broke and then endlessly re-prompted TCC.** The rebuilt
  app + core were first re-signed ad-hoc. That pins the TCC requirement to
  the cdhash, which changes on every re-sign, so after re-adding the grant
  macOS kept prompting "Control this Mac and access data" on every launch.
  Fixed with the stable self-signed `Deskflow Local` identity above: remove
  the stale entries (`tccutil reset Accessibility org.deskflow.deskflow`,
  `tccutil reset Accessibility deskflow-core`,
  `tccutil reset ScreenCapture org.deskflow.deskflow`), then grant once.
  Signing order matters: **core before bundle**, because the app's resource
  seal covers the core's file.
- **The agent shell is a Background launchd session.** `launchctl managername`
  → `Background`: no WindowServer. Every `deskflow-core` started from there —
  including the stock notarized one — dies with `failed to initialize
  computer shape` even with all displays awake, AppleEvents time out, and
  `open` launches the GUI only into the dead context. Deskflow must be
  relaunched from the console session; `sudo launchctl asuser "$(id -u)" open
  "/Applications/Deskflow Dev.app"` can do that from a script.
- **An orphaned core crashed on the first switch.** Killing the GUI left its
  child `deskflow-core` running (reparented to launchd, still holding port
  24800). When a switch was attempted it died with `EXC_BREAKPOINT (SIGTRAP)`
  in `Server::onMouseMovePrimary → switchComputer → Computer::leave() →
  OSXKeyState::pollActiveGroup()` → TSM's `islGetInputSourceListWithAdditions`
  → `dispatch_assert_queue_fail` (macOS 27.2.1). That is the stock
  edge-crossing path, not the new jump code; the TSM API insists on the main
  queue and the server event loop is a QThread. It did not reproduce from the
  proper console-session launch and there are no prior Deskflow crash
  reports. Treat it as an upstream hazard to watch (if it ever reproduces in
  a normal launch, marshal `pollActiveGroup()`'s TIS/TSM call to the main
  thread). Kill the core too when killing the GUI, and keep the
  `kill -TERM <core>` step in the deploy.
- Manual-core probes with `--log-level`/`-f` failed: this build takes no such
  options; run it without flags and read stdout.

## Verification (live)

After relaunching the app with the stable signature and granting once:

- Mac → pp → move pp's USB mouse → `Super+Ctrl+1` → Mac → pp again: the
  cursor landed where pp's USB mouse left it (the reported defect is gone).
- The core stayed up; pp reconnected; `lsof -nP -iTCP:24800` is owned by
  `deskflow-core`.
- DEBUG log lines: `waiting for live cursor position from "VTCC-TULM7"
  before jumping`; the following `switch from ... at x,y` carries the live
  coordinates.

## Invariants

- Jumps initiated toward the **primary** stay synchronous — never delay the
  pp → Mac return on a network round-trip.
- The saved-position fallback must stay: a client that cannot answer
  `QINF` still gets a working switch.
- A pending jump must never fire into a disconnected client or teleport a
  user who crossed the screen edge manually during the wait.
- `queryInfo()` must keep the no-op default for primary proxies; only real
  network clients speak `QINF`.
- Never re-sign the dev app ad-hoc: it breaks the TCC grants on every
  rebuild and prompts endlessly. Use `tools/macos-dev-signing.sh sign`.

## Lessons learned

- Deskflow's jump-position cache is write-once-per-leave; any client with
  local input makes it stale by design. Anything that needs a *current*
  client position must ask (`QINF`) or observe (`DINF`) — never trust the
  jump cache.
- The v1.0 `QINF`/`DINF` round-trip is the cheapest way to do that: the
  server side alone changes, no protocol extension, and the client's reply
  is already shape-validated and acknowledged.
- TCC consent cannot be granted by sudo or `tccutil`; the best automation is
  `tccutil reset` for stale entries + `sudo launchctl asuser ... open` to
  launch into the console session, then one human Allow. A stable code
  signature turns "allow on every launch" into "allow once".
- A background launchd session is a diagnostic trap on macOS: display APIs,
  AppleEvents, `open`, and TSM all misbehave. Run `launchctl managername`
  before blaming the code or the hardware — this session initially looked
  exactly like the documented "displays asleep" precondition.
- Killing a GUI does not kill its spawned core; the orphan keeps the
  listening socket and runs in the dead context. Always check
  `pgrep -f deskflow` after quitting.

## References

- [Operating guide update](../../../../important/client-return-hotkeys.md)
- [Signing tool](../../../../tools/macos-dev-signing.sh)
- [2026-11-16 client-return hotkeys](../16/2026-11-16-client-return-hotkeys.md) — the `CSWP` jump being fixed here
- Parent session record:
  [2026-11-20 live cursor jump](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/20/2026-11-20-deskflow-live-cursor-jump.md)
