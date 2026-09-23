#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT}/build-fixed"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "ERROR: Run this script as your normal desktop user, not with sudo." >&2
    exit 1
fi

cd "$ROOT"

echo "[1/4] Applying the RadioTray-only GNOME AppIndicator bridge..."
"${ROOT}/extras/gnome-appindicator/fix-radiotray-appindicator.sh"

echo
echo "[2/4] Configuring clean Release build..."
rm -rf "$BUILD_DIR"
cmake -S "$ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release

echo
echo "[3/4] Building package..."
cmake --build "$BUILD_DIR" --target package --parallel "$(nproc)"

mapfile -t DEBS < <(find "$BUILD_DIR" -type f -name 'radiotray-ng*.deb' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
if (( ${#DEBS[@]} == 0 )); then
    echo "ERROR: Build completed but no radiotray-ng .deb was found under $BUILD_DIR" >&2
    exit 1
fi

DEB="${DEBS[0]}"
echo
echo "[4/4] Installing: $DEB"
sudo dpkg -i "$DEB" || sudo apt-get -f install

echo
echo "Installed. On GNOME Wayland, log out and back in once before testing the tray icon."
