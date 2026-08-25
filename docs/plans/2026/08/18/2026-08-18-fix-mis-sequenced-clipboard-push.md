# Fix clipboard push rejected as "(mis-sequenced)" on a client-initiated (OSC 52) grab

## Problem

Running this machine as a deskflow **client** (server on `mac`), copying via OSC 52
in a local terminal works for a while, then the server starts dropping every
clipboard push from the client:

```
[10:40:16] INFO: ignored screen "VTCC-TULM7" grab of clipboard 0
[10:40:17] INFO: ignored screen "VTCC-TULM7" update of clipboard 0 (mis-sequenced)
[10:40:26] INFO: ignored screen "VTCC-TULM7" grab of clipboard 0
[10:40:26] INFO: ignored screen "VTCC-TULM7" update of clipboard 0 (mis-sequenced)
```

The condition is persistent: every subsequent OSC 52 copy is rejected until the
client screen is re-entered (cursor moved onto it), which re-synchronises the
sequence numbers. OSC 52 writes are detected on the client by the ownership
polling in `XWindowsScreen::checkClipboards()` (local patch), which fires
`ClipboardGrabbed` whenever the terminal takes the X selection directly.

## Root cause

Clipboard sequence numbers are only meaningful for the *active* screen.

- The server's global counter `Server::m_seqNum` is incremented on every screen
  switch (`Server.cpp:476`) and handed to the entering screen via
  `m_active->enter(x, y, m_seqNum, ...)`.
- A client's `ServerProxy::m_seqNum` is **only ever set from an "enter" message**
  (`ServerProxy.cpp:523`). It defaults to `0` and stays at its last-entered
  value for as long as the cursor is not on the client.
- The server's per-clipboard `m_clipboardSeqNum` is stamped from the last
  accepted grab (`Server.cpp:1176`). The **primary** screen is always allowed to
  grab, so its (potentially much larger) sequence number can ratchet
  `m_clipboardSeqNum` above the client's stale value.

When an OSC 52 write happens while the client is not the freshly-entered active
screen, the client reports its clipboard grab with a stale `m_seqNum`. The
server then hard-rejects it in `Server::handleClipboardGrabbed`
(`Server.cpp:1165`):

```cpp
if (grabber != m_primaryClient && info->m_sequenceNumber < clipboard.m_clipboardSeqNum) {
  LOG_DEBUG("ignored screen \"%s\" grab of clipboard %d", ...);
  return;   // never updates m_clipboardSeqNum
}
```

Because the rejected grab never updates `m_clipboardSeqNum`, the subsequent
data update is also rejected in `Server::onClipboardChanged` (`Server.cpp:1431`,
"(mis-sequenced)"). The client is now permanently locked out of clipboard
sharing until it is re-entered with a fresh sequence number.

The normal (non-OSC 52) path never hits this because grabs only originate from
the active screen, which carries a fresh sequence number.

Note: relaxing the grab guard is safe. `Screen::grabClipboard()` maps to
`setClipboard(id, nullptr)`, which on the macOS server is a no-op
(`OSXScreen.mm:840`), so telling the primary to grab does *not* claim the
pasteboard and cannot race ahead of the client's data. Stale *data* is still
filtered by `onClipboardChanged` (`seqNum < m_clipboardSeqNum` and the
"unchanged" check), which is left intact.

## Fix

In `src/lib/server/Server.cpp`, `Server::handleClipboardGrabbed`: accept a grab
from any known screen even when its sequence number is older than the current
one. Update the owner and sequence number as usual so the accompanying data
update is accepted. Log at debug level when the sequence number was stale, to
preserve the diagnostic signal.

```cpp
// accept the grab from any known screen, even if its sequence number is
// older than the current one.  a screen's sequence number only advances
// when the server enters it, so a client pushing its clipboard (e.g. an
// OSC 52 write on a terminal) legitimately carries a stale sequence
// number; rejecting it permanently locks that client out of clipboard
// sharing until it is re-entered.  stale DATA is still filtered in
// onClipboardChanged via the sequence and "unchanged" checks.
ClipboardInfo &clipboard = m_clipboards[info->m_id];
if (grabber != m_primaryClient && info->m_sequenceNumber < clipboard.m_clipboardSeqNum) {
  LOG_DEBUG(
      "screen \"%s\" grabbed clipboard %d with stale sequence number %u (current %u), accepting",
      getName(grabber).c_str(), info->m_id, info->m_sequenceNumber, clipboard.m_clipboardSeqNum
  );
}
```

`onClipboardChanged` (`Server.cpp:1426`) is unchanged: it still drops updates
whose sequence number is older than the stored one and drops identical data,
which prevents out-of-order/duplicate content from overwriting newer data.

## Files changed

- `src/lib/server/Server.cpp` — relax the clipboard-grab sequence-number guard.

## Verification

- Build the server (see `build/`).
- Reproduce the OSC 52 copy after the sequence numbers have diverged; the server
  must log `screen "VTCC-TULM7" updated clipboard 0` and the clipboard must
  reach the server instead of `(mis-sequenced)`.
- Confirm normal (active-screen) clipboard sharing still behaves as before.