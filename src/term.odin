package kuraokami

import "core:strings"
import "core:strconv"
import "core:sync"
import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"
import "core:encoding/base64"

// Color encoding: bit 31 = palette index (low byte), bit 30 = default (0 fg, 1 bg), else 0xRRGGBB.
PAL :: u32(1 << 31)
DEF :: u32(1 << 30)
DEF_FG :: DEF | 0
DEF_BG :: DEF | 1

// Cell.ch values >= CLUSTER_BASE index Term.clusters (grapheme clusters: combining marks, ZWJ emoji, flags).
CLUSTER_BASE :: rune(0x110000)

Attr :: enum u8 { Bold, Dim, Italic, Underline, Blink, Inverse, Hidden, Strike }
Attrs :: bit_set[Attr; u8]

Cell :: struct {
	ch:    rune,
	fg, bg: u32,
	attr:  Attrs,
	wide:  u8, // 0 normal, 1 wide head, 2 wide tail, 3 spacer left when a wide char wrapped
	link:  u16, // OSC 8 hyperlink id (0 none)
}

BLANK :: Cell{ch = ' ', fg = DEF_FG, bg = DEF_BG}

Line :: struct {
	cells:   []Cell,
	wrapped: bool, // continues on the next line (soft wrap) - drives reflow and copy
}

// Ring of lines; screen row y lives at index count-rows+y.
Ring :: struct {
	buf:   []Line,
	head:  int,
	count: int,
}

ring_ln :: #force_inline proc(r: ^Ring, i: int) -> ^Line {
	return &r.buf[(r.head + i) % len(r.buf)]
}

ring_line :: #force_inline proc(r: ^Ring, i: int) -> []Cell {
	return r.buf[(r.head + i) % len(r.buf)].cells
}

new_line :: proc(cols: int) -> Line {
	l := Line{cells = make([]Cell, cols)}
	for &c in l.cells do c = BLANK
	return l
}

ring_make :: proc(cap_, cols, rows: int) -> Ring {
	r := Ring{buf = make([]Line, max(cap_, rows))}
	for i in 0 ..< rows do r.buf[i] = new_line(cols)
	r.count = rows
	return r
}

ring_free :: proc(r: ^Ring) {
	for l in r.buf do delete(l.cells)
	delete(r.buf)
}

Parse_State :: enum u8 { Ground, Esc, Esc_Inter, Csi, Osc, Osc_Esc, Str, Str_Esc }

Saved :: struct {
	x, y:    int,
	pen:     Cell,
	origin:  bool,
	charset: bool,
}

Term :: struct {
	mu:              sync.Mutex,
	cols, rows:      int,
	primary, alt:    Ring,
	use_alt:         bool,
	scrollback:      int,
	cx, cy:          int,
	wrap_pending:    bool,
	pen:             Cell,
	saved, saved_alt: Saved,
	top, bot:        int,
	tabs:            []bool,
	// modes
	app_cursor, app_keypad, bracketed, focus_events, mouse_sgr, autowrap, origin, insert, reverse, sync_output: bool,
	cursor_hidden:   bool,
	alt_scroll:      bool,
	mouse_mode:      int, // 0, 1000, 1002, 1003
	cursor_shape:    int, // 0/1/2 block, 3/4 underline, 5/6 bar
	charset_g0_line: bool,
	last_char:       rune,
	// kitty keyboard protocol: flag stacks for main/alt screens
	kb_stack:        [2][16]u8,
	kb_depth:        [2]int,
	// grapheme clusters
	clusters:        [dynamic]string,
	cluster_ids:     map[string]rune,
	// view
	view_off:        int, // lines scrolled back
	total_pushed:    i64, // lines ever pushed off the top of primary (absolute line base)
	dirty:           bool,
	// parser
	state:           Parse_State,
	params:          [32]int,
	sub:             [32]bool, // param i was introduced with ':'
	nparams:         int,
	priv:            u8,
	inter:           u8,
	strbuf:          [dynamic]u8,
	str_overflow:    bool, // sequence exceeded its cap: discard instead of executing
	str_kind:        u8, // 'P' DCS, '_' APC, '^' PM, 'X' SOS
	utf8buf:         [4]u8,
	utf8len, utf8need: int,
	// metadata (read by UI thread under mu)
	title:           string,
	title_changed:   bool,
	cwd:             string,
	clipboard_set:   string,
	clipboard_pending: bool,
	bell:            bool,
	notify:          [dynamic]string,
	links:           [dynamic]string,
	link_ids:        map[string]u16,
	cur_link:        u16,
	prompts:         [dynamic]i64,
	palette:         [256]u32,
	fg_color, bg_color, cursor_color: u32,
	// graphics
	cell_w, cell_h:  int,
	gfx:             Graphics,
	// io
	pty:             Pty,
	exited:          bool,
	closing:         bool, // atomic: pane closed, the reader must stop touching the fd
	refs:            i32,  // atomic: UI + reader thread; the last one to let go frees the Term
	reply:           [dynamic]u8,
}

palette_reset :: proc(t: ^Term) {
	for i in 0 ..< 16 do t.palette[i] = cfg.palette[i]
	lv := [6]u32{0, 95, 135, 175, 215, 255}
	for i in 0 ..< 216 {
		t.palette[16 + i] = lv[i / 36] << 16 | lv[(i / 6) % 6] << 8 | lv[i % 6]
	}
	for i in 0 ..< 24 {
		g := u32(8 + i * 10)
		t.palette[232 + i] = g << 16 | g << 8 | g
	}
	t.fg_color, t.bg_color, t.cursor_color = cfg.fg, cfg.bg, cfg.cursor
}

term_init :: proc(t: ^Term, cols, rows: int) {
	t.cols, t.rows = cols, rows
	t.scrollback = cfg.scrollback
	t.primary = ring_make(rows + t.scrollback, cols, rows)
	t.alt = ring_make(rows, cols, rows)
	t.pen = BLANK
	t.top, t.bot = 0, rows - 1
	t.autowrap = true
	t.alt_scroll = true
	t.tabs = make([]bool, cols)
	for i := 0; i < cols; i += 8 do t.tabs[i] = true
	append(&t.links, "")
	palette_reset(t)
	t.dirty = true
}

