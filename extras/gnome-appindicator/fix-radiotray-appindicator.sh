#!/usr/bin/env bash
set -euo pipefail

UUID="appindicatorsupport@rgcjonas.gmail.com"
USER_EXT="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
SYSTEM_EXT="/usr/share/gnome-shell/extensions/${UUID}"
JS_REL="indicatorStatusIcon.js"
MARKER="RadioTray-NG native-menu click bridge v5"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    die "Run this as your normal desktop user, not with sudo."
fi

say "== RadioTray-NG GNOME AppIndicator click fix v5 =="
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
    die "GNOME AppIndicator extension not found."
fi

JS="${EXT_DIR}/${JS_REL}"
SYSTEM_JS="${SYSTEM_EXT}/${JS_REL}"
BACKUP_DIR="${EXT_DIR}/.radiotray-ng-backups"
BACKUP="${BACKUP_DIR}/indicatorStatusIcon.js.${STAMP}"
TMP="${JS}.radiotray-v5.tmp"

mkdir -p "$BACKUP_DIR"
cp -a "$JS" "$BACKUP"
say "Backup of current file: $BACKUP"

# Always rebuild the patched JS from a pristine source.  Earlier bridge
# revisions were incremental and could leave fragments behind when migrating.
if [[ -f "$SYSTEM_JS" ]]; then
    BASE="$SYSTEM_JS"
    say "Pristine base: $BASE"
else
    BASE=""
    while IFS= read -r candidate; do
        if ! grep -q "RadioTray-NG native-menu click bridge" "$candidate"; then
            BASE="$candidate"
            break
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'indicatorStatusIcon.js.*' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)

    [[ -n "$BASE" ]] || die "No pristine indicatorStatusIcon.js is available to rebuild from."
    say "Pristine backup base: $BASE"
fi

cp -a "$BASE" "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()

marker = "RadioTray-NG native-menu click bridge v5"
press_sig = "    vfunc_button_press_event(event) {"
scroll_sig = "    vfunc_scroll_event(event) {"

press_start = s.find(press_sig)
scroll_start = s.find(scroll_sig)

if press_start < 0:
    raise SystemExit("ERROR: pristine extension has no vfunc_button_press_event(event)")
if scroll_start < 0 or scroll_start <= press_start:
    raise SystemExit("ERROR: pristine extension has no expected vfunc_scroll_event(event)")

# The pristine base must not already contain one of our earlier patches.
if "RadioTray-NG native-menu click bridge" in s:
    raise SystemExit("ERROR: selected base is not pristine")

press_insert = press_start + len(press_sig)
press_block = r'''
        // RadioTray-NG native-menu click bridge v5
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

            // Stop GNOME's stock primary double-click and secondary DBusMenu
            // paths for RadioTray-NG.  We complete LEFT/RIGHT on release.
            if (button === Clutter.BUTTON_PRIMARY ||
                button === Clutter.BUTTON_SECONDARY ||
                button === Clutter.BUTTON_MIDDLE)
                return Clutter.EVENT_STOP;
        }
'''
s = s[:press_insert] + press_block + s[press_insert:]

# Re-locate scroll after the insertion.
scroll_start = s.find(scroll_sig)
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

                // Bypass AppIndicator.open() entirely.  Its normal primary
                // path is deliberately double-click aware.  RadioTray-NG
                // wants one LEFT or RIGHT click to open its native GTK menu.
                this._indicator._proxy.ActivateAsync(
                    x, y, this._indicator.cancellable).catch(logError);

                return Clutter.EVENT_STOP;
            }
        }

        return Clutter.EVENT_PROPAGATE;
    }

'''
s = s[:scroll_start] + release_method + s[scroll_start:]

# Older extension versions can have PanelMenu's own click gesture enabled.
# Disable it only for RadioTray-NG when upstream has not already disabled it.
if "this._clickGesture?.set_enabled(false);" not in s:
    assign = "        this._indicator = indicator;"
    idx = s.find(assign)
    if idx >= 0:
        end = idx + len(assign)
        guard = r'''

        // RadioTray-NG owns its mouse clicks.
        if (String(this._indicator?.id ?? '').toLowerCase() === 'radiotray-ng')
            this._clickGesture?.set_enabled(false);
'''
        s = s[:end] + guard + s[end:]

path.write_text(s.rstrip("\n") + "\n")
PY

# Structural checks before replacing the live extension file.
grep -qF "$MARKER" "$TMP" || die "V5 marker missing from generated JavaScript."
grep -q "vfunc_button_release_event(event)" "$TMP" || die "V5 release handler missing."
grep -q "_proxy.ActivateAsync" "$TMP" || die "V5 direct Activate call missing."

# Earlier migration fragments must not survive because TMP was built from a
# pristine base.
if grep -q "native-menu click bridge v[1234]" "$TMP"; then
    die "Old RadioTray bridge fragment found in generated JavaScript."
fi

mv "$TMP" "$JS"

say
say "RadioTray-NG click policy v5 installed from a pristine AppIndicator file:"
say "  LEFT   -> direct Activate on first release"
say "  RIGHT  -> direct Activate on first release"
say "  MIDDLE -> ignored"
say "  SCROLL -> original AppIndicator scroll handler"
say "Modified: $JS"

ACTIVE_PATH=""
if command -v gnome-extensions >/dev/null 2>&1; then
    ACTIVE_PATH="$(gnome-extensions info "$UUID" 2>/dev/null | sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' | head -n1 || true)"
fi
[[ -n "$ACTIVE_PATH" ]] && say "GNOME extension path: $ACTIVE_PATH"

say
say "Reloading the extension..."
gnome-extensions disable "$UUID" 2>/dev/null || true
sleep 1
if ! gnome-extensions enable "$UUID" 2>/dev/null; then
    say "GNOME could not enable the extension in this running Wayland session."
    say "Log out and back in; the on-disk JavaScript has been repaired."
else
    say "Extension enable request accepted."
fi

say
say "On GNOME Wayland, log out and back in once before testing."
say "Expected: LEFT/RIGHT single click -> native menu; MIDDLE -> no action; scroll -> volume."
