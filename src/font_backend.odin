package kuraokami

// Font backend in pure Odin: FreeType (rasterizing) + fontconfig (lookup) bindings,
// and Odin's vendored kb_text_shape for OpenType shaping (ligatures, marks, complex scripts).

import "core:c"
import "core:os"
import "core:strings"
import "base:runtime"
import kbts "vendor:kb_text_shape"

when ODIN_OS == .Windows {
	foreign import ft "system:freetype.lib"
} else {
	foreign import ft "system:freetype"
}

// ---- FreeType public structs (layouts verified against the C headers in test_freetype_layout) ----
FT_Generic :: struct {data, finalizer: rawptr}
FT_BBox :: struct {xMin, yMin, xMax, yMax: c.long}
FT_Bitmap_Size :: struct {height, width: i16, size, x_ppem, y_ppem: c.long}
FT_Size_Metrics :: struct {
	x_ppem, y_ppem: u16,
	x_scale, y_scale: c.long,
	ascender, descender, height, max_advance: c.long,
}
FT_SizeRec :: struct {
	face:    rawptr,
	generic: FT_Generic,
	metrics: FT_Size_Metrics,
}
FT_Bitmap :: struct {
	rows, width:  c.uint,
	pitch:        c.int,
	buffer:       [^]u8,
	num_grays:    u16,
	pixel_mode:   u8,
	palette_mode: u8,
	palette:      rawptr,
}
FT_Glyph_Metrics :: struct {width, height, horiBearingX, horiBearingY, horiAdvance, vertBearingX, vertBearingY, vertAdvance: c.long}
FT_GlyphSlotRec :: struct {
	library, face, next: rawptr,
	glyph_index:         u32,
	generic:             FT_Generic,
	metrics:             FT_Glyph_Metrics,
	linearHoriAdvance, linearVertAdvance: c.long,
	advance:             [2]c.long,
	format:              u32,
	bitmap:              FT_Bitmap,
	bitmap_left, bitmap_top: c.int,
}
FT_FaceRec :: struct {
	num_faces, face_index, face_flags, style_flags, num_glyphs: c.long,
	family_name, style_name: cstring,
	num_fixed_sizes:     c.int,
	available_sizes:     [^]FT_Bitmap_Size,
	num_charmaps:        c.int,
	charmaps:            rawptr,
	generic:             FT_Generic,
	bbox:                FT_BBox,
	units_per_EM:        u16,
	ascender, descender, height, max_advance_width, max_advance_height, underline_position, underline_thickness: i16,
	glyph:               ^FT_GlyphSlotRec,
	size:                ^FT_SizeRec,
	charmap:             rawptr,
}

FT_LOAD_RENDER :: i32(1 << 2)
FT_LOAD_COLOR :: i32(1 << 20)
FT_LOAD_TARGET_LIGHT :: i32(1 << 16)
FT_PIXEL_MODE_BGRA :: 7
FT_FACE_FLAG_SCALABLE :: 1

@(default_calling_convention = "c")
foreign ft {
	FT_Init_FreeType :: proc(lib: ^rawptr) -> c.int ---
	FT_New_Face :: proc(lib: rawptr, path: cstring, index: c.long, face: ^^FT_FaceRec) -> c.int ---
	FT_Done_Face :: proc(face: ^FT_FaceRec) -> c.int ---
	FT_Set_Pixel_Sizes :: proc(face: ^FT_FaceRec, w, h: u32) -> c.int ---
	FT_Select_Size :: proc(face: ^FT_FaceRec, idx: c.int) -> c.int ---
	FT_Get_Char_Index :: proc(face: ^FT_FaceRec, cp: c.ulong) -> u32 ---
	FT_Load_Glyph :: proc(face: ^FT_FaceRec, gid: u32, flags: i32) -> c.int ---
	FT_Load_Char :: proc(face: ^FT_FaceRec, cp: c.ulong, flags: i32) -> c.int ---
}

KFace :: struct {
	ft:      ^FT_FaceRec,
	path:    string,
	// kb_text_shape state, created lazily on the first run that needs shaping
	kb_data: []u8,
	kb_font: kbts.font,
	kb_ctx:  ^kbts.shape_context,
	kb_ok:   bool,
	kb_tried: bool,
	// cmap cache: FT_Get_Char_Index is slow on big fonts (Nerd Fonts) and runs per glyph per frame
	ascii:   [128]u32, // glyph id + 1 (0 = not looked up yet)
	gid_map: map[u32]u32,
}

