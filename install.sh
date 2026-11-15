#!/bin/sh
# Install kuraokami: binary, launcher entries (.desktop) and icon.
#   ./install.sh                          -> ~/.local (no root)
#   PREFIX=/usr/local sudo ./install.sh   -> system-wide
#   DESTDIR=$pkgdir PREFIX=/usr ./install.sh   (packaging, e.g. PKGBUILD)
# POSIX sh + POSIX tools only (BSD `install` has no -D, so directories are created explicitly).
set -e
cd "$(dirname "$0")"
[ -x kuraokami ] || ./build.sh
PREFIX=${PREFIX:-$HOME/.local}
DESTDIR=${DESTDIR:-}
ROOT="$DESTDIR$PREFIX"

put() { # put <mode> <src> <dest>
	mkdir -p "$(dirname "$3")"
	cp "$2" "$3"
	chmod "$1" "$3"
}

put 755 kuraokami "$ROOT/bin/kuraokami"
put 644 assets/kuraokami.svg "$ROOT/share/icons/hicolor/scalable/apps/kuraokami.svg"
for f in kuraokami kuraokami-quick; do
	mkdir -p "$ROOT/share/applications"
	sed "s|^Exec=kuraokami|Exec=$PREFIX/bin/kuraokami|; s|^TryExec=kuraokami|TryExec=$PREFIX/bin/kuraokami|" \
		"assets/$f.desktop" > "$ROOT/share/applications/$f.desktop"
	chmod 644 "$ROOT/share/applications/$f.desktop"
done

# Caches are refreshed by the package manager when packaging (DESTDIR set).
if [ -z "$DESTDIR" ]; then
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$PREFIX/share/applications" || true
	command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" || true
fi
echo "installed: $ROOT/bin/kuraokami (+ launcher entries and icon)"
