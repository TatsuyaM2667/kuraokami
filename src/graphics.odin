package kuraokami

import "core:strings"
import "core:c"
import "core:strconv"
import "core:fmt"
import "core:os"
import "core:encoding/base64"

Image :: struct {
	id:      u32,
	w, h:    int,
	pixels:  []u8, // RGBA
	tex:     u32,
	version: u32, // bumped when pixels change; renderer re-uploads when it differs
	tex_ver: u32,
}

Placement :: struct {
	img:      u32,
	pid:      u32,
	abs_row:  i64,
	col:      int,
	cols, rows: int,
	z:        i32,
}

Kitty_Ctrl :: struct {
	a, t, o, d: u8,
	f:          int,
	s, v:       int,
	i, p:       u32,
	c, r:       int,
	m, q:       int,
	C:          int,
	z:          i32,
	S, O:       int,
}

Graphics :: struct {
	images:       map[u32]^Image,
	placements:   [dynamic]Placement,
	pending:      [dynamic]u8,
	pending_ctrl: Kitty_Ctrl,
	chunking:     bool,
	next_id:      u32,
	dead_tex:     [dynamic]u32, // textures to delete on the GL thread
	bytes:        int,
}

IMAGE_BUDGET :: 320 * 1024 * 1024

gfx_destroy :: proc(g: ^Graphics) {
	for _, img in g.images {
		delete(img.pixels)
		free(img)
	}
	delete(g.images)
	delete(g.placements)
	delete(g.pending)
	delete(g.dead_tex)
}

gfx_clear_placements :: proc(g: ^Graphics) {
	clear(&g.placements)
}

gfx_clear_visible :: proc(g: ^Graphics, first_abs: i64, rows: int) {
	for i := len(g.placements) - 1; i >= 0; i -= 1 {
		p := g.placements[i]
		if p.abs_row + i64(p.rows) > first_abs && p.abs_row < first_abs + i64(rows) do unordered_remove(&g.placements, i)
	}
}

image_free :: proc(g: ^Graphics, id: u32) {
	img, ok := g.images[id]
	if !ok do return
	if img.tex != 0 do append(&g.dead_tex, img.tex)
	g.bytes -= len(img.pixels)
	delete(img.pixels)
	free(img)
	delete_key(&g.images, id)
}

cursor_abs :: proc(t: ^Term) -> i64 {
	return t.total_pushed + i64(t.cy) if !t.use_alt else i64(t.cy) - 1 << 40
}

parse_kitty_ctrl :: proc(s: string, k: ^Kitty_Ctrl) {
	for kv in strings.split(s, ",", context.temp_allocator) {
		if len(kv) < 3 || kv[1] != '=' do continue
		val := kv[2:]
		n, _ := strconv.parse_int(val)
		switch kv[0] {
		case 'a': k.a = val[0]
		case 't': k.t = val[0]
		case 'o': k.o = val[0]
		case 'd': k.d = val[0]
		case 'f': k.f = n
		case 's': k.s = n
		case 'v': k.v = n
		case 'i': k.i = u32(n)
		case 'p': k.p = u32(n)
		case 'c': k.c = n
		case 'r': k.r = n
		case 'm': k.m = n
		case 'q': k.q = n
		case 'C': k.C = n
		case 'z': k.z = i32(n)
		case 'S': k.S = n
		case 'O': k.O = n
		}
	}
}

kitty_reply :: proc(t: ^Term, k: ^Kitty_Ctrl, msg: string) {
	if k.i == 0 do return
	if k.q >= 2 || (k.q == 1 && msg == "OK") do return
	reply(t, fmt.tprintf("\x1b_Gi=%d;%s\x1b\\", k.i, msg))
}

kitty_command :: proc(t: ^Term, s: []u8) {
	str := string(s)
	semi := strings.index_byte(str, ';')
	ctrl_s := str if semi < 0 else str[:semi]
	payload := "" if semi < 0 else str[semi + 1:]
	g := &t.gfx

	if g.chunking {
		// Continuation chunk: only m (and q) are meaningful.
		k: Kitty_Ctrl
		parse_kitty_ctrl(ctrl_s, &k)
		append(&g.pending, payload)
		if len(g.pending) > 400 * 1024 * 1024 {g.chunking = false; clear(&g.pending); return}
		if k.m == 1 do return
		g.chunking = false
		kitty_execute(t, &g.pending_ctrl, g.pending[:])
		clear(&g.pending)
		return
	}
	k := Kitty_Ctrl{a = 't', t = 'd', f = 32}
	parse_kitty_ctrl(ctrl_s, &k)
	if k.m == 1 {
		g.chunking = true
		g.pending_ctrl = k
		clear(&g.pending)
		append(&g.pending, payload)
		return
	}
	kitty_execute(t, &k, transmute([]u8)payload)
}

