package kuraokami

import "core:strings"
import "core:c"
import "core:fmt"
import "core:math"
import "core:hash"
import "core:slice"
import "core:sync"
import "core:unicode/utf8"
import "core:os"
import gl "vendor:OpenGL"

Glyph :: struct {
	u0, v0, u1, v1: f32,
	w, h, left, top: f32, // in pixels, already scaled
	color:          bool,
	ok:             bool,
}

Shaped_Glyph :: struct {
	gid:  u32,
	cell: u16, // cell offset within the run
	x, y: f32, // pixel offset from that cell's origin (intra-cluster advance + hb offsets)
}

Fonts :: struct {
	px:          int,
	faces:       [dynamic]rawptr, // 0..3 = regular, bold, italic, bold-italic; then fallbacks
	paths:       [dynamic]string,
	fb_cache:    map[rune]int, // -1 = nothing covers it
	cell_w, cell_h, ascent: int,
	glyphs:      map[u64]Glyph,
	shaped:      map[u64][]Shaped_Glyph,
	atlas:       u32,
	atlas_size:  int,
	ax, ay, arow: int,
	atlas_reset: bool,
}

Vertex :: struct {
	x, y, u, v: f32,
	col:        [4]u8,
	mode:       f32,
}

Renderer :: struct {
	prog:      u32,
	vao, vbo:  u32,
	u_screen, u_offset: i32,
	bg, fg, ov: [dynamic]Vertex,
	width, height: int,
	ox:        f32, // horizontal translation (tab slide animation)
	// custom shader post-processing
	post:      u32,
	fbo, fbo_tex: u32,
	fbo_w, fbo_h: int,
	frame:     i32,
}

fonts: Fonts
ren: Renderer

find_font :: proc(family: string, bold, italic: bool, cp: u32 = 0) -> string {
	buf: [1024]u8
	fam := strings.clone_to_cstring(family, context.temp_allocator)
	if kf_find(fam, c.int(bold), c.int(italic), cp, &buf[0], len(buf)) == 0 do return ""
	return strings.clone(string(cstring(&buf[0])))
}

fonts_load :: proc(px: int) {
	closed := make(map[rawptr]bool, context.temp_allocator)
	for f in fonts.faces do if f != nil && !closed[f] {kf_close(f); closed[f] = true}
	for p in fonts.paths do delete(p)
	clear(&fonts.faces)
	clear(&fonts.paths)
	clear(&fonts.fb_cache)
	fonts.px = px
	for i in 0 ..< 4 {
		path := find_font(cfg.font_family, i & 1 != 0, i & 2 != 0)
		if path == "" && i == 0 do path = find_font("monospace", false, false)
		f: rawptr
		if path != "" {
			f = kf_open(strings.clone_to_cstring(path, context.temp_allocator), c.int(px))
			delete(path)
		}
		if f == nil do f = fonts.faces[0] if i > 0 else nil
		if f == nil {
			fmt.eprintln("kuraokami: no usable font found")
			os.exit(1)
		}
		append(&fonts.faces, f)
		append(&fonts.paths, "")
	}
	adv, asc, desc, h: c.int
	kf_metrics(fonts.faces[0], &adv, &asc, &desc, &h)
	fonts.cell_w, fonts.cell_h, fonts.ascent = int(adv), int(h), int(asc)
	atlas_clear()
}

shape_cache_clear :: proc() {
	for _, v in fonts.shaped do delete(v)
	clear(&fonts.shaped)
}

atlas_clear :: proc() {
	clear(&fonts.glyphs)
	shape_cache_clear()
	fonts.ax, fonts.ay, fonts.arow = 1, 1, 0
	if fonts.atlas == 0 {
		gl.GenTextures(1, &fonts.atlas)
		fonts.atlas_size = 1024
	}
	gl.BindTexture(gl.TEXTURE_2D, fonts.atlas)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(fonts.atlas_size), i32(fonts.atlas_size), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
}

is_emoji :: #force_inline proc(cp: rune) -> bool {
	return cp >= 0x1F000 || (cp >= 0x2600 && cp < 0x2800 && rune_width(cp) == 2)
}

