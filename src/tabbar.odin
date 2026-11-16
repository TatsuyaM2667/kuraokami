package kuraokami

import "core:fmt"
import sdl "vendor:sdl3"

// Browser-style tab bar: tabs sized like a browser's (shrinking as they multiply), a × on each
// tab, a + button, hover highlight, drag to reorder. tab-bar = always | auto | never.

Tab_Hit :: struct {
	index: int, // -1: none
	close: bool,
	plus:  bool,
}

tabbar_visible :: proc() -> bool {
	switch cfg.tab_bar {
	case "never": return false
	case "auto": return len(app.tabs) > 1
	}
	return true
}

// Tab width in pixels and the x of the + button.
tab_metrics :: proc(w: int) -> (tw: int, plus_x: int) {
	n := max(1, len(app.tabs))
	cw := fonts.cell_w
	avail := w - 4 * cw
	tw = min(avail / n, 28 * cw)
	return tw, n * tw
}

tab_hit :: proc(px, w: int) -> Tab_Hit {
	tw, plus_x := tab_metrics(w)
	cw := fonts.cell_w
	if px >= plus_x && px < plus_x + 3 * cw do return {-1, false, true}
	if tw <= 0 || px < 0 || px >= plus_x do return {-1, false, false}
	i := px / tw
	x0 := i * tw
	close := tw >= 8 * cw && px >= x0 + tw - 3 * cw
	return {i, close, false}
}

close_tab :: proc(i: int) {
	if i < 0 || i >= len(app.tabs) do return
	tab := app.tabs[i]
	app.cur = i
	for tab.root.term == nil do close_leaf(tab, tab.focus)
	close_pane(tab.root)
}

move_tab :: proc(from, to: int) {
	if from == to || from < 0 || to < 0 || from >= len(app.tabs) || to >= len(app.tabs) do return
	tab := app.tabs[from]
	ordered_remove(&app.tabs, from)
	inject_at(&app.tabs, to, tab)
	app.cur = to
	app.tab_prev = -1 // no slide animation while dragging
	app.redraw = true
}

draw_tabbar :: proc(w: int) {
	n := len(app.tabs)
	h := f32(app.tabbar_h)
	cw := fonts.cell_w
	tw, plus_x := tab_metrics(w)
	quad(&ren.ov, 0, 0, f32(w), h, rgba(mix(cfg.bg, cfg.fg, 0.03)))
	for tb, i in app.tabs {
		x := f32(i * tw)
		active := i == app.cur
		hover := i == app.tab_hover.index && !app.tab_hover.plus
		bg := mix(cfg.bg, cfg.fg, 0.16 if active else 0.10 if hover else 0.05)
		quad(&ren.ov, x, 0, x + f32(tw) - 1, h, rgba(bg))
		fg := cfg.fg if active else mix(cfg.fg, cfg.bg, 0.4)
		show_close := tw >= 8 * cw
		room := tw / cw - (4 if show_close else 1)
		draw_text(&ren.ov, x + f32(cw) / 2, 4, truncate_cells(fmt.tprintf("%d %s", i + 1, tab_title(tb)), max(1, room)), fg, bg)
		if show_close {
			cbg := bg
			if hover && app.tab_hover.close do cbg = mix(bg, cfg.palette[1], 0.5)
			draw_text(&ren.ov, x + f32(tw - 3 * cw), 4, " × ", fg if active || hover else mix(fg, bg, 0.3), cbg)
		}
	}
	pbg := mix(cfg.bg, cfg.fg, 0.14 if app.tab_hover.plus else 0.03)
	draw_text(&ren.ov, f32(plus_x), 4, " + ", cfg.fg, pbg)
	// Sliding underline marks the active tab.
	p := ease_out((app.now - app.tab_anim_start) / 0.25) if app.tab_prev >= 0 && cfg.animation else 1
	from := f32(app.tab_prev if app.tab_prev >= 0 && app.tab_prev < n else app.cur)
	ux := (from + (f32(app.cur) - from) * p) * f32(tw)
	quad(&ren.ov, ux, h - 2, ux + f32(tw) - 1, h, rgba(cfg.cursor))
}

// Mouse button on the tab bar. Returns true if handled.
tabbar_button :: proc(e: sdl.MouseButtonEvent, px, w: int) -> bool {
	hit := tab_hit(px, w)
	if !e.down {
		app.tab_drag = -1
		return true
	}
	switch {
	case hit.plus && e.button == 1: new_tab()
	case hit.index < 0:
		if e.button == 1 && e.clicks == 2 do new_tab() // double-click empty space: new tab
	case hit.index >= len(app.tabs):
	case e.button == 2 || (e.button == 1 && hit.close): close_tab(hit.index)
	case e.button == 1:
		switch_tab(hit.index)
		app.tab_drag = hit.index
	}
	return true
}

// Mouse motion: hover state and drag-to-reorder. Returns true if the pointer is on the bar.
tabbar_motion :: proc(e: sdl.MouseMotionEvent, px, py, w: int) -> bool {
	on_bar := app.tabbar_h > 0 && py < app.tabbar_h
	hit := tab_hit(px, w) if on_bar else Tab_Hit{-1, false, false}
	if hit != app.tab_hover {app.tab_hover = hit; app.redraw = true}
	if app.tab_drag >= 0 && .LEFT in e.state {
		if hit.index >= 0 && hit.index < len(app.tabs) && hit.index != app.tab_drag {
			move_tab(app.tab_drag, hit.index)
			app.tab_drag = hit.index
		}
		return true
	}
	return on_bar
}
