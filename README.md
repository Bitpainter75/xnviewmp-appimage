# XnViewMP — Fixed AppImage for Fedora / Bazzite / Aurora

Patched AppImage build of [XnViewMP](https://www.xnview.com/en/xnviewmp/) 1.11.2, fixing compatibility with Fedora-based systems (Bazzite, Aurora, Fedora Silverblue) where the official AppImage fails to start.

> XnViewMP is freeware (not open-source). All application code belongs to XnSoft.  
> This repository only provides a compatibility fix, not a redistribution of XnViewMP itself.

---

## The Problem

The official `XnView_MP.glibc2.34-x86_64.appimage` bundles **PulseAudio 8.0** (from Ubuntu 16.04). This old version hard-depends on two libraries that are **not available on Fedora-based systems**:

| Missing Library | Why it's missing |
|---|---|
| `libwrap.so.0` | `tcp_wrappers` — removed from Fedora since F28 |
| `libapparmor.so.1` | AppArmor — Fedora uses SELinux, not AppArmor |

This causes a cascade: `libpulsecommon-8.0.so` fails to load → `libpulse.so.0` fails → `libQt5Multimedia` fails → XnViewMP does not start.

Additionally, the official launcher script uses `$(pwd)` to locate the XnView binary, which is fragile and can resolve to the wrong path depending on how the AppRun sets the working directory.

---

## The Fix

Two small stub libraries are compiled and added to the AppImage:

- **`libwrap.so.0`** — no-op stub that always allows connections (`hosts_access` returns 1)
- **`libapparmor.so.1`** — stub that returns `ENODATA`, signalling "AppArmor not active" — the standard response on non-AppArmor systems

The launcher script is also patched to use the `$APPDIR` environment variable (set by the AppImage runtime) instead of `$(pwd)`.

No original XnViewMP files are modified — only two stub libraries are added and the launcher script is replaced.

---

## Download

Grab the patched AppImage from the [Releases](../../releases/latest) page.

```bash
chmod +x XnViewMP-1.11.2-x86_64-fixed.AppImage
./XnViewMP-1.11.2-x86_64-fixed.AppImage
```

---

## Requirements

No additional packages needed. The AppImage bundles Qt5, GStreamer, ICU, and all other dependencies.

Tested on:
| Distribution | Status |
|---|---|
| Bazzite / Aurora (Fedora 44) | ✅ fixed |
| Fedora Silverblue 40+ | ✅ expected |
| Arch / CachyOS / Manjaro | ✅ (original AppImage also works here) |
| Ubuntu / Debian | ✅ (original AppImage also works here) |

---

## Build it yourself

You need the official AppImage from XnSoft and `appimagetool` in the same directory. The build script downloads nothing — it only modifies what's already in the official AppImage.

### Download the official AppImage

From the [XnViewMP download page](https://www.xnview.com/en/xnviewmp/#downloads), get the **Linux 64-bit (glibc 2.34)** AppImage version.

### Prerequisites

```bash
# Arch / CachyOS
sudo pacman -S gcc binutils

# Fedora / Bazzite / Aurora
sudo rpm-ostree install gcc binutils   # or use a toolbox container

# Ubuntu / Debian
sudo apt install gcc binutils
```

`appimagetool-x86_64.AppImage` from [AppImage releases](https://github.com/AppImage/appimagetool/releases) must also be in the same directory.

### Build

```bash
chmod +x build-xnviewmp-appimage.sh
./build-xnviewmp-appimage.sh
```

Produces `XnViewMP-1.11.2-x86_64-fixed.AppImage` (~99 MB) in the current directory.

### What the script does

1. Extracts the official AppImage with `--appimage-extract`
2. Reads `libpulsecommon-8.0.so` to confirm which symbols are needed
3. Compiles `libwrap.so.0` stub (`hosts_access`, `request_init`, `sock_host`)
4. Compiles `libapparmor.so.1` stub (`aa_getpeercon@@APPARMOR_1.1` with correct symbol versioning)
5. Copies stubs into `usr/lib/x86_64-linux-gnu/`
6. Replaces the launcher script to use `$APPDIR` instead of `$(pwd)`
7. Validates that `ldd` finds all libraries for the XnView binary
8. Repacks with `appimagetool` using zstd compression

---

## Why not just use the `.deb` or `.tgz`?

XnSoft also provides a `.deb` and a `.tgz`. These work well on Debian/Ubuntu but require installing Qt5 system packages on Fedora. The AppImage approach is self-contained — no system Qt5 needed, works on immutable systems like Bazzite and Aurora without `rpm-ostree install` or `flatpak run`.

---

## Links

- [XnViewMP official website](https://www.xnview.com/en/xnviewmp/)
- [XnViewMP download page](https://www.xnview.com/en/xnviewmp/#downloads)
- [XnSoft support forum](https://newsgroup.xnview.com/)
