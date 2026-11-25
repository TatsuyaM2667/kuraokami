package kuraokami

import "core:fmt"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

Action :: enum u8 {
	None,
	Copy,
	Paste,
	Paste_Selection,
	Select_All,
	New_Tab,
	Close_Pane,
	Split_Right,
	Split_Down,
	Focus_Left,
	Focus_Right,
	Focus_Up,
	Focus_Down,
	Next_Tab,
	Prev_Tab,
	Goto_Tab,
	Resize_Left,
	Resize_Right,
	Resize_Up,
	Resize_Down,
	Equalize_Splits,
	Scroll_Page_Up,
	Scroll_Page_Down,
	Scroll_Top,
	Scroll_Bottom,
	Prompt_Prev,
	Prompt_Next,
	Font_Inc,
	Font_Dec,
	Font_Reset,
	Open_Config,
	Reload_Config,
	Search,
	Clear_Scrollback,
	Toggle_Fullscreen,
	Command_Palette,
	Unbind,
}

MOD_CTRL :: u8(1)
MOD_SHIFT :: u8(2)
MOD_ALT :: u8(4)
MOD_SUPER :: u8(8)

Keybind :: struct {
	mods:   u8,
	key:    sdl.Keycode,
	action: Action,
	arg:    int,
}

DEFAULT_BINDS := [?]string {
	"ctrl+shift+c=copy",
	"ctrl+shift+v=paste",
	"shift+insert=paste_selection",
	"ctrl+shift+a=select_all",
	"ctrl+shift+t=new_tab",
	"ctrl+shift+w=close_pane",
	"ctrl+shift+e=split_right",
	"ctrl+shift+o=split_down",
	"ctrl+alt+left=focus_left",
	"ctrl+alt+right=focus_right",
	"ctrl+alt+up=focus_up",
	"ctrl+alt+down=focus_down",
	"ctrl+tab=next_tab",
	"ctrl+shift+tab=prev_tab",
	"ctrl+pagedown=next_tab",
	"ctrl+pageup=prev_tab",
	"ctrl+shift+right=next_tab",
	"ctrl+shift+left=prev_tab",
	"ctrl+shift+alt+left=resize_left",
	"ctrl+shift+alt+right=resize_right",
	"ctrl+shift+alt+up=resize_up",
	"ctrl+shift+alt+down=resize_down",
	"ctrl+shift+alt+equal=equalize_splits",
	"shift+pageup=scroll_page_up",
	"shift+pagedown=scroll_page_down",
	"ctrl+shift+pageup=scroll_page_up",
	"ctrl+shift+pagedown=scroll_page_down",
	"ctrl+shift+home=scroll_top",
	"ctrl+shift+end=scroll_bottom",
	"ctrl+shift+up=prompt_prev",
	"ctrl+shift+down=prompt_next",
	"ctrl+equal=font_inc",
	"ctrl+shift+equal=font_inc",
	"ctrl+minus=font_dec",
	"ctrl+shift+minus=font_dec",
	"ctrl+0=font_reset",
	"ctrl+shift+comma=open_config",
	"ctrl+shift+r=reload_config",
	"ctrl+shift+f=search",
	"ctrl+shift+k=clear_scrollback",
	"ctrl+shift+p=command_palette",
	"f11=toggle_fullscreen",
	"ctrl+shift+1=goto_tab:1",
	"ctrl+shift+2=goto_tab:2",
	"ctrl+shift+3=goto_tab:3",
	"ctrl+shift+4=goto_tab:4",
	"ctrl+shift+5=goto_tab:5",
	"ctrl+shift+6=goto_tab:6",
	"ctrl+shift+7=goto_tab:7",
	"ctrl+shift+8=goto_tab:8",
	"ctrl+shift+9=goto_tab:9",
	"alt+1=goto_tab:1",
	"alt+2=goto_tab:2",
	"alt+3=goto_tab:3",
	"alt+4=goto_tab:4",
	"alt+5=goto_tab:5",
	"alt+6=goto_tab:6",
	"alt+7=goto_tab:7",
	"alt+8=goto_tab:8",
	"alt+9=goto_tab:9",
}

when ODIN_OS == .Darwin {
	PLATFORM_BINDS := [?]string {
		"super+c=copy",
		"super+v=paste",
		"super+t=new_tab",
		"super+w=close_pane",
		"super+d=split_right",
		"super+shift+d=split_down",
		"super+f=search",
		"super+equal=font_inc",
		"super+minus=font_dec",
		"super+0=font_reset",
		"super+comma=open_config",
		"super+k=clear_scrollback",
	}
} else {
	PLATFORM_BINDS := [?]string{}
}