term_destroy :: proc(t: ^Term) {
	ring_free(&t.primary)
	ring_free(&t.alt)
	delete(t.tabs)
	delete(t.strbuf)
	delete(t.title)
	delete(t.cwd)
	delete(t.clipboard_set)
	for s in t.links do delete(s)
	delete(t.links)
	delete(t.link_ids)
	for s in t.clusters do delete(s)
	delete(t.clusters)
	delete(t.cluster_ids)
	delete(t.prompts)
	delete(t.reply)
	delete(t.notify)
	gfx_destroy(&t.gfx)
}

screen :: #force_inline proc(t: ^Term) -> ^Ring {
	return &t.alt if t.use_alt else &t.primary
}

row :: #force_inline proc(t: ^Term, y: int) -> []Cell {
	r := screen(t)
	return ring_line(r, r.count - t.rows + y)
}

row_ln :: #force_inline proc(t: ^Term, y: int) -> ^Line {
	r := screen(t)
	return ring_ln(r, r.count - t.rows + y)
}

blank_cell :: #force_inline proc(t: ^Term) -> Cell {
	// Erased cells take the current background (BCE), like xterm.
	return Cell{ch = ' ', fg = t.pen.fg, bg = t.pen.bg}
}

clear_cells :: proc(t: ^Term, l: []Cell) {
	b := blank_cell(t)
	for &c in l do c = b
}

clear_row :: proc(t: ^Term, y: int) {
	ln := row_ln(t, y)
	clear_cells(t, ln.cells)
	ln.wrapped = false
}

// Rotate screen rows [a,b] up by one inside the ring: row a moves to b and is cleared.
rotate_up :: proc(t: ^Term, r: ^Ring, base, a, b: int) {
	first := ring_ln(r, base + a)^
	for y in a ..< b do ring_ln(r, base + y)^ = ring_ln(r, base + y + 1)^
	ring_ln(r, base + b)^ = first
	clear_cells(t, first.cells)
	ring_ln(r, base + b).wrapped = false
}

// Scroll region [top,bot] up by n lines. Full-screen scrolls on primary feed scrollback.
scroll_up :: proc(t: ^Term, n: int) {
	n := min(n, t.bot - t.top + 1)
	r := screen(t)
	if !t.use_alt && t.top == 0 && t.bot == t.rows - 1 {
		for _ in 0 ..< n {
			if r.count < len(r.buf) {
				ln := ring_ln(r, r.count)
				if len(ln.cells) != t.cols {
					delete(ln.cells)
					ln.cells = make([]Cell, t.cols)
				}
				clear_cells(t, ln.cells)
				ln.wrapped = false
				r.count += 1
			} else {
				old := &r.buf[r.head]
				r.head = (r.head + 1) % len(r.buf)
				clear_cells(t, old.cells)
				old.wrapped = false
			}
			t.total_pushed += 1
			if t.view_off > 0 do t.view_off = min(t.view_off + 1, r.count - t.rows)
		}
		return
	}
	base := r.count - t.rows
	for _ in 0 ..< n do rotate_up(t, r, base, t.top, t.bot)
}

scroll_down :: proc(t: ^Term, n: int) {
	n := min(n, t.bot - t.top + 1)
	r := screen(t)
	base := r.count - t.rows
	for _ in 0 ..< n {
		last := ring_ln(r, base + t.bot)^
		for y := t.bot; y > t.top; y -= 1 do ring_ln(r, base + y)^ = ring_ln(r, base + y - 1)^
		ring_ln(r, base + t.top)^ = last
		clear_cells(t, last.cells)
		ring_ln(r, base + t.top).wrapped = false
	}
}

linefeed :: proc(t: ^Term) {
	if t.cy == t.bot do scroll_up(t, 1)
	else if t.cy < t.rows - 1 do t.cy += 1
}

// ---------- resize & reflow ----------

is_blank :: #force_inline proc(c: Cell) -> bool {
	return c.ch == ' ' && c.bg == DEF_BG && c.attr == {} && c.link == 0
}

// Rewrap every logical line of the primary screen to the new width, tracking the cursor.
reflow :: proc(t: ^Term, r: ^Ring, cols, rows, cap_: int) -> (Ring, int, int) {
	ci := r.count - t.rows + t.cy
	out := make([dynamic]Line)
	defer delete(out)
	cells := make([dynamic]Cell)
	defer delete(cells)
	cur_row, cur_col := -1, 0
	i := 0
	for i < r.count {
		j := i
		for j < r.count - 1 && ring_ln(r, j).wrapped do j += 1
		clear(&cells)
		cur_off := -1
		for k in i ..= j {
			if k == ci do cur_off = len(cells) + t.cx
			append(&cells, ..ring_line(r, k))
		}
		n := len(cells)
		for n > 0 && is_blank(cells[n - 1]) do n -= 1
		if cur_off >= 0 do n = max(n, min(cur_off + 1, len(cells)))
		pos := 0
		for {
			ln := new_line(cols)
			x := 0
			for pos < n && x < cols {
				c := cells[pos]
				if c.wide >= 2 {pos += 1; continue} // orphan tail or wrap spacer
				if c.wide == 1 {
					if x == cols - 1 do break // wide char moves to the next row
					ln.cells[x] = c
					if pos + 1 < len(cells) do ln.cells[x + 1] = cells[pos + 1]
					if pos == cur_off || pos + 1 == cur_off {cur_row, cur_col = len(out), x + (1 if pos + 1 == cur_off else 0)}
					x += 2
					pos += 2
					continue
				}
				ln.cells[x] = c
				if pos == cur_off {cur_row, cur_col = len(out), x}
				x += 1
				pos += 1
			}
			ln.wrapped = pos < n
			append(&out, ln)
			if pos >= n do break
		}
		if cur_off >= 0 && cur_row < 0 {cur_row, cur_col = len(out) - 1, min(cur_off, cols - 1)}
		i = j + 1
	}
	if cur_row < 0 do cur_row = len(out) - 1
	// Keep non-blank lines below the cursor (at most a screenful); trailing blank lines are dropped
	// so growing content uses the empty space instead of pushing history into scrollback.
	last := cur_row
	for k in cur_row + 1 ..< len(out) {
		for cl in out[k].cells do if !is_blank(cl) {last = k; break}
	}
	keep := min(len(out), last + 1, cur_row + rows)
	for k in keep ..< len(out) do delete(out[k].cells)
	resize(&out, keep)
	for len(out) < rows do append(&out, new_line(cols))
	start := max(0, len(out) - cap_)
	for k in 0 ..< start do delete(out[k].cells)
	nr := Ring{buf = make([]Line, max(cap_, rows))}
	for k in start ..< len(out) {
		nr.buf[nr.count] = out[k]
		nr.count += 1
	}
	cy := (cur_row - start) - (nr.count - rows)
	return nr, clamp(cy, 0, rows - 1), clamp(cur_col, 0, cols - 1)
}