// Face index that can render cp (wide pictographs prefer a color emoji font).
face_for :: proc(cp: rune, style: int) -> int {
	if cp < 0x80 do return style
	emoji := is_emoji(cp)
	if !emoji {
		if kf_has(fonts.faces[style], u32(cp)) != 0 do return style
		if kf_has(fonts.faces[0], u32(cp)) != 0 do return 0
	}
	if idx, ok := fonts.fb_cache[cp]; ok do return idx
	if !emoji do for i in 4 ..< len(fonts.faces) {
		if kf_has(fonts.faces[i], u32(cp)) != 0 {fonts.fb_cache[cp] = i; return i}
	}
	path := find_font("emoji" if emoji else "", false, false, u32(cp))
	idx := -1
	if path != "" {
		for p, i in fonts.paths do if p == path {idx = i; break}
		if idx < 0 {
			face := kf_open(strings.clone_to_cstring(path, context.temp_allocator), c.int(fonts.px))
			if face != nil && kf_has(face, u32(cp)) != 0 {
				append(&fonts.faces, face)
				append(&fonts.paths, path)
				idx = len(fonts.faces) - 1
				path = ""
			} else if face != nil do kf_close(face)
		}
		if path != "" do delete(path)
	}
	fonts.fb_cache[cp] = idx
	return idx
}

get_glyph :: proc(face: int, gid: u32) -> Glyph {
	key := u64(face) << 32 | u64(gid)
	if g, ok := fonts.glyphs[key]; ok do return g
	g: Glyph
	w, h, left, top, pitch, color: c.int
	scale: f32
	buf: [^]u8
	if kf_render_glyph(fonts.faces[face], gid, c.int(fonts.px), &w, &h, &left, &top, &pitch, &color, &scale, &buf) != 0 && w > 0 && h > 0 {
		sz := fonts.atlas_size
		if fonts.ax + int(w) + 1 >= sz {
			fonts.ax = 1
			fonts.ay += fonts.arow + 1
			fonts.arow = 0
		}
		if fonts.ay + int(h) + 1 >= sz {
			// Full: grow (up to 4096) and rebuild on the next frame.
			if fonts.atlas_size < 4096 do fonts.atlas_size *= 2
			fonts.atlas_reset = true
			return g
		}
		px := make([]u8, int(w) * int(h) * 4, context.temp_allocator)
		for y in 0 ..< int(h) {
			src := buf[y * int(pitch):]
			for x in 0 ..< int(w) {
				o := (y * int(w) + x) * 4
				if color != 0 {
					b, gg, r, a := src[x * 4], src[x * 4 + 1], src[x * 4 + 2], src[x * 4 + 3]
					if a > 0 && a < 255 { // FreeType BGRA is premultiplied
						r = u8(min(255, int(r) * 255 / int(a)))
						gg = u8(min(255, int(gg) * 255 / int(a)))
						b = u8(min(255, int(b) * 255 / int(a)))
					}
					px[o], px[o + 1], px[o + 2], px[o + 3] = r, gg, b, a
				} else {
					px[o], px[o + 1], px[o + 2], px[o + 3] = 255, 255, 255, src[x]
				}
			}
		}
		gl.BindTexture(gl.TEXTURE_2D, fonts.atlas)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(fonts.ax), i32(fonts.ay), w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(px))
		fs := f32(sz)
		g = Glyph {
			u0 = f32(fonts.ax) / fs, v0 = f32(fonts.ay) / fs,
			u1 = f32(fonts.ax + int(w)) / fs, v1 = f32(fonts.ay + int(h)) / fs,
			w = f32(w) * scale, h = f32(h) * scale, left = f32(left) * scale, top = f32(top) * scale,
			color = color != 0, ok = true,
		}
		// Bitmap emoji are sized for a much larger ppem: fit them into the cell height.
		if color != 0 && g.h > f32(fonts.cell_h) {
			k := f32(fonts.cell_h) / g.h
			g.w *= k; g.h *= k; g.left *= k; g.top *= k
		}
		fonts.ax += int(w) + 1
		fonts.arow = max(fonts.arow, int(h))
	}
	fonts.glyphs[key] = g
	return g
}

// Shape a run with HarfBuzz (cached). cells[i] = cell offset of codepoint i.
shape_run :: proc(face: int, cps: []u32, cells: []u16) -> []Shaped_Glyph {
	h := hash.fnv64a(slice.to_bytes(cps))
	h = hash.fnv64a(slice.to_bytes(cells), h)
	key := h ~ u64(face) * 0x9E3779B97F4A7C15
	if s, ok := fonts.shaped[key]; ok do return s
	if len(fonts.shaped) > 8192 do shape_cache_clear()
	max_g := len(cps) * 2 + 8
	gids := make([]u32, max_g, context.temp_allocator)
	cl := make([]u32, max_g, context.temp_allocator)
	xadv := make([]c.int, max_g, context.temp_allocator)
	xoff := make([]c.int, max_g, context.temp_allocator)
	yoff := make([]c.int, max_g, context.temp_allocator)
	n := int(kf_shape(fonts.faces[face], raw_data(cps), c.int(len(cps)), c.int(cfg.ligatures), raw_data(gids), raw_data(cl), raw_data(xadv), raw_data(xoff), raw_data(yoff), c.int(max_g)))
	out := make([]Shaped_Glyph, n)
	pen: f32
	cluster_start: f32
	cur := u32(max(u32))
	for i in 0 ..< n {
		if cl[i] != cur {cur = cl[i]; cluster_start = pen}
		ci := min(int(cl[i]), len(cells) - 1)
		out[i] = {gids[i], cells[ci], pen - cluster_start + f32(xoff[i]) / 64, f32(yoff[i]) / 64}
		pen += f32(xadv[i]) / 64
	}
	fonts.shaped[key] = out
	return out
}