ft_lib: rawptr
kb_allocator: runtime.Allocator

kf_init :: proc() -> c.int {
	kb_allocator = runtime.heap_allocator()
	if FT_Init_FreeType(&ft_lib) != 0 do return 0
	when ODIN_OS != .Windows do return c.int(FcInit())
	else do return 1
}

kf_open :: proc(path: cstring, px: c.int) -> rawptr {
	f: ^FT_FaceRec
	if FT_New_Face(ft_lib, path, 0, &f) != 0 do return nil
	if f.face_flags & FT_FACE_FLAG_SCALABLE != 0 do FT_Set_Pixel_Sizes(f, 0, u32(px))
	else if f.num_fixed_sizes > 0 do FT_Select_Size(f, 0) // bitmap color emoji (e.g. Noto Color Emoji)
	k := new(KFace)
	k.ft = f
	k.path = strings.clone(string(path))
	return k
}

kf_close :: proc(p: rawptr) {
	k := (^KFace)(p)
	if k.kb_ctx != nil do kbts.DestroyShapeContext(k.kb_ctx)
	delete(k.gid_map)
	delete(k.kb_data)
	delete(k.path)
	FT_Done_Face(k.ft)
	free(k)
}

// Cell metrics in pixels: advance of 'M', ascender, descender (negative), line height.
kf_metrics :: proc(p: rawptr, adv, asc, desc, height: ^c.int) {
	f := (^KFace)(p).ft
	FT_Load_Char(f, 'M', 0)
	adv^ = c.int((f.glyph.advance[0] + 63) >> 6)
	asc^ = c.int((f.size.metrics.ascender + 63) >> 6)
	desc^ = c.int(f.size.metrics.descender >> 6)
	height^ = asc^ - desc^
}

kf_glyph_index :: proc(p: rawptr, cp: u32) -> u32 {
	k := (^KFace)(p)
	if cp < 128 {
		if k.ascii[cp] == 0 do k.ascii[cp] = FT_Get_Char_Index(k.ft, c.ulong(cp)) + 1
		return k.ascii[cp] - 1
	}
	if g, ok := k.gid_map[cp]; ok do return g
	g := FT_Get_Char_Index(k.ft, c.ulong(cp))
	k.gid_map[cp] = g
	return g
}
kf_has :: proc(p: rawptr, cp: u32) -> c.int {return 1 if kf_glyph_index(p, cp) != 0 else 0}

// Rasterize a glyph id. color=1 means BGRA (emoji), else 8-bit coverage. scale fits bitmap fonts to px.
kf_render_glyph :: proc(p: rawptr, gid: u32, px: c.int, w, h, left, top, pitch, color: ^c.int, scale: ^f32, buf: ^[^]u8) -> c.int {
	f := (^KFace)(p).ft
	if FT_Load_Glyph(f, gid, FT_LOAD_RENDER | FT_LOAD_COLOR | FT_LOAD_TARGET_LIGHT) != 0 do return 0
	g := f.glyph
	w^, h^ = c.int(g.bitmap.width), c.int(g.bitmap.rows)
	left^, top^ = g.bitmap_left, g.bitmap_top
	pitch^ = g.bitmap.pitch
	buf^ = g.bitmap.buffer
	color^ = 1 if g.bitmap.pixel_mode == FT_PIXEL_MODE_BGRA else 0
	scale^ = 1
	if f.face_flags & FT_FACE_FLAG_SCALABLE == 0 && f.num_fixed_sizes > 0 {
		scale^ = f32(px) / f32(f.available_sizes[0].y_ppem >> 6)
	}
	return 1
}

kb_prepare :: proc(k: ^KFace) -> bool {
	if k.kb_tried do return k.kb_ok
	k.kb_tried = true
	data, err := os.read_entire_file_from_path(k.path, context.allocator)
	if err != nil do return false
	k.kb_data = data
	af, ad := kbts.AllocatorFromOdinAllocator(&kb_allocator)
	k.kb_font = kbts.FontFromMemory(data, 0, af, ad)
	if k.kb_font.Error != .NONE do return false
	k.kb_ctx = kbts.CreateShapeContext(af, ad)
	if k.kb_ctx == nil do return false
	_ = kbts.ShapePushFont(k.kb_ctx, &k.kb_font)
	k.kb_ok = true
	return true
}

