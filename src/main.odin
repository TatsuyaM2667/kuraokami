package kuraokami

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:math"
import "core:unicode"
import "core:unicode/utf8"
import "core:c"
import sdl "vendor:sdl3"
import gl "vendor:OpenGL"

VERSION :: "0.2.0"

Node :: struct {
	term:      ^Term, // leaf when non-nil
	a, b:      ^Node,
	vertical:  bool, // a | b side by side
	ratio:     f32,
	parent:    ^Node,
	rect:      Rect,
	// animation state (leaves)
	scroll_vis: f32,
	cur_vis, trail: [2]f32,
	cur_target: [2]f32,
	cur_prev:   [2]f32, // previous target (for shaders)
	cur_change: f64,
	anim_init:  bool,
}

Tab :: struct {
	root, focus: ^Node,
}

App :: struct {
	window:        ^sdl.Window,
	tabs:          [dynamic]^Tab,
	cur:           int,
	sel:           Selection,
	selecting:     bool,
	sel_mode:      int, // 1 char, 2 word, 3 line
	preedit:       string,
	density:       f32,
	font_pt:       f32,
	wake_type:     u32,
	redraw:        bool,
	suppress_text: bool,
	tabbar_h:      int,
	running:       bool,
	exec_argv:     []string,
	fetch_done:    bool,
	last_mouse_cell: [2]int,
	mouse_px:      [2]f32,
	drag:          ^Node, // split divider being dragged
	cursor_default, cursor_ew, cursor_ns: ^sdl.Cursor,
	// search
	search_on:     bool,
	search_text:   [dynamic]rune,
	search_cur:    [2]i64,
	search_count:  int,
	// animation clocks (seconds)
	t0, now, last_frame: f64,
	start_time:    f64,
	bell_time:     f64,
	tab_anim_start: f64,
	tab_prev:      int,
	tab_dir:       f32,
	last_input:    f64,
	toast:         string,
	toast_time:    f64,
}

app: App
wake_pending: bool // atomic
config_dirty: bool // atomic, set by the config watcher

now_s :: proc() -> f64 {return f64(sdl.GetTicksNS()) / 1e9}

push_wake :: proc() {
	if sync.atomic_exchange(&wake_pending, true) do return
	ev: sdl.Event
	ev.type = sdl.EventType(app.wake_type)
	_ = sdl.PushEvent(&ev)
}

reader_proc :: proc(t: ^Term) {
	buf: [1 << 16]u8
	out := make([dynamic]u8)
	for {
		n := pty_read(t, buf[:])
		if n <= 0 {
			sync.mutex_lock(&t.mu)
			t.exited = true
			sync.mutex_unlock(&t.mu)
			push_wake()
			return
		}
		sync.mutex_lock(&t.mu)
		term_feed(t, buf[:n])
		clear(&out)
		append(&out, ..t.reply[:])
		clear(&t.reply)
		sync.mutex_unlock(&t.mu)
		if len(out) > 0 do pty_write(t, out[:])
		free_all(context.temp_allocator)
		push_wake()
	}
}

current_tab :: proc() -> ^Tab {return app.tabs[app.cur]}
focused :: proc() -> ^Term {return current_tab().focus.term}

show_toast :: proc(msg: string) {
	delete(app.toast)
	app.toast = strings.clone(msg)
	app.toast_time = app.now
	app.redraw = true
}

shell_cwd :: proc(t: ^Term) -> string {
	if t == nil do return ""
	sync.mutex_lock(&t.mu)
	cwd := strings.clone(t.cwd, context.temp_allocator)
	sync.mutex_unlock(&t.mu)
	if cwd != "" do return cwd
	return pty_cwd(t)
}

in_path :: proc(name: string) -> bool {
	if strings.contains_rune(name, '/') do return os.exists(name)
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":" when ODIN_OS != .Windows else ";", context.temp_allocator) {
		if dir != "" && os.exists(fmt.tprintf("%s/%s", dir, name)) do return true
	}
	return false
}

shell_argv :: proc() -> ([]string, [][2]string) {
	if len(app.exec_argv) > 0 && len(app.tabs) == 0 do return app.exec_argv, nil
	shell := cfg.shell
	if shell == "" do shell = os.get_env("SHELL", context.temp_allocator)
	when ODIN_OS == .Windows {
		if shell == "" do shell = "powershell.exe"
	} else {
		if shell == "" do shell = "/bin/sh"
	}
	argv, env := integrate(strings.fields(shell, context.temp_allocator))
	// Built-in greeting: run fastfetch once in the first terminal, then exec the real shell.
	when ODIN_OS != .Windows {
		if !app.fetch_done && cfg.startup_fetch && len(app.exec_argv) == 0 {
			app.fetch_done = true
			fetch := strings.fields(cfg.fetch_command, context.temp_allocator)
			if len(fetch) > 0 && in_path(fetch[0]) {
				out := make([dynamic]string, context.temp_allocator)
				// $0 = the shell itself so fastfetch reports the real shell
				append(&out, "/bin/sh", "-c", fmt.tprintf("%s; exec \"$0\" \"$@\"", cfg.fetch_command))
				append(&out, ..argv)
				return out[:], env
			}
		}
	}
	return argv, env
}

new_term :: proc(cwd: string, argv: []string = nil) -> ^Term {
	cols, rows := 80, 24
	t := new(Term)
	t.cell_w, t.cell_h = fonts.cell_w, fonts.cell_h
	term_init(t, cols, rows)
	args := argv
	env: [][2]string
	if args == nil do args, env = shell_argv()
	if !pty_spawn(t, cwd, args, env) {
		term_destroy(t)
		free(t)
		return nil
	}
	thread.create_and_start_with_poly_data(t, reader_proc, context, self_cleanup = true)
	return t
}

switch_tab :: proc(i: int) {
	if i == app.cur || i < 0 || i >= len(app.tabs) do return
	app.tab_prev = app.cur
	app.tab_dir = 1 if i > app.cur else -1
	app.tab_anim_start = app.now
	app.cur = i
	layout()
}

new_tab :: proc() {
	cwd := shell_cwd(focused()) if len(app.tabs) > 0 else ""
	t := new_term(cwd)
	if t == nil {show_toast("failed to start shell"); return}
	n := new(Node)
	n.term = t
	tab := new(Tab)
	tab.root, tab.focus = n, n
	append(&app.tabs, tab)
	if len(app.tabs) > 1 do switch_tab(len(app.tabs) - 1)
	layout()
}

split :: proc(vertical: bool) {
	tab := current_tab()
	leaf := tab.focus
	t := new_term(shell_cwd(leaf.term))
	if t == nil do return
	old := new(Node)
	old^ = leaf^
	old.parent = leaf
	nn := new(Node)
	nn.term = t
	nn.parent = leaf
	leaf.term = nil
	leaf.a, leaf.b, leaf.vertical, leaf.ratio = old, nn, vertical, 0.5
	tab.focus = nn
	layout()
}

first_leaf :: proc(n: ^Node) -> ^Node {
	n := n
	for n.term == nil do n = n.a
	return n
}

