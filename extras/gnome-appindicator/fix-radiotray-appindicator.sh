#!/usr/bin/env bash
set -euo pipefail

UUID="appindicatorsupport@rgcjonas.gmail.com"
USER_EXT="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
SYSTEM_EXT="/usr/share/gnome-shell/extensions/${UUID}"
JS_REL="indicatorStatusIcon.js"
MARKER="RadioTray-NG native-menu click bridge"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    die "Run this as your normal desktop user, not with sudo."
fi

say "== RadioTray-NG GNOME AppIndicator click fix =="
say

# Prefer a per-user extension so distro-owned files under /usr are not modified.
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

# Detect the old experimental script which replaced the handler for every icon.
if grep -q "RadioTray test: LEFT, MIDDLE and RIGHT" "$JS"; then
    die "The old all-indicators test patch is installed in ${JS}. Restore its backup/original extension first, then run this script again."
fi

if grep -q "$MARKER" "$JS"; then
    say "Already patched: ${JS}"
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
marker = "RadioTray-NG native-menu click bridge"

if marker in s:
    raise SystemExit(0)

sig = "    vfunc_button_press_event(event) {"
start = s.find(sig)
if start < 0:
    raise SystemExit("ERROR: Could not find vfunc_button_press_event(event) in indicatorStatusIcon.js")

insert_at = start + len(sig)
block = r'''
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
s = s[:insert_at] + block + s[insert_at:]

# Older extension releases may still have a PanelMenu click gesture.  Current
# releases already disable it globally.  Add a targeted fallback only when the
# extension does not already disable the gesture itself.
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

if ! grep -qF "$MARKER" "$JS"; then
    cp -a "$BACKUP" "$JS"
    die "Patch verification failed; original indicatorStatusIcon.js was restored."
fi

say
say "Patched only RadioTray-NG. Other AppIndicators retain their normal click behaviour."
say "Modified: $JS"
say
say "Reloading the extension..."
gnome-extensions disable "$UUID" 2>/dev/null || true
sleep 1
gnome-extensions enable "$UUID" 2>/dev/null || true
say
say "GNOME Wayland: log out and back in once so GNOME Shell definitely reloads the JavaScript."
say "After login: LEFT/MIDDLE/RIGHT on RadioTray-NG -> native RadioTray menu; scroll -> volume."
say "The empty grey GNOME popup should no longer appear."