VS :: `#version 330 core
layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec4 col;
layout(location=3) in float mode;
uniform vec2 screen;
uniform vec2 offset;
out vec2 v_uv; out vec4 v_col; flat out float v_mode;
void main() {
	vec2 p = pos + offset;
	gl_Position = vec4(p.x / screen.x * 2.0 - 1.0, 1.0 - p.y / screen.y * 2.0, 0.0, 1.0);
	v_uv = uv; v_col = col; v_mode = mode;
}`

FS :: `#version 330 core
in vec2 v_uv; in vec4 v_col; flat in float v_mode;
uniform sampler2D tex;
out vec4 o;
void main() {
	vec4 t = texture(tex, v_uv);
	if (v_mode < 0.5) o = v_col;
	else if (v_mode < 1.5) o = vec4(v_col.rgb, v_col.a * t.a);
	else o = vec4(t.rgb, t.a * v_col.a);
}`

POST_VS :: `#version 330 core
void main() {
	vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`

// Ghostty/shadertoy-compatible prelude: user shaders define mainImage().
POST_PRELUDE :: `#version 330 core
uniform vec3 iResolution;
uniform float iTime;
uniform float iTimeDelta;
uniform int iFrame;
uniform vec4 iMouse;
uniform sampler2D iChannel0;
uniform vec4 iCurrentCursor;
uniform vec4 iPreviousCursor;
uniform vec4 iCurrentCursorColor;
uniform vec4 iPreviousCursorColor;
uniform float iTimeCursorChange;
out vec4 _kuraokami_out;
`

POST_MAIN :: `
void main() { mainImage(_kuraokami_out, gl_FragCoord.xy); }
`

renderer_init :: proc() -> bool {
	prog, ok := gl.load_shaders_source(VS, FS)
	if !ok do return false
	ren.prog = prog
	ren.u_screen = gl.GetUniformLocation(prog, "screen")
	ren.u_offset = gl.GetUniformLocation(prog, "offset")
	gl.GenVertexArrays(1, &ren.vao)
	gl.GenBuffers(1, &ren.vbo)
	gl.BindVertexArray(ren.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ren.vbo)
	st := i32(size_of(Vertex))
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, st, 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, st, 8)
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, st, 16)
	gl.EnableVertexAttribArray(3)
	gl.VertexAttribPointer(3, 1, gl.FLOAT, false, st, 20)
	gl.Enable(gl.BLEND)
	gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	return true
}

// Load (or unload with "") the custom post-processing shader. Returns an error message.
post_shader_load :: proc(spec: string) -> string {
	if ren.post != 0 {gl.DeleteProgram(ren.post); ren.post = 0}
	if spec == "" do return ""
	src: string
	if strings.has_prefix(spec, "builtin:") {
		name := spec[8:]
		for b in BUILTIN_SHADERS do if b.name == name do src = b.src
		if src == "" do return fmt.tprintf("unknown builtin shader %q", name)
	} else {
		path := spec
		if strings.has_prefix(path, "~/") do path = fmt.tprintf("%s/%s", home_dir(), path[2:])
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil do return fmt.tprintf("cannot read shader %s", path)
		src = string(data)
	}
	fs := strings.concatenate({POST_PRELUDE, src, POST_MAIN}, context.temp_allocator)
	prog, ok := gl.load_shaders_source(POST_VS, fs)
	if !ok do return "custom shader failed to compile"
	ren.post = prog
	return ""
}

rgba :: #force_inline proc(c: u32, a: u8 = 255) -> [4]u8 {
	return {u8(c >> 16), u8(c >> 8), u8(c), a}
}