// Remove a leaf; returns false if the whole tab is gone.
close_leaf :: proc(tab: ^Tab, leaf: ^Node) -> bool {
	t := leaf.term
	if app.sel.term == t do app.sel = {}
	pty_close(t)
	// shortcut: the Term is not freed (the reader thread may still hold it); refcount if many panes churn.
	p := leaf.parent
	if p == nil {
		free(leaf)
		return false
	}
	sibling := p.b if p.a == leaf else p.a
	gp := p.parent
	p^ = sibling^
	p.parent = gp
	if p.term == nil {p.a.parent = p; p.b.parent = p}
	free(sibling)
	free(leaf)
	tab.focus = first_leaf(p)
	return true
}

close_pane :: proc(leaf: ^Node) {
	if app.drag != nil do app.drag = nil
	for tab, i in app.tabs {
		if !contains_leaf(tab.root, leaf) do continue
		if !close_leaf(tab, leaf) {
			free(tab)
			ordered_remove(&app.tabs, i)
			if len(app.tabs) == 0 {app.running = false; return}
			app.tab_prev = -1
			app.cur = min(app.cur, len(app.tabs) - 1)
		}
		break
	}
	layout()
}

contains_leaf :: proc(n, leaf: ^Node) -> bool {
	if n == leaf do return true
	if n.term != nil do return false
	return contains_leaf(n.a, leaf) || contains_leaf(n.b, leaf)
}

for_leaves :: proc(n: ^Node, f: proc(n: ^Node, data: rawptr), data: rawptr) {
	if n.term != nil {f(n, data); return}
	for_leaves(n.a, f, data)
	for_leaves(n.b, f, data)
}

layout_node :: proc(n: ^Node, r: Rect) {
	n.rect = r
	if n.term != nil {
		pad := cfg.padding
		cols := max(2, (r.w - 2 * pad) / fonts.cell_w)
		rows := max(1, (r.h - 2 * pad) / fonts.cell_h)
		t := n.term
		sync.mutex_lock(&t.mu)
		t.cell_w, t.cell_h = fonts.cell_w, fonts.cell_h
		changed := cols != t.cols || rows != t.rows
		term_resize(t, cols, rows)
		sync.mutex_unlock(&t.mu)
		if changed {
			pty_resize(t)
			if app.sel.term == t do app.sel = {}
			n.scroll_vis = 0
		}
		return
	}
	if n.vertical {
		w := int(f32(r.w) * n.ratio)
		layout_node(n.a, {r.x, r.y, w - 1, r.h})
		layout_node(n.b, {r.x + w + 1, r.y, r.w - w - 1, r.h})
	} else {
		h := int(f32(r.h) * n.ratio)
		layout_node(n.a, {r.x, r.y, r.w, h - 1})
		layout_node(n.b, {r.x, r.y + h + 1, r.w, r.h - h - 1})
	}
}

layout :: proc() {
	if len(app.tabs) == 0 do return
	w, h: c.int
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	app.tabbar_h = fonts.cell_h + 6 if len(app.tabs) > 1 else 0
	for tab in app.tabs do layout_node(tab.root, {0, app.tabbar_h, int(w), int(h) - app.tabbar_h})
	app.redraw = true
	update_ime_rect()
}

update_ime_rect :: proc() {
	if len(app.tabs) == 0 do return
	leaf := current_tab().focus
	t := leaf.term
	d := app.density
	r := sdl.Rect {
		c.int(f32(leaf.rect.x + cfg.padding + t.cx * fonts.cell_w) / d),
		c.int(f32(leaf.rect.y + cfg.padding + t.cy * fonts.cell_h) / d),
		c.int(f32(fonts.cell_w) / d), c.int(f32(fonts.cell_h) / d),
	}
	_ = sdl.SetTextInputArea(app.window, &r, 0)
}

set_font_size :: proc(pt: f32) {
	app.font_pt = clamp(pt, 4, 200)
	fonts_load(int(math.round(app.font_pt * 96.0 / 72.0 * app.density)))
	layout()
}

apply_config :: proc() {
	errs := config_load()
	set_font_size(cfg.font_size)
	for tab in app.tabs do for_leaves(tab.root, proc(n: ^Node, _: rawptr) {
		t := n.term
		sync.mutex_lock(&t.mu)
		palette_reset(t)
		t.dirty = true
		sync.mutex_unlock(&t.mu)
	}, nil)
	if e := post_shader_load(cfg.custom_shader); e != "" do show_toast(e)
	else if len(errs) > 0 do show_toast(fmt.tprintf("config: %s", strings.join(errs, " / ", context.temp_allocator)))
	else do show_toast("config reloaded")
	layout()
}

// ---------- animation ----------

approach :: proc(cur, target: f32, dt, tau: f64, snap: f32) -> f32 {
	if !cfg.animation || abs(target - cur) < snap do return target
	k := f32(1 - math.exp(-dt / tau))
	return cur + (target - cur) * k
}

ease_out :: proc(p: f64) -> f32 {
	q := clamp(p, 0, 1)
	return f32(1 - (1 - q) * (1 - q) * (1 - q))
}

blink_alpha :: proc() -> (alpha: f32, next_ms: i32) {
	if !cfg.cursor_blink || sdl.GetKeyboardFocus() != app.window do return 1, -1
	idle := app.now - app.last_input
	if idle > 30 do return 1, -1 // stop blinking when idle: no wakeups at all
	p := math.mod(idle, 1.0)
	switch {
	case p < 0.5: return 1, i32((0.5 - p) * 1000) + 1
	case p < 0.6: return f32(1 - (p - 0.5) / 0.1), 0
	case p < 0.9: return 0, i32((0.9 - p) * 1000) + 1
	case: return f32((p - 0.9) / 0.1), 0
	}
}

// Advance per-pane animations; returns true while anything is still moving.
anim_tick :: proc(dt: f64) -> bool {
	active := false
	if len(app.tabs) == 0 do return false
	Ctx :: struct {dt: f64, active: bool}
	ctx := Ctx{dt, false}
	for_leaves(current_tab().root, proc(n: ^Node, data: rawptr) {
		ctx := (^Ctx)(data)
		t := n.term
		sync.mutex_lock(&t.mu)
		target := [2]f32{f32(t.cx * fonts.cell_w), f32(t.cy * fonts.cell_h)}
		voff := f32(t.view_off)
		sync.mutex_unlock(&t.mu)
		if !n.anim_init {
			n.cur_vis, n.trail, n.cur_target, n.cur_prev = target, target, target, target
			n.scroll_vis = voff
			n.anim_init = true
		}
		if target != n.cur_target {
			n.cur_prev = n.cur_target
			n.cur_target = target
			n.cur_change = app.now
			app.last_input = app.now // keep the cursor solid while it moves
		}
		for i in 0 ..< 2 {
			n.cur_vis[i] = approach(n.cur_vis[i], target[i], ctx.dt, 0.025 if cfg.cursor_trail else 0.0001, 0.5)
			n.trail[i] = approach(n.trail[i], n.cur_vis[i], ctx.dt, 0.06, 0.5)
		}
		if !cfg.cursor_trail do n.trail = n.cur_vis
		n.scroll_vis = approach(n.scroll_vis, voff, ctx.dt, 0.045 if cfg.smooth_scroll else 0.0001, 0.01)
		if n.cur_vis != target || n.trail != n.cur_vis || n.scroll_vis != voff do ctx.active = true
	}, &ctx)
	active = ctx.active
	if cfg.animation {
		if app.now - app.start_time < 0.35 do active = true
		if cfg.visual_bell && app.now - app.bell_time < 0.3 do active = true
		if app.tab_prev >= 0 && app.now - app.tab_anim_start < 0.25 do active = true
		if app.toast != "" && app.now - app.toast_time < 4.5 && app.now - app.toast_time > 3.5 do active = true
	}
	if ren.post != 0 && cfg.shader_animation && sdl.GetKeyboardFocus() == app.window do active = true
	return active
}