// Non-reflowing resize (alt screen): keeps lines up to the cursor, truncates/pads columns.
ring_resize :: proc(t: ^Term, r: ^Ring, cap_, cols, rows, cy: int) -> (Ring, int) {
	oldrows := t.rows
	through := r.count - oldrows + cy + 1
	after := min(oldrows - cy - 1, max(0, rows - (cy + 1)))
	n := through + after
	start := max(0, n - cap_)
	nr := Ring{buf = make([]Line, max(cap_, rows))}
	for i in start ..< n {
		src := ring_line(r, i)
		dst := new_line(cols)
		for x in 0 ..< min(cols, len(src)) do dst.cells[x] = src[x]
		if cols < len(src) && dst.cells[cols - 1].wide == 1 do dst.cells[cols - 1] = BLANK
		nr.buf[nr.count] = dst
		nr.count += 1
	}
	for nr.count < rows {
		nr.buf[nr.count] = new_line(cols)
		nr.count += 1
	}
	cur_idx := through - 1 - start
	new_cy := cur_idx - (nr.count - rows)
	return nr, clamp(new_cy, 0, rows - 1)
}

term_resize :: proc(t: ^Term, cols, rows: int) {
	if cols == t.cols && rows == t.rows do return
	cols, rows := max(cols, 2), max(rows, 1)
	old_sb := t.primary.count - t.rows
	np: Ring
	pcy, pcx: int
	if t.use_alt {
		// Reflow primary using the saved cursor.
		scx, scy := t.cx, t.cy
		t.cx, t.cy = min(t.saved.x, t.cols - 1), min(t.saved.y, t.rows - 1)
		np, pcy, pcx = reflow(t, &t.primary, cols, rows, rows + t.scrollback)
		t.cx, t.cy = scx, scy
	} else {
		np, pcy, pcx = reflow(t, &t.primary, cols, rows, rows + t.scrollback)
	}
	na, acy := ring_resize(t, &t.alt, rows, cols, rows, t.cy if t.use_alt else 0)
	t.total_pushed += i64((np.count - rows) - old_sb)
	ring_free(&t.primary)
	ring_free(&t.alt)
	t.primary, t.alt = np, na
	if t.use_alt {
		t.cy = acy
		t.cx = min(t.cx, cols - 1)
		t.saved.y, t.saved.x = pcy, pcx
	} else {
		t.cy, t.cx = pcy, pcx
	}
	t.cols, t.rows = cols, rows
	t.top, t.bot = 0, rows - 1
	t.wrap_pending = false
	t.view_off = 0
	delete(t.tabs)
	t.tabs = make([]bool, cols)
	for i := 0; i < cols; i += 8 do t.tabs[i] = true
	t.dirty = true
}

// ---------- writing characters ----------

DEC_LINE := [32]rune {
	'◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋', '┘', '┐', '┌', '└', '┼', '⎺',
	'⎻', '─', '⎼', '⎽', '├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠', '£', '·', ' ',
}

ZWJ :: rune(0x200D)

is_ri :: #force_inline proc(r: rune) -> bool {return r >= 0x1F1E6 && r <= 0x1F1FF}

// Text of a cell (single rune or grapheme cluster). Caller holds t.mu.
cell_text :: proc(t: ^Term, ch: rune, buf: ^[4]u8) -> string {
	if ch >= CLUSTER_BASE {
		id := int(ch - CLUSTER_BASE)
		return t.clusters[id] if id < len(t.clusters) else ""
	}
	b, n := utf8.encode_rune(ch)
	buf^ = b
	return string(buf[:n])
}

cluster_append :: proc(t: ^Term, c: ^Cell, r: rune) {
	if len(t.clusters) >= 65536 do return // shortcut: cap distinct clusters; beyond that extra marks are dropped
	buf: [4]u8
	s := strings.concatenate({cell_text(t, c.ch, &buf), string(utf8.runes_to_string({r}, context.temp_allocator))}, context.temp_allocator)
	if id, ok := t.cluster_ids[s]; ok {c.ch = id; return}
	owned := strings.clone(s)
	id := CLUSTER_BASE + rune(len(t.clusters))
	append(&t.clusters, owned)
	t.cluster_ids[owned] = id
	c.ch = id
}

// Previous written cell (head of a wide char) or nil.
prev_cell :: proc(t: ^Term) -> ^Cell {
	x := t.cx if t.wrap_pending else t.cx - 1
	if x < 0 do return nil
	l := row(t, t.cy)
	if l[x].wide == 2 && x > 0 do x -= 1
	return &l[x]
}

last_rune :: proc(t: ^Term, ch: rune) -> (r: rune, count: int) {
	if ch < CLUSTER_BASE do return ch, 1
	buf: [4]u8
	s := cell_text(t, ch, &buf)
	for x in s {r = x; count += 1}
	return
}

// Fast path for printable ASCII (the bulk of output): no width lookup, no grapheme joining.
put_ascii :: proc(t: ^Term, b: u8) {
	if t.charset_g0_line || t.insert {put_char(t, rune(b)); return}
	if t.wrap_pending && t.autowrap {
		row_ln(t, t.cy).wrapped = true
		t.cx = 0
		linefeed(t)
	}
	t.wrap_pending = false
	l := row(t, t.cy)
	c := &l[t.cx]
	if c.wide != 0 {put_char(t, rune(b)); return} // overwriting part of a wide char: slow path cleans up
	c^ = t.pen
	c.ch = rune(b)
	c.link = t.cur_link
	t.last_char = rune(b)
	if t.cx + 1 >= t.cols do t.wrap_pending = true
	else do t.cx += 1
}