quad :: proc(list: ^[dynamic]Vertex, x0, y0, x1, y1: f32, col: [4]u8, mode: f32 = 0, u0: f32 = 0, v0: f32 = 0, u1: f32 = 0, v1: f32 = 0) {
	append(list,
		Vertex{x0, y0, u0, v0, col, mode}, Vertex{x1, y0, u1, v0, col, mode}, Vertex{x1, y1, u1, v1, col, mode},
		Vertex{x0, y0, u0, v0, col, mode}, Vertex{x1, y1, u1, v1, col, mode}, Vertex{x0, y1, u0, v1, col, mode})
}

glyph_at :: proc(list: ^[dynamic]Vertex, g: Glyph, x, baseline: f32, fg: [4]u8) {
	if !g.ok do return
	gx := x + g.left
	gy := baseline - g.top
	if g.color do quad(list, gx, gy, gx + g.w, gy + g.h, {255, 255, 255, fg[3]}, 2, g.u0, g.v0, g.u1, g.v1)
	else do quad(list, gx, gy, gx + g.w, gy + g.h, fg, 1, g.u0, g.v0, g.u1, g.v1)
}

// Single codepoint, unshaped (UI text).
glyph_quad :: proc(list: ^[dynamic]Vertex, cp: rune, style: int, x, y: f32, fg: [4]u8) {
	f := face_for(cp, style)
	if f < 0 do f = 0
	glyph_at(list, get_glyph(f, kf_glyph_index(fonts.faces[f], u32(cp))), x, y + f32(fonts.ascent), fg)
}

flush :: proc(list: ^[dynamic]Vertex, tex: u32) {
	if len(list) == 0 do return
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.BufferData(gl.ARRAY_BUFFER, len(list) * size_of(Vertex), raw_data(list^), gl.STREAM_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(list)))
	clear(list)
}

Rect :: struct {x, y, w, h: int}

Selection :: struct {
	active:   bool,
	a, b:     [2]i64, // {abs_line, col}
	term:     ^Term,
}

in_selection :: proc(s: ^Selection, abs: i64, x: int) -> bool {
	if !s.active do return false
	a, b := s.a, s.b
	if a[0] > b[0] || (a[0] == b[0] && a[1] > b[1]) do a, b = b, a
	p := [2]i64{abs, i64(x)}
	if p[0] < a[0] || p[0] > b[0] do return false
	if p[0] == a[0] && p[1] < a[1] do return false
	if p[0] == b[0] && p[1] > b[1] do return false
	return true
}

mix :: proc(a, b: u32, t: f32) -> u32 {
	ca, cb := rgba(a), rgba(b)
	r := u32(f32(ca[0]) * (1 - t) + f32(cb[0]) * t)
	g := u32(f32(ca[1]) * (1 - t) + f32(cb[1]) * t)
	bl := u32(f32(ca[2]) * (1 - t) + f32(cb[2]) * t)
	return r << 16 | g << 8 | bl
}

image_texture :: proc(img: ^Image) -> u32 {
	if img.tex == 0 {
		gl.GenTextures(1, &img.tex)
		gl.BindTexture(gl.TEXTURE_2D, img.tex)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	}
	if img.tex_ver != img.version {
		gl.BindTexture(gl.TEXTURE_2D, img.tex)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(img.w), i32(img.h), 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(img.pixels))
		img.tex_ver = img.version
	}
	return img.tex
}

draw_images :: proc(t: ^Term, r: Rect, off: int, frac: f32, neg: bool) {
	g := &t.gfx
	top := view_abs_at(t, off, 0)
	cw, ch := f32(fonts.cell_w), f32(fonts.cell_h)
	for p in g.placements {
		if (p.z < 0) != neg do continue
		y := p.abs_row - top
		if y + i64(p.rows) <= -1 || y >= i64(t.rows) do continue
		img, ok := g.images[p.img]
		if !ok do continue
		x0 := f32(r.x) + f32(p.col) * cw
		y0 := f32(r.y) + (f32(y) + frac) * ch
		quad(&ren.ov, x0, y0, x0 + f32(p.cols) * cw, y0 + f32(p.rows) * ch, {255, 255, 255, 255}, 2, 0, 0, 1, 1)
		flush(&ren.ov, image_texture(img))
	}
}

Draw_Opts :: struct {
	focused:       bool,
	sel:           ^Selection,
	preedit:       string,
	view_vis:      f32, // animated scrollback offset in lines
	cursor:        [2]f32, // animated cursor position (pixels, relative to rect)
	trail:         [2]f32, // lagging trail position
	cursor_alpha:  f32,
	cursor_arrived: bool,
	search:        []rune,
	search_cur:    [2]i64,
}

Cell_Paint :: struct {
	fg:    u32,
	style: int,
	draw:  bool,
}

