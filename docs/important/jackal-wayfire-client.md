# Jackal (Wayfire) Deskflow client

**Status:** Local fork deployment; connected to the Mac server with the
native wlroots backend. Clipboard and the `Super+Ctrl` return hotkeys are not
available on this backend.

jackal (`jk`, Ubuntu 26.04) runs Wayfire. The Mac is the Deskflow server; pp
(`VTCC-TULM7`) is the X11 client on the left and jackal (`jackal`) is the
Wayland client on the right. This guide covers the jackal side; see
[client-return-hotkeys.md](client-return-hotkeys.md) for the Mac/pp custom
hotkeys and their X11 invariants.

## Topology

```text
Mac (server, Deskflow Dev.app, *:24800)
  |-- pp / VTCC-TULM7      X11 client, branch master-lamnt45 @ 53dbfcfb
  `-- jackal               Wayfire/wlroots client, branch master-lamnt45-02-wlroots @ 172c1ac8e
```

Server screen grid: `VTCC-TULM7 | Mac | jackal` (jackal immediately to the
right of the Mac).

## Branches and paths

| What | Where |
| --- | --- |
| Mac checkout | `/Users/lamnt45/git/deskflow`, `master-lamnt45-02` @ `e3dce8899` |
| jackal main checkout (X11 fallback) | `~/git4/deskflow`, `master-lamnt45-02` |
| jackal Wayland worktree (running client) | `~/git4/deskflow-wlr`, `master-lamnt45-02-wlroots` @ `172c1ac8e` |
| Running binary | `~/git4/deskflow-wlr/build/bin/deskflow-core` |
| Client config | `~/.config/Deskflow/Deskflow.conf` |
| Start script | `~/bin/deskflow-start` |
| X11 fallback script | `~/bin/deskflow-start-x11` |
| Client log | `~/deskflow.log` |
| Wayfire autostart | `~/.config/wayfire.ini` → `[autostart] deskflow = ...` |
| Build deps | `~/opt/deskflow-deps` (user-local `-dev` packages) |

The wlroots support is an upstream commit (`1f7bce66d`) cherry-picked onto
`master-lamnt45-02`; it is Linux-only. The Mac server does not need that
branch, and `/Applications/Deskflow Dev.app` remains built from
`master-lamnt45-02`.

## Build on jackal

The user has no passwordless sudo, so the missing `-dev` packages are
extracted under `~/opt/deskflow-deps`:

```bash
mkdir -p ~/opt/deskflow-deps /tmp/dfdeps
cd /tmp/dfdeps
apt-get download libxinerama-dev libxrandr-dev libxkbfile-dev \
  libei-dev libportal-dev libxkbregistry-dev
