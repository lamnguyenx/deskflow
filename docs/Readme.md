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

This checkout carries an uncommitted local patch for the Mac server + Linux
client pair: the client can register `Super+Ctrl+1…4` and send a native `CSWP`
message that returns the active cursor to the primary computer. The patch also
fixes X11 secondary clients, which previously registered global hotkeys but
never processed them.

A second uncommitted patch (2026-11-17) makes the client
`yScrollScale`/`xScrollScale` settings effective on X11: `XWindowsComputer`
now scales in whole wheel clicks and carries the fractional remainder between
events (upstream quantized any scaled delta back up to one click). See
[2026-11-17 session record](plans/2026/11/17/2026-11-17-x11-fractional-scroll-scale.md).

A third uncommitted patch (2026-11-17) clears modifiers left down on an X11
client: `Computer::leaveSecondary()` now calls `releasePressedKeys()`, and
`XWindowsKeyState` releases every key the X server still reports pressed
(`XQueryKeymap` + XTest) instead of only the keys it still tracks as synthetic.
See
[2026-11-17 session record](plans/2026/11/17/2026-11-17-x11-release-stuck-keys-on-leave.md).

The patched Mac build is installed separately as `/Applications/Deskflow Dev.app`
and needs Accessibility for the app and its inner `deskflow-core` (Screen
Recording for the app). The notarized app does not handle `CSWP`.

- [Client-return hotkey operating guide](important/client-return-hotkeys.md)
- [2026-11-16 session record](plans/2026/11/16/2026-11-16-client-return-hotkeys.md)
- [2026-11-17 scroll-scale session record](plans/2026/11/17/2026-11-17-x11-fractional-scroll-scale.md)
- [2026-11-17 stuck-key release session record](plans/2026/11/17/2026-11-17-x11-release-stuck-keys-on-leave.md)
- [Parent workspace record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/16/2026-11-16-deskflow-client-return-hotkeys.md)
- [Parent workspace scroll-scale record](file:///Users/lamnt45/git/hacker-workspace-automator/docs/plans/2026/11/17/2026-11-17-pp-scroll-scale-and-orphan-fd-fix.md)
