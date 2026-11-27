package kuraokami

import "core:testing"
import "core:strings"
import "core:encoding/base64"
import sdl "vendor:sdl3"
import "core:image/png"
import "core:bytes"
import "core:os"
import "core:unicode/utf8"

line_text :: proc(t: ^Term, y: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in row(t, y) {
		buf: [4]u8
		if c.wide != 2 do strings.write_string(&b, cell_text(t, c.ch, &buf))
	}
	return strings.trim_right(strings.to_string(b), " ")
}

mk :: proc(cols, rows: int) -> ^Term {
	// Only the fields the core reads; config_defaults() would race with test_keybinds over cfg.binds.
	cfg.palette, cfg.scrollback, cfg.fg, cfg.bg = DEFAULT_PALETTE, 10000, 0xc5c8c6, 0x1d1f21
	t := new(Term)
	t.cell_w, t.cell_h = 10, 20
	term_init(t, cols, rows)
	return t
}

feed :: proc(t: ^Term, s: string) {term_feed(t, transmute([]u8)s)}

@(test)
test_basic :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer {term_destroy(t); free(t)}
	feed(t, "hello\r\nworld")
	testing.expect_value(tt, line_text(t, 0), "hello")
	testing.expect_value(tt, line_text(t, 1), "world")
	feed(t, "\x1b[1;1H\x1b[2K\x1b[31mX")
	testing.expect_value(tt, line_text(t, 0), "X")
	testing.expect_value(tt, row(t, 0)[0].fg, PAL | 1)
	feed(t, "\x1b[38;2;1;2;3mY\x1b[38:2::4:5:6mZ")
	testing.expect_value(tt, row(t, 0)[1].fg, u32(0x010203))
	testing.expect_value(tt, row(t, 0)[2].fg, u32(0x040506))
}

@(test)
test_wrap_scroll_wide :: proc(tt: ^testing.T) {
	t := mk(4, 2)
	defer {term_destroy(t); free(t)}
	feed(t, "abcdefgh\r\nij")
	testing.expect_value(tt, line_text(t, 0), "efgh")
	testing.expect_value(tt, line_text(t, 1), "ij")
	testing.expect_value(tt, t.primary.count, 3)
	testing.expect_value(tt, t.total_pushed, i64(1))
	feed(t, "\x1b[2J\x1b[H日本x")
	testing.expect_value(tt, line_text(t, 0), "日本")
	testing.expect_value(tt, row(t, 0)[1].wide, u8(2))
	testing.expect_value(tt, line_text(t, 1), "x")
}

@(test)
test_alt_and_region :: proc(tt: ^testing.T) {
	t := mk(5, 4)
	defer {term_destroy(t); free(t)}
	feed(t, "1\r\n2\r\n3\r\n4")
	feed(t, "\x1b[?1049h")
	testing.expect_value(tt, line_text(t, 0), "")
	feed(t, "\x1b[2;3r\x1b[3;1Hz\n")
	testing.expect_value(tt, line_text(t, 1), "z")
	feed(t, "\x1b[?1049l")
	testing.expect_value(tt, line_text(t, 3), "4")
	testing.expect_value(tt, t.cy, 3)
	feed(t, "\x1b[6n")
	testing.expect_value(tt, string(t.reply[:]), "\x1b[4;2R")
}

@(test)
test_resize :: proc(tt: ^testing.T) {
	t := mk(10, 4)
	defer {term_destroy(t); free(t)}
	feed(t, "a\r\nb\r\nc\r\nd")
	term_resize(t, 6, 2)
	testing.expect_value(tt, line_text(t, 0), "c")
	testing.expect_value(tt, line_text(t, 1), "d")
	testing.expect_value(tt, t.cy, 1)
	term_resize(t, 12, 5)
	testing.expect_value(tt, line_text(t, 3), "d")
	testing.expect_value(tt, t.cy, 3)
}