// ---------- rendering ----------

leaf_opts :: proc(n: ^Node, focus: bool, blink: f32) -> Draw_Opts {
	o := Draw_Opts {
		focused        = focus,
		sel            = &app.sel,
		preedit        = app.preedit if focus && !app.search_on else "",
		view_vis       = n.scroll_vis,
		cursor         = n.cur_vis,
		trail          = n.trail,
		cursor_alpha   = blink if focus else 1,
		cursor_arrived = abs(n.cur_vis[0] - n.cur_target[0]) < 1 && abs(n.cur_vis[1] - n.cur_target[1]) < 1,
	}
	if focus && app.search_on {
		o.search = app.search_text[:]
		o.search_cur = app.search_cur
	}
	return o
}

draw_tab :: proc(tab: ^Tab, active: bool, blink: f32) {
	Ctx :: struct {tab: ^Tab, active: bool, blink: f32}
	ctx := Ctx{tab, active, blink}
	for_leaves(tab.root, proc(n: ^Node, data: rawptr) {
		ctx := (^Ctx)(data)
		t := n.term
		pad := cfg.padding
		r := Rect{n.rect.x + pad, n.rect.y + pad, n.rect.w - 2 * pad, n.rect.h - 2 * pad}
		is_focus := ctx.active && n == ctx.tab.focus && sdl.GetKeyboardFocus() == app.window
		sync.mutex_lock(&t.mu)
		if t.bg_color != cfg.bg {
			scissor(n.rect.x, n.rect.y, n.rect.w, n.rect.h)
			quad(&ren.bg, f32(n.rect.x), f32(n.rect.y), f32(n.rect.x + n.rect.w), f32(n.rect.y + n.rect.h), rgba(t.bg_color, u8(cfg.opacity * 255)))
			flush(&ren.bg, fonts.atlas)
		}
		if !n.anim_init {
			n.cur_vis = {f32(t.cx * fonts.cell_w), f32(t.cy * fonts.cell_h)}
			n.trail, n.cur_target = n.cur_vis, n.cur_vis
			n.scroll_vis = f32(t.view_off)
		}
		sync.mutex_unlock(&t.mu)
		draw_term(t, r, leaf_opts(n, n == ctx.tab.focus && ctx.active, ctx.blink))
	}, &ctx)
	scissor(0, 0, ren.width, ren.height)
	draw_dividers(tab.root)
	flush(&ren.ov, fonts.atlas)
}

draw_dividers :: proc(n: ^Node) {
	if n.term != nil do return
	col := rgba(mix(cfg.bg, cfg.fg, 0.45 if n == app.drag else 0.25))
	if n.vertical {
		x := f32(n.a.rect.x + n.a.rect.w)
		quad(&ren.ov, x, f32(n.rect.y), x + 2, f32(n.rect.y + n.rect.h), col)
	} else {
		y := f32(n.a.rect.y + n.a.rect.h)
		quad(&ren.ov, f32(n.rect.x), y, f32(n.rect.x + n.rect.w), y + 2, col)
	}
	draw_dividers(n.a)
	draw_dividers(n.b)
}

tab_title :: proc(tab: ^Tab) -> string {
	t := tab.focus.term
	return t.title if t.title != "" else "kuraokami"
}

truncate_cells :: proc(s: string, maxc: int) -> string {
	cells := 0
	for ch, bi in s {
		cw := rune_width(ch)
		if cells + cw > maxc do return s[:bi]
		cells += cw
	}
	return s
}

draw_overlay_ui :: proc(w, h: int) {
	set_offset(0)
	scissor(0, 0, w, h)
	if app.tabbar_h > 0 {
		n := len(app.tabs)
		tw := w / n
		// Sliding underline marks the active tab.
		p := ease_out((app.now - app.tab_anim_start) / 0.25) if app.tab_prev >= 0 && cfg.animation else 1
		from := f32(app.tab_prev if app.tab_prev >= 0 && app.tab_prev < n else app.cur)
		ux := (from + (f32(app.cur) - from) * p) * f32(tw)
		for tb, i in app.tabs {
			x := f32(i * tw)
			active := i == app.cur
			bg := mix(cfg.bg, cfg.fg, 0.14 if active else 0.05)
			quad(&ren.ov, x, 0, x + f32(tw) - 1, f32(app.tabbar_h), rgba(bg))
			label := truncate_cells(fmt.tprintf(" %d %s", i + 1, tab_title(tb)), max(1, tw / fonts.cell_w - 1))
			draw_text(&ren.ov, x + 2, 3, label, cfg.fg if active else mix(cfg.fg, cfg.bg, 0.4), bg)
		}
		quad(&ren.ov, ux, f32(app.tabbar_h - 2), ux + f32(tw) - 1, f32(app.tabbar_h), rgba(cfg.cursor))
	}
	if app.search_on {
		leaf := current_tab().focus
		label := fmt.tprintf(" 🔍 %s%s▏ %d ", utf8.runes_to_string(app.search_text[:], context.temp_allocator), app.preedit, app.search_count)
		wpx := f32(fonts.cell_w * (strings.rune_count(label) + 2))
		x := f32(leaf.rect.x + leaf.rect.w) - wpx - 8
		draw_text(&ren.ov, x, f32(leaf.rect.y + 4), label, cfg.bg, mix(cfg.fg, cfg.cursor, 0.3))
	}
	if app.toast != "" {
		age := app.now - app.toast_time
		if age < 4.5 {
			a := u8(255 * clamp(min(age / 0.15, (4.5 - age)), 0, 1)) if cfg.animation else 255
			msg := truncate_cells(fmt.tprintf("  %s  ", app.toast), max(1, w / fonts.cell_w - 2))
			mw := f32(fonts.cell_w * strings.rune_count(msg))
			slide := f32(0) if !cfg.animation else (1 - ease_out(age / 0.2)) * f32(fonts.cell_h)
			draw_text(&ren.ov, (f32(w) - mw) / 2, f32(h - fonts.cell_h * 2) + slide, msg, cfg.bg, cfg.fg, false, a)
		}
	}
	if cfg.animation && cfg.visual_bell && app.now - app.bell_time < 0.3 {
		a := u8(60 * (1 - (app.now - app.bell_time) / 0.3))
		quad(&ren.ov, 0, 0, f32(w), f32(h), rgba(cfg.fg, a))
	}
	if cfg.animation && app.now - app.start_time < 0.35 {
		a := u8(255 * (1 - ease_out((app.now - app.start_time) / 0.35)))
		quad(&ren.ov, 0, 0, f32(w), f32(h), rgba(cfg.bg, a))
	}
	flush(&ren.ov, fonts.atlas)
}

