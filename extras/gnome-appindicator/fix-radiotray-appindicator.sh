#!/usr/bin/env bash
set -euo pipefail

UUID="appindicatorsupport@rgcjonas.gmail.com"
USER_EXT="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
SYSTEM_EXT="/usr/share/gnome-shell/extensions/${UUID}"
JS_REL="indicatorStatusIcon.js"
MARKER_V1="RadioTray-NG native-menu click bridge"
MARKER_V2="RadioTray-NG native-menu click bridge v2"
MARKER_V3="RadioTray-NG native-menu click bridge v3"
MARKER_V4="RadioTray-NG native-menu click bridge v4"
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

if grep -qF "$MARKER_V4" "$JS"; then
    say "Already patched with v4: $JS"
    say "No changes required."
    exit 0
fi

mkdir -p "$BACKUP_DIR"
cp -a "$JS" "$BACKUP"
say "Backup: $BACKUP"

python3 - "$JS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text()

press_sig = "    vfunc_button_press_event(event) {"
scroll_sig = "    vfunc_scroll_event(event) {"

if press_sig not in s:
    raise SystemExit("ERROR: Could not find vfunc_button_press_event(event) in indicatorStatusIcon.js")
if scroll_sig not in s:
    raise SystemExit("ERROR: Could not find vfunc_scroll_event(event) in indicatorStatusIcon.js")

# Remove any earlier RadioTray bridge block from the press handler.
press_start = s.find(press_sig)
press_body_start = press_start + len(press_sig)
stock_marker = "        if (this._waitDoubleClickPromise)"
stock_start = s.find(stock_marker, press_body_start)
if stock_start < 0:
    raise SystemExit("ERROR: Could not locate the stock AppIndicator press handler body")

prefix = s[press_body_start:stock_start]
if "RadioTray-NG native-menu click bridge" in prefix:
    prefix = ""
s = s[:press_body_start] + prefix + s[stock_start:]

# Remove the v3 release handler if present.
release_pattern = re.compile(
    r'\n\s{4}vfunc_button_release_event\(event\) \{.*?\n\s{4}\}\n\n',
    re.S)
s, removed = release_pattern.subn("\n", s, count=1)

# V4: detect RadioTray-NG defensively. Some extension builds expose the app
# identity through id, some through title/uniqueId; do not rely on one field.
press_start = s.find(press_sig)
press_insert = press_start + len(press_sig)
press_block = r'''
        // RadioTray-NG native-menu click bridge v4
        const rtId = String(this._indicator?.id ?? '').toLowerCase();
        const rtTitle = String(this._indicator?.title ?? '').toLowerCase();
        const rtUniqueId = String(this._indicator?.uniqueId ?? '').toLowerCase();
        const isRadioTray =
            rtId === 'radiotray-ng' ||
            rtTitle === 'radiotray-ng' ||
            rtUniqueId.includes('radiotray-ng') ||
            rtUniqueId.includes('radiotray');

        if (isRadioTray) {
            if (this._waitDoubleClickPromise)
                this._waitDoubleClickPromise.cancel();

            const button = event.get_button();

            // Consume the press so none of the stock double-click/menu-toggle
            // logic below can run for RadioTray-NG.
            if (button === Clutter.BUTTON_PRIMARY ||
                button === Clutter.BUTTON_SECONDARY ||
                button === Clutter.BUTTON_MIDDLE)
                return Clutter.EVENT_STOP;
        }
'''
s = s[:press_insert] + press_block + s[press_insert:]

# Open on button release. Call the generated D-Bus Activate proxy directly,
# bypassing AppIndicator.open() and its activation-token/double-click policy.
release_method = r'''
    vfunc_button_release_event(event) {
        const rtId = String(this._indicator?.id ?? '').toLowerCase();
        const rtTitle = String(this._indicator?.title ?? '').toLowerCase();
        const rtUniqueId = String(this._indicator?.uniqueId ?? '').toLowerCase();
        const isRadioTray =
            rtId === 'radiotray-ng' ||
            rtTitle === 'radiotray-ng' ||
            rtUniqueId.includes('radiotray-ng') ||
            rtUniqueId.includes('radiotray');

        if (isRadioTray) {
            const button = event.get_button();

            if (button === Clutter.BUTTON_MIDDLE)
                return Clutter.EVENT_STOP;

            if (button === Clutter.BUTTON_PRIMARY ||
                button === Clutter.BUTTON_SECONDARY) {
                if (this._waitDoubleClickPromise)
                    this._waitDoubleClickPromise.cancel();

                if (Main.panel.menuManager.activeMenu)
                    Main.panel.menuManager._closeMenu(
                        true, Main.panel.menuManager.activeMenu);

                const [x, y] = event.get_coords();

                // Direct D-Bus method call: one release => one Activate.
                this._indicator._proxy.ActivateAsync(
                    x, y, this._indicator.cancellable).catch(logError);

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

# Current upstream AppIndicator disables the PanelMenu click gesture globally.
# Retain a targeted fallback for older extension releases.
if "this._clickGesture?.set_enabled(false);" not in s:
    assign = "        this._indicator = indicator;"
    idx = s.find(assign)
    if idx >= 0:
        end = idx + len(assign)
        guard = r'''

        // RadioTray-NG owns click handling; keep the Shell click gesture out of its path.
        if (String(this._indicator?.id ?? '').toLowerCase() === 'radiotray-ng')
            this._clickGesture?.set_enabled(false);
'''
        s = s[:end] + guard + s[end:]

path.write_text(s.rstrip("\n") + "\n")
PY

if ! grep -qF "$MARKER_V4" "$JS"; then
    cp -a "$BACKUP" "$JS"
    die "V4 patch verification failed; original indicatorStatusIcon.js was restored."
fi

if ! grep -q "_proxy.ActivateAsync" "$JS"; then
    cp -a "$BACKUP" "$JS"
    die "Direct Activate verification failed; original indicatorStatusIcon.js was restored."
fi

say
say "RadioTray-NG click policy v4 installed:"
say "  LEFT   -> direct Activate on first button release"
say "  RIGHT  -> direct Activate on first button release"
say "  MIDDLE -> ignored"
say "  SCROLL -> original AppIndicator volume path"
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
say "GNOME Wayland: log out and back in once so Shell definitely loads v4."
say "Expected: LEFT/RIGHT single click -> native menu; MIDDLE -> no action; scroll -> volume."
say "The hidden DBusMenu bridge keeps the grey popup artefact invisible."