put_char :: proc(t: ^Term, ch: rune) {
	ch := ch
	if t.charset_g0_line && ch >= 0x5f && ch <= 0x7e do ch = DEC_LINE[ch - 0x5f]
	w := rune_width(ch)
	// Grapheme joining: combining marks, ZWJ sequences, and regional-indicator pairs (flags).
	if p := prev_cell(t); p != nil && p.ch != ' ' && p.ch != 0 {
		lr, cnt := last_rune(t, p.ch)
		if w == 0 || lr == ZWJ || (is_ri(ch) && is_ri(lr) && cnt == 1) {
			cluster_append(t, p, ch)
			return
		}
	}
	if w == 0 do return
	if t.wrap_pending && t.autowrap {
		row_ln(t, t.cy).wrapped = true
		t.cx = 0
		linefeed(t)
	}
	t.wrap_pending = false
	if w == 2 && t.cx == t.cols - 1 {
		if t.autowrap {
			sp := blank_cell(t)
			sp.wide = 3
			row(t, t.cy)[t.cx] = sp
			row_ln(t, t.cy).wrapped = true
			t.cx = 0
			linefeed(t)
		} else do return
	}
	l := row(t, t.cy)
	if t.insert {
		copy(l[t.cx + w:], l[t.cx:len(l) - w])
	}
	// Overwriting half of a wide char clears the other half.
	if l[t.cx].wide == 2 && t.cx > 0 do l[t.cx - 1] = blank_cell(t)
	if l[t.cx].wide == 1 && t.cx + 1 < t.cols do l[t.cx + 1] = blank_cell(t)
	c := t.pen
	c.ch = ch
	c.link = t.cur_link
	c.wide = 1 if w == 2 else 0
	l[t.cx] = c
	if w == 2 {
		if t.cx + 2 < t.cols && l[t.cx + 2].wide == 2 do l[t.cx + 2] = blank_cell(t)
		c.wide = 2
		c.ch = 0
		l[t.cx + 1] = c
	}
	t.last_char = ch
	if t.cx + w >= t.cols {
		t.cx = t.cols - 1
		t.wrap_pending = true
	} else do t.cx += w
}

// ---------- parser ----------

term_feed :: proc(t: ^Term, data: []u8) {
	for b in data {
		switch t.state {
		case .Ground:
			if t.utf8need > 0 {
				if b & 0xC0 == 0x80 {
					t.utf8buf[t.utf8len] = b
					t.utf8len += 1
					if t.utf8len == t.utf8need {
						r, _ := utf8.decode_rune(t.utf8buf[:t.utf8len])
						t.utf8need = 0
						put_char(t, r)
					}
					continue
				}
				t.utf8need = 0
				put_char(t, utf8.RUNE_ERROR)
			}
			if b < 0x20 || b == 0x7f do control(t, b)
			else if b < 0x80 do put_ascii(t, b)
			else {
				need := 2 if b & 0xE0 == 0xC0 else 3 if b & 0xF0 == 0xE0 else 4 if b & 0xF8 == 0xF0 else 0
				if need == 0 {put_char(t, utf8.RUNE_ERROR); continue}
				t.utf8buf[0] = b
				t.utf8len, t.utf8need = 1, need
			}
		case .Esc:
			esc_dispatch(t, b)
		case .Esc_Inter:
			if b >= 0x20 && b < 0x30 {t.inter = b; continue}
			if t.inter == '(' do t.charset_g0_line = b == '0'
			else if t.inter == '#' && b == '8' {
				for y in 0 ..< t.rows do for &c in row(t, y) do c = Cell{ch = 'E', fg = DEF_FG, bg = DEF_BG}
			}
			t.state = .Ground
		case .Csi:
			switch b {
			case '0' ..= '9':
				if t.nparams == 0 do t.nparams = 1
				p := &t.params[t.nparams - 1]
				p^ = min(p^ * 10 + int(b - '0'), 99999)
			case ';', ':':
				if t.nparams == 0 do t.nparams = 1
				if t.nparams < len(t.params) {
					t.params[t.nparams] = 0
					t.sub[t.nparams] = b == ':'
					t.nparams += 1
				}
			case '<', '=', '>', '?':
				t.priv = b
			case 0x20 ..= 0x2f:
				t.inter = b
			case 0x40 ..= 0x7e:
				csi_dispatch(t, b)
				t.state = .Ground
			case 0x18, 0x1a:
				t.state = .Ground
			case 0x1b:
				t.state = .Esc
			case:
				if b < 0x20 do control(t, b)
			}
		case .Osc:
			if b == 0x07 {osc_dispatch(t); t.state = .Ground}
			else if b == 0x1b do t.state = .Osc_Esc
			else do str_push(t, b, MAX_OSC)
		case .Osc_Esc:
			osc_dispatch(t)
			t.state = .Ground
			if b != '\\' {t.state = .Esc; esc_dispatch(t, b)}
		case .Str:
			if b == 0x1b do t.state = .Str_Esc
			else if b == 0x07 && t.str_kind != 'P' {str_dispatch(t); t.state = .Ground}
			else do str_push(t, b, MAX_STR)
		case .Str_Esc:
			if b == '\\' {str_dispatch(t); t.state = .Ground}
			else {
				str_push(t, 0x1b, MAX_STR)
				str_push(t, b, MAX_STR)
				t.state = .Str
			}
		}
	}
	t.dirty = true
}

begin_seq :: proc(t: ^Term) {
	t.nparams = 0
	t.params = {}
	t.sub = {}
	t.priv = 0
	t.inter = 0
}

control :: proc(t: ^Term, b: u8) {
	switch b {
	case 0x07: t.bell = true
	case 0x08:
		if t.cx > 0 {t.cx -= 1}
		t.wrap_pending = false
	case 0x09:
		t.cx = min(t.cx + 1, t.cols - 1)
		for t.cx < t.cols - 1 && !t.tabs[t.cx] do t.cx += 1
	case 0x0a, 0x0b, 0x0c:
		linefeed(t)
		t.wrap_pending = false
	case 0x0d:
		t.cx = 0
		t.wrap_pending = false
	case 0x0e, 0x0f:
	case 0x1b:
		begin_seq(t)
		t.state = .Esc
	}
}