render :: proc() {
	w, h: c.int
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	blink, _ := blink_alpha()
	for {
		frame_begin(int(w), int(h))
		p := ease_out((app.now - app.tab_anim_start) / 0.25)
		if cfg.animation && app.tab_prev >= 0 && app.tab_prev < len(app.tabs) && p < 1 {
			set_offset(-app.tab_dir * p * f32(w))
			draw_tab(app.tabs[app.tab_prev], false, blink)
			set_offset(app.tab_dir * (1 - p) * f32(w))
		} else do set_offset(0)
		draw_tab(current_tab(), true, blink)
		draw_overlay_ui(int(w), int(h))
		if !fonts.atlas_reset do break
		fonts.atlas_reset = false
		atlas_clear()
	}
	if ren.post != 0 {
		leaf := current_tab().focus
		pad := f32(cfg.padding)
		cr :: proc(leaf: ^Node, p: [2]f32, pad: f32, h: c.int) -> [4]f32 {
			return {f32(leaf.rect.x) + pad + p[0], f32(h) - (f32(leaf.rect.y) + pad + p[1]), f32(fonts.cell_w), f32(fonts.cell_h)}
		}
		frame_post(Post_Uniforms {
			time = f32(app.now - app.t0), dt = f32(app.now - app.last_frame),
			cursor = cr(leaf, leaf.cur_vis, pad, h), prev = cr(leaf, leaf.cur_prev, pad, h),
			cursor_color = leaf.term.cursor_color, cursor_change = f32(leaf.cur_change - app.t0),
			mouse = app.mouse_px,
		})
	}
	if shot := os.get_env("KURAOKAMI_SHOT", context.temp_allocator); shot != "" {
		// Debug aid: dump each frame as a PNG (used for headless visual checks).
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		px := make([]u8, int(w) * int(h) * 3, context.temp_allocator)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, w, h, gl.RGB, gl.UNSIGNED_BYTE, raw_data(px))
		_ = os.write_entire_file(shot, png_encode_rgb(px, int(w), int(h)))
		alpha: [4]u8
		gl.ReadPixels(w - 1, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &alpha[0])
		fmt.eprintfln("kuraokami-shot: corner rgba=%v", alpha)
	}
	_ = sdl.GL_SwapWindow(app.window)
	app.last_frame = app.now
	app.redraw = false
}

// ---------- input ----------

send :: proc(s: string) {
	t := focused()
	if t.view_off != 0 {
		sync.mutex_lock(&t.mu)
		t.view_off = 0
		sync.mutex_unlock(&t.mu)
		app.redraw = true
	}
	app.last_input = app.now
	pty_write(t, transmute([]u8)s)
}

paste :: proc(text: string) {
	t := focused()
	b := strings.builder_make(context.temp_allocator)
	if t.bracketed do strings.write_string(&b, "\x1b[200~")
	for i := 0; i < len(text); i += 1 {
		ch := text[i]
		if ch == 0x1b do continue // never let pasted text end the bracket or inject escapes
		if ch == '\r' && i + 1 < len(text) && text[i + 1] == '\n' do continue
		strings.write_byte(&b, '\r' if ch == '\n' else ch)
	}
	if t.bracketed do strings.write_string(&b, "\x1b[201~")
	send(strings.to_string(b))
}

mods_param :: proc(m: sdl.Keymod) -> int {
	p := 1
	if m & sdl.KMOD_SHIFT != {} do p += 1
	if m & sdl.KMOD_ALT != {} do p += 2
	if m & sdl.KMOD_CTRL != {} do p += 4
	return p
}

special_key :: proc(t: ^Term, key: sdl.Keycode, mod: sdl.Keymod) -> string {
	mp := mods_param(mod)
	csi_letter :: proc(t: ^Term, l: u8, mp: int) -> string {
		if mp > 1 do return fmt.tprintf("\x1b[1;%d%c", mp, l)
		return fmt.tprintf("\x1bO%c", l) if t.app_cursor else fmt.tprintf("\x1b[%c", l)
	}
	tilde :: proc(n, mp: int) -> string {
		if mp > 1 do return fmt.tprintf("\x1b[%d;%d~", n, mp)
		return fmt.tprintf("\x1b[%d~", n)
	}
	switch key {
	case sdl.K_UP: return csi_letter(t, 'A', mp)
	case sdl.K_DOWN: return csi_letter(t, 'B', mp)
	case sdl.K_RIGHT: return csi_letter(t, 'C', mp)
	case sdl.K_LEFT: return csi_letter(t, 'D', mp)
	case sdl.K_HOME: return csi_letter(t, 'H', mp)
	case sdl.K_END: return csi_letter(t, 'F', mp)
	case sdl.K_INSERT: return tilde(2, mp)
	case sdl.K_DELETE: return tilde(3, mp)
	case sdl.K_PAGEUP: return tilde(5, mp)
	case sdl.K_PAGEDOWN: return tilde(6, mp)
	case sdl.K_F1 ..= sdl.K_F4:
		l := u8('P' + int(key - sdl.K_F1))
		return fmt.tprintf("\x1b[1;%d%c", mp, l) if mp > 1 else fmt.tprintf("\x1bO%c", l)
	case sdl.K_F5 ..= sdl.K_F12:
		codes := [8]int{15, 17, 18, 19, 20, 21, 23, 24}
		return tilde(codes[key - sdl.K_F5], mp)
	case sdl.K_RETURN, sdl.K_KP_ENTER: return "\x1b\r" if mod & sdl.KMOD_ALT != {} else "\r"
	case sdl.K_BACKSPACE:
		if mod & sdl.KMOD_CTRL != {} do return "\x08"
		return "\x1b\x7f" if mod & sdl.KMOD_ALT != {} else "\x7f"
	case sdl.K_TAB: return "\x1b[Z" if mod & sdl.KMOD_SHIFT != {} else "\t"
	case sdl.K_ESCAPE: return "\x1b"
	}
	return ""
}

scroll_lines :: proc(t: ^Term, n: int) {
	sync.mutex_lock(&t.mu)
	scroll_view(t, n)
	sync.mutex_unlock(&t.mu)
	app.redraw = true
}

jump_prompt :: proc(t: ^Term, dir: int) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	if t.use_alt || len(t.prompts) == 0 do return
	top := view_abs(t, 0)
	target: i64 = -1
	if dir < 0 {
		for i := len(t.prompts) - 1; i >= 0; i -= 1 do if t.prompts[i] < top {target = t.prompts[i]; break}
	} else {
		for p in t.prompts do if p > top {target = p; break}
	}
	if target < 0 do return
	scroll_view(t, int(top - target))
	app.redraw = true
}

// Move the nearest ancestor divider of the focused pane.
resize_split :: proc(vertical: bool, delta: f32) {
	n := current_tab().focus.parent
	for n != nil && n.vertical != vertical do n = n.parent
	if n == nil do return
	n.ratio = clamp(n.ratio + delta, 0.1, 0.9)
	layout()
}

equalize :: proc(n: ^Node) {
	if n.term != nil do return
	n.ratio = 0.5
	equalize(n.a)
	equalize(n.b)
}

clear_scrollback :: proc(t: ^Term) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	if t.use_alt do return
	r := &t.primary
	r.head = (r.head + r.count - t.rows) % len(r.buf)
	r.count = t.rows
	t.view_off = 0
	t.dirty = true
}

