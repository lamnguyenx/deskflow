# Jackal (Wayfire) as a second Deskflow client

**Date:** 2026-11-24
**Status:** Implemented, built, deployed and connected. Native wlroots input is
in use; the cursor is visible after fixing the output layout. Clipboard
sharing and the `Super+Ctrl` client hotkeys are **not** available on this
backend (both are X11-only).
**Commits:** `172c1ac8e` (wlroots backend cherry-picked onto
`master-lamnt45-02`; branch `master-lamnt45-02-wlroots`) plus this docs
record. The Mac server build remains `master-lamnt45-02` @ `e3dce8899`; the
wlroots code is Linux-only (`UNIX AND NOT APPLE`), so macOS is unaffected.

## Problem

The Mac was already the server for pp (`VTCC-TULM7`, X11). The second client,
jackal (`jk`, Ubuntu 26.04 on Wayfire), needed to connect to the same Mac and
be usable with the Mac's keyboard and mouse.

The first install used the X11 backend on Xwayland. The client connected and
completed the handshake, but the cursor never appeared on jackal and could not
be moved. Xwayland's `XTestFakeMotionEvent` only moves the Xwayland pointer; it
cannot move Wayfire's real Wayland cursor. A second, independent problem was
the output layout: the main display's logical origin was far enough below the
top that Deskflow's entry point (`x=0`) landed in a dead gap between outputs.

## Environment

| Host | Role | Details |
| --- | --- | --- |
| Mac (`lamnt45s-MacBook-Pro.local`) | server | `/Applications/Deskflow Dev.app` 1.26.0.541 custom (`CSWP`); core listens on `*:24800` |
| pp (`VTCC-TULM7`) | client, X11 | `~/git4/deskflow`, branch `master-lamnt45` @ `53dbfcfb` |
| jackal (`jk`) | client, Wayfire | Ubuntu 26.04, Wayfire 0.10.0 / wlroots 0.19.1, Xwayland `:0` |

jackal output layout (before the fix):

```text
HDMI-A-1  2560x1600  normal  scale 1.300781  position 0,720
DVI-I-1   1920x1080  270     scale 1.300781  position 1968,0   (EINK)
```

The logical HDMI rectangle was `0,720 .. 1968,1950`; the left edge
`x=0, y<720` had no output at all. Deskflow enters a right-hand neighbour at
the client's left edge, so a Mac cursor in the upper ~37% of the screen
placed jackal's cursor in that gap and nothing was drawn.

## What was done

### 1. Install and build on jackal

jackal's SSH session has no passwordless sudo, so the dev packages were
fetched and extracted into the user's home instead of installed system-wide:

```bash
mkdir -p ~/opt/deskflow-deps /tmp/dfdeps
cd /tmp/dfdeps
apt-get download libxinerama-dev libxrandr-dev libxkbfile-dev \
  libei-dev libportal-dev libxkbregistry-dev
for f in *.deb; do dpkg -x "$f" ~/opt/deskflow-deps; done
```

The extracted `pkg-config` files keep `prefix=/usr`, so they were rewritten to
the extracted prefix, and the dev `.so` symlinks (which point at runtime
`.so.1` files that a `-dev` package does not ship) were repointed at the
system runtime libraries:

```bash
pcdir=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu/pkgconfig
sed -i 's|^prefix=/usr|prefix=/home/lamnt45/opt/deskflow-deps/usr|' "$pcdir"/*.pc
d=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu
for n in Xinerama Xrandr xkbfile ei portal xkbregistry; do
  ln -sf "$(ls /usr/lib/x86_64-linux-gnu/lib$n.so.* | head -1)" "$d/lib$n.so"
done
```

The build needs all three of these paths, including for CMake's
`check_include_files` / `check_library_exists` probes:

```bash
export PKG_CONFIG_PATH=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu/pkgconfig
export CPATH=$HOME/opt/deskflow-deps/usr/include
export LIBRARY_PATH=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu

cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DBUILD_INSTALLER=OFF \
  -DCMAKE_INSTALL_PREFIX=$HOME/.local \
  -DCMAKE_LIBRARY_PATH=$LIBRARY_PATH -DCMAKE_INCLUDE_PATH=$CPATH
cmake --build build -j"$(nproc)"
```

