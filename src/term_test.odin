package kuraokami

import "core:testing"
import "core:strings"
import "core:encoding/base64"
import sdl "vendor:sdl3"

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