run_action :: proc(b: Keybind) {
	t := focused()
	switch b.action {
	case .None, .Unbind:
	case .Copy:
		if s := selection_text(); s != "" do _ = sdl.SetClipboardText(strings.clone_to_cstring(s, context.temp_allocator))
	case .Paste:
		if p := sdl.GetClipboardText(); p != nil {paste(string(cstring(p))); sdl.free(p)}
	case .Paste_Selection:
		if p := sdl.GetPrimarySelectionText(); p != nil {paste(string(cstring(p))); sdl.free(p)}
	case .Select_All:
		sync.mutex_lock(&t.mu)
		app.sel = {active = true, a = {first_abs(t), 0}, b = {view_abs_at(t, 0, t.rows - 1), i64(t.cols - 1)}, term = t}
		sync.mutex_unlock(&t.mu)
		app.redraw = true
	case .New_Tab: new_tab()
	case .Close_Pane: close_pane(current_tab().focus)
	case .Split_Right: split(true)
	case .Split_Down: split(false)
	case .Focus_Left: focus_dir({-1, 0})
	case .Focus_Right: focus_dir({1, 0})
	case .Focus_Up: focus_dir({0, -1})
	case .Focus_Down: focus_dir({0, 1})
	case .Next_Tab: switch_tab((app.cur + 1) % len(app.tabs))
	case .Prev_Tab: switch_tab((app.cur + len(app.tabs) - 1) % len(app.tabs))
	case .Goto_Tab: switch_tab(b.arg - 1)
	case .Resize_Left: resize_split(true, -0.05)
	case .Resize_Right: resize_split(true, 0.05)
	case .Resize_Up: resize_split(false, -0.05)
	case .Resize_Down: resize_split(false, 0.05)
	case .Equalize_Splits: equalize(current_tab().root); layout()
	case .Scroll_Page_Up: scroll_lines(t, t.rows - 1)
	case .Scroll_Page_Down: scroll_lines(t, -(t.rows - 1))
	case .Scroll_Top: scroll_lines(t, 1 << 30)
	case .Scroll_Bottom: scroll_lines(t, -(1 << 30))
	case .Prompt_Prev: jump_prompt(t, -1)
	case .Prompt_Next: jump_prompt(t, 1)
	case .Font_Inc: set_font_size(app.font_pt + 1)
	case .Font_Dec: set_font_size(app.font_pt - 1)
	case .Font_Reset: set_font_size(cfg.font_size)
	case .Open_Config:
		os.make_directory_all(config_dir())
		if !os.exists(config_path()) do _ = os.write_entire_file(config_path(), transmute([]u8)string(SAMPLE_CONFIG))
		ed := os.get_env("EDITOR", context.temp_allocator)
		t2 := new_term("", {ed if ed != "" else "vi", config_path()})
		if t2 != nil {
			n := new(Node)
			n.term = t2
			tab := new(Tab)
			tab.root, tab.focus = n, n
			append(&app.tabs, tab)
			switch_tab(len(app.tabs) - 1)
			layout()
		}
	case .Reload_Config: apply_config()
	case .Search:
		app.search_on = true
		clear(&app.search_text)
		sync.mutex_lock(&t.mu)
		app.search_cur = {view_abs_at(t, 0, t.rows - 1) + 1, 0}
		sync.mutex_unlock(&t.mu)
		app.search_count = 0
		app.redraw = true
	case .Clear_Scrollback: clear_scrollback(t)
	case .Toggle_Fullscreen:
		_ = sdl.SetWindowFullscreen(app.window, .FULLSCREEN not_in sdl.GetWindowFlags(app.window))
	}
}

SAMPLE_CONFIG :: `# kuraokami config (hot-reloaded on save)
# theme = tokyonight          # tokyonight catppuccin-mocha dracula gruvbox-dark nord solarized-dark
# font-family = JetBrainsMono Nerd Font Mono
# font-size = 12
# font-ligatures = true
# background-opacity = 0.7
# shell-preset = true          # built-in zsh niceties (suggestions, highlighting, completion, prompt)
# animation = true
# cursor-blink = true
# cursor-trail = true
# smooth-scroll = true
# custom-shader = builtin:aurora   # builtin:crt builtin:aurora builtin:cursor-glow or a .glsl path
# startup-fetch = true
# keybind = ctrl+shift+d=split_right
`

Focus_Search :: struct {
	from:  Rect,
	dir:   [2]int,
	best:  ^Node,
	dist:  int,
}

focus_dir :: proc(dir: [2]int) {
	tab := current_tab()
	fs := Focus_Search{from = tab.focus.rect, dir = dir, dist = max(int)}
	for_leaves(tab.root, proc(n: ^Node, data: rawptr) {
		fs := (^Focus_Search)(data)
		a, b := fs.from, n.rect
		ac := [2]int{a.x + a.w / 2, a.y + a.h / 2}
		bc := [2]int{b.x + b.w / 2, b.y + b.h / 2}
		d := [2]int{bc.x - ac.x, bc.y - ac.y}
		along := d.x * fs.dir.x + d.y * fs.dir.y
		if along <= 0 do return
		dist := along + 2 * abs(d.x * fs.dir.y + d.y * fs.dir.x)
		if dist < fs.dist {fs.dist = dist; fs.best = n}
	}, &fs)
	if fs.best != nil {tab.focus = fs.best; app.redraw = true; update_ime_rect()}
}

// ---------- search ----------

search_step :: proc(dir: int) {
	t := focused()
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	if len(app.search_text) == 0 do return
	pos, ok := search(t, app.search_text[:], app.search_cur, dir)
	if !ok do return
	app.search_cur = pos
	if !t.use_alt {
		top, bot := view_abs(t, 0), view_abs(t, t.rows - 1)
		if pos[0] < top || pos[0] > bot {
			t.view_off = clamp(int(t.total_pushed + i64(t.rows / 2) - pos[0]), 0, t.primary.count - t.rows)
		}
	}
	app.redraw = true
}

search_changed :: proc() {
	t := focused()
	sync.mutex_lock(&t.mu)
	app.search_count = 0
	ms := make([dynamic][2]int, context.temp_allocator)
	if len(app.search_text) > 0 {
		r := screen(t)
		for i in 0 ..< r.count {
			clear(&ms)
			line_matches(t, ring_line(r, i), app.search_text[:], &ms)
			app.search_count += len(ms)
		}
	}
	app.search_cur = {view_abs_at(t, 0, t.rows - 1) + 1, 0}
	sync.mutex_unlock(&t.mu)
	search_step(-1)
	app.redraw = true
}

search_key :: proc(e: sdl.KeyboardEvent) {
	switch e.key {
	case sdl.K_ESCAPE:
		app.search_on = false
		app.redraw = true
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		search_step(1 if e.mod & sdl.KMOD_SHIFT != {} else -1)
	case sdl.K_BACKSPACE:
		if len(app.search_text) > 0 {pop(&app.search_text); search_changed()}
	case sdl.K_V:
		if e.mod & sdl.KMOD_CTRL != {} {
			if p := sdl.GetClipboardText(); p != nil {
				for r in string(cstring(p)) do if r >= ' ' do append(&app.search_text, unicode.to_lower(r))
				sdl.free(p)
				search_changed()
			}
		}
	}
}

