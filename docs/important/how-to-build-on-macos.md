# How to Build on macOS

This guide covers building the Deskflow GUI application (`Deskflow.app`) natively on macOS
(Apple Silicon) with Homebrew-provided Qt.

## Prerequisites

- macOS 26.x (tested on 26.5.2) or compatible
- [Xcode] 26+ (or Command Line Tools) with a working `clang`
- [Homebrew]
- [cmake] 3.24+
- [Qt] 6.7+ (`brew install qt`)
- [openssl] 3.0+ (`brew install openssl`)

Verify the toolchain:

```bash
brew install cmake qt openssl
cmake --version        # 3.24+
qmake6 --version       # Qt 6.7+
```

## Known issue: AGL framework was removed from the macOS 26 SDK

Qt's CMake module `FindWrapOpenGL.cmake` unconditionally links `-framework AGL` on Apple
platforms. Apple removed `AGL.framework` from the macOS 26 SDK (it now only exists as a
stub that is resolved from the dyld shared cache at runtime), so linking fails with:

```
ld: framework 'AGL' not found
```

### Workaround

The system `AGL.framework` is a stub without a linkable binary, so `find_library` finds it
but `ld` cannot use it. Patch the Homebrew Qt find module to fall back to plain `-framework
OpenGL` (AGL is no longer needed; its symbols are in the shared cache):

```bash
vim /opt/homebrew/opt/qt/lib/cmake/Qt6/FindWrapOpenGL.cmake
```

Replace this block:

```cmake
find_library(WrapOpenGL_AGL NAMES AGL)
if(WrapOpenGL_AGL)
    set(__opengl_agl_fw_path "${WrapOpenGL_AGL}")
endif()
if(NOT __opengl_agl_fw_path)
    set(__opengl_agl_fw_path "-framework AGL")
endif()
```

with:

```cmake
find_library(WrapOpenGL_AGL NAMES AGL)
if(WrapOpenGL_AGL)
    set(__opengl_agl_fw_bin "${WrapOpenGL_AGL}/Versions/Current/AGL")
    if(NOT EXISTS "${__opengl_agl_fw_bin}" AND NOT EXISTS "${WrapOpenGL_AGL}/AGL")
        set(WrapOpenGL_AGL WrapOpenGL_AGL-NOTFOUND)
    endif()
endif()
if(WrapOpenGL_AGL)
    set(__opengl_agl_fw_path "${WrapOpenGL_AGL}")
endif()
if(NOT __opengl_agl_fw_path)
    set(__opengl_agl_fw_path "-framework OpenGL")
endif()
```

## Configure and build

Always use a fresh build directory — an existing `build/` created on another machine
(e.g. Linux) carries a stale `CMakeCache.txt` with wrong source/prefix paths and will fail
to reconfigure.

```bash
cmake -S . -B build-mac \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_OSX_BUNDLE=ON \
  -DBUILD_INSTALLER=OFF

cmake --build build-mac -j$(sysctl -n hw.ncpu)
```

The bundle is produced at `build-mac/bin/Deskflow.app` with the GUI binary `Deskflow` and
the service binary `deskflow-core` inside `Contents/MacOS/`.

> `BUILD_OSX_BUNDLE` defaults to `ON` on Apple; it is listed explicitly above for clarity.
> All unit tests run as part of the build.

## Bundle the Qt frameworks

Deploy Qt frameworks and plugins into the app bundle:

```bash
/opt/homebrew/opt/qt/bin/macdeployqt build-mac/bin/Deskflow.app -always-overwrite \
  -executable=build-mac/bin/Deskflow.app/Contents/MacOS/deskflow-core
```

macdeployqt may print benign `Cannot resolve rpath` warnings for Homebrew Qt — the Qt
frameworks reference each other via `@rpath` and are still copied correctly.

### Missing QtDBus.framework

`QtGui.framework` depends on `QtDBus.framework`, which macdeployqt sometimes fails to copy.
Copy it manually and fix its install name:

```bash
cd build-mac/bin/Deskflow.app/Contents/Frameworks
cp -R /opt/homebrew/opt/qt/lib/QtDBus.framework .
install_name_tool -id "@rpath/QtDBus.framework/Versions/A/QtDBus" \
  QtDBus.framework/Versions/A/QtDBus
```

`@rpath` resolves via the framework's own `LC_RPATH` (`@loader_path/../../../`) to
`Contents/Frameworks/`, so the bundle stays relocatable.

## Signing

The build is ad-hoc signed, which Gatekeeper rejects when launched via Finder/`open`.
Verify and sign, then add a Gatekeeper exception (requires sudo once) or run the app once
via right-click → Open:

```bash
codesign --force --deep --sign - /Applications/Deskflow.app
sudo spctl --add /Applications/Deskflow.app
open /Applications/Deskflow.app
```

> The app refuses to run from `/Volumes/...` (it shows a "drag to Applications" dialog).
> Copy it to `/Applications` first.

## Install

```bash
rm -rf /Applications/Deskflow.app
cp -R build-mac/bin/Deskflow.app /Applications/
codesign --force --deep --sign - /Applications/Deskflow.app
```

## Verification

- The build finishes with `100% tests passed`.
- `open /Applications/Deskflow.app` shows the Deskflow settings window and runs
  `deskflow-core` on port `24800`.
- `otool -L` on the bundle binaries shows only `@executable_path/../Frameworks` /
  `@rpath` references — no absolute Homebrew paths — confirming the bundle is portable.

[Homebrew]: https://brew.sh
[Xcode]: https://developer.apple.com/xcode/
[cmake]: https://cmake.org
[Qt]: https://www.qt.io
[openssl]: https://www.openssl.org