KEY_ALIASES := [?][2]string {
	{"enter", "Return"},
	{"esc", "Escape"},
	{"equal", "="},
	{"plus", "="},
	{"minus", "-"},
	{"comma", ","},
	{"period", "."},
	{"slash", "/"},
	{"backslash", "\\"},
	{"pgup", "PageUp"},
	{"pgdn", "PageDown"},
	{"semicolon", ";"},
	{"apostrophe", "'"},
	{"grave", "`"},
	{"bracketleft", "["},
	{"bracketright", "]"},
}

binds_defaults :: proc() {
	for b in DEFAULT_BINDS do bind_add(b)
	for b in PLATFORM_BINDS do bind_add(b)
}

parse_trigger :: proc(s: string) -> (mods: u8, key: sdl.Keycode, ok: bool) {
	parts := strings.split(s, "+", context.temp_allocator)
	for p, i in parts {
		name := strings.to_lower(strings.trim_space(p), context.temp_allocator)
		if i < len(parts) - 1 {
			switch name {
			case "ctrl", "control":
				mods |= MOD_CTRL
			case "shift":
				mods |= MOD_SHIFT
			case "alt", "opt", "option":
				mods |= MOD_ALT
			case "super", "cmd", "win", "logo":
				mods |= MOD_SUPER
			case:
				return 0, 0, false
			}
			continue
		}
		for a in KEY_ALIASES do if a[0] == name do name = a[1]
		key = sdl.GetKeyFromName(strings.clone_to_cstring(name, context.temp_allocator))
		if key == sdl.K_UNKNOWN && len(name) == 1 do key = sdl.Keycode(name[0])
		return mods, key, key != sdl.K_UNKNOWN
	}
	return 0, 0, false
}

parse_action :: proc(s: string) -> (Action, int, bool) {
	name, arg := s, 0
	if i := strings.index_byte(s, ':'); i >= 0 {
		name = s[:i]
		n, ok := strconv.parse_int(s[i + 1:])
		if !ok do return .None, 0, false
		arg = n
	}
	name = strings.to_lower(strings.trim_space(name), context.temp_allocator)
	for a in Action {
		if strings.to_lower(fmt.tprint(a), context.temp_allocator) == name do return a, arg, true
	}
	return .None, 0, false
}

// "trigger=action[:arg]"; later bindings replace earlier ones with the same trigger.
bind_add :: proc(spec: string) -> bool {
	i := strings.last_index_byte(spec, '=')
	if i <= 0 do return false
	trig, act := spec[:i], spec[i + 1:]
	mods, key, ok := parse_trigger(trig)
	if !ok do return false
	a, arg, ok2 := parse_action(act)
	if !ok2 do return false
	for j := len(cfg.binds) - 1; j >= 0; j -= 1 {
		if cfg.binds[j].mods == mods && cfg.binds[j].key == key do ordered_remove(&cfg.binds, j)
	}
	if a != .Unbind do append(&cfg.binds, Keybind{mods, key, a, arg})
	return true
}

mods_of :: proc(m: sdl.Keymod) -> u8 {
	r: u8
	if m & sdl.KMOD_CTRL != {} do r |= MOD_CTRL
	if m & sdl.KMOD_SHIFT != {} do r |= MOD_SHIFT
	if m & sdl.KMOD_ALT != {} do r |= MOD_ALT
	if m & sdl.KMOD_GUI != {} do r |= MOD_SUPER
	return r
}

find_bind :: proc(key: sdl.Keycode, mod: sdl.Keymod) -> (Keybind, bool) {
	m := mods_of(mod)
	for b in cfg.binds do if b.key == key && b.mods == m do return b, true
	return {}, false
}

// ---------- kitty keyboard protocol ----------

Kitty_Key :: struct {
	code: int,
	term: u8, // 'u', '~' or a letter
}

