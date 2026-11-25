package kuraokami

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:unicode"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// Command palette (Ctrl+Shift+P): fuzzy-search every action, tab, theme and shader.

Palette_Kind :: enum u8 {
	Action,
	Theme,
	Shader,
}

Palette_Item :: struct {
	label:  string,
	kind:   Palette_Kind,
	action: Action,
	arg:    int,
	name:   string,
}

ACTION_LABELS := [Action]string {
	.None              = "",
	.Copy              = "コピー",
	.Paste             = "貼り付け",
	.Paste_Selection   = "選択範囲(PRIMARY)を貼り付け",
	.Select_All        = "すべて選択",
	.New_Tab           = "新しいタブ",
	.Close_Pane        = "ペインを閉じる",
	.Split_Right       = "右に分割",
	.Split_Down        = "下に分割",
	.Focus_Left        = "左のペインへ",
	.Focus_Right       = "右のペインへ",
	.Focus_Up          = "上のペインへ",
	.Focus_Down        = "下のペインへ",
	.Next_Tab          = "次のタブ",
	.Prev_Tab          = "前のタブ",
	.Goto_Tab          = "",
	.Resize_Left       = "分割を左へ広げる",
	.Resize_Right      = "分割を右へ広げる",
	.Resize_Up         = "分割を上へ広げる",
	.Resize_Down       = "分割を下へ広げる",
	.Equalize_Splits   = "分割を均等にする",
	.Scroll_Page_Up    = "1 ページ上へスクロール",
	.Scroll_Page_Down  = "1 ページ下へスクロール",
	.Scroll_Top        = "いちばん上へスクロール",
	.Scroll_Bottom     = "いちばん下へスクロール",
	.Prompt_Prev       = "前のプロンプトへ",
	.Prompt_Next       = "次のプロンプトへ",
	.Font_Inc          = "文字を大きく",
	.Font_Dec          = "文字を小さく",
	.Font_Reset        = "文字の大きさを戻す",
	.Open_Config       = "設定ファイルを開く",
	.Reload_Config     = "設定を再読み込み",
	.Search            = "スクロールバックを検索",
	.Clear_Scrollback  = "スクロールバックを消去",
	.Toggle_Fullscreen = "フルスクリーン切り替え",
	.Command_Palette   = "",
	.Unbind            = "",
}

palette_items :: proc() -> []Palette_Item {
	items := make([dynamic]Palette_Item, context.temp_allocator)
	for a in Action {
		if ACTION_LABELS[a] == "" do continue
		append(&items, Palette_Item{label = ACTION_LABELS[a], kind = .Action, action = a})
	}
	for tab, i in app.tabs {
		append(
			&items,
			Palette_Item {
				label = fmt.tprintf("タブ %d へ: %s", i + 1, tab_title(tab)),
				kind = .Action,
				action = .Goto_Tab,
				arg = i + 1,
			},
		)
	}
	for th in BUILTIN_THEMES do append(&items, Palette_Item{label = fmt.tprintf("テーマ: %s", th.name), kind = .Theme, name = th.name})
	for sh in BUILTIN_SHADERS do append(&items, Palette_Item{label = fmt.tprintf("シェーダー: %s", sh.name), kind = .Shader, name = fmt.tprintf("builtin:%s", sh.name)})
	append(&items, Palette_Item{label = "シェーダー: なし", kind = .Shader, name = ""})
	return items[:]
}

// Subsequence match, case-insensitive; also matches the English action name (e.g. "split").
palette_match :: proc(it: Palette_Item, q: []rune) -> bool {
	if len(q) == 0 do return true
	hay := it.label
	if it.kind == .Action do hay = fmt.tprintf("%s %v", it.label, it.action)
	k := 0
	for r in hay {
		if k < len(q) && unicode.to_lower(r) == q[k] do k += 1
	}
	return k == len(q)
}

palette_filtered :: proc() -> []Palette_Item {
	out := make([dynamic]Palette_Item, context.temp_allocator)
	for it in palette_items() do if palette_match(it, app.palette_text[:]) do append(&out, it)
	return out[:]
}

bind_label :: proc(a: Action, arg: int) -> string {
	for b in cfg.binds {
		if b.action != a || b.arg != arg do continue
		sb := strings.builder_make(context.temp_allocator)
		if b.mods & MOD_CTRL != 0 do strings.write_string(&sb, "Ctrl+")
		if b.mods & MOD_SHIFT != 0 do strings.write_string(&sb, "Shift+")
		if b.mods & MOD_ALT != 0 do strings.write_string(&sb, "Alt+")
		if b.mods & MOD_SUPER != 0 do strings.write_string(&sb, "Super+")
		strings.write_string(&sb, string(sdl.GetKeyName(b.key)))
		return strings.to_string(sb)
	}
	return ""
}

