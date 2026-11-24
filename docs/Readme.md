# Deskflow

Deskflow is a free and open source keyboard and mouse sharing app. Use the keyboard, mouse, or trackpad of one computer to control nearby computers, and work seamlessly between them.

[Homepage](https://deskflow.org) [Code](https://github.com/deskflow/deskflo)

## Getting help online

 - View the [wiki](https://github.com/deskflow/deskflow/wiki) Online resource

### Chat with us
 - Main discussion on Matrix: [`#deskflow:matrix.org`](https://matrix.to/#/#deskflow:matrix.org) ([Matrix clients](https://matrix.org/ecosystem/clients/))
 - Discussion also happens on IRC: `#deskflow` or `#deskflow-dev` on [Libera Chat](https://libera.chat/)
 - Start a [new discussion](https://github.com/deskflow/deskflow/discussions) on our GitHub project.

## Reporting security issues

Check [Security](Security.md) to find out how to report security issues.

## Local client-return hotkey fork

This checkout carries local commits (branch `master-lamnt45-02`) for the Mac
server + Linux client pair: the client can register `Super+Ctrl+1…4` and send
a native `CSWP` message that returns the active cursor to the primary
computer. The patch also fixes X11 secondary clients, which previously
registered global hotkeys but never processed them.

A second local patch (2026-11-17) makes the client
`yScrollScale`/`xScrollScale` settings effective on X11: `XWindowsComputer`
now scales in whole wheel clicks and carries the fractional remainder between
events (upstream quantized any scaled delta back up to one click). See
[2026-11-17 session record](plans/2026/11/17/2026-11-17-x11-fractional-scroll-scale.md).

A third local patch (2026-11-17) clears modifiers left down on an X11
client: `Computer::leaveSecondary()` now calls `releasePressedKeys()`, and
`XWindowsKeyState` releases every key the X server still reports pressed
(`XQueryKeymap` + XTest) instead of only the keys it still tracks as synthetic.
See
[2026-11-17 session record](plans/2026/11/17/2026-11-17-x11-release-stuck-keys-on-leave.md).

A fourth local patch (2026-11-20) makes a jump to a client land on the
client's **live** cursor position: `jumpToComputer()` asks the client with
`kMsgQInfo` and jumps to the position in its `kMsgDInfo` reply, with the
saved jump position as a 500 ms timeout fallback. Server side only. See
[2026-11-20 session record](plans/2026/11/20/2026-11-20-live-cursor-position-on-jump.md).

A fifth change (2026-11-24) adds jackal (`jk`) as a second client. It runs
Wayfire, whose portal has no RemoteDesktop interface, so the client uses the
wlroots virtual-pointer/virtual-keyboard backend instead of Xwayland; the
latter connects but cannot move the real Wayfire cursor. jackal's main output
must sit at logical `x=0` so the entry point is not in an output gap.
Clipboard sharing and the `Super+Ctrl` return hotkeys are X11-only and are not
available on this backend. See
[2026-11-24 session record](plans/2026/11/24/2026-11-24-jackal-wayfire-client.md)
and the [jackal client guide](important/jackal-wayfire-client.md).

The `master-lamnt45-02-wlroots` branch carries all of the above plus the
upstream wlroots backend (cherry-picked from `deskflow/deskflow`
`1f7bce66d`). It is the branch used by jackal; the Mac server remains on
`master-lamnt45-02` because the wlroots code is Linux-only.

The patched Mac build is installed separately as `/Applications/Deskflow Dev.app`
and needs Accessibility for the app and its inner `deskflow-core` (Screen
Recording for the app). The notarized app does not handle `CSWP`.

Sign the dev app with the stable local `Deskflow Local` identity
(`tools/macos-dev-signing.sh setup|sign|status`), never ad-hoc: ad-hoc
signatures pin the TCC requirement to the cdhash, so every rebuild
invalidates the grants and macOS re-prompts on every launch. Core first, then
the bundle.

- [Client-return hotkey operating guide](important/client-return-hotkeys.md)
- [2026-11-16 session record](plans/2026/11/16/2026-11-16-client-return-hotkeys.md)
- [2026-11-17 scroll-scale session record](plans/2026/11/17/2026-11-17-x11-fractional-scroll-scale.md)
- [2026-11-17 stuck-key release session record](plans/2026/11/17/2026-11-17-x11-release-stuck-keys-on-leave.md)
- [2026-11-20 live-cursor-position session record](plans/2026/11/20/2026-11-20-live-cursor-position-on-jump.md)
- [2026-11-24 jackal/Wayfire session record](plans/2026/11/24/2026-11-24-jackal-wayfire-client.md)
- [Jackal Wayfire client guide](important/jackal-wayfire-client.md)
- [Parent workspace record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/16/2026-11-16-deskflow-client-return-hotkeys.md)
- [Parent workspace scroll-scale record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/17/2026-11-17-pp-scroll-scale-and-orphan-fd-fix.md)
- [Parent workspace live-cursor record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/20/2026-11-20-deskflow-live-cursor-jump.md)