// Shape UTF-32 text. clusters[i] = index into text. Positions in 1/64 px (same contract as before).
kf_shape :: proc(p: rawptr, text: [^]u32, n: c.int, ligatures: c.int, gids, clusters: [^]u32, xadv, xoff, yoff: [^]c.int, max_out: c.int) -> c.int {
	k := (^KFace)(p)
	if !kb_prepare(k) {
		// No shaper for this font: one glyph per codepoint.
		cnt := min(n, max_out)
		for i in 0 ..< int(cnt) {
			gids[i] = kf_glyph_index(p, text[i])
			clusters[i] = u32(i)
			xadv[i], xoff[i], yoff[i] = c.int(k.ft.size.metrics.max_advance), 0, 0
		}
		return cnt
	}
	ctx := k.kb_ctx
	kbts.ShapeBegin(ctx, .DONT_KNOW, .DONT_KNOW)
	if ligatures == 0 {
		kbts.ShapePushFeature(ctx, .liga, 0)
		kbts.ShapePushFeature(ctx, .calt, 0)
		kbts.ShapePushFeature(ctx, .dlig, 0)
	}
	for i in 0 ..< int(n) do kbts.ShapeCodepoint(ctx, rune(text[i]))
	if ligatures == 0 {
		_ = kbts.ShapePopFeature(ctx, .dlig)
		_ = kbts.ShapePopFeature(ctx, .calt)
		_ = kbts.ShapePopFeature(ctx, .liga)
	}
	kbts.ShapeEnd(ctx)
	// Font units -> 1/64 px.
	upem := f64(max(k.ft.units_per_EM, 1))
	scale := f64(k.ft.size.metrics.y_ppem) * 64 / upem
	out := 0
	for {
		run, ok := kbts.ShapeRun(ctx)
		if !ok do break
		for {
			g, gok := kbts.GlyphIteratorNext(&run.Glyphs)
			if !gok do break
			if out >= int(max_out) do continue
			gids[out] = u32(g.Id)
			clusters[out] = u32(clamp(g.UserIdOrCodepointIndex, 0, n - 1))
			xadv[out] = c.int(f64(g.AdvanceX) * scale)
			xoff[out] = c.int(f64(g.OffsetX) * scale)
			yoff[out] = c.int(f64(g.OffsetY) * scale)
			out += 1
		}
	}
	return c.int(out)
}

// ---- font lookup ----