scissor :: proc(x, y, w, h: int) {
	gl.Scissor(i32(f32(x) + ren.ox), i32(ren.height - y - h), i32(w), i32(h))
}

// Immutable copy of what one frame needs, taken under t.mu so shaping/drawing never blocks the PTY reader.
Snap :: struct {
	cols, rows:   int,
	lines:        [][]Cell,
	abs:          []i64,
	hl:           [][]u8, // search highlight per line (nil when no search)
	clusters:     map[rune]string,
	palette:      [256]u32,
	fg, bg, cursor: u32,
	reverse:      bool,
	cx, cy:       int,
	cursor_hidden: bool,
	cursor_shape: int,
	off:          int,
	frac, vis:    f32,
	y0:           int,
}

snap_take :: proc(t: ^Term, o: Draw_Opts) -> Snap {
	s := Snap{cols = t.cols, rows = t.rows, palette = t.palette, fg = t.fg_color, bg = t.bg_color, cursor = t.cursor_color,
		reverse = t.reverse, cx = t.cx, cy = t.cy, cursor_hidden = t.cursor_hidden, cursor_shape = t.cursor_shape}
	s.vis = clamp(o.view_vis, 0, f32(screen(t).count - t.rows))
	s.off = int(math.floor(s.vis))
	s.frac = s.vis - f32(s.off)
	s.y0 = -1 if s.frac > 0 else 0
	n := t.rows - s.y0
	s.lines = make([][]Cell, n, context.temp_allocator)
	s.abs = make([]i64, n, context.temp_allocator)
	s.hl = make([][]u8, n, context.temp_allocator)
	s.clusters = make(map[rune]string, 0, context.temp_allocator)
	ms := make([dynamic][2]int, context.temp_allocator)
	for i in 0 ..< n {
		y := s.y0 + i
		line := view_line_at(t, s.off, y)
		if line == nil do continue
		s.lines[i] = slice_clone_temp(line)
		s.abs[i] = view_abs_at(t, s.off, y)
		for c in line do if c.ch >= CLUSTER_BASE && c.ch not_in s.clusters {
			buf: [4]u8
			s.clusters[c.ch] = strings.clone(cell_text(t, c.ch, &buf), context.temp_allocator)
		}
		if len(o.search) > 0 {
			hl := make([]u8, t.cols, context.temp_allocator)
			clear(&ms)
			line_matches(t, line, o.search, &ms)
			for m in ms {
				v := u8(2) if s.abs[i] == o.search_cur[0] && i64(m[0]) == o.search_cur[1] else 1
				for x in m[0] ..= min(m[1], t.cols - 1) do hl[x] = v
			}
			s.hl[i] = hl
		}
	}
	return s
}

slice_clone_temp :: proc(l: []Cell) -> []Cell {
	out := make([]Cell, len(l), context.temp_allocator)
	copy(out, l)
	return out
}

snap_text :: proc(s: ^Snap, ch: rune, buf: ^[4]u8) -> string {
	if ch >= CLUSTER_BASE do return s.clusters[ch]
	b, n := utf8.encode_rune(ch)
	buf^ = b
	return string(buf[:n])
}

snap_resolve :: #force_inline proc(s: ^Snap, c: u32) -> u32 {
	if c & PAL != 0 do return s.palette[c & 0xff]
	if c & DEF != 0 do return s.fg if c & 1 == 0 else s.bg
	return c
}