kitty_load :: proc(t: ^Term, k: ^Kitty_Ctrl, b64: []u8) -> (pixels: []u8, w, h: int, err: string) {
	raw, derr := base64.decode(string(b64))
	if derr != nil do return nil, 0, 0, "EINVAL:bad base64"
	defer if raw != nil do delete(raw)
	data := raw
	owned: []u8
	defer if owned != nil do delete(owned)
	switch k.t {
	case 'f', 't':
		path := string(raw)
		if k.t == 't' && !strings.contains(path, "tty-graphics-protocol") do return nil, 0, 0, "EPERM:temp file name"
		bytes, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil do return nil, 0, 0, "ENOENT:cannot read file"
		owned = bytes
		data = bytes
		if k.O > 0 && k.O < len(data) do data = data[k.O:]
		if k.S > 0 && k.S < len(data) do data = data[:k.S]
		if k.t == 't' do remove_file(path)
	case 's':
		size := k.S
		if size <= 0 do size = k.s * k.v * (3 if k.f == 24 else 4)
		if size <= 0 || size > 400 * 1024 * 1024 do return nil, 0, 0, "EINVAL:shm size"
		buf, ok := shm_read(string(raw), size)
		if !ok do return nil, 0, 0, "ENOENT:shm"
		owned = buf
		data = owned
	}
	if k.o == 'z' {
		out: [^]u8
		n := kf_inflate(raw_data(data), c.long(len(data)), &out)
		if n < 0 do return nil, 0, 0, "EINVAL:zlib"
		inflated := make([]u8, n)
		copy(inflated, out[:n])
		kf_free(out)
		if owned != nil do delete(owned)
		owned = inflated
		data = inflated
	}
	switch k.f {
	case 100:
		iw, ih: i32
		px := kf_image_decode(raw_data(data), i32(len(data)), &iw, &ih)
		if px == nil do return nil, 0, 0, "EBADPNG:decode failed"
		out := make([]u8, int(iw) * int(ih) * 4)
		copy(out, px[:len(out)])
		kf_free(px)
		return out, int(iw), int(ih), ""
	case 24, 32:
		bpp := 3 if k.f == 24 else 4
		if k.s <= 0 || k.v <= 0 || len(data) < k.s * k.v * bpp do return nil, 0, 0, "EINVAL:size"
		out := make([]u8, k.s * k.v * 4)
		if bpp == 4 do copy(out, data[:len(out)])
		else do for i in 0 ..< k.s * k.v {
			out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255
		}
		return out, k.s, k.v, ""
	}
	return nil, 0, 0, "EINVAL:format"
}

kitty_place :: proc(t: ^Term, k: ^Kitty_Ctrl, img: ^Image) {
	g := &t.gfx
	cols, rows := k.c, k.r
	cw, ch := max(t.cell_w, 1), max(t.cell_h, 1)
	if cols == 0 && rows == 0 {
		cols = (img.w + cw - 1) / cw
		rows = (img.h + ch - 1) / ch
	} else if cols == 0 {
		cols = max(1, (rows * ch * img.w / max(img.h, 1) + cw - 1) / cw)
	} else if rows == 0 {
		rows = max(1, (cols * cw * img.h / max(img.w, 1) + ch - 1) / ch)
	}
	p := Placement{img = img.id, pid = k.p, abs_row = cursor_abs(t), col = t.cx, cols = cols, rows = rows, z = k.z}
	replaced := false
	for &e in g.placements {
		if e.img == img.id && e.pid == k.p {e = p; replaced = true; break}
	}
	if !replaced do append(&g.placements, p)
	if k.C != 1 {
		for _ in 0 ..< rows - 1 do linefeed(t)
		t.cx = min(t.cx + cols, t.cols - 1)
	}
}