when ODIN_OS != .Windows {
	foreign import fc "system:fontconfig"

	FcMatchPattern :: 0
	FcResultMatch :: 0
	FC_WEIGHT_REGULAR :: 80
	FC_WEIGHT_BOLD :: 200
	FC_SLANT_ROMAN :: 0
	FC_SLANT_ITALIC :: 100
	FC_MONO :: 100

	@(default_calling_convention = "c")
	foreign fc {
		FcInit :: proc() -> b32 ---
		FcPatternCreate :: proc() -> rawptr ---
		FcPatternDestroy :: proc(p: rawptr) ---
		FcPatternAddString :: proc(p: rawptr, obj: cstring, s: cstring) -> b32 ---
		FcPatternAddInteger :: proc(p: rawptr, obj: cstring, i: c.int) -> b32 ---
		FcPatternAddCharSet :: proc(p: rawptr, obj: cstring, cs: rawptr) -> b32 ---
		FcPatternGetString :: proc(p: rawptr, obj: cstring, n: c.int, s: ^cstring) -> c.int ---
		FcPatternGetCharSet :: proc(p: rawptr, obj: cstring, n: c.int, cs: ^rawptr) -> c.int ---
		FcCharSetCreate :: proc() -> rawptr ---
		FcCharSetDestroy :: proc(cs: rawptr) ---
		FcCharSetAddChar :: proc(cs: rawptr, cp: u32) -> b32 ---
		FcCharSetHasChar :: proc(cs: rawptr, cp: u32) -> b32 ---
		FcConfigSubstitute :: proc(cfg: rawptr, p: rawptr, kind: c.int) -> b32 ---
		FcDefaultSubstitute :: proc(p: rawptr) ---
		FcFontMatch :: proc(cfg: rawptr, p: rawptr, result: ^c.int) -> rawptr ---
	}

	// Resolve family+style to a font file via fontconfig. If cp>0, the font must cover cp.
	// strict: only accept a match whose family really is `family` (fontconfig otherwise substitutes silently).
	kf_find :: proc(family: cstring, bold, italic: c.int, cp: u32, out: [^]u8, outlen: c.int, strict := false) -> c.int {
		p := FcPatternCreate()
		defer FcPatternDestroy(p)
		if family != nil && len(family) > 0 do FcPatternAddString(p, "family", family)
		FcPatternAddInteger(p, "weight", FC_WEIGHT_BOLD if bold != 0 else FC_WEIGHT_REGULAR)
		FcPatternAddInteger(p, "slant", FC_SLANT_ITALIC if italic != 0 else FC_SLANT_ROMAN)
		if cp == 0 do FcPatternAddInteger(p, "spacing", FC_MONO)
		cs: rawptr
		if cp != 0 {
			cs = FcCharSetCreate()
			FcCharSetAddChar(cs, cp)
			FcPatternAddCharSet(p, "charset", cs)
		}
		defer if cs != nil do FcCharSetDestroy(cs)
		FcConfigSubstitute(nil, p, FcMatchPattern)
		FcDefaultSubstitute(p)
		res: c.int
		m := FcFontMatch(nil, p, &res)
		if m == nil do return 0
		defer FcPatternDestroy(m)
		if cp != 0 {
			mcs: rawptr
			if FcPatternGetCharSet(m, "charset", 0, &mcs) != FcResultMatch || !FcCharSetHasChar(mcs, cp) do return 0
		}
		if strict {
			found := false
			name: cstring
			for i: c.int = 0; FcPatternGetString(m, "family", i, &name) == FcResultMatch; i += 1 {
				if strings.equal_fold(string(name), string(family)) {found = true; break}
			}
			if !found do return 0
		}
		file: cstring
		if FcPatternGetString(m, "file", 0, &file) != FcResultMatch do return 0
		s := string(file)
		if len(s) >= int(outlen) do return 0
		copy(out[:outlen], s)
		out[len(s)] = 0
		return 1
	}
} else {
	// No fontconfig on Windows: probe well-known files in the system font directory.
	kf_find :: proc(family: cstring, bold, italic: c.int, cp: u32, out: [^]u8, outlen: c.int, strict := false) -> c.int {
		dir := os.get_env("WINDIR", context.temp_allocator)
		if dir == "" do dir = "C:\\Windows"
		put :: proc(s: string, out: [^]u8, outlen: c.int) -> c.int {
			if len(s) >= int(outlen) do return 0
			copy(out[:outlen], s)
			out[len(s)] = 0
			return 1
		}
		if cp == 0 {
			fam := string(family)
			if strings.contains_rune(fam, '.') {
				path := strings.concatenate({dir, "\\Fonts\\", fam}, context.temp_allocator)
				if os.exists(path) do return put(path, out, outlen)
			}
			mono := [4]string{"consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf"}
			return put(strings.concatenate({dir, "\\Fonts\\", mono[(1 if bold != 0 else 0) + (2 if italic != 0 else 0)]}, context.temp_allocator), out, outlen)
		}
		fb := [?]string{"seguiemj.ttf", "YuGothM.ttc", "msgothic.ttc", "malgun.ttf", "msyh.ttc", "seguisym.ttf", "segoeui.ttf"}
		for name, i in fb {
			if string(family) == "emoji" && i > 0 do break
			path := strings.concatenate({dir, "\\Fonts\\", name}, context.temp_allocator)
			f: ^FT_FaceRec
			if FT_New_Face(ft_lib, strings.clone_to_cstring(path, context.temp_allocator), 0, &f) != 0 do continue
			ok := FT_Get_Char_Index(f, c.ulong(cp)) != 0
			FT_Done_Face(f)
			if ok do return put(path, out, outlen)
		}
		return 0
	}
}