`cmake --install build` installs the GUI and core under `~/.local`, but the
running client is started from the build tree, matching pp's setup.

Client config, `~/.config/Deskflow/Deskflow.conf`:

```ini
[client]
remoteHost=mac.tail0ec64c.ts.net:24800
yScrollScale=0.1

[core]
computerName=jackal
coreMode=1
port=24800
processMode=1

[security]
certificate=/home/lamnt45/.config/Deskflow/tls/deskflow.pem
checkPeerFingerprints=true
keySize=2048
tlsEnabled=false
```

The `[security] tlsEnabled=false` matters: without it the core defaults to TLS
and the handshake dies with `tls certificate doesn't exist .../tls/deskflow.pem`
because jackal has no client certificate.

Startup is a small script, `~/bin/deskflow-start`, plus a Wayfire autostart
entry and a `start_deskflow` function in `~/.bashrc`:

```ini
# ~/.config/wayfire.ini
[autostart]
deskflow = /home/lamnt45/bin/deskflow-start
```

The script waits for the Wayland socket, exports the session environment,
kills any old instance, and starts the core detached.

### 2. Server-side screen setup

The Mac server config is split:

- `~/Library/Deskflow/Deskflow.conf` — GUI/core settings and the
  `[internalConfig]` grid;
- `~/Library/Deskflow/deskflow-server.conf` — the `section: links` layout that
  the core consumes.

The GUI only accepts a client once its name is in the internal 5×3 `screens`
array. An unknown client gets refused (`server refused client with name
"jackal"`). After the first connection the GUI added jackal automatically and
restarted the core; the initial auto-placement was above the Mac (grid index
2, directly above index 7). That caused edge flapping at the top of the Mac
screen. Moving jackal to grid index 8 (immediately right of the Mac at index 7)
produced the stable layout:

```text
VTCC-TULM7 (pp) | Mac | jackal
```

The GUI rewrites `deskflow-server.conf` from its in-memory grid on every
start, so editing the external file while the GUI is running is pointless.
The working procedure was:

1. Stop **both** GUI and core (`pgrep -x Deskflow`, `pgrep -x deskflow-core`;
   `kill -9` to guarantee no save-on-exit).
2. Edit the `screens\N\name` slots in `Deskflow.conf` (1-based; index 8 is
   `screens\9`).
3. Start `Deskflow Dev.app`.

### 3. Backend: Xwayland → native wlroots

The Wayland backend in upstream Deskflow uses the XDG portal's
`org.freedesktop.portal.RemoteDesktop`. Wayfire's portal stack does not
implement that interface:

```text
ERROR: failed to initialize remote desktop session:
GDBus.Error:org.freedesktop.DBus.Error.InvalidArgs:
No such interface “org.freedesktop.portal.RemoteDesktop”
```

