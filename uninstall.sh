#!/bin/sh
PREFIX=${PREFIX:-$HOME/.local}
rm -f "$PREFIX/bin/kuraokami" "$PREFIX/share/applications/kuraokami.desktop" "$PREFIX/share/icons/hicolor/scalable/apps/kuraokami.svg"
echo "removed kuraokami from $PREFIX"