on_key :: proc(e: sdl.KeyboardEvent) {
	app.suppress_text = false
	app.last_input = app.now
	if app.search_on {
		search_key(e)
		app.suppress_text = e.key < 0x40000000 && e.mod & sdl.KMOD_CTRL != {}
		return
	}
	if b, ok := find_bind(e.key, e.mod); ok {
		run_action(b)
		app.suppress_text = true
		return
	}
	t := focused()
	sync.mutex_lock(&t.mu)
	flags := kb_flags(t)
	sync.mutex_unlock(&t.mu)
	if flags != 0 {
		text := rune(0)
		if flags & 16 != 0 {
			k := sdl.GetKeyFromScancode(e.scancode, e.mod & sdl.KMOD_SHIFT, false)
			if k >= 32 && k < 0x40000000 do text = rune(k)
		}
		if s := kitty_encode(flags, e.key, mods_of(e.mod), 2 if e.repeat else 1, text); s != "" {
			send(s)
			app.suppress_text = true
			return
		}
		if is_modifier_key(e.key) do return
	}
	ctrl := e.mod & sdl.KMOD_CTRL != {}
	alt := e.mod & sdl.KMOD_ALT != {}
	if s := special_key(t, e.key, e.mod); s != "" {
		send(s)
		app.suppress_text = true
		return
	}
	if ctrl {
		k := e.key
		b: int = -1
		switch k {
		case sdl.K_A ..= sdl.K_Z: b = int(k - sdl.K_A) + 1
		case sdl.K_SPACE, sdl.K_2: b = 0
		case sdl.K_LEFTBRACKET, sdl.K_3: b = 27
		case sdl.K_BACKSLASH, sdl.K_4: b = 28
		case sdl.K_RIGHTBRACKET, sdl.K_5: b = 29
		case sdl.K_6: b = 30
		case sdl.K_SLASH, sdl.K_7, sdl.K_MINUS: b = 31
		case sdl.K_8: b = 127
		}
		if b >= 0 {
			bytes := [2]u8{0x1b, u8(b)}
			send(string(bytes[:] if alt else bytes[1:]))
			app.suppress_text = true
		}
	}
}

on_key_up :: proc(e: sdl.KeyboardEvent) {
	if app.search_on || len(app.tabs) == 0 do return
	t := focused()
	sync.mutex_lock(&t.mu)
	flags := kb_flags(t)
	sync.mutex_unlock(&t.mu)
	if flags & 2 == 0 do return
	if s := kitty_encode(flags, e.key, mods_of(e.mod), 3, 0); s != "" do pty_write(t, transmute([]u8)s)
}

on_text :: proc(text: string) {
	if app.suppress_text {app.suppress_text = false; return}
	delete(app.preedit)
	app.preedit = ""
	if app.search_on {
		for r in text do append(&app.search_text, unicode.to_lower(r))
		search_changed()
		return
	}
	if sdl.GetModState() & sdl.KMOD_ALT != {} && len(text) == 1 {
		send(fmt.tprintf("\x1b%s", text))
		return
	}
	send(text)
}

// ---------- mouse & selection ----------

pane_at :: proc(px, py: int) -> ^Node {
	Hit :: struct {x, y: int, n: ^Node}
	h := Hit{px, py, nil}
	for_leaves(current_tab().root, proc(n: ^Node, data: rawptr) {
		h := (^Hit)(data)
		r := n.rect
		if h.x >= r.x && h.x < r.x + r.w && h.y >= r.y && h.y < r.y + r.h do h.n = n
	}, &h)
	return h.n
}

divider_at :: proc(n: ^Node, px, py: int) -> ^Node {
	if n.term != nil do return nil
	r := n.rect
	if px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h {
		if n.vertical {
			x := n.a.rect.x + n.a.rect.w + 1
			if abs(px - x) <= 4 do return n
		} else {
			y := n.a.rect.y + n.a.rect.h + 1
			if abs(py - y) <= 4 do return n
		}
	}
	if d := divider_at(n.a, px, py); d != nil do return d
	return divider_at(n.b, px, py)
}

cell_at :: proc(n: ^Node, px, py: int) -> (int, int) {
	t := n.term
	x := (px - n.rect.x - cfg.padding) / fonts.cell_w
	y := (py - n.rect.y - cfg.padding) / fonts.cell_h
	return clamp(x, 0, t.cols - 1), clamp(y, 0, t.rows - 1)
}

mouse_report :: proc(t: ^Term, button, x, y: int, press: bool, motion := false) {
	mod := sdl.GetModState()
	b := button
	if mod & sdl.KMOD_SHIFT != {} do b += 4
	if mod & sdl.KMOD_ALT != {} do b += 8
	if mod & sdl.KMOD_CTRL != {} do b += 16
	if motion do b += 32
	if t.mouse_sgr {
		pty_write(t, transmute([]u8)fmt.tprintf("\x1b[<%d;%d;%d%c", b, x + 1, y + 1, 'M' if press else 'm'))
	} else {
		if !press do b = 3 + (b & ~int(3))
		if x > 222 || y > 222 do return
		bytes := [6]u8{0x1b, '[', 'M', u8(32 + b), u8(33 + x), u8(33 + y)}
		pty_write(t, bytes[:])
	}
}

is_word :: proc(r: rune) -> bool {
	if r > 0x7f do return true
	if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') do return true
	return strings.contains_rune("-_./~:@%+?&=#", r)
}

expand_selection :: proc(t: ^Term) {
	if app.sel_mode == 1 do return
	a, b := &app.sel.a, &app.sel.b
	if a[0] > b[0] || (a[0] == b[0] && a[1] > b[1]) do a, b = b, a
	if app.sel_mode == 3 {
		// Whole logical line, following soft wraps.
		for {
			prev := abs_ln(t, a[0] - 1)
			if prev == nil || !prev.wrapped do break
			a[0] -= 1
		}
		for {
			ln := abs_ln(t, b[0])
			if ln == nil || !ln.wrapped do break
			b[0] += 1
		}
		a[1] = 0
		b[1] = i64(t.cols - 1)
		return
	}
	if l, ok := abs_line(t, a[0]); ok {
		x := int(a[1])
		for x > 0 && is_word(l[x - 1].ch) && is_word(l[x].ch) do x -= 1
		a[1] = i64(x)
	}
	if l, ok := abs_line(t, b[0]); ok {
		x := int(b[1])
		for x + 1 < len(l) && is_word(l[x + 1].ch) && is_word(l[x].ch) do x += 1
		b[1] = i64(x)
	}
}