// Draw one terminal into rect r (pixels). Takes t.mu itself, only while copying state and drawing images.
draw_term :: proc(t: ^Term, r: Rect, o: Draw_Opts) {
	sync.mutex_lock(&t.mu)
	for tex in t.gfx.dead_tex {tex := tex; gl.DeleteTextures(1, &tex)}
	clear(&t.gfx.dead_tex)
	s := snap_take(t, o)
	t.dirty = false
	sync.mutex_unlock(&t.mu)

	scissor(r.x, r.y, r.w, r.h)
	cw, ch := fonts.cell_w, fonts.cell_h
	bgdef := s.bg
	vis, off, frac := s.vis, s.off, s.frac
	show_cursor := !s.cursor_hidden && vis < 0.999
	shape := s.cursor_shape if s.cursor_shape != 0 else cfg.cursor_style
	block := shape <= 2
	sel_on := o.sel.active && o.sel.term == t
	paint := make([]Cell_Paint, s.cols, context.temp_allocator)
	cps := make([dynamic]u32, context.temp_allocator)
	cmap := make([dynamic]u16, context.temp_allocator)
	match_bg, cur_bg := s.palette[3], s.palette[1]
	for line, i in s.lines {
		if line == nil do continue
		y := s.y0 + i
		abs := s.abs[i]
		hl := s.hl[i]
		py := f32(r.y) + (f32(y) + frac) * f32(ch)
		n := min(s.cols, len(line))
		for x in 0 ..< n {
			cell := line[x]
			paint[x] = {}
			if cell.wide == 2 do continue
			fg := snap_resolve(&s, cell.fg)
			bg := snap_resolve(&s, cell.bg)
			if .Bold in cell.attr && cell.fg & PAL != 0 && cell.fg & 0xff < 8 do fg = s.palette[(cell.fg & 0xff) + 8]
			inv := .Inverse in cell.attr
			if s.reverse do inv = !inv
			if inv do fg, bg = bg, fg
			is_default_bg := bg == bgdef && !inv
			if sel_on && in_selection(o.sel, abs, x) {
				bg = cfg.selection_bg
				is_default_bg = false
			}
			if hl != nil && hl[x] != 0 {
				bg = cur_bg if hl[x] == 2 else match_bg
				fg = bgdef
				is_default_bg = false
			}
			if show_cursor && o.focused && block && o.cursor_arrived && o.cursor_alpha > 0.5 && off == 0 && y == s.cy && x == s.cx {
				fg = bg
			}
			if .Dim in cell.attr do fg = mix(fg, bg, 0.4)
			px := f32(r.x + x * cw)
			wcells := 2 if cell.wide == 1 else 1
			if !is_default_bg do quad(&ren.bg, px, py, px + f32(cw * wcells), py + f32(ch), rgba(bg))
			if cell.ch > ' ' && .Hidden not_in cell.attr {
				paint[x] = {fg, (1 if .Bold in cell.attr else 0) | (2 if .Italic in cell.attr else 0), true}
			}
			if .Underline in cell.attr || cell.link != 0 {
				uy := py + f32(fonts.ascent) + 2
				quad(&ren.fg, px, uy, px + f32(cw * wcells), uy + 1, rgba(fg))
			}
			if .Strike in cell.attr {
				sy := py + f32(ch) / 2
				quad(&ren.fg, px, sy, px + f32(cw * wcells), sy + 1, rgba(fg))
			}
		}
		// Glyphs: group cells into runs with the same face, shape each run (ligatures, clusters).
		baseline := py + f32(fonts.ascent)
		x := 0
		for x < n {
			if !paint[x].draw {x += 1; continue}
			buf: [4]u8
			first, _ := utf8_first(snap_text(&s, line[x].ch, &buf))
			face := face_for(first, paint[x].style)
			if face < 0 do face = 0
			start := x
			clear(&cps)
			clear(&cmap)
			needs_shape := line[x].ch >= CLUSTER_BASE
			for x < n && paint[x].draw && len(cps) < 512 {
				fr, _ := utf8_first(snap_text(&s, line[x].ch, &buf))
				f := face_for(fr, paint[x].style)
				if f < 0 do f = 0
				if f != face do break
				for rr in snap_text(&s, line[x].ch, &buf) {
					append(&cps, u32(rr))
					append(&cmap, u16(x - start))
					// Ligatures live among symbols; complex scripts need shaping. Plain alnum/CJK runs skip HarfBuzz.
					if cfg.ligatures && ((rr < 0x80 && strings.contains_rune(LIGATURE_CHARS, rr)) || (rr >= 0x80 && line[x].wide == 0)) do needs_shape = true
				}
				if line[x].ch >= CLUSTER_BASE do needs_shape = true
				x += 2 if line[x].wide == 1 else 1
			}
			if needs_shape {
				for sg in shape_run(face, cps[:], cmap[:]) {
					cx := start + int(sg.cell)
					glyph_at(&ren.fg, get_glyph(face, sg.gid), f32(r.x + cx * cw) + sg.x, baseline - sg.y, rgba(paint[cx].fg))
				}
			} else {
				for cp, k in cps {
					cx := start + int(cmap[k])
					glyph_at(&ren.fg, get_glyph(face, kf_glyph_index(fonts.faces[face], cp)), f32(r.x + cx * cw), baseline, rgba(paint[cx].fg))
				}
			}
		}
	}
	// Cursor (animated position, blink alpha, smear trail).
	if show_cursor && o.preedit == "" && o.cursor_alpha > 0.01 {
		px := f32(r.x) + o.cursor[0]
		py := f32(r.y) + o.cursor[1] + vis * f32(ch)
		a := u8(o.cursor_alpha * 255)
		cc := rgba(s.cursor, a)
		cwf, chf := f32(cw), f32(ch)
		if o.focused && cfg.cursor_trail && !o.cursor_arrived {
			tx := f32(r.x) + o.trail[0]
			ty := f32(r.y) + o.trail[1] + vis * f32(ch)
			quad(&ren.bg, min(px, tx), min(py, ty), max(px, tx) + cwf, max(py, ty) + chf, rgba(s.cursor, a / 3))
		}
		if !o.focused {
			quad(&ren.ov, px, py, px + cwf, py + 1, cc)
			quad(&ren.ov, px, py + chf - 1, px + cwf, py + chf, cc)
			quad(&ren.ov, px, py, px + 1, py + chf, cc)
			quad(&ren.ov, px + cwf - 1, py, px + cwf, py + chf, cc)
		} else if block {
			quad(&ren.bg, px, py, px + cwf, py + chf, cc)
		} else if shape <= 4 {
			quad(&ren.ov, px, py + chf - 2, px + cwf, py + chf, cc)
		} else {
			quad(&ren.ov, px, py, px + 2, py + chf, cc)
		}
	}
	if o.preedit != "" && o.focused {
		px := f32(r.x + s.cx * cw)
		py := f32(r.y + s.cy * ch)
		draw_text(&ren.ov, px, py, o.preedit, s.fg, mix(s.bg, s.fg, 0.15), true)
	}
	flush(&ren.bg, fonts.atlas)
	if len(t.gfx.placements) > 0 { // racy peek is fine: only skips taking the lock
		sync.mutex_lock(&t.mu)
		draw_images(t, r, off, frac, true)
		flush(&ren.fg, fonts.atlas)
		draw_images(t, r, off, frac, false)
		sync.mutex_unlock(&t.mu)
	} else do flush(&ren.fg, fonts.atlas)
	flush(&ren.ov, fonts.atlas)
}