esc_dispatch :: proc(t: ^Term, b: u8) {
	t.state = .Ground
	switch b {
	case '[':
		begin_seq(t)
		t.state = .Csi
	case ']':
		clear(&t.strbuf)
		t.str_overflow = false
		t.state = .Osc
	case 'P', '_', '^', 'X':
		clear(&t.strbuf)
		t.str_overflow = false
		t.str_kind = b
		t.state = .Str
	case '(', ')', '*', '+', '#', '%', ' ':
		t.inter = b
		t.state = .Esc_Inter
	case '7': save_cursor(t)
	case '8': restore_cursor(t)
	case 'D': linefeed(t)
	case 'E': t.cx = 0; linefeed(t)
	case 'H': t.tabs[t.cx] = true
	case 'M':
		if t.cy == t.top do scroll_down(t, 1)
		else if t.cy > 0 do t.cy -= 1
	case 'c': full_reset(t)
	case '=': t.app_keypad = true
	case '>': t.app_keypad = false
	case '\\':
	}
}

full_reset :: proc(t: ^Term) {
	if t.use_alt do set_alt(t, false, false)
	t.pen = BLANK
	t.cx, t.cy = 0, 0
	t.top, t.bot = 0, t.rows - 1
	t.app_cursor, t.app_keypad, t.bracketed, t.focus_events, t.mouse_sgr = false, false, false, false, false
	t.origin, t.insert, t.reverse, t.cursor_hidden = false, false, false, false
	t.autowrap = true
	t.mouse_mode = 0
	t.charset_g0_line = false
	t.cursor_shape = 0
	t.kb_depth = {}
	palette_reset(t)
	for y in 0 ..< t.rows do clear_row(t, y)
	gfx_clear_placements(&t.gfx)
}

save_cursor :: proc(t: ^Term) {
	s := &t.saved_alt if t.use_alt else &t.saved
	s^ = Saved{t.cx, t.cy, t.pen, t.origin, t.charset_g0_line}
}

restore_cursor :: proc(t: ^Term) {
	s := &t.saved_alt if t.use_alt else &t.saved
	t.cx, t.cy = min(s.x, t.cols - 1), min(s.y, t.rows - 1)
	t.pen, t.origin, t.charset_g0_line = s.pen, s.origin, s.charset
	t.wrap_pending = false
}

set_alt :: proc(t: ^Term, on: bool, clear_it: bool) {
	if on == t.use_alt do return
	t.use_alt = on
	t.view_off = 0
	if on && clear_it {
		for y in 0 ..< t.rows {
			for &c in row(t, y) do c = BLANK
			row_ln(t, y).wrapped = false
		}
	}
	t.dirty = true
}

param :: #force_inline proc(t: ^Term, i: int, def: int) -> int {
	if i >= t.nparams || t.params[i] == 0 do return def
	return t.params[i]
}

move_to :: proc(t: ^Term, x, y: int) {
	miny, maxy := 0, t.rows - 1
	yy := y
	if t.origin {
		miny, maxy = t.top, t.bot
		yy += t.top
	}
	t.cx = clamp(x, 0, t.cols - 1)
	t.cy = clamp(yy, miny, maxy)
	t.wrap_pending = false
}

reply :: proc(t: ^Term, s: string) {
	append(&t.reply, s)
}

// Current kitty keyboard flags for the active screen.
kb_flags :: proc(t: ^Term) -> u8 {
	s := 1 if t.use_alt else 0
	return t.kb_stack[s][t.kb_depth[s] - 1] if t.kb_depth[s] > 0 else 0
}

KB_SUPPORTED :: u8(1 | 2 | 8 | 16) // disambiguate, event types, all keys as escapes, associated text

kb_csi :: proc(t: ^Term, b: u8) {
	s := 1 if t.use_alt else 0
	st := &t.kb_stack[s]
	d := &t.kb_depth[s]
	switch t.priv {
	case '?': reply(t, fmt.tprintf("\x1b[?%du", kb_flags(t)))
	case '>':
		f := u8(param(t, 0, 0)) & KB_SUPPORTED
		if d^ == len(st) {copy(st[:], st[1:]); d^ -= 1}
		st[d^] = f
		d^ += 1
	case '<':
		d^ = max(0, d^ - param(t, 0, 1))
	case '=':
		f := u8(param(t, 0, 0)) & KB_SUPPORTED
		mode := param(t, 1, 1)
		if d^ == 0 {st[0] = 0; d^ = 1}
		cur := &st[d^ - 1]
		switch mode {
		case 1: cur^ = f
		case 2: cur^ |= f
		case 3: cur^ &~= f
		}
	}
}