@(test)
test_kitty_and_sixel :: proc(tt: ^testing.T) {
	t := mk(20, 10)
	defer {term_destroy(t); free(t)}
	px := [12]u8{255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9}
	b64, _ := base64.encode(px[:], allocator = context.temp_allocator)
	// chunked transmit + place: 2x2 RGB image
	half := len(b64) / 2
	feed(t, strings.concatenate({"\x1b_Ga=T,f=24,s=2,v=2,i=7,m=1;", b64[:half], "\x1b\\\x1b_Gm=0;", b64[half:], "\x1b\\"}, context.temp_allocator))
	img, ok := t.gfx.images[7]
	testing.expect(tt, ok)
	if ok {
		testing.expect_value(tt, img.w, 2)
		testing.expect_value(tt, img.pixels[4], u8(0))
		testing.expect_value(tt, img.pixels[5], u8(255))
	}
	testing.expect_value(tt, len(t.gfx.placements), 1)
	testing.expect_value(tt, string(t.reply[:]), "\x1b_Gi=7;OK\x1b\\")
	feed(t, "\x1b_Ga=d,d=A\x1b\\")
	testing.expect_value(tt, len(t.gfx.placements), 0)
	testing.expect_value(tt, len(t.gfx.images), 0)
	// sixel: one red column 6px tall, 3 wide
	feed(t, "\x1bPq#1;2;100;0;0#1!3~\x1b\\")
	testing.expect_value(tt, len(t.gfx.images), 1)
	for _, im in t.gfx.images {
		testing.expect_value(tt, im.w, 3)
		testing.expect_value(tt, im.h, 6)
		testing.expect_value(tt, im.pixels[0], u8(255))
	}
}

@(test)
test_osc :: proc(tt: ^testing.T) {
	t := mk(20, 3)
	defer {term_destroy(t); free(t)}
	feed(t, "\x1b]2;my title\x07\x1b]8;;https://x.y\x1b\\L\x1b]8;;\x1b\\\x1b]52;c;aGk=\x07\x1b]133;A\x07")
	testing.expect_value(tt, t.title, "my title")
	testing.expect(tt, row(t, 0)[0].link != 0)
	testing.expect_value(tt, t.clipboard_set, "hi")
	testing.expect_value(tt, len(t.prompts), 1)
	feed(t, "\x1b]11;?\x1b\\")
	testing.expect(tt, strings.has_prefix(string(t.reply[:]), "\x1b]11;rgb:"))
}

@(test)
test_reflow :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer {term_destroy(t); free(t)}
	feed(t, "abcdefghijKLMNO\r\nxy")
	testing.expect_value(tt, line_text(t, 0), "abcdefghij")
	testing.expect(tt, row_ln(t, 0).wrapped)
	term_resize(t, 20, 3)
	testing.expect_value(tt, line_text(t, 0), "abcdefghijKLMNO")
	testing.expect_value(tt, line_text(t, 1), "xy")
	testing.expect_value(tt, t.cy, 1)
	testing.expect_value(tt, t.cx, 2)
	term_resize(t, 5, 3)
	// 15 chars -> 3 rows of 5, plus "xy" = 4 lines; screen shows the last 3
	testing.expect_value(tt, line_text(t, 0), "fghij")
	testing.expect_value(tt, line_text(t, 1), "KLMNO")
	testing.expect_value(tt, line_text(t, 2), "xy")
	testing.expect_value(tt, t.cx, 2)
	// wide chars never split across rows
	feed(t, "\x1b[2J\x1b[H")
	feed(t, "ab日本")
	term_resize(t, 3, 3)
	testing.expect_value(tt, line_text(t, 0), "ab")
	testing.expect_value(tt, line_text(t, 1), "日")
}

@(test)
test_graphemes :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer {term_destroy(t); free(t)}
	feed(t, "éx👨‍👩‍👧🇯🇵")
	testing.expect_value(tt, line_text(t, 0), "éx👨‍👩‍👧🇯🇵")
	testing.expect_value(tt, t.cx, 6) // é(1) x(1) family(2) flag(2)
}

