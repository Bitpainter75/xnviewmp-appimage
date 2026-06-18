# XnViewMP AppImage Fix – Build-Dokumentation

## Überblick

Das offizielle XnViewMP AppImage (`XnView_MP.glibc2.34-x86_64.appimage`) startet auf Fedora-basierten Systemen (Bazzite, Aurora, Fedora Silverblue) nicht. Dieses Build-Skript repariert das AppImage durch minimale, gezielte Eingriffe.

---

## Diagnose: Warum läuft das Original nicht?

### Problem 1 — fehlende Systemlibraries auf Fedora (Hauptursache)

Das AppImage bündelt **PulseAudio 8.0** aus Ubuntu 16.04. Diese alte Version hat harte Abhängigkeiten:

```
libpulsecommon-8.0.so
  ├── NEEDED: libwrap.so.0       ← tcp_wrappers, seit Fedora 28 entfernt
  └── NEEDED: libapparmor.so.1   ← AppArmor, auf Fedora nicht vorhanden (SELinux)
```

Fehlende Symbole aus `libwrap.so.0`:
- `hosts_access` — TCP-Zugangskontrolle: darf dieser Client verbinden?
- `request_init` — Request-Struktur initialisieren
- `sock_host` — Hostnamen des Sockets ermitteln

Fehlendes Symbol aus `libapparmor.so.1`:
- `aa_getpeercon@APPARMOR_1.1` — AppArmor-Sicherheitskontext eines Peer-Sockets

**Kaskadeneffekt** — weil `libpulsecommon-8.0.so` nicht lädt, schlagen auch folgende Libraries fehl:
- `libpulse.so.0` (PulseAudio Client)
- `libQt5Multimedia.so.5`
- `libQt5MultimediaWidgets.so.5`
- `libmdk.so` (Media Decoding Kit)

### Problem 2 — fehlerhafter Launcher-Script

```sh
# Original usr/bin/xnviewmp:
usr="$(pwd)"
"$usr/XnView/XnView" "$@"
```

`$(pwd)` gibt das aktuelle Arbeitsverzeichnis zurück. Wenn der AppRun zu `$APPDIR` wechselt (nicht `$APPDIR/usr`), liegt das Binary bei `$APPDIR/XnView/XnView` statt dem korrekten `$APPDIR/usr/XnView/XnView`.

Der zuverlässige Ansatz: `$APPDIR`-Umgebungsvariable nutzen, die vom AppImage-Runtime gesetzt wird.

---

## Fix-Strategie

### Stub-Libraries

Anstatt die alte `libpulsecommon-8.0.so` zu ersetzen (invasiv), werden zwei kleine Stub-Libraries ergänzt:

**`libwrap.so.0`** — erlaubt alle Verbindungen (no-op):
```c
int hosts_access(request_t r) { return 1; }    // immer erlauben
request_t request_init(request_t r, ...) { return r; }
char *sock_host(request_t r) { return ""; }
```

**`libapparmor.so.1`** — signalisiert "AppArmor nicht verfügbar":
```c
int aa_getpeercon(int fd, char **con, char **mode) {
    errno = ENODATA;  // AppArmor nicht aktiv
    return -1;
}
```
Mit korrekter Symbol-Versionierung: `aa_getpeercon@@APPARMOR_1.1`

**Warum ist das sicher?**
- XnViewMP ist ein PulseAudio-*Client*, kein Daemon. `hosts_access()` hat im Client-Kontext keine sicherheitsrelevante Funktion.
- `aa_getpeercon()` mit `ENODATA` ist die standardkonforme Antwort auf nicht-AppArmor-Systemen. libpulsecommon behandelt diesen Fehler korrekt.

### Launcher-Script

```sh
# Repariert:
if [ -n "$APPDIR" ]; then
    XNVIEW_DIR="${APPDIR}/usr/XnView"
else
    SELF="$(readlink -f "$0")"
    XNVIEW_DIR="$(dirname "$SELF")/../XnView"
fi
```

---

## Build-Prozess

```
XnView_MP.glibc2.34-x86_64.appimage
              │
              ▼
   --appimage-extract
              │
              ▼
      squashfs-root/
       ├── kompiliere libwrap.so.0 Stub (gcc)
       ├── kompiliere libapparmor.so.1 Stub (gcc, --version-script)
       ├── kopiere Stubs → usr/lib/x86_64-linux-gnu/
       ├── ersetze usr/bin/xnviewmp (Launcher-Fix)
       └── validiere ldd XnView-Binary
              │
              ▼
         appimagetool
              │
              ▼
   XnViewMP-1.11.2-x86_64-fixed.AppImage (~99 MB)
```

---

## Dateistruktur (relevante Änderungen)

```
squashfs-root/
└── usr/
    ├── bin/
    │   └── xnviewmp          ← ERSETZT: $APPDIR statt $(pwd)
    ├── lib/
    │   └── x86_64-linux-gnu/
    │       ├── libwrap.so.0          ← NEU: tcp_wrappers Stub
    │       ├── libapparmor.so.1      ← NEU: AppArmor Stub
    │       ├── libpulsecommon-8.0.so ← unverändert (Original)
    │       └── libpulse.so.0         ← unverändert (Original)
    └── XnView/
        ├── XnView            ← unverändert (Original Binary)
        ├── lib/              ← unverändert
        └── Plugins/          ← unverändert
```

---

## Nicht geändert

- Das XnView-Hauptbinary (`usr/XnView/XnView`)
- Alle Qt5-Libraries (`usr/XnView/lib/`)
- Alle Plugin-Libraries (`usr/XnView/Plugins/`)
- Der binäre AppRun (von AppImageKit)
- Alle GStreamer-Libraries (`usr/lib/x86_64-linux-gnu/`)

---

## Systemanforderungen auf dem Zielsystem

Keine zusätzlichen Pakete nötig. Das AppImage bringt Qt5, GStreamer, ICU und alle weiteren Abhängigkeiten selbst mit.

Optional für erweiterte Funktionen:
- `libsane` — Scanner-Import (XnViewMP kann von Scannern importieren)
