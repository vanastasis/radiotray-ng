#!/usr/bin/env bash
set -euo pipefail

UUID="appindicatorsupport@rgcjonas.gmail.com"
USER_EXT="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
SYSTEM_EXT="/usr/share/gnome-shell/extensions/${UUID}"
JS_REL="indicatorStatusIcon.js"
MARKER_V1="RadioTray-NG native-menu click bridge"
MARKER_V2="RadioTray-NG native-menu click bridge v2"
MARKER_V3="RadioTray-NG native-menu click bridge v3"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    die "Run this as your normal desktop user, not with sudo."
fi

say "== RadioTray-NG GNOME AppIndicator click fix =="
say

if [[ -f "${USER_EXT}/${JS_REL}" ]]; then
    EXT_DIR="$USER_EXT"
elif [[ -f "${SYSTEM_EXT}/${JS_REL}" ]]; then
    say "Creating a per-user copy of the installed AppIndicator extension..."
    mkdir -p "$(dirname "$USER_EXT")"
    rm -rf "${USER_EXT}.new"
    cp -a "$SYSTEM_EXT" "${USER_EXT}.new"
    rm -rf "$USER_EXT"
    mv "${USER_EXT}.new" "$USER_EXT"
    EXT_DIR="$USER_EXT"
else
    die "GNOME AppIndicator extension not found. Install 'AppIndicator and KStatusNotifierItem Support' first."
fi

JS="${EXT_DIR}/${JS_REL}"
BACKUP_DIR="${EXT_DIR}/.radiotray-ng-backups"
BACKUP="${BACKUP_DIR}/indicatorStatusIcon.js.${STAMP}"

if grep -q "RadioTray test: LEFT, MIDDLE and RIGHT" "$JS"; then
    die "The old all-indicators test patch is installed in ${JS}. Restore its backup/original extension first, then run this script again."
fi

if grep -qF "$MARKER_V3" "$JS"; then
    say "Already patched with v3: $JS"
    say "No changes required."
    exit 0
fi

mkdir -p "$BACKUP_DIR"
cp -a "$JS" "$BACKUP"
say "Backup: $BACKUP"

python3 - "$JS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()

marker_v3 = "RadioTray-NG native-menu click bridge v3"
press_sig = "    vfunc_button_press_event(event) {"
scroll_sig = "    vfunc_scroll_event(event) {"

if press_sig not in s:
    raise SystemExit("ERROR: Could not find vfunc_button_press_event(event) in indicatorStatusIcon.js")
if scroll_sig not in s:
    raise SystemExit("ERROR: Could not find vfunc_scroll_event(event) in indicatorStatusIcon.js")

old_v1 = r'''
        // RadioTray-NG native-menu click bridge
        // RadioTray-NG owns its GTK popup menu.  Do not open GNOME Shell's
        // DBusMenu shim for this one indicator; send the click directly to
        // SecondaryActivate(x, y), which RadioTray-NG handles in direct_sni.cpp.
        if (this._indicator?.id === 'radiotray-ng') {
            if (this._waitDoubleClickPromise)
                this._waitDoubleClickPromise.cancel();

            const button = event.get_button();
            if (button === Clutter.BUTTON_PRIMARY ||
                button === Clutter.BUTTON_MIDDLE ||
                button === Clutter.BUTTON_SECONDARY) {
                if (Main.panel.menuManager.activeMenu)
                    Main.panel.menuManager._closeMenu(
                        true, Main.panel.menuManager.activeMenu);

                this._indicator.secondaryActivate(
                    event.get_time(), ...event.get_coords());
                return Clutter.EVENT_STOP;
            }
        }
'''

old_v2 = r'''
        // RadioTray-NG native-menu click bridge v2
        // PRIMARY and SECONDARY open RadioTray-NG's native GTK menu on the
        // first click. MIDDLE is intentionally consumed and does nothing.
        if (this._indicator?.id === 'radiotray-ng') {
            if (this._waitDoubleClickPromise)
                this._waitDoubleClickPromise.cancel();

            const button = event.get_button();

            if (button === Clutter.BUTTON_PRIMARY ||
                button === Clutter.BUTTON_SECONDARY) {
                if (Main.panel.menuManager.activeMenu)
                    Main.panel.menuManager._closeMenu(
                        true, Main.panel.menuManager.activeMenu);

                this._indicator.open(
                    ...event.get_coords(), event.get_time()).catch(logError);
                return Clutter.EVENT_STOP;
            }

            if (button === Clutter.BUTTON_MIDDLE)
                return Clutter.EVENT_STOP;
        }
'''

for old in (old_v1, old_v2):
    if old in s:
        s = s.replace(old, "", 1)