csi_dispatch :: proc(t: ^Term, b: u8) {
	p0 := param(t, 0, 1)
	if b == 'u' && t.priv != 0 {kb_csi(t, b); return}
	if t.priv == '?' {
		switch b {
		case 'h', 'l':
			for i in 0 ..< max(t.nparams, 1) do set_mode_private(t, t.params[i], b == 'h')
		case 'p':
			if t.inter == '$' {
				mode := t.params[0]
				st := 0
				switch mode {
				case 1: st = 1 if t.app_cursor else 2
				case 7: st = 1 if t.autowrap else 2
				case 25: st = 2 if t.cursor_hidden else 1
				case 1000, 1002, 1003: st = 1 if t.mouse_mode == mode else 2
				case 1004: st = 1 if t.focus_events else 2
				case 1006: st = 1 if t.mouse_sgr else 2
				case 1049, 47, 1047: st = 1 if t.use_alt else 2
				case 2004: st = 1 if t.bracketed else 2
				case 2026: st = 1 if t.sync_output else 2
				}
				reply(t, fmt.tprintf("\x1b[?%d;%d$y", mode, st))
			}
		}
		return
	}
	if t.priv == '>' {
		switch b {
		case 'c': reply(t, "\x1b[>1;10;0c")
		case 'q': reply(t, "\x1bP>|kuraokami " + VERSION + "\x1b\\")
		}
		return
	}
	if t.inter == ' ' && b == 'q' {
		t.cursor_shape = param(t, 0, 0)
		return
	}
	switch b {
	case '@':
		l := row(t, t.cy)
		n := min(p0, t.cols - t.cx)
		copy(l[t.cx + n:], l[t.cx:t.cols - n])
		clear_cells(t, l[t.cx:t.cx + n])
	case 'A': move_to(t, t.cx, t.cy - p0 - (t.top if t.origin else 0))
	case 'B', 'e': move_to(t, t.cx, t.cy + p0 - (t.top if t.origin else 0))
	case 'C', 'a': move_to(t, t.cx + p0, t.cy - (t.top if t.origin else 0))
	case 'D': move_to(t, t.cx - p0, t.cy - (t.top if t.origin else 0))
	case 'E': move_to(t, 0, t.cy + p0 - (t.top if t.origin else 0))
	case 'F': move_to(t, 0, t.cy - p0 - (t.top if t.origin else 0))
	case 'G', '`': move_to(t, p0 - 1, t.cy - (t.top if t.origin else 0))
	case 'H', 'f': move_to(t, param(t, 1, 1) - 1, p0 - 1)
	case 'I':
		for _ in 0 ..< p0 {
			t.cx = min(t.cx + 1, t.cols - 1)
			for t.cx < t.cols - 1 && !t.tabs[t.cx] do t.cx += 1
		}
	case 'J':
		switch param(t, 0, 0) {
		case 0:
			clear_cells(t, row(t, t.cy)[t.cx:])
			row_ln(t, t.cy).wrapped = false
			for y in t.cy + 1 ..< t.rows do clear_row(t, y)
		case 1:
			for y in 0 ..< t.cy do clear_row(t, y)
			clear_cells(t, row(t, t.cy)[:t.cx + 1])
		case 2:
			for y in 0 ..< t.rows do clear_row(t, y)
			// History must not soft-wrap into the cleared screen (reflow would join them).
			if r := screen(t); r.count > t.rows do ring_ln(r, r.count - t.rows - 1).wrapped = false
			gfx_clear_visible(&t.gfx, t.total_pushed, t.rows)
		case 3:
			if !t.use_alt {
				r := &t.primary
				keep := t.rows
				r.head = (r.head + r.count - keep) % len(r.buf)
				r.count = keep
				t.view_off = 0
			}
		}
	case 'K':
		l := row(t, t.cy)
		switch param(t, 0, 0) {
		case 0: clear_cells(t, l[t.cx:]); row_ln(t, t.cy).wrapped = false
		case 1: clear_cells(t, l[:t.cx + 1])
		case 2: clear_row(t, t.cy)
		}
	case 'L', 'M':
		if t.cy >= t.top && t.cy <= t.bot {
			otop := t.top
			t.top = t.cy
			if b == 'L' do scroll_down(t, p0)
			else do scroll_up_region(t, p0)
			t.top = otop
			t.cx = 0
		}
	case 'P':
		l := row(t, t.cy)
		n := min(p0, t.cols - t.cx)
		copy(l[t.cx:], l[t.cx + n:])
		clear_cells(t, l[t.cols - n:])
	case 'S': scroll_up_region(t, p0)
	case 'T': scroll_down(t, p0)
	case 'X':
		l := row(t, t.cy)
		clear_cells(t, l[t.cx:min(t.cx + p0, t.cols)])
	case 'Z':
		for _ in 0 ..< p0 {
			if t.cx > 0 do t.cx -= 1
			for t.cx > 0 && !t.tabs[t.cx] do t.cx -= 1
		}
	case 'b':
		if t.last_char != 0 do for _ in 0 ..< min(p0, 65535) do put_char(t, t.last_char)
	case 'c': if t.priv == 0 do reply(t, "\x1b[?62;4;22c")
	case 'd': move_to(t, t.cx, p0 - 1)
	case 'g':
		switch param(t, 0, 0) {
		case 0: t.tabs[t.cx] = false
		case 3: for &s in t.tabs do s = false
		}
	case 'h', 'l':
		for i in 0 ..< max(t.nparams, 1) do if t.params[i] == 4 do t.insert = b == 'h'
	case 'm': sgr(t)
	case 'n':
		switch param(t, 0, 0) {
		case 5: reply(t, "\x1b[0n")
		case 6: reply(t, fmt.tprintf("\x1b[%d;%dR", t.cy + 1 - (t.top if t.origin else 0), t.cx + 1))
		}
	case 'r':
		top, bot := param(t, 0, 1) - 1, param(t, 1, t.rows) - 1
		if top < bot && bot < t.rows {
			t.top, t.bot = top, bot
			move_to(t, 0, 0)
		}
	case 's': save_cursor(t)
	case 'u': restore_cursor(t)
	case 't':
		switch param(t, 0, 0) {
		case 14: reply(t, fmt.tprintf("\x1b[4;%d;%dt", t.rows * t.cell_h, t.cols * t.cell_w))
		case 16: reply(t, fmt.tprintf("\x1b[6;%d;%dt", t.cell_h, t.cell_w))
		case 18: reply(t, fmt.tprintf("\x1b[8;%d;%dt", t.rows, t.cols))
		}
	}
}

scroll_up_region :: proc(t: ^Term, n: int) {
	// CSI S / DL must not feed scrollback even when the region is the full screen.
	if !t.use_alt && t.top == 0 && t.bot == t.rows - 1 {
		r := screen(t)
		base := r.count - t.rows
		for _ in 0 ..< min(n, t.rows) do rotate_up(t, r, base, 0, t.rows - 1)
		return
	}
	scroll_up(t, n)
}

set_mode_private :: proc(t: ^Term, m: int, on: bool) {
	switch m {
	case 1: t.app_cursor = on
	case 5: t.reverse = on
	case 6:
		t.origin = on
		move_to(t, 0, 0)
	case 7: t.autowrap = on
	case 25: t.cursor_hidden = !on
	case 47, 1047: set_alt(t, on, on)
	case 1049:
		if on {save_cursor(t); set_alt(t, true, true)}
		else {set_alt(t, false, false); restore_cursor(t)}
	case 1000, 1002, 1003: t.mouse_mode = m if on else 0
	case 1004: t.focus_events = on
	case 1006: t.mouse_sgr = on
	case 1007: t.alt_scroll = on
	case 2004: t.bracketed = on
	case 2026: t.sync_output = on
	}
}

sgr_color :: proc(t: ^Term, i: ^int) -> (u32, bool) {
	if i^ + 1 >= t.nparams do return 0, false
	switch t.params[i^ + 1] {
	case 5:
		if i^ + 2 >= t.nparams do return 0, false
		c := PAL | u32(t.params[i^ + 2] & 0xff)
		i^ += 2
		return c, true
	case 2:
		// Both 38;2;r;g;b and 38:2::r:g:b (colorspace slot) forms.
		off := 2
		if t.sub[i^ + 2] && i^ + 5 < t.nparams && t.sub[i^ + 5] do off = 3
		if i^ + off + 2 >= t.nparams do return 0, false
		r, g, b := u32(t.params[i^ + off] & 0xff), u32(t.params[i^ + off + 1] & 0xff), u32(t.params[i^ + off + 2] & 0xff)
		i^ += off + 2
		return r << 16 | g << 8 | b, true
	}
	return 0, false
}