LIGATURE_CHARS :: "!#$%&*+-./:;<=>?@\\^_|~[](){}'\"`,"

utf8_first :: proc(s: string) -> (rune, bool) {
	for r in s do return r, true
	return ' ', false
}

// Returns width in pixels.
draw_text :: proc(list: ^[dynamic]Vertex, x, y: f32, s: string, fg, bg: u32, underline := false, alpha: u8 = 255) -> f32 {
	cx := x
	for ch in s {
		w := rune_width(ch)
		if w == 0 do continue
		cwp := f32(fonts.cell_w * w)
		quad(list, cx, y, cx + cwp, y + f32(fonts.cell_h), rgba(bg, alpha))
		cx += cwp
	}
	cx = x
	for ch in s {
		w := rune_width(ch)
		if w == 0 do continue
		glyph_quad(list, ch, 0, cx, y, rgba(fg, alpha))
		if underline do quad(list, cx, y + f32(fonts.cell_h) - 2, cx + f32(fonts.cell_w * w), y + f32(fonts.cell_h) - 1, rgba(fg, alpha))
		cx += f32(fonts.cell_w * w)
	}
	return cx - x
}

frame_begin :: proc(w, h: int) {
	ren.width, ren.height = w, h
	if ren.post != 0 {
		if ren.fbo == 0 do gl.GenFramebuffers(1, &ren.fbo)
		if ren.fbo_tex == 0 || ren.fbo_w != w || ren.fbo_h != h {
			if ren.fbo_tex == 0 do gl.GenTextures(1, &ren.fbo_tex)
			gl.BindTexture(gl.TEXTURE_2D, ren.fbo_tex)
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
			gl.BindFramebuffer(gl.FRAMEBUFFER, ren.fbo)
			gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, ren.fbo_tex, 0)
			ren.fbo_w, ren.fbo_h = w, h
		}
		gl.BindFramebuffer(gl.FRAMEBUFFER, ren.fbo)
	} else {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	}
	gl.Viewport(0, 0, i32(w), i32(h))
	gl.Disable(gl.SCISSOR_TEST)
	bg := rgba(cfg.bg)
	a := cfg.opacity
	gl.ClearColor(f32(bg[0]) / 255 * a, f32(bg[1]) / 255 * a, f32(bg[2]) / 255 * a, a)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.UseProgram(ren.prog)
	gl.Uniform2f(ren.u_screen, f32(w), f32(h))
	set_offset(0)
	gl.BindVertexArray(ren.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ren.vbo)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.Enable(gl.SCISSOR_TEST)
}

set_offset :: proc(ox: f32) {
	ren.ox = ox
	gl.Uniform2f(ren.u_offset, ox, 0)
}

