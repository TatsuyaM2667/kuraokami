#!/bin/sh
# Build kuraokami. Needs: odin, gcc, freetype2, fontconfig, zlib, SDL3 (runtime lib), OpenGL 3.3.
set -e
cd "$(dirname "$0")"
mkdir -p lib
[ -e lib/libSDL3.so ] || ln -sf "$(ls /usr/lib/libSDL3.so* /usr/lib64/libSDL3.so* /usr/lib/x86_64-linux-gnu/libSDL3.so* 2>/dev/null | head -1)" lib/libSDL3.so
gcc -O2 -c csrc/shim.c -o lib/shim.o $(pkg-config --cflags freetype2 fontconfig harfbuzz)
ar rcs lib/libkshim.a lib/shim.o
MODE=${1:-release}
if [ "$MODE" = debug ]; then OPT="-debug -o:none"; else OPT="-o:speed -no-bounds-check"; fi
odin build src -out:kuraokami $OPT -extra-linker-flags:"-L$(pwd)/lib -Wl,-rpath,/usr/lib"
echo "built ./kuraokami ($(du -h kuraokami | cut -f1))"