selection_text :: proc() -> string {
	s := &app.sel
	if !s.active || s.term == nil do return ""
	t := s.term
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	a, b := s.a, s.b
	if a[0] > b[0] || (a[0] == b[0] && a[1] > b[1]) do a, b = b, a
	sb := strings.builder_make(context.temp_allocator)
	for ln := a[0]; ln <= b[0]; ln += 1 {
		line := abs_ln(t, ln)
		if line == nil do continue
		l := line.cells
		x0 := int(a[1]) if ln == a[0] else 0
		x1 := int(b[1]) if ln == b[0] else len(l) - 1
		part := strings.builder_make(context.temp_allocator)
		for x in x0 ..= min(x1, len(l) - 1) {
			if l[x].wide == 2 do continue
			buf: [4]u8
			strings.write_string(&part, cell_text(t, l[x].ch, &buf) if l[x].ch != 0 else " ")
		}
		txt := strings.to_string(part)
		// Soft-wrapped lines join without a newline (and keep their trailing spaces).
		if line.wrapped && ln != b[0] do strings.write_string(&sb, txt)
		else {
			strings.write_string(&sb, strings.trim_right(txt, " "))
			if ln != b[0] do strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

url_at :: proc(t: ^Term, x, y: int) -> string {
	l := view_line(t, y)
	if l == nil do return ""
	if l[x].link != 0 && int(l[x].link) < len(t.links) do return strings.clone(t.links[l[x].link], context.temp_allocator)
	stop :: proc(r: rune) -> bool {return r <= ' ' || strings.contains_rune("\"'<>`|", r)}
	if stop(l[x].ch) do return ""
	x0, x1 := x, x
	for x0 > 0 && !stop(l[x0 - 1].ch) do x0 -= 1
	for x1 + 1 < len(l) && !stop(l[x1 + 1].ch) do x1 += 1
	sb := strings.builder_make(context.temp_allocator)
	for i in x0 ..= x1 do if l[i].wide != 2 {buf: [4]u8; strings.write_string(&sb, cell_text(t, l[i].ch, &buf))}
	s := strings.trim_right(strings.to_string(sb), ".,;:)]}")
	if i := strings.index(s, "://"); i > 0 do return s[max(0, strings.last_index_any(s[:i], "([{") + 1):]
	return ""
}

on_mouse_button :: proc(e: sdl.MouseButtonEvent) {
	px, py := int(e.x * app.density), int(e.y * app.density)
	if app.tabbar_h > 0 && py < app.tabbar_h {
		if e.down {
			w, h: c.int
			_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
			i := px / max(1, int(w) / len(app.tabs))
			if i >= len(app.tabs) do return
			if e.button == 2 {
				tab := app.tabs[i]
				app.cur = i
				for tab.root.term == nil do close_leaf(tab, tab.focus)
				close_pane(tab.root)
			} else do switch_tab(i)
		}
		return
	}
	if e.button == 1 {
		if e.down {
			if d := divider_at(current_tab().root, px, py); d != nil {app.drag = d; app.redraw = true; return}
		} else if app.drag != nil {app.drag = nil; app.redraw = true; return}
	}
	n := pane_at(px, py)
	if n == nil do return
	tab := current_tab()
	if e.down && tab.focus != n {tab.focus = n; app.redraw = true; update_ime_rect()}
	t := n.term
	x, y := cell_at(n, px, py)
	mod := sdl.GetModState()
	btn := 0 if e.button == 1 else 1 if e.button == 2 else 2
	if t.mouse_mode != 0 && mod & sdl.KMOD_SHIFT == {} {
		mouse_report(t, btn, x, y, e.down)
		return
	}
	if e.button == 2 && e.down {
		if p := sdl.GetPrimarySelectionText(); p != nil {paste(string(cstring(p))); sdl.free(p)}
		return
	}
	if e.button != 1 do return
	if e.down {
		if mod & (sdl.KMOD_CTRL | sdl.KMOD_GUI) != {} {
			sync.mutex_lock(&t.mu)
			u := url_at(t, x, y)
			sync.mutex_unlock(&t.mu)
			if u != "" {_ = sdl.OpenURL(strings.clone_to_cstring(u, context.temp_allocator)); return}
		}
		sync.mutex_lock(&t.mu)
		abs := view_abs(t, y)
		app.sel = Selection{active = e.clicks > 1, a = {abs, i64(x)}, b = {abs, i64(x)}, term = t}
		app.sel_mode = min(int(e.clicks), 3)
		expand_selection(t)
		sync.mutex_unlock(&t.mu)
		app.selecting = true
		app.redraw = true
	} else {
		app.selecting = false
		if app.sel.active && cfg.copy_on_select {
			if s := selection_text(); s != "" do _ = sdl.SetPrimarySelectionText(strings.clone_to_cstring(s, context.temp_allocator))
		}
	}
}

on_mouse_motion :: proc(e: sdl.MouseMotionEvent) {
	px, py := int(e.x * app.density), int(e.y * app.density)
	app.mouse_px = {f32(px), f32(py)}
	if app.drag != nil {
		n := app.drag
		if n.vertical do n.ratio = clamp(f32(px - n.rect.x) / f32(max(n.rect.w, 1)), 0.1, 0.9)
		else do n.ratio = clamp(f32(py - n.rect.y) / f32(max(n.rect.h, 1)), 0.1, 0.9)
		layout()
		return
	}
	if e.state == {} {
		d := divider_at(current_tab().root, px, py)
		_ = sdl.SetCursor(app.cursor_default if d == nil else app.cursor_ew if d.vertical else app.cursor_ns)
	}
	leaf := current_tab().focus
	t := leaf.term
	if t.mouse_mode != 0 && sdl.GetModState() & sdl.KMOD_SHIFT == {} {
		x, y := cell_at(leaf, px, py)
		if x == app.last_mouse_cell.x && y == app.last_mouse_cell.y do return
		app.last_mouse_cell = {x, y}
		pressed := e.state != {}
		if t.mouse_mode == 1003 || (t.mouse_mode == 1002 && pressed) {
			btn := 3
			if .LEFT in e.state do btn = 0
			else if .MIDDLE in e.state do btn = 1
			else if .RIGHT in e.state do btn = 2
			mouse_report(t, btn, x, y, true, true)
		}
		return
	}
	if !app.selecting || app.sel.term != t do return
	x, y := cell_at(leaf, px, py)
	sync.mutex_lock(&t.mu)
	if py < leaf.rect.y do scroll_view(t, 1)
	else if py > leaf.rect.y + leaf.rect.h do scroll_view(t, -1)
	app.sel.b = {view_abs(t, y), i64(x)}
	app.sel.active = true
	expand_selection(t)
	sync.mutex_unlock(&t.mu)
	app.redraw = true
}

wheel_accum: f32

on_wheel :: proc(e: sdl.MouseWheelEvent) {
	px, py := int(e.mouse_x * app.density), int(e.mouse_y * app.density)
	n := pane_at(px, py)
	if n == nil do return
	t := n.term
	// Touchpads deliver fractional deltas: accumulate them so scrolling stays smooth.
	wheel_accum += e.y * 3
	lines := int(wheel_accum)
	if lines == 0 do return
	wheel_accum -= f32(lines)
	x, y := cell_at(n, px, py)
	if t.mouse_mode != 0 {
		for _ in 0 ..< max(1, abs(lines) / 3) do mouse_report(t, 64 if lines > 0 else 65, x, y, true)
		return
	}
	if t.use_alt && t.alt_scroll {
		k := ("\x1bOA" if t.app_cursor else "\x1b[A") if lines > 0 else ("\x1bOB" if t.app_cursor else "\x1b[B")
		for _ in 0 ..< abs(lines) do pty_write(t, transmute([]u8)k)
		return
	}
	scroll_lines(t, lines)
}

// ---------- events from terminals ----------

process_wake :: proc() {
	sync.atomic_store(&wake_pending, false)
	if sync.atomic_exchange(&config_dirty, false) && config_file_mtime() != config_mtime do apply_config()
	dead := make([dynamic]^Node, context.temp_allocator)
	Ctx :: struct {dead: ^[dynamic]^Node, visible: bool}
	for tab, ti in app.tabs {
		ctx := Ctx{&dead, ti == app.cur}
		for_leaves(tab.root, proc(n: ^Node, data: rawptr) {
			ctx := (^Ctx)(data)
			t := n.term
			sync.mutex_lock(&t.mu)
			defer sync.mutex_unlock(&t.mu)
			if t.exited do append(ctx.dead, n)
			if t.dirty && ctx.visible && !t.sync_output do app.redraw = true
			if t.title_changed {
				t.title_changed = false
				app.redraw = true
			}
			if t.clipboard_pending {
				t.clipboard_pending = false
				_ = sdl.SetClipboardText(strings.clone_to_cstring(t.clipboard_set, context.temp_allocator))
			}
			if t.bell {
				t.bell = false
				app.bell_time = app.now
				_ = sdl.FlashWindow(app.window, .BRIEFLY)
			}
			for msg in t.notify {
				title, body := "kuraokami", msg
				if i := strings.index_byte(msg, ';'); i >= 0 do title, body = msg[:i], msg[i + 1:]
				notify(title, body)
				delete(msg)
			}
			clear(&t.notify)
		}, &ctx)
	}
	for n in dead do close_pane(n)
	if app.running && len(app.tabs) > 0 {
		t := focused()
		title := t.title if t.title != "" else "kuraokami"
		_ = sdl.SetWindowTitle(app.window, strings.clone_to_cstring(title, context.temp_allocator))
		update_ime_rect()
	}
}

// ---------- main ----------

main :: proc() {
	args := os.args
	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "-v", "--version":
			fmt.println("kuraokami", VERSION)
			return
		case "-h", "--help":
			fmt.println("usage: kuraokami [-e command args...]\nconfig:", config_path())
			return
		case "-e":
			app.exec_argv = args[i + 1:]
			i = len(args)
		}
	}
	platform_init()
	errs := config_load()
	install_shell_integration()
	if kf_init() == 0 {fmt.eprintln("kuraokami: freetype/fontconfig init failed"); os.exit(1)}

	_ = sdl.SetHint(sdl.HINT_KEYCODE_OPTIONS, "unmodified,latin_letters")
	_ = sdl.SetHint(sdl.HINT_APP_NAME, "kuraokami")
	_ = sdl.SetHint(sdl.HINT_APP_ID, "kuraokami") // Wayland app_id: matches kuraokami.desktop for the launcher icon
	_ = sdl.SetHint(sdl.HINT_IME_IMPLEMENTED_UI, "composition")
	if !sdl.Init({.VIDEO, .EVENTS}) {
		fmt.eprintln("kuraokami: SDL_Init failed:", sdl.GetError())
		os.exit(1)
	}
	_ = sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	_ = sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	_ = sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))
	when ODIN_OS == .Darwin do _ = sdl.GL_SetAttribute(.CONTEXT_FLAGS, 2) // forward-compatible, required for core 3.3 on macOS
	_ = sdl.GL_SetAttribute(.ALPHA_SIZE, 8)
	_ = sdl.GL_SetAttribute(.DEPTH_SIZE, 0)
	// Always alpha-capable so background-opacity can change live on config reload.
	flags := sdl.WindowFlags{.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY, .TRANSPARENT}
	app.window = sdl.CreateWindow("kuraokami", 960, 600, flags)
	if app.window == nil {fmt.eprintln("kuraokami: window:", sdl.GetError()); os.exit(1)}
	glctx := sdl.GL_CreateContext(app.window)
	if glctx == nil {fmt.eprintln("kuraokami: GL:", sdl.GetError()); os.exit(1)}
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)
	_ = sdl.GL_SetSwapInterval(1)
	if !renderer_init() {fmt.eprintln("kuraokami: shader compile failed"); os.exit(1)}
	app.cursor_default = sdl.CreateSystemCursor(.TEXT)
	app.cursor_ew = sdl.CreateSystemCursor(.EW_RESIZE)
	app.cursor_ns = sdl.CreateSystemCursor(.NS_RESIZE)
	app.density = max(sdl.GetWindowPixelDensity(app.window), 1)
	app.wake_type = sdl.RegisterEvents(1)
	app.font_pt = cfg.font_size
	app.t0 = now_s()
	app.now = app.t0
	app.start_time, app.last_frame, app.last_input = app.now, app.now, app.now
	app.bell_time, app.tab_anim_start = -100, -100
	app.tab_prev = -1
	fonts_load(int(math.round(app.font_pt * 96.0 / 72.0 * app.density)))
	if e := post_shader_load(cfg.custom_shader); e != "" do show_toast(e)
	else if len(errs) > 0 do show_toast(fmt.tprintf("config: %s", strings.join(errs, " / ", context.temp_allocator)))
	app.running = true
	new_tab()
	if len(app.tabs) == 0 {fmt.eprintln("kuraokami: failed to spawn shell"); os.exit(1)}
	_ = sdl.StartTextInput(app.window)
	_ = sdl.SetWindowMinimumSize(app.window, 100, 60)
	config_watch_start()

	for app.running {
		ev: sdl.Event
		// Block until something happens. While animating, vsync paces frames; idle = zero wakeups.
		timeout := i32(-1)
		app.now = now_s()
		animating := anim_tick(0)
		if animating do timeout = 4
		else {
			_, bms := blink_alpha()
			if bms >= 0 do timeout = bms
			if app.toast != "" {
				age := app.now - app.toast_time
				if age < 4.5 {
					ms := i32((3.5 - age) * 1000) + 1 if age < 3.5 else 0
					timeout = ms if timeout < 0 else min(timeout, ms)
				}
			}
		}
		got := sdl.WaitEvent(&ev) if timeout < 0 else sdl.WaitEventTimeout(&ev, timeout)
		app.now = now_s()
		if got {
			for {
				handle_event(&ev)
				if !app.running || !sdl.PollEvent(&ev) do break
			}
		}
		if !app.running do break
		// Also draw once more on the frame an animation settles, so its final state is shown.
		still := anim_tick(app.now - app.last_frame)
		if still || animating || timeout >= 0 do app.redraw = true
		if app.redraw do render()
		free_all(context.temp_allocator)
	}
	for tab in app.tabs do for_leaves(tab.root, proc(n: ^Node, _: rawptr) {pty_close(n.term)}, nil)
	sdl.Quit()
}

