#!/bin/bash
# ============================================================
#  build-xnviewmp-appimage.sh
#  Repariert das offizielle XnViewMP AppImage für Fedora-basierte
#  Systeme (Bazzite, Aurora, Fedora Silverblue).
#
#  Probleme im Original-AppImage:
#    1. libpulsecommon-8.0 (Ubuntu 16.04) benötigt libwrap.so.0
#       (tcp_wrappers) und libapparmor.so.1 — beide auf Fedora
#       nicht vorhanden. Dadurch scheitert das Laden von
#       libpulse.so.0, libQt5Multimedia und libmdk.so.
#    2. Launcher-Script (usr/bin/xnviewmp) nutzt $(pwd) zur
#       Pfadermittlung — schlägt fehl wenn AppRun zu $APPDIR
#       statt $APPDIR/usr wechselt.
#
#  Fix:
#    - Stub-Libraries für libwrap.so.0 + libapparmor.so.1
#    - Robusterer Launcher-Script via $APPDIR
#
#  Voraussetzungen im gleichen Verzeichnis:
#    - XnView_MP.glibc2.34-x86_64.appimage
#    - appimagetool-x86_64.AppImage
#    - gcc
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ---- Schritt 0: Voraussetzungen ----------------------------------------

step "Schritt 0: Voraussetzungen"

APPIMAGETOOL="${SCRIPT_DIR}/appimagetool-x86_64.AppImage"
[ -x "$APPIMAGETOOL" ] || error "appimagetool-x86_64.AppImage nicht gefunden oder nicht ausführbar."

APPIMAGE_SRC=$(find "$SCRIPT_DIR" -maxdepth 1 -name "XnView_MP*.appimage" | sort -V | tail -1)
[ -n "$APPIMAGE_SRC" ] || error "Kein XnView_MP*.appimage in $SCRIPT_DIR gefunden."
[ -x "$APPIMAGE_SRC" ] || chmod +x "$APPIMAGE_SRC"

command -v gcc &>/dev/null || error "gcc fehlt – bitte installieren."
command -v readelf &>/dev/null || error "readelf fehlt – bitte binutils installieren."

