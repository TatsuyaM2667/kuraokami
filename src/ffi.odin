package kuraokami

import "core:c"

// Flat C shim over FreeType/HarfBuzz/fontconfig/stb_image/zlib (csrc/shim.c).
when ODIN_OS == .Windows {
	foreign import shim {"../lib/kshim.lib", "system:freetype.lib", "system:harfbuzz.lib", "system:zlib.lib"}
} else when ODIN_OS == .Darwin {
	foreign import shim {"../lib/libkshim.a", "system:freetype", "system:harfbuzz", "system:fontconfig", "system:z"}
} else {
	foreign import shim {"../lib/libkshim.a", "system:freetype", "system:harfbuzz", "system:fontconfig", "system:z", "system:m"}
}

@(default_calling_convention = "c")
foreign shim {
	kf_init :: proc() -> c.int ---
	kf_find :: proc(family: cstring, bold, italic: c.int, cp: u32, out: [^]u8, outlen: c.int) -> c.int ---
	kf_open :: proc(path: cstring, px: c.int) -> rawptr ---
	kf_close :: proc(f: rawptr) ---
	kf_metrics :: proc(f: rawptr, adv, asc, desc, height: ^c.int) ---
	kf_has :: proc(f: rawptr, cp: u32) -> c.int ---
	kf_glyph_index :: proc(f: rawptr, cp: u32) -> u32 ---
	kf_render_glyph :: proc(f: rawptr, gid: u32, px: c.int, w, h, left, top, pitch, color: ^c.int, scale: ^f32, buf: ^[^]u8) -> c.int ---
	kf_shape :: proc(f: rawptr, text: [^]u32, len: c.int, ligatures: c.int, gids, clusters: [^]u32, xadv, xoff, yoff: [^]c.int, max: c.int) -> c.int ---
	kf_image_decode :: proc(data: [^]u8, len: c.int, w, h: ^c.int) -> [^]u8 ---
	kf_free :: proc(p: rawptr) ---
	kf_inflate :: proc(src: [^]u8, len: c.long, out: ^[^]u8) -> c.long ---
}