@(test)
test_kitty_keyboard :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer {term_destroy(t); free(t)}
	feed(t, "\x1b[>1u\x1b[?u")
	testing.expect_value(tt, string(t.reply[:]), "\x1b[?1u")
	testing.expect_value(tt, kb_flags(t), u8(1))
	feed(t, "\x1b[<u")
	testing.expect_value(tt, kb_flags(t), u8(0))
	testing.expect_value(tt, kitty_encode(1, sdl.K_ESCAPE, 0, 1, 0), "\x1b[27u")
	testing.expect_value(tt, kitty_encode(1, sdl.K_A, MOD_CTRL, 1, 0), "\x1b[97;5u")
	testing.expect_value(tt, kitty_encode(1, sdl.K_A, 0, 1, 0), "")
	testing.expect_value(tt, kitty_encode(1, sdl.K_1, MOD_SHIFT, 1, 0), "") // Shift+1 types "!"
	testing.expect_value(tt, kitty_encode(1, sdl.K_A, MOD_SHIFT, 1, 0), "") // Shift+a types "A"
	testing.expect_value(tt, kitty_encode(1, sdl.K_1, MOD_SHIFT | MOD_CTRL, 1, 0), "\x1b[49;6u")
	testing.expect_value(tt, kitty_encode(1, sdl.K_UP, MOD_SHIFT, 1, 0), "\x1b[1;2A")
	testing.expect_value(tt, kitty_encode(1, sdl.K_UP, 0, 1, 0), "\x1b[A")
	testing.expect_value(tt, kitty_encode(10, sdl.K_A, 0, 3, 0), "\x1b[97;1:3u")
	testing.expect_value(tt, kitty_encode(24, sdl.K_A, MOD_SHIFT, 1, 'A'), "\x1b[97;2;65u")
}

@(test)
test_keybinds :: proc(tt: ^testing.T) {
	config_defaults()
	b, ok := find_bind(sdl.K_T, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
	testing.expect(tt, ok && b.action == .New_Tab)
	testing.expect(tt, bind_add("ctrl+shift+t=split_down"))
	b, ok = find_bind(sdl.K_T, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
	testing.expect(tt, ok && b.action == .Split_Down)
	testing.expect(tt, bind_add("alt+3=goto_tab:3"))
	b, ok = find_bind(sdl.K_3, sdl.KMOD_LALT)
	testing.expect(tt, ok && b.action == .Goto_Tab && b.arg == 3)
	testing.expect(tt, bind_add("ctrl+equal=unbind"))
	_, ok = find_bind(sdl.K_EQUALS, sdl.KMOD_LCTRL)
	testing.expect(tt, !ok)
	testing.expect(tt, !bind_add("ctrl+nosuchkey=copy"))
	testing.expect(tt, !bind_add("ctrl+a=nosuchaction"))
	errs := make([dynamic]string, context.temp_allocator)
	config_apply_text("theme = dracula\nbackground = #000001\nbogus = 1\nfont-size = x", &errs)
	testing.expect_value(tt, cfg.bg, u32(1))
	testing.expect_value(tt, cfg.palette[1], u32(0xff5555))
	testing.expect_value(tt, len(errs), 2)
	delete(cfg.binds)
	cfg.binds = {}
}

@(test)
test_search :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer {term_destroy(t); free(t)}
	feed(t, "foo\r\nbar Foo\r\nbaz\r\nqux\r\nend")
	needle := []rune{'f', 'o', 'o'}
	pos, ok := search(t, needle, {t.total_pushed + 3, 0}, -1)
	testing.expect(tt, ok)
	testing.expect_value(tt, pos, [2]i64{1, 4})
	pos, ok = search(t, needle, pos, -1)
	testing.expect_value(tt, pos, [2]i64{0, 0})
	_, ok = search(t, needle, pos, -1)
	testing.expect(tt, !ok)
}

@(test)
test_shell_integration :: proc(tt: ^testing.T) {
	saved := integration_ready
	defer integration_ready = saved
	integration_ready = true
	argv, env := integrate({"/usr/bin/zsh"})
	testing.expect_value(tt, len(argv), 1)
	found := false
	for e in env do if e[0] == "ZDOTDIR" do found = true
	testing.expect(tt, found)
	argv, env = integrate({"/bin/bash"})
	testing.expect_value(tt, len(argv), 3)
	testing.expect_value(tt, argv[1], "--rcfile")
	argv, env = integrate({"/bin/bash", "-c", "true"}) // explicit args: untouched
	testing.expect_value(tt, len(argv), 3)
	testing.expect(tt, env == nil)
}

@(test)
test_freetype_layout :: proc(tt: ^testing.T) {
	// Offsets measured from the system FreeType headers (x86_64 LP64).
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		testing.expect_value(tt, offset_of(FT_FaceRec, face_flags), uintptr(16))
		testing.expect_value(tt, offset_of(FT_FaceRec, num_fixed_sizes), uintptr(56))
		testing.expect_value(tt, offset_of(FT_FaceRec, available_sizes), uintptr(64))
		testing.expect_value(tt, offset_of(FT_FaceRec, units_per_EM), uintptr(136))
		testing.expect_value(tt, offset_of(FT_FaceRec, glyph), uintptr(152))
		testing.expect_value(tt, offset_of(FT_FaceRec, size), uintptr(160))
		testing.expect_value(tt, offset_of(FT_SizeRec, metrics), uintptr(24))
		testing.expect_value(tt, offset_of(FT_Size_Metrics, ascender), uintptr(24))
		testing.expect_value(tt, offset_of(FT_GlyphSlotRec, advance), uintptr(128))
		testing.expect_value(tt, offset_of(FT_GlyphSlotRec, bitmap), uintptr(152))
		testing.expect_value(tt, offset_of(FT_GlyphSlotRec, bitmap_left), uintptr(192))
		testing.expect_value(tt, offset_of(FT_Bitmap, buffer), uintptr(16))
		testing.expect_value(tt, offset_of(FT_Bitmap, pixel_mode), uintptr(26))
		testing.expect_value(tt, size_of(FT_Bitmap_Size), 32)
	}
}