sgr :: proc(t: ^Term) {
	if t.nparams == 0 {
		t.pen.fg, t.pen.bg, t.pen.attr = DEF_FG, DEF_BG, {}
		return
	}
	for i := 0; i < t.nparams; i += 1 {
		p := t.params[i]
		switch p {
		case 0: t.pen.fg, t.pen.bg, t.pen.attr = DEF_FG, DEF_BG, {}
		case 1: t.pen.attr += {.Bold}
		case 2: t.pen.attr += {.Dim}
		case 3: t.pen.attr += {.Italic}
		case 4:
			if i + 1 < t.nparams && t.sub[i + 1] {
				if t.params[i + 1] == 0 do t.pen.attr -= {.Underline}
				else do t.pen.attr += {.Underline}
				i += 1
			} else do t.pen.attr += {.Underline}
		case 5, 6: t.pen.attr += {.Blink}
		case 7: t.pen.attr += {.Inverse}
		case 8: t.pen.attr += {.Hidden}
		case 9: t.pen.attr += {.Strike}
		case 21: t.pen.attr += {.Underline}
		case 22: t.pen.attr -= {.Bold, .Dim}
		case 23: t.pen.attr -= {.Italic}
		case 24: t.pen.attr -= {.Underline}
		case 25: t.pen.attr -= {.Blink}
		case 27: t.pen.attr -= {.Inverse}
		case 28: t.pen.attr -= {.Hidden}
		case 29: t.pen.attr -= {.Strike}
		case 30 ..= 37: t.pen.fg = PAL | u32(p - 30)
		case 38: if c, ok := sgr_color(t, &i); ok do t.pen.fg = c
		case 39: t.pen.fg = DEF_FG
		case 40 ..= 47: t.pen.bg = PAL | u32(p - 40)
		case 48: if c, ok := sgr_color(t, &i); ok do t.pen.bg = c
		case 49: t.pen.bg = DEF_BG
		case 58: sgr_color(t, &i) // underline color: parsed, not rendered
		case 90 ..= 97: t.pen.fg = PAL | u32(p - 90 + 8)
		case 100 ..= 107: t.pen.bg = PAL | u32(p - 100 + 8)
		}
	}
}

parse_color_spec :: proc(s: string) -> (u32, bool) {
	if strings.has_prefix(s, "#") && len(s) == 7 {
		v, ok := strconv.parse_uint(s[1:], 16)
		return u32(v), ok
	}
	if strings.has_prefix(s, "rgb:") {
		parts := strings.split(s[4:], "/", context.temp_allocator)
		if len(parts) != 3 do return 0, false
		out: u32
		for p in parts {
			v, ok := strconv.parse_uint(p, 16)
			if !ok || len(p) == 0 || len(p) > 4 do return 0, false
			bits := uint(len(p) * 4)
			out = out << 8 | u32(v * 255 / ((1 << bits) - 1))
		}
		return out, true
	}
	return 0, false
}