for f in *.deb; do dpkg -x "$f" ~/opt/deskflow-deps; done
```

The extracted `.pc` prefix and the dev `.so` symlinks must be fixed; `-dev`
packages ship `libXinerama.so -> libXinerama.so.1.0.0`, but the runtime target
is not in the package:

```bash
pcdir=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu/pkgconfig
sed -i 's|^prefix=/usr|prefix=/home/lamnt45/opt/deskflow-deps/usr|' "$pcdir"/*.pc

d=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu
for n in Xinerama Xrandr xkbfile ei portal xkbregistry; do
  ln -sf "$(ls /usr/lib/x86_64-linux-gnu/lib$n.so.* | head -1)" "$d/lib$n.so"
done
```

Then build with all three search paths exported (CMake's feature probes need
them too):

```bash
export PKG_CONFIG_PATH=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu/pkgconfig
export CPATH=$HOME/opt/deskflow-deps/usr/include
export LIBRARY_PATH=$HOME/opt/deskflow-deps/usr/lib/x86_64-linux-gnu

cd ~/git4/deskflow-wlr
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DBUILD_INSTALLER=OFF \
  -DCMAKE_INSTALL_PREFIX=$HOME/.local \
  -DCMAKE_LIBRARY_PATH=$LIBRARY_PATH -DCMAKE_INCLUDE_PATH=$CPATH
cmake --build build -j"$(nproc)"
```

The configure output must say `-- wlroots backend: ON`. Check the binary with
`QT_QPA_PLATFORM=offscreen build/bin/deskflow-core --version` (without the
offscreen platform Qt tries to open a display).

The X11 fallback is built the same way in `~/git4/deskflow` (no Wayland
backend needed). Keep it rebuilt when syncing branches; `deskflow-start-x11`
runs that tree.

## Client config

`~/.config/Deskflow/Deskflow.conf`:

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

`tlsEnabled=false` is required unless a client certificate is installed.
`computerName` must match the server's screen name exactly.

## Start, stop, status

```bash
~/bin/deskflow-start                 # native wlroots/Wayland client (default)
~/bin/deskflow-start-x11             # Xwayland fallback; clipboard works, cursor does not
pkill -f '[d]eskflow-core client'    # stop; the brackets avoid matching this shell
tail -f ~/deskflow.log               # client log
pgrep -af '[d]eskflow-core client'
```

On the Mac:

```bash
pgrep -ax deskflow-core
lsof -nP -iTCP:24800 -sTCP:LISTEN
lsof -nP -iTCP:24800 -sTCP:ESTABLISHED
```

`-sTCP:ESTABLISHED` (colon) is the macOS lsof syntax; `-sTCP=...` prints
usage.

## Autostart

`~/.config/wayfire.ini`:

```ini
[autostart]
deskflow = /home/lamnt45/bin/deskflow-start
```

`~/bin/deskflow-start` exports the Wayland session variables, waits for the
Wayland socket, kills any old client, and starts the core detached. The
`start_deskflow` shell function in `~/.bashrc` calls the same script.

The client must start **after** the compositor's Wayland socket exists; the
script checks `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` and exits rather than
falling back to Xwayland silently.

## Mac server layout

The GUI's internal 5×3 grid is authoritative. In
`~/Library/Deskflow/Deskflow.conf`, the slots are 1-based:

```text
screens\7\name=VTCC-TULM7      # left of the Mac
screens\8\name=lamnt45s-MacBook-Pro.local
screens\9\name=jackal          # right of the Mac
```

`deskflow-server.conf` is generated from that grid. Do not edit it while the
GUI is running; the GUI rewrites it on start. To change the layout safely:

```bash
# stop the GUI and its core
pkill -9 -x Deskflow
pkill -9 -x deskflow-core
# edit the screens\N slots, then
open -a "Deskflow Dev"
```

The server listens on `*:24800`; the Mac firewall is disabled on this host.
TLS is disabled on both ends.

## Wayland backend notes

- Wayfire's XDG portal does **not** implement
  `org.freedesktop.portal.RemoteDesktop`, so the libei backend fails with
  `No such interface “org.freedesktop.portal.RemoteDesktop”`.
- Wayfire does expose `zwlr_virtual_pointer_manager_v1` and
  `zwp_virtual_keyboard_manager_v1`; the wlroots backend uses those directly.
- The client log should contain `INFO: using wlroots for wayland`.
- Clipboard is disabled: `compositor has no ext-data-control, clipboard
  sharing is disabled`.
- The X11-only `Super+Ctrl+1..4` client hotkeys are not registered on this
  backend. Return to the Mac by moving off jackal's left edge (the Mac is to
  the left in the server grid).
- `WlrComputer::isSupported(false)` requires `wl_seat`,
  `zxdg_output_manager_v1`, and both virtual-device managers. If any is
  missing, the client falls back to the portal path and fails as above.

## Output layout

The client reports the **bounding box of all enabled outputs** as its screen.
A gap or overlap at the edge Deskflow enters from puts the injected cursor
into a hole. The working layout on jackal:

```text
HDMI-A-1   position 0,0      2560x1600 @ scale 1.300781
DVI-I-1    position 1968,0   1920x1080  @ scale 1.300781, transform 270 (EINK)
```

Persist changes with the existing helper:

```bash
wlr-randr --output HDMI-A-1 --pos 0,0
~/.local/bin/wayfire-save-outputs
```

The HDMI logical height is 1230 while the rotated EINK makes the union 1476
high. The left edge is covered for `y=0..1230`; the bottom tail
`y≈1230..1476` is still a gap. If a crossing from the bottom of the Mac
screen loses the cursor, clamp absolute injection to the nearest output in
`WlrComputer::fakeMouseMove()` (a local patch), rather than moving the
displays again.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `tls certificate doesn't exist` | Client has no cert but TLS defaults on. Add `[security] tlsEnabled=false`. |
| `server refused client with name "jackal"` | `jackal` is not in the server's `[internalConfig] screens` grid. Add it, restart the GUI. |
| Client connects but no cursor, nothing moves | Xwayland backend in use. Run `~/bin/deskflow-start` (wlroots), not `deskflow-start-x11`. Check the log for `using wlroots for wayland`. |
| Cursor invisible only near one edge | Missing output at the entry edge. Check `wlr-randr` logical positions; align the main output to `0,0`. |
| Cursor flips between machines at an edge | The client screen is at the wrong grid slot. Put jackal at index 8 (right of the Mac) and fully restart the GUI. |
| `No such interface …RemoteDesktop` | Libei/portal path picked. Wayfire needs the wlroots backend; check `-- wlroots backend: ON` and the registry probe. |
| Clipboard empty | Expected on wlroots/Wayfire (`ext-data-control` absent). Use VNC/ClipCascade or the X11 fallback if clipboard is required. |
| Hotkeys do nothing on jackal | `Super+Ctrl` grabs are `#if WINAPI_XWINDOWS`; use the edge or the server's hotkeys. |
| Client won't start from autostart | Check the Wayland socket exists (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`) and the script waited for it. |
| Version/build errors from `--version` | No display in the SSH session. Prefix `QT_QPA_PLATFORM=offscreen`. |
| Build can't find Xinerama/Xrandr/xkbregistry | Export all three paths; verify `pkg-config --modversion` and that the dev `.so` symlinks point at real runtime files. |

## Verification

```bash
# on jackal
pgrep -af '[d]eskflow-core client'
grep -E 'using wlroots|local layouts|remote layouts' ~/deskflow.log
tail -5 ~/deskflow.log

# on the Mac
lsof -nP -iTCP:24800 -sTCP:ESTABLISHED
```

A healthy client logs `using wlroots for wayland`, then `local layouts: en`
and `remote layouts: en`, and the Mac shows an ESTABLISHED socket from
jackal's Tailscale address.

## References

- [2026-11-24 session record](../plans/2026/11/24/2026-11-24-jackal-wayfire-client.md)
- [Client-return hotkeys and X11 invariants](client-return-hotkeys.md)
- [Upstream wlroots commit](https://github.com/deskflow/deskflow/commit/1f7bce66d)
