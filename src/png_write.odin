package kuraokami

import "core:hash"

// Minimal PNG writer (stored/uncompressed deflate) for the KURAOKAMI_SHOT debug dump.
// px is bottom-up RGB as read back from OpenGL.
png_encode_rgb :: proc(px: []u8, w, h: int, allocator := context.temp_allocator) -> []u8 {
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
	ihdr[8], ihdr[9] = 8, 2 // 8-bit RGB
	chunk(&out, "IHDR", ihdr[:])
	raw := make([dynamic]u8, allocator)
	for y := h - 1; y >= 0; y -= 1 {
		append(&raw, 0) // filter: none
		append(&raw, ..px[y * w * 3:(y + 1) * w * 3])
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
