#!/bin/sh
# Install kuraokami for the current user (no root): binary, launcher entry, icon.
set -e
cd "$(dirname "$0")"
[ -x kuraokami ] || ./build.sh
PREFIX=${PREFIX:-$HOME/.local}
install -Dm755 kuraokami "$PREFIX/bin/kuraokami"
install -Dm644 assets/kuraokami.svg "$PREFIX/share/icons/hicolor/scalable/apps/kuraokami.svg"
sed "s|^Exec=kuraokami|Exec=$PREFIX/bin/kuraokami|; s|^TryExec=kuraokami|TryExec=$PREFIX/bin/kuraokami|" \
    assets/kuraokami.desktop > /tmp/kuraokami.desktop.$$
install -Dm644 /tmp/kuraokami.desktop.$$ "$PREFIX/share/applications/kuraokami.desktop"
rm -f /tmp/kuraokami.desktop.$$
command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" || true
echo "installed: $PREFIX/bin/kuraokami (+ launcher entry and icon)"