kitty_functional :: proc(key: sdl.Keycode) -> (Kitty_Key, bool) {
	switch key {
	case sdl.K_ESCAPE:
		return {27, 'u'}, true
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		return {13, 'u'}, true
	case sdl.K_TAB:
		return {9, 'u'}, true
	case sdl.K_BACKSPACE:
		return {127, 'u'}, true
	case sdl.K_INSERT:
		return {2, '~'}, true
	case sdl.K_DELETE:
		return {3, '~'}, true
	case sdl.K_LEFT:
		return {1, 'D'}, true
	case sdl.K_RIGHT:
		return {1, 'C'}, true
	case sdl.K_UP:
		return {1, 'A'}, true
	case sdl.K_DOWN:
		return {1, 'B'}, true
	case sdl.K_PAGEUP:
		return {5, '~'}, true
	case sdl.K_PAGEDOWN:
		return {6, '~'}, true
	case sdl.K_HOME:
		return {1, 'H'}, true
	case sdl.K_END:
		return {1, 'F'}, true
	case sdl.K_F1:
		return {1, 'P'}, true
	case sdl.K_F2:
		return {1, 'Q'}, true
	case sdl.K_F3:
		return {13, '~'}, true
	case sdl.K_F4:
		return {1, 'S'}, true
	case sdl.K_F5:
		return {15, '~'}, true
	case sdl.K_F6:
		return {17, '~'}, true
	case sdl.K_F7:
		return {18, '~'}, true
	case sdl.K_F8:
		return {19, '~'}, true
	case sdl.K_F9:
		return {20, '~'}, true
	case sdl.K_F10:
		return {21, '~'}, true
	case sdl.K_F11:
		return {23, '~'}, true
	case sdl.K_F12:
		return {24, '~'}, true
	case sdl.K_LSHIFT:
		return {57441, 'u'}, true
	case sdl.K_LCTRL:
		return {57442, 'u'}, true
	case sdl.K_LALT:
		return {57443, 'u'}, true
	case sdl.K_LGUI:
		return {57444, 'u'}, true
	case sdl.K_RSHIFT:
		return {57447, 'u'}, true
	case sdl.K_RCTRL:
		return {57448, 'u'}, true
	case sdl.K_RALT:
		return {57449, 'u'}, true
	case sdl.K_RGUI:
		return {57450, 'u'}, true
	}
	return {}, false
}

is_modifier_key :: proc(key: sdl.Keycode) -> bool {
	switch key {
	case sdl.K_LSHIFT,
	     sdl.K_RSHIFT,
	     sdl.K_LCTRL,
	     sdl.K_RCTRL,
	     sdl.K_LALT,
	     sdl.K_RALT,
	     sdl.K_LGUI,
	     sdl.K_RGUI:
		return true
	}
	return false
}

// Encode a key for the kitty keyboard protocol. event: 1 press, 2 repeat, 3 release.
// Returns "" when the key should go through the legacy path (or produce nothing).
kitty_encode :: proc(flags: u8, key: sdl.Keycode, mods: u8, event: int, text: rune) -> string {
	all := flags & 8 != 0
	events := flags & 2 != 0
	if event != 1 && !events do return ""
	m :=
		1 +
		int(mods & MOD_SHIFT != 0) +
		2 * int(mods & MOD_ALT != 0) +
		4 * int(mods & MOD_CTRL != 0) +
		8 * int(mods & MOD_SUPER != 0)
	fk, functional := kitty_functional(key)
	if !functional {
		if key < 32 || key >= 0x40000000 || key == 127 do return ""
		fk = {int(key), 'u'}
	}
	if is_modifier_key(key) && !all do return ""
	legacy_text := !functional || key == sdl.K_RETURN || key == sdl.K_TAB || key == sdl.K_BACKSPACE
	if !all {
		if legacy_text && event != 1 do return "" // text-ish keys report release/repeat only in all-keys mode
		// Plain or Shift-only text stays text (Shift+1 must type "!", not CSI 49;2u).
		if !functional && mods & ~MOD_SHIFT == 0 do return ""
		if (key == sdl.K_RETURN || key == sdl.K_TAB || key == sdl.K_BACKSPACE) && m == 1 do return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[")
	show_text := all && flags & 16 != 0 && text >= 32 && event != 3
	if fk.code != 1 || fk.term == 'u' || m != 1 || event != 1 do strings.write_int(&b, fk.code)
	if m != 1 || event != 1 || show_text {
		strings.write_byte(&b, ';')
		strings.write_int(&b, m)
		if event != 1 {strings.write_byte(&b, ':'); strings.write_int(&b, event)}
	}
	if show_text {strings.write_byte(&b, ';'); strings.write_int(&b, int(text))}
	strings.write_byte(&b, fk.term)
	return strings.to_string(b)
}