palette_open :: proc() {
	app.palette_on = true
	clear(&app.palette_text)
	app.palette_sel = 0
	app.palette_time = app.now
	app.redraw = true
}

refresh_term_colors :: proc() {
	for tab in app.tabs do for_leaves(tab.root, proc(n: ^Node, _: rawptr) {
			t := n.term
			sync.mutex_lock(&t.mu)
			palette_reset(t)
			t.dirty = true
			sync.mutex_unlock(&t.mu)
		}, nil)
	app.redraw = true
}

palette_run :: proc(it: Palette_Item) {
	app.palette_on = false
	app.redraw = true
	switch it.kind {
	case .Action:
		run_action(Keybind{action = it.action, arg = it.arg})
	case .Theme:
		// Applies until the config file is reloaded (write `theme = ...` there to keep it).
		errs := make([dynamic]string, context.temp_allocator)
		config_apply_text(fmt.tprintf("theme = %s", it.name), &errs)
		refresh_term_colors()
		show_toast(
			fmt.tprintf(
				"テーマ %s を適用しました(残すには設定に theme = %s)",
				it.name,
				it.name,
			),
		)
	case .Shader:
		cfg.custom_shader = strings.clone(it.name)
		if e := post_shader_load(cfg.custom_shader); e != "" do show_toast(e)
	}
}

palette_key :: proc(e: sdl.KeyboardEvent) {
	items := palette_filtered()
	switch e.key {
	case sdl.K_ESCAPE:
		app.palette_on = false
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		if len(items) > 0 do palette_run(items[clamp(app.palette_sel, 0, len(items) - 1)])
	case sdl.K_UP:
		app.palette_sel = max(0, app.palette_sel - 1)
	case sdl.K_DOWN, sdl.K_TAB:
		app.palette_sel = min(max(0, len(items) - 1), app.palette_sel + 1)
	case sdl.K_BACKSPACE:
		if len(app.palette_text) > 0 do pop(&app.palette_text)
		app.palette_sel = 0
	}
	app.redraw = true
}

palette_text_input :: proc(text: string) {
	for r in text do append(&app.palette_text, unicode.to_lower(r))
	app.palette_sel = 0
	app.redraw = true
}

palette_draw :: proc(w, h: int) {
	items := palette_filtered()
	cw, ch := fonts.cell_w, fonts.cell_h
	cols := min(72, w / cw - 4)
	if cols < 10 do return
	bw := f32(cols * cw)
	x := (f32(w) - bw) / 2
	slide :=
		f32(0) if !cfg.animation else (1 - ease_out((app.now - app.palette_time) / 0.18)) * f32(ch)
	y := f32(h) * 0.14 - slide
	shown := min(len(items), 12)
	box_bg := mix(cfg.bg, cfg.fg, 0.08)
	quad(&ren.ov, x - 8, y - 8, x + bw + 8, y + f32((shown + 1) * ch) + 16, rgba(box_bg, 245))
	query := utf8.runes_to_string(app.palette_text[:], context.temp_allocator)
	draw_text(
		&ren.ov,
		x,
		y,
		truncate_cells(fmt.tprintf("❯ %s%s▏", query, app.preedit), cols),
		cfg.fg,
		box_bg,
	)
	y += f32(ch) + 8
	// Keep the selection visible when it is beyond the first page.
	first := max(0, app.palette_sel - shown + 1)
	for i in first ..< min(len(items), first + shown) {
		it := items[i]
		sel := i == app.palette_sel
		bg := cfg.selection_bg if sel else box_bg
		fg := cfg.selection_fg if sel && cfg.selection_fg != NO_COLOR else cfg.fg
		keys := bind_label(it.action, it.arg) if it.kind == .Action else ""
		label := truncate_cells(fmt.tprintf(" %s", it.label), cols - strings.rune_count(keys) - 2)
		quad(&ren.ov, x, y, x + bw, y + f32(ch), rgba(bg))
		draw_text(&ren.ov, x, y, label, fg, bg)
		if keys != "" do draw_text(&ren.ov, x + bw - f32((strings.rune_count(keys) + 1) * cw), y, keys, mix(fg, bg, 0.4), bg)
		y += f32(ch)
	}
	if len(items) == 0 do draw_text(&ren.ov, x, y, " 該当なし", mix(cfg.fg, box_bg, 0.4), box_bg)
}