handle_event :: proc(ev: ^sdl.Event) {
	if u32(ev.type) == app.wake_type {process_wake(); return}
	#partial switch ev.type {
	case .QUIT: app.running = false
	case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED:
		layout()
	case .WINDOW_DISPLAY_SCALE_CHANGED:
		app.density = max(sdl.GetWindowPixelDensity(app.window), 1)
		set_font_size(app.font_pt)
	case .WINDOW_EXPOSED: app.redraw = true
	case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST:
		app.redraw = true
		app.last_input = app.now
		if ev.type == .WINDOW_FOCUS_GAINED && ODIN_OS != .Linux && config_file_mtime() != config_mtime do apply_config()
		if len(app.tabs) > 0 {
			t := focused()
			if t.focus_events do pty_write(t, transmute([]u8)string("\x1b[I" if ev.type == .WINDOW_FOCUS_GAINED else "\x1b[O"))
		}
	case .KEY_DOWN: on_key(ev.key)
	case .KEY_UP: on_key_up(ev.key)
	case .TEXT_INPUT: on_text(string(ev.text.text))
	case .TEXT_EDITING:
		delete(app.preedit)
		app.preedit = strings.clone(string(ev.edit.text))
		app.redraw = true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP: on_mouse_button(ev.button)
	case .MOUSE_MOTION: on_mouse_motion(ev.motion)
	case .MOUSE_WHEEL: on_wheel(ev.wheel)
	case .DROP_FILE:
		// Drag & drop a file: paste its shell-quoted path.
		p := string(ev.drop.data)
		paste(fmt.tprintf("'%s' ", strings.replace_all(p, "'", "'\\''", context.temp_allocator)))
	}
}