@(test)
test_png_roundtrip :: proc(tt: ^testing.T) {
	px := [12]u8{255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 8, 7} // 2x2, bottom-up
	data := png_encode_rgb(px[:], 2, 2)
	img, err := png.load_from_bytes(data)
	testing.expect(tt, err == nil)
	if err == nil {
		defer png.destroy(img)
		b := image_bytes(img)
		testing.expect_value(tt, img.width, 2)
		testing.expect_value(tt, b[0], u8(0)) // top-left = last row of input = (0,0,255)
		testing.expect_value(tt, b[2], u8(255))
	}
}

@(test)
test_security_kitty_files :: proc(tt: ^testing.T) {
	t := mk(20, 5)
	defer {term_destroy(t); free(t)}
	b64 :: proc(s: string) -> string {e, _ := base64.encode(transmute([]u8)s, allocator = context.temp_allocator); return e}
	// Device files must be refused (reading /dev/zero would never end).
	feed(t, strings.concatenate({"\x1b_Ga=t,t=f,f=100,i=1;", b64("/dev/zero"), "\x1b\\"}, context.temp_allocator))
	testing.expect(tt, strings.contains(string(t.reply[:]), "EPERM"))
	clear(&t.reply)
	// t=t outside a temp dir must neither be read nor deleted.
	victim := "./tty-graphics-protocol-victim.txt"
	_ = os.write_entire_file(victim, transmute([]u8)string("keep me"))
	defer os.remove(victim)
	abs, _ := os.get_absolute_path(victim, context.temp_allocator)
	feed(t, strings.concatenate({"\x1b_Ga=t,t=t,f=100,i=2;", b64(abs), "\x1b\\"}, context.temp_allocator))
	testing.expect(tt, strings.contains(string(t.reply[:]), "EPERM"))
	testing.expect(tt, os.exists(victim))
	clear(&t.reply)
	// Relative paths are refused.
	feed(t, strings.concatenate({"\x1b_Ga=t,t=f,f=100,i=3;", b64("etc/passwd"), "\x1b\\"}, context.temp_allocator))
	testing.expect(tt, strings.contains(string(t.reply[:]), "EPERM"))
}

@(test)
test_security_limits :: proc(tt: ^testing.T) {
	t := mk(20, 5)
	defer {term_destroy(t); free(t)}
	// A huge placement must not loop for 2^30 lines.
	px := [3]u8{1, 2, 3}
	e, _ := base64.encode(px[:], allocator = context.temp_allocator)
	feed(t, strings.concatenate({"\x1b_Ga=T,f=24,s=1,v=1,i=9,r=999999999,c=999999999;", e, "\x1b\\"}, context.temp_allocator))
	testing.expect(tt, len(t.gfx.placements) == 1 && t.gfx.placements[0].rows <= MAX_PLACE_CELLS)
	// Oversized dimensions are rejected instead of overflowing.
	feed(t, "\x1b_Ga=t,f=32,s=99999999999,v=99999999999,i=10;AAAA\x1b\\")
	_, ok := t.gfx.images[10]
	testing.expect(tt, !ok)
	// An unterminated OSC stops growing at the cap and is not executed.
	big := strings.repeat("x", MAX_OSC + 1000, context.temp_allocator)
	feed(t, "\x1b]2;")
	feed(t, big)
	feed(t, "\x07")
	testing.expect(tt, len(t.strbuf) <= MAX_OSC)
	testing.expect(tt, t.title == "")
}

