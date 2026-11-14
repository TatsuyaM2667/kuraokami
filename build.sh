#!/bin/sh
# Build kuraokami with Odin. Zig is used only as the C toolchain for Odin's vendored
# kb_text_shape (built once into the Odin install). Runtime libs: SDL3, freetype2, fontconfig, OpenGL 3.3.
set -e
cd "$(dirname "$0")"
ZIG=${ZIG:-zig}
ODIN_ROOT=$(odin root)
KB="$ODIN_ROOT/vendor/kb_text_shape/lib/kb_text_shape.a"
if [ ! -f "$KB" ]; then
	echo "building vendor:kb_text_shape with zig cc"
	CC="$ZIG cc" AR="$ZIG ar" sh "$ODIN_ROOT/vendor/kb_text_shape/src/build_unix.sh"
fi
mkdir -p lib
# Some distros only ship libSDL3.so.0 (no dev symlink): link against it explicitly.
[ -e lib/libSDL3.so ] || ln -sf "$(ls /usr/lib/libSDL3.so* /usr/lib64/libSDL3.so* /usr/lib/*-linux-gnu/libSDL3.so* /opt/homebrew/lib/libSDL3*.dylib 2>/dev/null | head -1)" lib/libSDL3.so
MODE=${1:-release}
if [ "$MODE" = debug ]; then OPT="-debug -o:none"; else OPT="-o:speed -no-bounds-check"; fi
# Cap zlib/PNG output so a compressed image from the PTY cannot inflate into gigabytes.
odin build src -out:kuraokami $OPT -define:COMPRESS_OUTPUT_ALLOCATE_MAX=268435456 -extra-linker-flags:"-L$(pwd)/lib"
echo "built ./kuraokami ($(du -h kuraokami | cut -f1))"
