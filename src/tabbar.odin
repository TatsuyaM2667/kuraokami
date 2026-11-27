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
	case "never":
		return false
	case "auto":
		return len(app.tabs) > 1
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

// Glass tab bar: everything is a translucent tint over the (already translucent) window
// background, so the wallpaper shows through like in the terminal area.
draw_tabbar :: proc(w: int) {
	n := len(app.tabs)
	H := f32(app.tabbar_h)
	cw, ch := f32(fonts.cell_w), f32(fonts.cell_h)
	tw_i, plus_x := tab_metrics(w)
	tw := f32(tw_i)
	fgc := cfg.fg
	accent := cfg.cursor
	alpha :: proc(c: u32, a: f32) -> [4]u8 {return rgba(c, u8(clamp(a, 0, 1) * 255))}
	// A faint darkening behind the bar and a hairline where it meets the content.
	quad(&ren.ov, 0, 0, f32(w), H, alpha(0x000000, 0.18))
	quad(&ren.ov, 0, H - 1, f32(w), H, alpha(fgc, 0.06))
	top := f32(4)
	uh := f32(fonts.ui_h)
	ty := top + (H - top - uh) / 2 // UI text line box, vertically centered in the tab
	radius := ch * 0.45
	for tb, i in app.tabs {
		x0 := f32(i) * tw + 3
		x1 := f32(i + 1) * tw - 1
		active := i == app.cur
		hover := i == app.tab_hover.index && !app.tab_hover.plus
		if active do rounded_rect(&ren.ov, x0, top, x1, H, radius, alpha(fgc, 0.15), true)
		else if hover do rounded_rect(&ren.ov, x0, top, x1, H, radius, alpha(fgc, 0.08), true)
		else if i + 1 != app.cur && i + 1 < n {
			// thin divider between two inactive tabs
			quad(&ren.ov, x1, top + (H - top) * 0.28, x1 + 1, H - (H - top) * 0.28, alpha(fgc, 0.12))
		}
		show_close := tw_i >= 8 * fonts.cell_w
		room := tw - cw * (4.2 if show_close else 1.6)
		fg := alpha(fgc, 1.0 if active else 0.85 if hover else 0.5)
		lx := x0 + cw * 0.9
		if tb.agent_state != .None {
			// Agent status dot: working / waiting for you / idle / finished
			dr := uh * 0.2
			dcx, dcy := lx + dr, ty + uh / 2
			rounded_rect(&ren.ov, dcx - dr, dcy - dr, dcx + dr, dcy + dr, dr, alpha(agent_color(tb.agent_state), 1))
			lx += dr * 2 + cw * 0.6
			room -= dr * 2 + cw * 0.6
		}
		label := ui_truncate(tab_title(tb), max(cw, room))
		draw_ui_text(&ren.ov, lx, ty, label, fg)
		if show_close && (active || hover) {
			cx := x1 - cw * 1.6
			cy := top + (H - top) / 2
			cr := ch * 0.42
			if hover && app.tab_hover.close do rounded_rect(&ren.ov, cx - cr, cy - cr, cx + cr, cy + cr, cr, alpha(cfg.palette[1], 0.45))
			draw_ui_text(
				&ren.ov,
				cx - ui_advance('×') / 2,
				cy - uh / 2,
				"×",
				alpha(fgc, 0.9 if hover && app.tab_hover.close else 0.6),
			)
		}
	}
	// + button: a round hover highlight.
	px := f32(plus_x) + cw * 1.5
	py := top + (H - top) / 2
	pr := ch * 0.45
	if app.tab_hover.plus do rounded_rect(&ren.ov, px - pr, py - pr, px + pr, py + pr, pr, alpha(fgc, 0.12))
	draw_ui_text(
		&ren.ov,
		px - ui_advance('+') / 2,
		py - uh / 2,
		"+",
		alpha(fgc, 0.9 if app.tab_hover.plus else 0.55),
	)
	// Sliding accent underline with a soft glow under the active tab.
	p :=
		ease_out((app.now - app.tab_anim_start) / 0.25) if app.tab_prev >= 0 && cfg.animation else 1
	from := f32(app.tab_prev if app.tab_prev >= 0 && app.tab_prev < n else app.cur)
	ux := (from + (f32(app.cur) - from) * p) * tw
	inset := tw * 0.18
	rounded_rect(&ren.ov, ux + inset - 2, H - 6, ux + tw - inset + 2, H, 3, alpha(accent, 0.18))
	rounded_rect(&ren.ov, ux + inset, H - 3, ux + tw - inset, H - 1, 1, alpha(accent, 0.95))
}

// Mouse button on the tab bar. Returns true if handled.
tabbar_button :: proc(e: sdl.MouseButtonEvent, px, w: int) -> bool {
	hit := tab_hit(px, w)
	if !e.down {
		app.tab_drag = -1
		return true
	}
	switch {
	case hit.plus && e.button == 1:
		new_tab()
	case hit.index < 0:
		if e.button == 1 && e.clicks == 2 do new_tab() // double-click empty space: new tab
	case hit.index >= len(app.tabs):
	case e.button == 2 || (e.button == 1 && hit.close):
		close_tab(hit.index)
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