@(test)
test_security_urls :: proc(tt: ^testing.T) {
	testing.expect(tt, url_allowed("https://example.com"))
	testing.expect(tt, url_allowed("mailto:a@b.c"))
	testing.expect(tt, !url_allowed("javascript:alert(1)"))
	testing.expect(tt, !url_allowed("ssh://host"))
	testing.expect(tt, url_allowed("file:///tmp"))
	testing.expect(tt, !url_allowed("file:///usr/bin/sh"))      // executable
	testing.expect(tt, !url_allowed("file:///x/evil.desktop"))  // launcher
}

@(test)
test_palette_and_cmd_done :: proc(tt: ^testing.T) {
	q :: proc(s: string) -> []rune {return utf8.string_to_runes(s, context.temp_allocator)}
	split := Palette_Item{label = "右に分割", kind = .Action, action = .Split_Right}
	testing.expect(tt, palette_match(split, q("右分")))        // Japanese subsequence
	testing.expect(tt, palette_match(split, q("split")))      // English action name
	testing.expect(tt, !palette_match(split, q("theme")))
	testing.expect(tt, palette_match(Palette_Item{label = "テーマ: dracula", kind = .Theme}, q("drc")))
	// OSC 133 C/D produce a finished-command record with the exit status.
	t := mk(10, 2)
	defer {term_destroy(t); free(t)}
	feed(t, "\x1b]133;C\x07\x1b]133;D;3\x07")
	testing.expect(tt, t.cmd_done.pending)
	testing.expect_value(tt, t.cmd_done.status, 3)
	feed(t, "\x1b]133;D;0\x07") // D without C is ignored
	testing.expect_value(tt, t.cmd_done.status, 3)
}

@(test)
test_ime_enter_does_not_eat_commit :: proc(tt: ^testing.T) {
	// Enter never produces TEXT_INPUT, so handling it must not drop the IME commit that follows.
	e := sdl.KeyboardEvent{key = sdl.K_RETURN}
	e.timestamp = 1_000_000_000
	suppress_text_of(e, true)
	testing.expect_value(tt, app.suppress_until, u64(0))
	// A handled printable key (e.g. Ctrl+Shift+C) still drops its own text...
	c := sdl.KeyboardEvent{key = sdl.K_C}
	c.timestamp = 2_000_000_000
	suppress_text_of(c, true)
	testing.expect(tt, app.suppress_until > c.timestamp)
	// ...but only for that keypress: text arriving later is kept.
	testing.expect(tt, app.suppress_until < c.timestamp + 100_000_000)
	app.suppress_until = 0
}

@(test)
test_fish_integration_env :: proc(tt: ^testing.T) {
	saved := integration_ready
	defer integration_ready = saved
	integration_ready = true
	_, env := integrate({"/usr/bin/fish"})
	found := false
	for e in env do if e[0] == "XDG_DATA_DIRS" && strings.contains(e[1], "/xdg:") do found = true
	testing.expect(tt, found)
}

@(test)
test_reflow_keeps_image_anchor :: proc(tt: ^testing.T) {
	t := mk(10, 6)
	defer {term_destroy(t); free(t)}
	// A long wrapped line above the image: narrowing the window adds rows above it.
	feed(t, "abcdefghijklmnopqrs\r\n")
	px := [3]u8{1, 2, 3}
	e, _ := base64.encode(px[:], allocator = context.temp_allocator)
	feed(t, strings.concatenate({"\x1b_Ga=T,f=24,s=1,v=1,i=5,c=1,r=1,C=1;", e, "\x1b\\X"}, context.temp_allocator))
	// The image sits on the line that starts with "X".
	img_line :: proc(t: ^Term) -> string {
		for p in t.gfx.placements {
			l, ok := abs_line(t, p.abs_row)
			// A string pointing at a compound literal can't be returned (an error since Odin dev-2026-11): use a static byte.
			@(static) one: [1]u8
			if ok {
				one[0] = u8(l[0].ch)
				return string(one[:])
			}
		}
		return "?"
	}
	testing.expect_value(tt, img_line(t), "X")
	term_resize(t, 5, 6)
	testing.expect_value(tt, img_line(t), "X")
	term_resize(t, 20, 6)
	testing.expect_value(tt, img_line(t), "X")
}