# GTK popup menus opened while the mouse button is still physically held can
# immediately consume the corresponding release and disappear.  That made a
# "single click" look like it needed a double click.  Consume the press here,
# remember it, and invoke Activate only on the matching release.
press_start = s.find(press_sig)
press_insert = press_start + len(press_sig)
press_block = r'''
        // RadioTray-NG native-menu click bridge v3
        // Arm LEFT/RIGHT on press, open on release. This avoids GTK consuming
        // the initiating button release and immediately closing its native menu.
        if (this._indicator?.id === 'radiotray-ng') {
            if (this._waitDoubleClickPromise)
                this._waitDoubleClickPromise.cancel();

            const button = event.get_button();

            if (button === Clutter.BUTTON_PRIMARY ||
                button === Clutter.BUTTON_SECONDARY) {
                this._radiotrayMenuButton = button;
                return Clutter.EVENT_STOP;
            }

            if (button === Clutter.BUTTON_MIDDLE) {
                delete this._radiotrayMenuButton;
                return Clutter.EVENT_STOP;
            }
        }
'''
s = s[:press_insert] + press_block + s[press_insert:]

release_method = r'''
    vfunc_button_release_event(event) {
        if (this._indicator?.id === 'radiotray-ng') {
            const button = event.get_button();

            if (button === Clutter.BUTTON_MIDDLE) {
                delete this._radiotrayMenuButton;
                return Clutter.EVENT_STOP;
            }

            if ((button === Clutter.BUTTON_PRIMARY ||
                 button === Clutter.BUTTON_SECONDARY) &&
                this._radiotrayMenuButton === button) {
                delete this._radiotrayMenuButton;

                if (Main.panel.menuManager.activeMenu)
                    Main.panel.menuManager._closeMenu(
                        true, Main.panel.menuManager.activeMenu);

                this._indicator.open(
                    ...event.get_coords(), event.get_time()).catch(logError);
                return Clutter.EVENT_STOP;
            }
        }

        return Clutter.EVENT_PROPAGATE;
    }

'''

scroll_start = s.find(scroll_sig)
if scroll_start < 0:
    raise SystemExit("ERROR: Could not locate vfunc_scroll_event(event)")
s = s[:scroll_start] + release_method + s[scroll_start:]

# Current upstream AppIndicator already disables PanelMenu's click gesture.
# Keep a targeted fallback for older extension versions.
if "this._clickGesture?.set_enabled(false);" not in s:
    assign = "        this._indicator = indicator;"
    idx = s.find(assign)
    if idx >= 0:
        end = idx + len(assign)
        guard = r'''

        // RadioTray-NG owns click handling; keep the Shell click gesture out of its path.
        if (this._indicator?.id === 'radiotray-ng')
            this._clickGesture?.set_enabled(false);
'''
        s = s[:end] + guard + s[end:]

path.write_text(s.rstrip("\n") + "\n")
PY

if ! grep -qF "$MARKER_V3" "$JS"; then
    cp -a "$BACKUP" "$JS"
    die "Patch verification failed; original indicatorStatusIcon.js was restored."
fi

if ! grep -q "vfunc_button_release_event(event)" "$JS"; then
    cp -a "$BACKUP" "$JS"
    die "Release-handler verification failed; original indicatorStatusIcon.js was restored."
fi

say
say "RadioTray-NG click policy v3 installed:"
say "  LEFT   -> native menu on first click (opens on release)"
say "  RIGHT  -> native menu on first click (opens on release)"
say "  MIDDLE -> ignored"
say "Other AppIndicators retain their normal click behaviour."
say "Modified: $JS"

ACTIVE_BEFORE=""
if command -v gnome-extensions >/dev/null 2>&1; then
    ACTIVE_BEFORE="$(gnome-extensions info "$UUID" 2>/dev/null | sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' | head -n1 || true)"
fi
if [[ -n "$ACTIVE_BEFORE" ]]; then
    say "GNOME currently reports extension path: $ACTIVE_BEFORE"
fi

say
say "Reloading the extension..."
gnome-extensions disable "$UUID" 2>/dev/null || true
sleep 1
gnome-extensions enable "$UUID" 2>/dev/null || true
sleep 1

ACTIVE_AFTER=""
if command -v gnome-extensions >/dev/null 2>&1; then
    ACTIVE_AFTER="$(gnome-extensions info "$UUID" 2>/dev/null | sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' | head -n1 || true)"
fi
if [[ -n "$ACTIVE_AFTER" ]]; then
    say "GNOME now reports extension path: $ACTIVE_AFTER"
fi

say
say "GNOME Wayland: log out and back in once so Shell definitely loads the v3 JavaScript."
say "Expected after login: LEFT/RIGHT one click -> native menu; MIDDLE -> no action; scroll -> volume."
say "The hidden DBusMenu bridge keeps the grey popup artefact invisible."
