#!/bin/sh
# Build kuraokami (Linux / FreeBSD / OpenBSD / NetBSD / macOS).
# Needs: odin, zig (C toolchain for the vendored kb_text_shape; falls back to cc),
# and SDL3, freetype2, fontconfig, OpenGL 3.3 at runtime.
# Nothing outside this directory is modified (works with read-only distro Odin packages).
set -e
cd "$(dirname "$0")"
MODE=${1:-release}

if command -v "${ZIG:-zig}" >/dev/null 2>&1; then
	CC="${ZIG:-zig} cc"
	AR="${ZIG:-zig} ar"
else
	CC=${CC:-cc}
	AR=${AR:-ar}
	echo "zig not found: building kb_text_shape with $CC"
fi

mkdir -p lib
if [ ! -f lib/kb_text_shape.a ] || [ third_party/kbts/src/kb_text_shape.h -nt lib/kb_text_shape.a ]; then
	echo "compiling third_party/kbts (kb_text_shape)"
	# -g0: zig cc emits debug info by default (+600 KB in the final binary)
	$CC -O2 -g0 -fPIC -c third_party/kbts/src/kb_text_shape.c -o lib/kb_text_shape.o
	rm -f lib/kb_text_shape.a
	$AR rcs lib/kb_text_shape.a lib/kb_text_shape.o
	rm -f lib/kb_text_shape.o
fi

# Library search paths: pkg-config first, then the usual prefixes (BSDs/Homebrew use /usr/local or /opt).
LDIRS=""
for pc in sdl3 freetype2 fontconfig; do
	d=$(pkg-config --variable=libdir "$pc" 2>/dev/null || true)
	[ -n "$d" ] && LDIRS="$LDIRS -L$d"
done
for d in /usr/local/lib /usr/pkg/lib /opt/homebrew/lib /usr/X11R6/lib; do
	[ -d "$d" ] && LDIRS="$LDIRS -L$d"
done

# Some distros ship only libSDL3.so.0 without the dev symlink: link against it explicitly.
if [ ! -e lib/libSDL3.so ] && [ "$(uname)" != Darwin ]; then
	so=""
	for d in $(echo "$LDIRS" | sed 's/-L//g') /usr/lib /usr/lib64 /usr/lib/*-linux-gnu; do
		for f in "$d"/libSDL3.so "$d"/libSDL3.so.*; do
			[ -e "$f" ] && { so=$f; break 2; }
		done
	done
	[ -n "$so" ] && ln -sf "$so" lib/libSDL3.so
fi

if [ "$MODE" = debug ]; then OPT="-debug -o:none"; else OPT="-o:speed -no-bounds-check"; fi
# Cap zlib/PNG output so a compressed image from the PTY cannot inflate into gigabytes.
odin build src -out:kuraokami $OPT -define:COMPRESS_OUTPUT_ALLOCATE_MAX=268435456 \
	-extra-linker-flags:"-L$(pwd)/lib $LDIRS"
echo "built ./kuraokami ($(du -h kuraokami | cut -f1))"
