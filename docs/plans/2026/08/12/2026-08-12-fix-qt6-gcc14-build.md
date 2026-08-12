# Fix Qt6 + GCC 14 build error in XWindowsClipboardTests

## Problem

Building with GCC 14.2.0 + Qt 6.9.3 + C++20 on Linux fails with:

```
error: invalid use of incomplete type 'class QDirPrivate'
```

in `/opt/conda/include/qt6/QtCore/qshareddata.h:57`, triggered from `qdir.h:242`.

## Root cause

`<X11/Xlib.h>` (pulled in via `platform/XWindowsClipboard.h`) defines `#define Status int` at line 79. This macro breaks Qt header parsing when Qt headers are included *after* X11 headers, because Qt uses `Status` as an identifier (e.g., `QTextStream::Status`, QEvent members).

The incorrect include order in `XWindowsClipboardTests.h` was:

```cpp
#include "base/Log.h"
#include "platform/XWindowsClipboard.h"   // includes <X11/Xlib.h> → #define Status int
#include <QTest>                           // Qt headers broken by Status macro
```

The cascade: broken `qcoreevent.h` → broken `qobject.h` → broken `qsharedpointer.h` → `QSharedDataPointer<QDirPrivate>` destructor instantiation fails because `QDirPrivate` is still an incomplete type at the point where the type traits in `Q_DECLARE_SHARED(QDir)` require it to be complete.

## Fix

### 1. Reorder includes in `src/unittests/platform/XWindowsClipboardTests.h`

Move `<QTest>` to the top so Qt headers are processed before any X11 headers:

```cpp
#include <QTest>                            // Qt first, before X11
#include "base/Log.h"
#include "platform/XWindowsClipboard.h"     // X11 headers after Qt
```

### 2. Fix pre-existing enum naming in `src/unittests/platform/XWindowsClipboardTests.cpp`

The test used `XWindowsClipboard::kText` but the codebase uses `IClipboard::Format::Text` (the `kText`/`kHTML`/`kBitmap` names don't exist):

```cpp
// Before:
clipboard.add(XWindowsClipboard::kText, m_testString);

// After:
clipboard.add(IClipboard::Format::Text, m_testString);
```

## Files changed

- `src/unittests/platform/XWindowsClipboardTests.h` — reorder includes
- `src/unittests/platform/XWindowsClipboardTests.cpp` — fix enum references

## Verification

All 100% of targets build successfully. The `XWindowsClipboardTests` test SEGFAULTS at runtime because it requires a running X server (`XOpenDisplay`), which is expected in headless build environments.
