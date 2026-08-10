#!/usr/bin/env bash
set -euo pipefail

UUID="appindicatorsupport@rgcjonas.gmail.com"
JS="${HOME}/.local/share/gnome-shell/extensions/${UUID}/indicatorStatusIcon.js"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${HOME}/Downloads/indicatorStatusIcon.js.before-all-clicks-${STAMP}"

echo "== AppIndicator: force LEFT/MIDDLE/RIGHT through SecondaryActivate =="
echo

if [[ ! -f "$JS" ]]; then
    echo "ERROR: File not found:"
    echo "  $JS"
    exit 1
fi

echo "[1/5] Backup..."
cp "$JS" "$BACKUP"
echo "  $BACKUP"
echo

echo "[2/5] Replacing vfunc_button_press_event()..."

python3 - "$JS" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

start = s.find("    vfunc_button_press_event(event) {")
end = s.find("\n    vfunc_scroll_event(event) {", start)

if start < 0 or end < 0:
    raise SystemExit("ERROR: Could not locate vfunc_button_press_event()")

new_handler = r"""    vfunc_button_press_event(event) {
        if (this._waitDoubleClickPromise)
            this._waitDoubleClickPromise.cancel();

        // RadioTray test: LEFT, MIDDLE and RIGHT all use the exact
        // SecondaryActivate(x,y) path that already works for middle-click.
        if (event.get_button() === Clutter.BUTTON_PRIMARY ||
            event.get_button() === Clutter.BUTTON_MIDDLE ||
            event.get_button() === Clutter.BUTTON_SECONDARY) {
            if (Main.panel.menuManager.activeMenu)
                Main.panel.menuManager._closeMenu(
                    true, Main.panel.menuManager.activeMenu);

            this._indicator.secondaryActivate(
                event.get_time(), ...event.get_coords());

            return Clutter.EVENT_STOP;
        }

        return Clutter.EVENT_PROPAGATE;
    }
"""

s = s[:start] + new_handler + s[end:]

if "this._clickGesture?.set_enabled(false);" not in s:
    init_start = s.find("class IndicatorStatusIcon extends BaseStatusIcon")
    super_start = s.find("super._init(", init_start)
    semi = s.find(";", super_start)

    if init_start < 0 or super_start < 0 or semi < 0:
        raise SystemExit("ERROR: Could not locate IndicatorStatusIcon _init()")

    insertion = """
        // Clicks are handled explicitly by vfunc_button_press_event().
        this._clickGesture?.set_enabled(false);
"""
    s = s[:semi + 1] + insertion + s[semi + 1:]

p.write_text(s.rstrip("\n") + "\n")
PY

echo "[3/5] Verify installed code..."
grep -n -A24 -B3 "RadioTray test: LEFT, MIDDLE and RIGHT" "$JS"
echo
grep -n "this._clickGesture?.set_enabled(false)" "$JS"

echo
echo "[4/5] Reload extension..."
gnome-extensions disable "$UUID" || true
sleep 2
gnome-extensions enable "$UUID"
sleep 2

echo
echo "[5/5] DONE"
echo
echo "After GNOME Shell loads this file:"
echo "  LEFT   -> SecondaryActivate(x,y)"
echo "  MIDDLE -> SecondaryActivate(x,y)"
echo "  RIGHT  -> SecondaryActivate(x,y)"
echo
echo "There is NO this.menu.toggle() and NO double-click logic in the handler."
echo "The existing scroll handler is untouched."
echo
echo "Backup:"
echo "  $BACKUP"
echo
echo "IMPORTANT:"
echo "This test changes click behaviour for all indicators handled by this extension."
echo "Once verified, it can be narrowed back to RadioTray only."
echo
echo "On Wayland, log out/in once after running this so GNOME Shell definitely"
echo "loads the replaced JavaScript."