color_reply :: proc(t: ^Term, code: int, c: u32) {
	r, g, b := (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff
	reply(t, fmt.tprintf("\x1b]%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\", code, r, r, g, g, b, b))
}

osc_dispatch :: proc(t: ^Term) {
	if t.str_overflow do return
	s := string(t.strbuf[:])
	semi := strings.index_byte(s, ';')
	code_s := s if semi < 0 else s[:semi]
	rest := "" if semi < 0 else s[semi + 1:]
	code, ok := strconv.parse_int(code_s)
	if !ok do return
	switch code {
	case 0, 2:
		delete(t.title)
		t.title = strings.clone(rest)
		t.title_changed = true
	case 4:
		parts := strings.split(rest, ";", context.temp_allocator)
		for i := 0; i + 1 < len(parts); i += 2 {
			idx, ok1 := strconv.parse_int(parts[i])
			if !ok1 || idx < 0 || idx > 255 do continue
			if parts[i + 1] == "?" {
				c := t.palette[idx]
				r, g, b := (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff
				reply(t, fmt.tprintf("\x1b]4;%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\", idx, r, r, g, g, b, b))
			} else if c, ok2 := parse_color_spec(parts[i + 1]); ok2 do t.palette[idx] = c
		}
	case 7:
		p := rest
		if strings.has_prefix(p, "file://") {
			p = p[7:]
			if i := strings.index_byte(p, '/'); i >= 0 do p = p[i:]
		}
		delete(t.cwd)
		t.cwd = percent_decode(p)
	case 8:
		i := strings.index_byte(rest, ';')
		uri := "" if i < 0 else rest[i + 1:]
		if uri == "" || len(uri) > 4096 do t.cur_link = 0
		else if id, ok := t.link_ids[uri]; ok do t.cur_link = id // same URI reuses its id (ls --hyperlink repeats them)
		else if len(t.links) >= 65535 do t.cur_link = 0
		else {
			owned := strings.clone(uri)
			append(&t.links, owned)
			t.cur_link = u16(len(t.links) - 1)
			t.link_ids[owned] = t.cur_link
		}
	case 9:
		if len(t.notify) < 4 do append(&t.notify, strings.clone(rest[:min(len(rest), 512)]))
	case 777:
		if strings.has_prefix(rest, "notify;") && len(t.notify) < 4 do append(&t.notify, strings.clone(rest[7:min(len(rest), 519)]))
	case 10, 11, 12:
		target := [3]^u32{&t.fg_color, &t.bg_color, &t.cursor_color}
		p := target[code - 10]
		if rest == "?" do color_reply(t, code, p^)
		else if c, ok2 := parse_color_spec(rest); ok2 do p^ = c
	case 52:
		i := strings.index_byte(rest, ';')
		if i < 0 do return
		data := rest[i + 1:]
		if data == "?" do return // reading the clipboard from apps is refused (privacy)
		dec, err := base64.decode(data)
		if err == nil {
			delete(t.clipboard_set)
			t.clipboard_set = string(dec)
			t.clipboard_pending = true
		}
	case 104:
		if rest == "" {
			for i in 0 ..< 16 do t.palette[i] = cfg.palette[i]
		} else {
			for part in strings.split(rest, ";", context.temp_allocator) {
				if idx, ok1 := strconv.parse_int(part); ok1 && idx >= 0 && idx < 16 do t.palette[idx] = cfg.palette[idx]
			}
		}
	case 110: t.fg_color = cfg.fg
	case 111: t.bg_color = cfg.bg
	case 112: t.cursor_color = cfg.cursor
	case 133:
		if strings.has_prefix(rest, "A") {
			abs := t.total_pushed + i64(t.cy)
			if len(t.prompts) == 0 || t.prompts[len(t.prompts) - 1] != abs do append(&t.prompts, abs)
			if len(t.prompts) > 4096 do remove_range(&t.prompts, 0, 1024)
		}
	}
}

percent_decode :: proc(s: string) -> string {
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_uint(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

str_dispatch :: proc(t: ^Term) {
	s := t.strbuf[:]
	if t.str_overflow do s = nil
	if len(s) > 0 do switch t.str_kind {
	case '_':
		if len(s) > 0 && s[0] == 'G' do kitty_command(t, s[1:])
	case 'P':
		i := 0
		for i < len(s) && ((s[i] >= '0' && s[i] <= '9') || s[i] == ';') do i += 1
		if i < len(s) && s[i] == 'q' do sixel_decode(t, s[i + 1:])
		else if i + 1 < len(s) && s[i] == '+' && s[i + 1] == 'q' do reply(t, "\x1bP0+r\x1b\\")
		else if i + 1 < len(s) && s[i] == '$' && s[i + 1] == 'q' do reply(t, "\x1bP0$r\x1b\\")
	}
	clear(&t.strbuf)
	if cap(t.strbuf) > 1 << 22 {
		delete(t.strbuf)
		t.strbuf = {}
	}
}

// ---------- queries used by the UI ----------

// Line at visible row y with view offset `off` (y may be -1 for smooth scrolling); nil if none.
view_line_at :: proc(t: ^Term, off, y: int) -> []Cell {
	r := screen(t)
	i := r.count - t.rows - off + y
	if i < 0 || i >= r.count do return nil
	return ring_line(r, i)
}

view_line :: proc(t: ^Term, y: int) -> []Cell {return view_line_at(t, t.view_off, y)}

// Absolute line number for visible row y.
view_abs_at :: proc(t: ^Term, off, y: int) -> i64 {
	return t.total_pushed - i64(off) + i64(y) if !t.use_alt else i64(y) - 1 << 40
}
view_abs :: proc(t: ^Term, y: int) -> i64 {return view_abs_at(t, t.view_off, y)}

abs_ln :: proc(t: ^Term, abs: i64) -> ^Line {
	r := screen(t)
	if t.use_alt {
		y := int(abs + 1 << 40)
		if y < 0 || y >= t.rows do return nil
		return row_ln(t, y)
	}
	base := t.total_pushed - i64(r.count - t.rows)
	i := abs - base
	if i < 0 || i >= i64(r.count) do return nil
	return ring_ln(r, int(i))
}

abs_line :: proc(t: ^Term, abs: i64) -> ([]Cell, bool) {
	ln := abs_ln(t, abs)
	if ln == nil do return nil, false
	return ln.cells, true
}

first_abs :: proc(t: ^Term) -> i64 {
	if t.use_alt do return -(1 << 40)
	return t.total_pushed - i64(t.primary.count - t.rows)
}

scroll_view :: proc(t: ^Term, delta: int) {
	if t.use_alt do return
	maxoff := t.primary.count - t.rows
	t.view_off = clamp(t.view_off + delta, 0, maxoff)
	t.dirty = true
}

resolve :: proc(t: ^Term, c: u32, is_fg: bool) -> u32 {
	if c & PAL != 0 do return t.palette[c & 0xff]
	if c & DEF != 0 do return t.fg_color if c & 1 == 0 else t.bg_color
	return c
}

// ---------- search ----------

// Case-insensitive matches of needle in a line; returns [start,end] cell ranges.
line_matches :: proc(t: ^Term, l: []Cell, needle: []rune, out: ^[dynamic][2]int) {
	if len(needle) == 0 do return
	for x in 0 ..< len(l) {
		if l[x].wide == 2 do continue
		k, cx := 0, x
		for k < len(needle) && cx < len(l) {
			c := l[cx]
			if c.wide == 2 {cx += 1; continue}
			r := c.ch
			if r >= CLUSTER_BASE {r, _ = last_rune(t, r)}
			if unicode.to_lower(r) != needle[k] do break
			k += 1
			cx += 1
		}
		if k == len(needle) do append(out, [2]int{x, cx - 1})
	}
}

// Next match strictly before (dir<0) or after (dir>0) position `from` = {abs, col}.
search :: proc(t: ^Term, needle: []rune, from: [2]i64, dir: int) -> ([2]i64, bool) {
	ms := make([dynamic][2]int, context.temp_allocator)
	last := t.total_pushed + i64(t.rows) - 1 if !t.use_alt else i64(t.rows - 1) - 1 << 40
	lo := first_abs(t)
	for ln := clamp(from[0], lo, last); ln >= lo && ln <= last; ln += i64(dir) {
		l, ok := abs_line(t, ln)
		if !ok do continue
		clear(&ms)
		line_matches(t, l, needle, &ms)
		if dir < 0 {
			for i := len(ms) - 1; i >= 0; i -= 1 {
				if ln < from[0] || i64(ms[i][0]) < from[1] do return {ln, i64(ms[i][0])}, true
			}
		} else {
			for m in ms {
				if ln > from[0] || i64(m[0]) > from[1] do return {ln, i64(m[0])}, true
			}
		}
	}
	return {}, false
}

// Caps for string sequences: an unterminated OSC/DCS/APC (e.g. `cat /dev/urandom`) must not grow forever.
MAX_OSC :: 1 << 20 // 1 MiB: titles, colors, OSC 52 clipboard
MAX_STR :: 64 << 20 // 64 MiB: sixel images, kitty graphics chunks

str_push :: #force_inline proc(t: ^Term, b: u8, limit: int) {
	if len(t.strbuf) >= limit {t.str_overflow = true; return}
	append(&t.strbuf, b)
}
