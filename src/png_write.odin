package kuraokami

import "core:hash"

// Minimal PNG writer (stored/uncompressed deflate): debug frame dumps and fetch-logo frames.
// channels: 3 (RGB) or 4 (RGBA). bottom_up: rows come from OpenGL read-back.
png_encode :: proc(px: []u8, w, h, channels: int, bottom_up := false, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	be32 :: proc(out: ^[dynamic]u8, v: u32) {append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
	chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
		be32(out, u32(len(data)))
		start := len(out)
		append(out, kind)
		append(out, ..data)
		be32(out, hash.crc32(out[start:]))
	}
	append(&out, "\x89PNG\r\n\x1a\n")
	ihdr: [13]u8
	ihdr[0], ihdr[1], ihdr[2], ihdr[3] = u8(w >> 24), u8(w >> 16), u8(w >> 8), u8(w)
	ihdr[4], ihdr[5], ihdr[6], ihdr[7] = u8(h >> 24), u8(h >> 16), u8(h >> 8), u8(h)
	ihdr[8], ihdr[9] = 8, 6 if channels == 4 else 2 // 8-bit RGBA / RGB
	chunk(&out, "IHDR", ihdr[:])
	stride := w * channels
	raw := make([dynamic]u8, allocator)
	for i in 0 ..< h {
		y := h - 1 - i if bottom_up else i
		append(&raw, 0) // filter: none
		append(&raw, ..px[y * stride:(y + 1) * stride])
	}
	z := make([dynamic]u8, allocator)
	append(&z, 0x78, 0x01)
	for i := 0; i < len(raw); i += 65535 {
		n := min(65535, len(raw) - i)
		append(&z, 1 if i + n == len(raw) else 0, u8(n), u8(n >> 8), u8(~n), u8(~n >> 8))
		append(&z, ..raw[i:i + n])
	}
	be32(&z, hash.adler32(raw[:]))
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return out[:]
}

png_encode_rgb :: proc(px: []u8, w, h: int, allocator := context.temp_allocator) -> []u8 {
	return png_encode(px, w, h, 3, true, allocator)
}