kitty_execute :: proc(t: ^Term, k: ^Kitty_Ctrl, payload: []u8) {
	g := &t.gfx
	switch k.a {
	case 'q':
		_, _, _, err := kitty_load(t, k, payload)
		kitty_reply(t, k, "OK" if err == "" else err)
	case 't', 'T':
		px, w, h, err := kitty_load(t, k, payload)
		if err != "" {kitty_reply(t, k, err); return}
		if k.i == 0 {
			g.next_id += 1
			k.i = 0x40000000 | g.next_id
		}
		img, exists := g.images[k.i]
		if exists {
			g.bytes -= len(img.pixels)
			delete(img.pixels)
		} else {
			img = new(Image)
			img.id = k.i
			g.images[k.i] = img
		}
		img.pixels, img.w, img.h = px, w, h
		img.version += 1
		g.bytes += len(px)
		gfx_evict(g)
		if k.a == 'T' do kitty_place(t, k, img)
		if !exists && img.id & 0x40000000 != 0 do return // client gave no id: spec says no reply
		kitty_reply(t, k, "OK")
	case 'p':
		img, ok := g.images[k.i]
		if !ok {kitty_reply(t, k, "ENOENT:no image"); return}
		kitty_place(t, k, img)
		kitty_reply(t, k, "OK")
	case 'd':
		d := k.d if k.d != 0 else 'a'
		for i := len(g.placements) - 1; i >= 0; i -= 1 {
			p := g.placements[i]
			hit := false
			switch d {
			case 'a', 'A': hit = true
			case 'i', 'I': hit = p.img == k.i && (k.p == 0 || p.pid == k.p)
			case 'z', 'Z': hit = p.z == k.z
			case 'c', 'C':
				abs := cursor_abs(t)
				hit = abs >= p.abs_row && abs < p.abs_row + i64(p.rows) && t.cx >= p.col && t.cx < p.col + p.cols
			}
			if hit do unordered_remove(&g.placements, i)
		}
		if d == 'A' || d == 'I' {
			ids := make([dynamic]u32, context.temp_allocator)
			for id in g.images do if d == 'A' || id == k.i do append(&ids, id)
			for id in ids do image_free(g, id)
		}
	}
}

// Drop images with no placement first when over budget.
gfx_evict :: proc(g: ^Graphics) {
	if g.bytes <= IMAGE_BUDGET do return
	ids := make([dynamic]u32, context.temp_allocator)
	outer: for id in g.images {
		for p in g.placements do if p.img == id do continue outer
		append(&ids, id)
	}
	for id in ids {
		image_free(g, id)
		if g.bytes <= IMAGE_BUDGET do return
	}
}

// ---------- sixel ----------