Post_Uniforms :: struct {
	time, dt:         f32,
	cursor, prev:     [4]f32, // x, y(top, from bottom), w, h
	cursor_color:     u32,
	cursor_change:    f32,
	mouse:            [2]f32,
}

// Run the custom shader over the offscreen frame into the window.
frame_post :: proc(u: Post_Uniforms) {
	if ren.post == 0 do return
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.BLEND)
	gl.Viewport(0, 0, i32(ren.width), i32(ren.height))
	p := ren.post
	gl.UseProgram(p)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, ren.fbo_tex)
	gl.Uniform1i(gl.GetUniformLocation(p, "iChannel0"), 0)
	gl.Uniform3f(gl.GetUniformLocation(p, "iResolution"), f32(ren.width), f32(ren.height), 1)
	gl.Uniform1f(gl.GetUniformLocation(p, "iTime"), u.time)
	gl.Uniform1f(gl.GetUniformLocation(p, "iTimeDelta"), u.dt)
	gl.Uniform1i(gl.GetUniformLocation(p, "iFrame"), ren.frame)
	gl.Uniform4f(gl.GetUniformLocation(p, "iMouse"), u.mouse[0], f32(ren.height) - u.mouse[1], 0, 0)
	gl.Uniform4f(gl.GetUniformLocation(p, "iCurrentCursor"), u.cursor[0], u.cursor[1], u.cursor[2], u.cursor[3])
	gl.Uniform4f(gl.GetUniformLocation(p, "iPreviousCursor"), u.prev[0], u.prev[1], u.prev[2], u.prev[3])
	cc := rgba(u.cursor_color)
	gl.Uniform4f(gl.GetUniformLocation(p, "iCurrentCursorColor"), f32(cc[0]) / 255, f32(cc[1]) / 255, f32(cc[2]) / 255, 1)
	gl.Uniform4f(gl.GetUniformLocation(p, "iPreviousCursorColor"), f32(cc[0]) / 255, f32(cc[1]) / 255, f32(cc[2]) / 255, 1)
	gl.Uniform1f(gl.GetUniformLocation(p, "iTimeCursorChange"), u.cursor_change)
	gl.BindVertexArray(ren.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Enable(gl.BLEND)
	ren.frame += 1
}

// ---------- built-in shaders (shadertoy/ghostty format) ----------

Builtin_Shader :: struct {name, src: string}

BUILTIN_SHADERS := [?]Builtin_Shader {
	{"crt", `
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec2 c = uv - 0.5;
	uv = 0.5 + c * (1.0 + 0.04 * dot(c, c) * 4.0);
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { fragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }
	float ab = 0.0012;
	vec3 col = vec3(texture(iChannel0, uv + vec2(ab, 0.0)).r, texture(iChannel0, uv).g, texture(iChannel0, uv - vec2(ab, 0.0)).b);
	float scan = 0.88 + 0.12 * sin(fragCoord.y * 3.14159 + iTime * 6.0);
	float vig = smoothstep(0.85, 0.25, length(c));
	float flicker = 0.985 + 0.015 * sin(iTime * 50.0);
	fragColor = vec4(col * scan * vig * flicker, texture(iChannel0, uv).a);
}`},
	{"aurora", `
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y); }
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec4 term = texture(iChannel0, uv);
	vec4 bg = texture(iChannel0, vec2(0.999, 0.001));
	float t = iTime * 0.08;
	float band = n(vec2(uv.x * 3.0 + t, uv.y * 1.5 - t)) + 0.5 * n(vec2(uv.x * 7.0 - t * 2.0, uv.y * 3.0));
	vec3 aur = mix(vec3(0.1, 0.9, 0.6), vec3(0.5, 0.3, 1.0), uv.x + 0.3 * sin(t * 3.0));
	aur *= smoothstep(0.6, 1.3, band) * (0.25 + 0.35 * uv.y);
	float isbg = 1.0 - smoothstep(0.02, 0.12, distance(term.rgb, bg.rgb));
	fragColor = vec4(term.rgb + aur * isbg, term.a);
}`},
	{"cursor-glow", `
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	vec4 term = texture(iChannel0, uv);
	vec2 cc = iCurrentCursor.xy + vec2(iCurrentCursor.z, -iCurrentCursor.w) * 0.5;
	float d = length(fragCoord - cc);
	float since = iTime - iTimeCursorChange;
	float pulse = 1.0 + 0.6 * exp(-since * 6.0);
	float glow = exp(-d / (iCurrentCursor.w * 1.6 * pulse)) * 0.35;
	fragColor = vec4(term.rgb + iCurrentCursorColor.rgb * glow, term.a);
}`},
}