Wayfire **does** expose
`zwlr_virtual_pointer_manager_v1` and
`zwp_virtual_keyboard_manager_v1`, which is exactly what upstream's
`feat/wlroots-backend` (`1f7bce66d`, "feat(wayland): add wlroots support for
sway") uses. That branch was cherry-picked onto this fork's newer
`master-lamnt45-02` (clean pick, `172c1ac8e`), built on jackal, and the client
now logs:

```text
INFO: using wlroots for wayland
INFO: local layouts: en
INFO: remote layouts: en
```

`WlrComputer::isSupported(false)` probes the registry for the two virtual
device protocols plus `wl_seat` and `zxdg_output_manager_v1`; if any are
missing it falls back to the libei/portal path.

### 4. Output-layout fix

The left-edge gap above was removed by top-aligning the main output and
persisting the layout with the existing helper:

```bash
wlr-randr --output HDMI-A-1 --pos 0,0
~/.local/bin/wayfire-save-outputs
```

Result:

```text
HDMI-A-1  0,0      2560x1600 @ 1.300781
DVI-I-1   1968,0   1920x1080  @ 1.300781, transform 270
```

The left edge is now covered by the main display for `y=0..1230`. The union is
taller (`1476` logical) because the rotated EINK is taller than the main
screen, so the bottom `y≈1230..1476` slice of the left edge still has no
output. Normal crossings at mid-screen height are fine; a crossing from the
bottom of the Mac screen can still land in that remainder. If that becomes
annoying, clamp absolute injection to the nearest output in
`WlrComputer::fakeMouseMove()` rather than changing the user's display
arrangement again.

### 5. Code sync between the Mac and jackal

The Mac checkout was already ahead of jackal: `master-lamnt45-02` @
`e3dce8899` contains the split client-hotkey, scroll-scale, stuck-key and
live-cursor-position commits. jackal was on the older squashed
`master-lamnt45` @ `53dbfcfb`. The sync is:

```text
e3dce8899  master-lamnt45-02            (Mac server, pp-style X11 client)
172c1ac8e  master-lamnt45-02-wlroots    (+ upstream 1f7bce66d wlroots backend)
```

- jackal's main clone (`~/git4/deskflow`) is now on `master-lamnt45-02` and
  rebuilt, so the X11 fallback is not stale;
- jackal's worktree (`~/git4/deskflow-wlr`) is on
  `master-lamnt45-02-wlroots` and is what the running client uses;
- pp is deliberately still on `53dbfcfb`; updating it is a separate step
  (same branch/rebuild procedure).
- The Mac server was **not** rebuilt: the wlroots commit is inside
  `if(UNIX AND NOT APPLE)` and does not change the macOS binary.

## Trials and errors

- **`qt.qpa.xcb: could not connect to display` from a plain version check.**
  `deskflow-core --version` still initialises Qt. Use
  `QT_QPA_PLATFORM=offscreen` when checking versions over SSH.
- **Missing `xkbregistry`.** `pkg-config` found `xkbcommon` but not
  `xkbregistry`; `libxkbregistry-dev` is a separate package from
  `libxkbcommon-dev` on this Ubuntu.
- **Xinerama/Xrandr link checks failed even after the headers were found.**
  The extracted `-dev` packages contain symlinks such as
  `libXinerama.so -> libXinerama.so.1.0.0`, but not the `.so.1.0.0` file
  itself. The symlinks were dangling, so `check_library_exists` (and the
  eventual link) failed. Repointing them at `/usr/lib/.../libXinerama.so.1`
  fixed it.
- **`#if with no expression` in `XWindowsComputer.cpp`.** This was a symptom
  of the same probing failure: `HAVE_X11_EXTENSIONS_XRANDR_H` was empty.
  Fixed by the include/library paths above, not by editing the source.
- **`pkill -f 'deskflow-core client'` killed the SSH shell that contained the
  pattern.** The shell's own `bash -c` command line included the here-doc
  text. Use `pkill -f '[d]eskflow-core client'` from a script file, or send
  the script over `ssh host bash -s` so the pattern is on stdin, not in the
  remote process command line.
- **Single-quoted `ssh` commands break on apostrophes** in comments
  ("Wayfire's portal"). One command silently ran part of the heredoc on the
  Mac. `ssh host bash -s <<'OUTER'` avoids the quoting trap entirely.
- **TLS defaulted on.** The client had no `~/.config/Deskflow/tls/deskflow.pem`,
  so every connection attempt logged `secure socket error` and timed out.
  pp's config had an explicit `tlsEnabled=false`; jackal's did not.
- **The server refused the client before the screen existed.**
  `server refused client with name "jackal"` is a screen-list error, not a
  network/TLS error. The screen only becomes accepted after the GUI adds it
  to `[internalConfig]`.
- **The GUI owns the layout.**
  `deskflow-server.conf` is an output of the GUI's grid state, not an input
  once the GUI has started. Restarting only the core left the old in-memory
  layout in place; the GUI had to be fully restarted after editing the
  `screens` slots.
- **`osascript ... quit` returned “User canceled”.**
  The dev app refused the AppleEvent. `kill -TERM`/`kill -9` by exact process
  name (`pgrep -x`) was reliable; killing only the GUI leaves the core
  orphaned and holding port 24800.
- **Wayland portal is not enough on Wayfire.**
  The libei backend fails before it can connect; `isWayland()` is based only
  on `XDG_SESSION_TYPE`, so a naive autostart from the Wayfire session picked
  the broken portal path. The wlroots probe runs before libei in
  `ClientApp::createComputer()` and fixes that.
- **`lsof -sTCP=ESTABLISHED` is not valid on the macOS lsof.** Use
  `-sTCP:ESTABLISHED`. This produced a usage dump while trying to verify the
  connection.
- **Screenshots proved the cursor existed but hid again after idle.**
  `grim -c` vs `grim` and an image diff showed a real 23×36 cursor at
  `(1824,1558)` on HDMI-A-1. Wayfire hides the cursor after inactivity, so a
  missing diff is not proof that Deskflow hid it; compare immediately after
  input.

## Verification

- `lsof -nP -iTCP:24800 -sTCP:ESTABLISHED` shows two sockets to the Mac:
  pp (`100.118.47.39`) and jackal (`100.71.8.37`).
- jackal's log shows the wlroots backend and a completed handshake:
  `using wlroots for wayland`, `local layouts: en`, `remote layouts: en`.
- Screenshot diff with `grim -c` shows the cursor rendered on `HDMI-A-1`.
- The layout is persisted in `~/.config/wayfire.ini`:
  `HDMI-A-1 position = 0,0`, `DVI-I-1 position = 1968,0`.
- The client reconnects on its own after a core restart (`failed to connect:
  Connection refused` while the server is down, then a successful handshake).

## Invariants

- Use the **wlroots** backend on Wayfire. Do not switch jackal back to the
  Xwayland client expecting a cursor; Xwayland cannot move the Wayfire
  pointer.
- Keep `HDMI-A-1` at `x=0` so the server's left-edge entry point is on a real
  output.
- Keep the client name `jackal` in both the server's `screens` grid and the
  client's `computerName`.
- Keep `tlsEnabled=false` on both ends unless certificates are installed on
  jackal.
- The Mac server needs no wlroots build; the Linux-only code is inert on
  macOS.
- jackal's clipboard is expected to be empty under this backend: Wayfire has
  no `ext-data-control`, and the client logs `clipboard sharing is disabled`.
- `Super+Ctrl+1..4` remains an X11 feature. It is not registered by the
  wlroots client.

## Lessons learned

- A Deskflow **client's screen is the bounding box of all its outputs**. If
  outputs overlap, or leave a gap at the edge Deskflow enters from, absolute
  pointer injection can land in a hole. Check `wlr-randr`/`xrandr` logical
  rectangles, not just the physical monitors.
- On Wayland, "it connects" is not the same as "it can move the pointer".
  Xwayland only injects into the X11 sub-world; the real compositor cursor is
  controlled by the compositor's virtual-pointer protocol.
- Wayfire lacks the RemoteDesktop portal but implements the wlroots virtual
  input protocols. Test the protocol registry before concluding that a
  Wayland compositor cannot work.
- When a desktop GUI persists a server layout, its in-memory grid is the
  source of truth. Stop the GUI before editing generated config files, and
  expect it to rewrite them on the next start.
- Keep the custom features and the wlroots support on one branch. Running an
  old squashed client branch next to a newer feature branch caused a
  version/feature mismatch (the Mac had `master-lamnt45-02` while jackal
  had `53dbfcfb`).
- Local dependency installs are viable without sudo, but dangling
  `-dev` symlinks and missing `pkg-config` prefixes fail in ways that look
  like source errors. Verify with `pkg-config`, `-Wl,-t`, and `ldd` before
  touching code.

## References

- [Jackal client operating guide](../../../../important/jackal-wayfire-client.md)
- [Client-return hotkeys guide](../../../../important/client-return-hotkeys.md)
- [Upstream wlroots commit `1f7bce66d`](https://github.com/deskflow/deskflow/commit/1f7bce66d)
- [2026-11-20 live-cursor-position plan](../20/2026-11-20-live-cursor-position-on-jump.md)
- [2026-11-17 stuck-key release plan](../17/2026-11-17-x11-release-stuck-keys-on-leave.md)