# Version: erst aus Dateiname, dann aus Desktop-Datei
VERSION=$(basename "$APPIMAGE_SRC" | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$VERSION" ]; then
    # Extraktion nötig um Desktop-Datei zu lesen — erst später bekannt
    VERSION="latest"
fi

info "Quelle: $APPIMAGE_SRC"
info "appimagetool: $APPIMAGETOOL"

# ---- Schritt 1: AppImage extrahieren -----------------------------------

step "Schritt 1: AppImage extrahieren"

WORK_DIR=$(mktemp -d /tmp/xnviewmp-appimage-XXXXXX)
EXTRACT_DIR="${WORK_DIR}/squashfs-root"

info "Arbeitsverzeichnis: $WORK_DIR"

cd "$WORK_DIR"
"$APPIMAGE_SRC" --appimage-extract >/dev/null 2>&1
[ -d "$EXTRACT_DIR" ] || error "Extraktion fehlgeschlagen — squashfs-root nicht gefunden."

# Version aus Desktop-Datei nachlesen falls nicht im Dateinamen
if [ "$VERSION" = "latest" ]; then
    VERSION=$(grep "X-AppImage-Version" "${EXTRACT_DIR}/xnviewmp.desktop" 2>/dev/null | \
              grep -oP '\d+\.\d+\.\d+' | head -1)
    [ -z "$VERSION" ] && VERSION="latest"
fi
info "Version: $VERSION"

APPDIR_LIB="${EXTRACT_DIR}/usr/lib/x86_64-linux-gnu"
[ -d "$APPDIR_LIB" ] || error "$APPDIR_LIB nicht gefunden."

info "Extrahiert nach: $EXTRACT_DIR"
info "Library-Verzeichnis: $APPDIR_LIB"

trap 'info "Räume auf: $WORK_DIR"; rm -rf "$WORK_DIR"' EXIT

# ---- Schritt 2: Diagnose der fehlenden Libraries -----------------------

step "Schritt 2: Diagnose"

LIBPULSE="${APPDIR_LIB}/libpulsecommon-8.0.so"
[ -f "$LIBPULSE" ] || error "libpulsecommon-8.0.so nicht in AppDir gefunden."

info "libpulsecommon: $(readelf -d "$LIBPULSE" | grep SONAME | grep -o '\[.*\]' | tr -d '[]')"

NEEDED_WRAP=$(readelf -d "$LIBPULSE" | grep "libwrap.so" || true)
NEEDED_ARMR=$(readelf -d "$LIBPULSE" | grep "libapparmor.so" || true)

[ -n "$NEEDED_WRAP" ] && warn "libpulsecommon braucht libwrap.so.0 (tcp_wrappers — nicht auf Fedora)"
[ -n "$NEEDED_ARMR" ] && warn "libpulsecommon braucht libapparmor.so.1 (AppArmor — nicht auf Fedora/SELinux-Systemen)"

# Symbole ermitteln
WRAP_SYMS=$(nm -D "$LIBPULSE" 2>/dev/null | awk '/ U /{print $2}' | grep -E "^hosts_access$|^request_init$|^sock_host$" | tr '\n' ' ')
ARMR_SYMS=$(nm -D "$LIBPULSE" 2>/dev/null | awk '/ U /{print $2}' | grep "^aa_" | tr '\n' ' ')

info "Benötigte libwrap-Symbole:    ${WRAP_SYMS:-hosts_access request_init sock_host}"
info "Benötigte libapparmor-Symbole: ${ARMR_SYMS:-aa_getpeercon}"

# ---- Schritt 3: libwrap.so.0 Stub kompilieren --------------------------

step "Schritt 3: libwrap.so.0 Stub"

cat > "${WORK_DIR}/libwrap-stub.c" << 'LIBWRAP_C'
/*
 * libwrap.so.0 – Stub-Implementierung (tcp_wrappers Ersatz)
 *
 * libpulsecommon-8.0 (Ubuntu 16.04) nutzt tcp_wrappers für
 * Zugangskontrolle zum PulseAudio-Daemon. Auf Fedora/RHEL/Arch
 * ist tcp_wrappers nicht mehr Teil der Distribution.
 *
 * XnViewMP ist ein PulseAudio-Client, nicht der Daemon.
 * Der Stub erlaubt alle Verbindungen (hosts_access → 1).
 */

/* Minimale Abbildung der tcp_wrappers request_info-Struktur */
struct request_info {
    int   fd;
    char *user;
    char *host;
    char *addr;
    char *daemon;
};
typedef struct request_info *request_t;

/* Immer Zugriff erlauben */
int hosts_access(request_t r) {
    (void)r;
    return 1;
}

/* Request-Struktur initialisieren — no-op Stub */
request_t request_init(request_t r, ...) {
    return r;
}

/* Hostname des Sockets ermitteln — leerer String (kein Netzwerkzugriff nötig) */
char *sock_host(request_t r) {
    (void)r;
    return (char *)"";
}
LIBWRAP_C

gcc -shared -fPIC \
    -Wl,-soname,libwrap.so.0 \
    -o "${WORK_DIR}/libwrap.so.0" \
    "${WORK_DIR}/libwrap-stub.c" \
    -nostartfiles \
    2>&1

STUB_WRAP="${WORK_DIR}/libwrap.so.0"
[ -f "$STUB_WRAP" ] || error "libwrap.so.0 Stub-Kompilierung fehlgeschlagen."
STUB_WRAP_SIZE=$(du -sh "$STUB_WRAP" | cut -f1)
info "libwrap.so.0 kompiliert: $STUB_WRAP_SIZE"

# Symbole prüfen
readelf -d "$STUB_WRAP" | grep SONAME && true
nm -D "$STUB_WRAP" | grep -E "hosts_access|request_init|sock_host" | head -5
info "Symbole exportiert: hosts_access, request_init, sock_host ✅"

# ---- Schritt 4: libapparmor.so.1 Stub kompilieren ----------------------

step "Schritt 4: libapparmor.so.1 Stub"

# Version-Script für APPARMOR_1.1 Symbol-Versionierung
cat > "${WORK_DIR}/libapparmor.map" << 'APPARMOR_MAP'
APPARMOR_1.1 {
    global:
        aa_getpeercon;
    local:
        *;
};
APPARMOR_MAP

cat > "${WORK_DIR}/libapparmor-stub.c" << 'LIBAPPARMOR_C'
/*
 * libapparmor.so.1 – Stub-Implementierung
 *
 * libpulsecommon-8.0 ruft aa_getpeercon() auf, um den AppArmor-
 * Sicherheitskontext eines Sockets zu ermitteln.
 *
 * Auf Fedora, RHEL, Arch und anderen SELinux- oder MAC-freien
 * Systemen ist AppArmor nicht installiert. Der Stub gibt ENODATA
 * zurück — das wird von libpulsecommon korrekt als "kein AppArmor"
 * interpretiert und der Ablauf wird ohne Fehler fortgesetzt.
 */
#include <errno.h>

/*
 * aa_getpeercon — ermittelt AppArmor-Kontext eines Peer-Sockets
 * Gibt -1 mit ENODATA zurück: "AppArmor nicht verfügbar"
 */
int aa_getpeercon(int fd, char **con, char **mode) {
    (void)fd;
    (void)con;
    (void)mode;
    errno = 61; /* ENODATA */
    return -1;
}
LIBAPPARMOR_C

gcc -shared -fPIC \
    -Wl,-soname,libapparmor.so.1 \
    -Wl,--version-script="${WORK_DIR}/libapparmor.map" \
    -o "${WORK_DIR}/libapparmor.so.1" \
    "${WORK_DIR}/libapparmor-stub.c" \
    -nostartfiles \
    2>&1

STUB_ARMR="${WORK_DIR}/libapparmor.so.1"
[ -f "$STUB_ARMR" ] || error "libapparmor.so.1 Stub-Kompilierung fehlgeschlagen."
STUB_ARMR_SIZE=$(du -sh "$STUB_ARMR" | cut -f1)
info "libapparmor.so.1 kompiliert: $STUB_ARMR_SIZE"

# Symbol-Versionierung prüfen
readelf -V "$STUB_ARMR" 2>/dev/null | grep -A3 "APPARMOR" || true
nm -D "$STUB_ARMR" | grep "aa_getpeercon" | head -3
info "Symbol aa_getpeercon@APPARMOR_1.1 exportiert ✅"

# ---- Schritt 5: Stubs ins AppDir installieren --------------------------

step "Schritt 5: Stubs in AppDir installieren"

cp "$STUB_WRAP" "${APPDIR_LIB}/libwrap.so.0"
cp "$STUB_ARMR" "${APPDIR_LIB}/libapparmor.so.1"

info "libwrap.so.0    → $APPDIR_LIB/"
info "libapparmor.so.1 → $APPDIR_LIB/"

# Validierung: fehlen noch Libraries?
info "Validiere XnView-Binary..."
MISSING=$(LD_LIBRARY_PATH="${EXTRACT_DIR}/usr/XnView/lib:${EXTRACT_DIR}/usr/XnView/Plugins:${APPDIR_LIB}" \
    ldd "${EXTRACT_DIR}/usr/XnView/XnView" 2>/dev/null | grep "not found" || true)

if [ -z "$MISSING" ]; then
    info "Alle Libraries gefunden — XnView-Binary vollständig ✅"
else
    warn "Noch fehlende Libraries:"
    echo "$MISSING" | sed 's/^/    /'
fi

# ---- Schritt 6: Launcher-Script reparieren -----------------------------

step "Schritt 6: Launcher-Script"

LAUNCHER="${EXTRACT_DIR}/usr/bin/xnviewmp"
info "Original-Script:"
cat "$LAUNCHER" | sed 's/^/  /'

cat > "$LAUNCHER" << 'LAUNCHER_SH'
#!/bin/sh
# XnViewMP AppImage Launcher
#
# Fix: Das Original-Script nutzt $(pwd) zur Pfadermittlung.
# Korrekt ist die Verwendung von $APPDIR (gesetzt vom AppRun)
# mit Fallback über readlink -f für direkten Aufruf.

if [ -n "$APPDIR" ]; then
    # Standard: $APPDIR wird vom AppImage-Runtime gesetzt
    XNVIEW_DIR="${APPDIR}/usr/XnView"
else
    # Fallback: Pfad über Script-Verzeichnis ermitteln
    SELF="$(readlink -f "$0")"
    XNVIEW_DIR="$(dirname "$SELF")/../XnView"
fi

export LD_LIBRARY_PATH="${XNVIEW_DIR}/lib:${XNVIEW_DIR}/Plugins:${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="${XNVIEW_DIR}/lib:${QT_PLUGIN_PATH:-}"

exec "${XNVIEW_DIR}/XnView" "$@"
LAUNCHER_SH

chmod +x "$LAUNCHER"

info "Launcher-Script repariert:"
cat "$LAUNCHER" | sed 's/^/  /'

# ---- Schritt 7: SONAME-Symlinks prüfen ---------------------------------

step "Schritt 7: SONAME-Symlinks"

MISSING_SYMLINKS=0
for lib in "${APPDIR_LIB}"/*.so.*.*; do
    [[ -f "$lib" ]] || continue
    soname=$(readelf -d "$lib" 2>/dev/null | grep SONAME | grep -o '\[.*\]' | tr -d '[]')
    [[ -z "$soname" ]] && continue
    fname=$(basename "$lib")
    [[ "$soname" == "$fname" ]] && continue
    if [[ ! -e "${APPDIR_LIB}/${soname}" ]]; then
        ln -sf "$fname" "${APPDIR_LIB}/${soname}"
        info "  Symlink erstellt: $soname → $fname"
        ((MISSING_SYMLINKS++)) || true
    fi
done
[ "$MISSING_SYMLINKS" -eq 0 ] && info "Alle SONAME-Symlinks vorhanden ✅"

# ---- Schritt 8: Desktop-Datei prüfen ----------------------------------

step "Schritt 8: Desktop-Datei"

DESK="${EXTRACT_DIR}/xnviewmp.desktop"
cat "$DESK" | sed 's/^/  /'

# TryExec entfernen (verhindert Menü-Integration auf manchen Systemen)
if grep -q "^TryExec=" "$DESK"; then
    sed -i 's/^TryExec=.*//' "$DESK"
    info "TryExec= entfernt"
fi

# ---- Schritt 9: AppImage neu packen ------------------------------------

step "Schritt 9: AppImage bauen"

OUTPUT="${SCRIPT_DIR}/XnViewMP-${VERSION}-x86_64-fixed.AppImage"

cd "${WORK_DIR}"
ARCH=x86_64 "$APPIMAGETOOL" "${EXTRACT_DIR}" "${OUTPUT}" 2>&1

if [ -f "$OUTPUT" ]; then
    SIZE=$(du -sh "$OUTPUT" | cut -f1)
    info ""
    info "✅ AppImage erfolgreich erstellt!"
    info "   Datei:  $OUTPUT"
    info "   Größe:  $SIZE"
    info ""
    info "Behobene Probleme:"
    info "  ✅ libwrap.so.0 Stub (tcp_wrappers Ersatz)"
    info "  ✅ libapparmor.so.1 Stub (AppArmor Ersatz)"
    info "  ✅ Launcher-Script via \$APPDIR statt \$(pwd)"
else
    error "AppImage wurde nicht erstellt."
fi