sixel_decode :: proc(t: ^Term, s: []u8) {
	pal: [256]u32
	vt340 := [16]u32{0x000000, 0x3333cc, 0xcc2121, 0x33cc33, 0xcc33cc, 0x33cccc, 0xcccc33, 0x878787,
		0x424242, 0x545499, 0x994242, 0x549954, 0x995499, 0x549999, 0x999954, 0xcccccc}
	for i in 0 ..< 16 do pal[i] = vt340[i]
	for i in 16 ..< 256 do pal[i] = 0x808080
	W, H := 0, 0
	px := make([dynamic]u32) // 0 = transparent
	defer delete(px)
	ensure :: proc(px: ^[dynamic]u32, W, H: ^int, w, h: int) {
		if w <= W^ && h <= H^ do return
		nw, nh := max(W^, w, 64), max(H^, h)
		if nw > W^ do nw = max(nw, W^ * 2)
		np := make([dynamic]u32, nw * nh)
		for y in 0 ..< H^ do copy(np[y * nw:y * nw + W^], px[y * W^:(y + 1) * W^])
		delete(px^)
		px^ = np
		W^, H^ = nw, nh
	}
	x, y, color := 0, 0, u32(0)
	maxx, maxy := 0, 0
	i := 0
	read_num :: proc(s: []u8, i: ^int) -> int {
		n := 0
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {n = min(n * 10 + int(s[i^] - '0'), 100000); i^ += 1}
		return n
	}
	color = pal[0]
	for i < len(s) {
		b := s[i]
		i += 1
		switch b {
		case '"':
			read_num(s, &i); if i < len(s) && s[i] == ';' do i += 1
			read_num(s, &i); if i < len(s) && s[i] == ';' do i += 1
			pw := read_num(s, &i); if i < len(s) && s[i] == ';' do i += 1
			ph := read_num(s, &i)
			if pw > 0 && ph > 0 && pw <= 8192 && ph <= 8192 do ensure(&px, &W, &H, pw, ph)
		case '#':
			n := read_num(s, &i) & 255
			if i < len(s) && s[i] == ';' {
				i += 1
				kind := read_num(s, &i); i += 1
				a := read_num(s, &i); i += 1
				bb := read_num(s, &i); i += 1
				c := read_num(s, &i)
				if kind == 2 {
					pal[n] = u32(a * 255 / 100) << 16 | u32(bb * 255 / 100) << 8 | u32(c * 255 / 100)
				} else if kind == 1 {
					pal[n] = hls_to_rgb(a, bb, c)
				}
			}
			color = pal[n]
		case '!':
			n := read_num(s, &i)
			if i < len(s) {
				ch := s[i]
				i += 1
				if ch >= '?' && ch <= '~' {
					sixel_put(&px, &W, &H, x, y, int(ch - '?'), n, color, ensure)
					x += n
				}
			}
		case '$': x = 0
		case '-': x = 0; y += 6
		case '?' ..= '~':
			sixel_put(&px, &W, &H, x, y, int(b - '?'), 1, color, ensure)
			x += 1
		}
		if x > maxx do maxx = x
		if y + 6 > maxy do maxy = y + 6
		if W * H > 8192 * 8192 do break
	}
	w, h := min(W, maxx), min(H, maxy)
	if w <= 0 || h <= 0 do return
	out := make([]u8, w * h * 4)
	for yy in 0 ..< h do for xx in 0 ..< w {
		c := px[yy * W + xx]
		o := (yy * w + xx) * 4
		if c == 0 do continue
		out[o], out[o + 1], out[o + 2], out[o + 3] = u8(c >> 16), u8(c >> 8), u8(c), 255
	}
	g := &t.gfx
	g.next_id += 1
	img := new(Image)
	img.id = 0x40000000 | g.next_id
	img.pixels, img.w, img.h = out, w, h
	img.version = 1
	g.images[img.id] = img
	g.bytes += len(out)
	k := Kitty_Ctrl{C = 1}
	kitty_place(t, &k, img)
	rows := (h + max(t.cell_h, 1) - 1) / max(t.cell_h, 1)
	for _ in 0 ..< rows do linefeed(t)
	gfx_evict(g)
}

sixel_put :: proc(px: ^[dynamic]u32, W, H: ^int, x, y, bits, n: int, color: u32, ensure: proc(^[dynamic]u32, ^int, ^int, int, int)) {
	if bits == 0 do return
	if x + n > 8192 || y + 6 > 8192 do return
	ensure(px, W, H, x + n, y + 6)
	c := color | 0xff000000 // nonzero marks opaque, even for black
	for bit in 0 ..< 6 {
		if bits & (1 << uint(bit)) == 0 do continue
		base := (y + bit) * W^
		for k in 0 ..< n do px[base + x + k] = c
	}
}

hls_to_rgb :: proc(h, l, s: int) -> u32 {
	hf, lf, sf := f32((h + 240) % 360) / 360, f32(l) / 100, f32(s) / 100
	hue :: proc(p, q, t: f32) -> f32 {
		t := t
		if t < 0 do t += 1
		if t > 1 do t -= 1
		if t < 1.0 / 6 do return p + (q - p) * 6 * t
		if t < 0.5 do return q
		if t < 2.0 / 3 do return p + (q - p) * (2.0 / 3 - t) * 6
		return p
	}
	if sf == 0 {v := u32(lf * 255); return v << 16 | v << 8 | v}
	q := lf * (1 + sf) if lf < 0.5 else lf + sf - lf * sf
	p := 2 * lf - q
	r, g, b := hue(p, q, hf + 1.0 / 3), hue(p, q, hf), hue(p, q, hf - 1.0 / 3)
	return u32(r * 255) << 16 | u32(g * 255) << 8 | u32(b * 255)
}
