package kuraokami

// AI coding agents (Claude Code, opencode, Antigravity, Codex, Gemini, aider, ...) as first-class
// citizens: kuraokami tracks what each agent is doing, shows it in a sidebar and on the tabs,
// notifies when one needs you, and lets agents drive kuraokami through `kuraokami ctl`.
//
// How the state is known (no agent cooperation needed, but used when available):
//   started / finished   shell integration: OSC 133 C/D, command line from the title (OSC 2)
//   working              output arrived within the last AGENT_QUIET seconds
//   blocked              bell / OSC 9 / OSC 777 notification, or a question on screen ("(y/n)", "Do you want")
//   idle                 quiet and not asking: waiting for your next instruction
//   explicit             OSC 7700 ; working|blocked|idle|done|clear [; detail]  (e.g. from agent hooks)

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:path/filepath"
import sdl "vendor:sdl3"

Agent_State :: enum u8 {None, Working, Blocked, Idle, Done}

AGENT_STATE_NAMES := [Agent_State]string{.None = "none", .Working = "working", .Blocked = "blocked", .Idle = "idle", .Done = "done"}
AGENT_STATE_LABELS := [Agent_State]string{.None = "", .Working = "作業中", .Blocked = "入力待ち", .Idle = "待機中", .Done = "終了"}

AGENT_QUIET :: 1.5 // seconds without output before a running agent counts as idle

Agent :: struct {
	name:        string, // detected command, or "agent" when only OSC 7700 told us
	detail:      string, // optional message from OSC 7700
	explicit:    Agent_State,
	attention:   bool, // bell / notification since the user last typed here
	done:        bool,
	started:     time.Tick,
	last_output: time.Tick,
	// UI-thread bookkeeping
	shown:       Agent_State,
	work_since:  f64,
}

// ---------- detection (called by the parser on the PTY reader thread, with t.mu held) ----------

// "claude", "npx @anthropic-ai/claude-code", "FOO=1 opencode run" -> agent name, or "".
agent_name_of :: proc(cmdline: string) -> string {
	wrappers := [?]string{"npx", "bunx", "pnpx", "pnpm", "yarn", "uvx", "env", "nice", "time", "command", "exec", "nohup", "dlx"}
	for w in strings.fields(cmdline, context.temp_allocator) {
		if strings.contains_rune(w, '=') || strings.has_prefix(w, "-") do continue
		lw := strings.to_lower(w, context.temp_allocator)
		skip := false
		for x in wrappers do if lw == x {skip = true; break}
		if skip do continue
		base := filepath.base(lw)
		if strings.contains(base, "claude-code") do return "claude"
		for name in strings.split(cfg.agent_commands, ",", context.temp_allocator) {
			n := strings.trim_space(name)
			if n != "" && base == n do return n
		}
		return ""
	}
	return ""
}

agent_reset :: proc(t: ^Term) {
	delete(t.agent.name)
	delete(t.agent.detail)
	t.agent = {}
}

agent_on_command_start :: proc(t: ^Term) {
	if t.agent.name != "" && t.agent.done do agent_reset(t) // a new command after the agent exited
}

agent_on_title :: proc(t: ^Term) {
	if !t.cmd_running || t.agent.name != "" do return
	if n := agent_name_of(t.title); n != "" {
		now := time.tick_now()
		t.agent = {name = strings.clone(n), started = now, last_output = now}
	}
}

agent_on_command_end :: proc(t: ^Term) {
	if t.agent.name == "" do return
	t.agent.done = true
	t.agent.explicit = .None
	t.agent.attention = false
}

agent_attention :: proc(t: ^Term) {
	if t.agent.name != "" && !t.agent.done do t.agent.attention = true
}

agent_explicit :: proc(t: ^Term, rest: string) {
	state, detail := rest, ""
	if i := strings.index_byte(rest, ';'); i >= 0 do state, detail = rest[:i], rest[i + 1:]
	if state == "clear" {agent_reset(t); return}
	s: Agent_State
	switch state {
	case "working": s = .Working
	case "blocked": s = .Blocked
	case "idle": s = .Idle
	case "done": s = .Done
	case: return
	}
	if t.agent.name == "" {
		now := time.tick_now()
		t.agent = {name = strings.clone("agent"), started = now, last_output = now}
	}
	t.agent.explicit = s
	delete(t.agent.detail)
	t.agent.detail = strings.clone(detail[:min(len(detail), 200)])
}

// The user typed into this pane: whatever it was asking for has been answered.
agent_user_input :: proc(t: ^Term) {
	sync.mutex_lock(&t.mu)
	t.agent.attention = false
	if t.agent.explicit == .Blocked do t.agent.explicit = .None
	sync.mutex_unlock(&t.mu)
}

// Phrases agents print when they wait for a yes/no or a choice.
ASK_PATTERNS := [?]string{"do you want", "(y/n)", "[y/n]", "y/n)", "[y/n]?", "allow ", "approve", "permission", "許可", "continue?", "press enter", "❯ 1."}

screen_asks_user :: proc(t: ^Term) -> bool {
	b := strings.builder_make(context.temp_allocator)
	// The agent's latest output is around the cursor (the rest of the screen may be blank or stale).
	for y in max(0, t.cy - 12) ..< min(t.rows, t.cy + 2) {
		for c in row(t, y) {
			if c.wide == 2 do continue
			buf: [4]u8
			strings.write_string(&b, cell_text(t, c.ch, &buf) if c.ch != 0 else " ")
		}
		strings.write_byte(&b, '\n')
	}
	text := strings.to_lower(strings.to_string(b), context.temp_allocator)
	for p in ASK_PATTERNS do if strings.contains(text, p) do return true
	return false
}

// Caller holds t.mu.
agent_state :: proc(t: ^Term) -> Agent_State {
	a := &t.agent
	if a.name == "" do return .None
	if a.done do return .Done
	if a.explicit != .None do return a.explicit
	if a.attention do return .Blocked
	if time.duration_seconds(time.tick_since(a.last_output)) < AGENT_QUIET do return .Working
	if screen_asks_user(t) do return .Blocked
	return .Idle
}

// ---------- UI thread ----------

Agent_Row :: struct {
	tab:     int,
	node:    ^Node,
	state:   Agent_State,
	name:    string,
	folder:  string,
	detail:  string,
	elapsed: f64,
}

agent_color :: proc(s: Agent_State) -> u32 {
	switch s {
	case .Working: return cfg.palette[4]
	case .Blocked: return cfg.palette[3]
	case .Done: return cfg.palette[2]
	case .Idle, .None:
	}
	return mix(cfg.fg, cfg.bg, 0.45)
}

collect_agents :: proc() -> []Agent_Row {
	Ctx :: struct {rows: ^[dynamic]Agent_Row, tab: int}
	rows := make([dynamic]Agent_Row, context.temp_allocator)
	for tab, ti in app.tabs {
		ctx := Ctx{&rows, ti}
		for_leaves(tab.root, proc(n: ^Node, data: rawptr) {
			ctx := (^Ctx)(data)
			t := n.term
			sync.mutex_lock(&t.mu)
			defer sync.mutex_unlock(&t.mu)
			if t.agent.name == "" do return
			r := Agent_Row{tab = ctx.tab, node = n, state = agent_state(t), name = strings.clone(t.agent.name, context.temp_allocator)}
			r.detail = strings.clone(t.agent.detail, context.temp_allocator)
			r.folder = filepath.base(strings.clone(t.cwd, context.temp_allocator)) if t.cwd != "" else ""
			r.elapsed = time.duration_seconds(time.tick_since(t.agent.started))
			append(ctx.rows, r)
		}, &ctx)
	}
	return rows[:]
}

agent_sidebar_visible :: proc() -> bool {
	if !app.agents_on do return false
	return cfg.agent_sidebar == "always" || app.agent_count > 0
}

agent_sidebar_w :: proc() -> int {
	return 30 * fonts.cell_w if agent_sidebar_visible() else 0
}

// Per frame/wake: update states, tab dots, sidebar visibility and notifications.
// Returns ms until the next re-check (idle detection needs time to pass), or -1.
agent_tick :: proc() -> i32 {
	rows := collect_agents()
	for tab in app.tabs do tab.agent_state = .None
	urgency := [Agent_State]int{.None = 0, .Done = 1, .Idle = 2, .Working = 3, .Blocked = 4}
	active := 0
	focused_win := sdl.GetKeyboardFocus() == app.window
	for r in rows {
		tab := app.tabs[r.tab]
		if urgency[r.state] > urgency[tab.agent_state] do tab.agent_state = r.state
		if r.state != .Done do active += 1
		t := r.node.term
		prev := t.agent.shown
		if prev == r.state do continue
		t.agent.shown = r.state
		app.redraw = true
		if r.state == .Working do t.agent.work_since = app.now
		seen := focused_win && r.tab == app.cur
		if seen || !cfg.agent_notify do continue
		loc := r.detail if r.detail != "" else r.folder
		if r.state == .Blocked {
			notify(fmt.tprintf("⏸ %s: 入力を待っています", r.name), fmt.tprintf("タブ %d · %s", r.tab + 1, loc))
		} else if prev == .Working && r.state == .Idle && app.now - t.agent.work_since >= 8 {
			notify(fmt.tprintf("✓ %s: 応答が終わりました", r.name), fmt.tprintf("タブ %d · %s", r.tab + 1, loc))
		}
	}
	if len(rows) != app.agent_count {
		was := agent_sidebar_visible()
		app.agent_count = len(rows)
		if agent_sidebar_visible() != was do layout()
		app.redraw = true
	}
	ctl_check_waits(rows)
	return 1000 if active > 0 || len(app.ctl_waits) > 0 else -1
}

draw_agent_sidebar :: proc(w, h: int) {
	sw := f32(agent_sidebar_w())
	if sw <= 0 do return
	top := f32(app.tabbar_h)
	cw := f32(fonts.cell_w)
	uh := f32(fonts.ui_h)
	alpha :: proc(c: u32, a: f32) -> [4]u8 {return rgba(c, u8(clamp(a, 0, 1) * 255))}
	quad(&ren.ov, 0, top, sw, f32(h), alpha(0x000000, 0.22))
	quad(&ren.ov, sw - 1, top, sw, f32(h), alpha(cfg.fg, 0.08))
	rows := collect_agents()
	y := top + 10
	draw_ui_text(&ren.ov, cw, y, fmt.tprintf("エージェント  %d", len(rows)), alpha(cfg.fg, 0.6))
	y += uh + 10
	clear(&app.agent_hits)
	if len(rows) == 0 {
		draw_ui_text(&ren.ov, cw, y, "実行中のエージェントはありません", alpha(cfg.fg, 0.4))
		return
	}
	row_h := uh * 2 + 14
	for r in rows {
		if y + row_h > f32(h) do break
		current := r.tab == app.cur && current_tab().focus == r.node
		hover := app.mouse_px.x < sw && app.mouse_px.y >= y && app.mouse_px.y < y + row_h
		if current || hover do rounded_rect(&ren.ov, 6, y, sw - 8, y + row_h - 4, 8, alpha(cfg.fg, 0.12 if current else 0.07))
		// status dot (working pulses once a second)
		dot := agent_color(r.state)
		da := f32(1)
		if r.state == .Working do da = 0.55 + 0.45 * f32(int(app.now) % 2)
		dr := uh * 0.22
		dx, dy := cw * 1.1, y + 7 + uh / 2
		rounded_rect(&ren.ov, dx - dr, dy - dr, dx + dr, dy + dr, dr, alpha(dot, da))
		label := AGENT_STATE_LABELS[r.state]
		lw := ui_text_width(label)
		draw_ui_text(&ren.ov, sw - lw - cw, y + 7, label, alpha(dot, 0.95))
		draw_ui_text(&ren.ov, cw * 2, y + 7, ui_truncate(r.name, sw - cw * 3 - lw - cw), alpha(cfg.fg, 0.95))
		mins := int(r.elapsed / 60)
		age := fmt.tprintf("%d分", mins) if mins > 0 else fmt.tprintf("%d秒", int(r.elapsed))
		loc := r.detail if r.detail != "" else r.folder
		sub := fmt.tprintf("タブ %d · %s · %s", r.tab + 1, loc, age) if loc != "" else fmt.tprintf("タブ %d · %s", r.tab + 1, age)
		draw_ui_text(&ren.ov, cw * 2, y + 9 + uh, ui_truncate(sub, sw - cw * 3), alpha(cfg.fg, 0.5))
		append(&app.agent_hits, Agent_Hit{y, y + row_h, r.tab, r.node})
		y += row_h
	}
}

Agent_Hit :: struct {
	y0, y1: f32,
	tab:    int,
	node:   ^Node,
}

// Click in the sidebar: jump to that agent's pane.
agent_sidebar_click :: proc(px, py: int) -> bool {
	if f32(px) >= f32(agent_sidebar_w()) || py < app.tabbar_h do return false
	for hit in app.agent_hits {
		if f32(py) >= hit.y0 && f32(py) < hit.y1 && hit.tab < len(app.tabs) && contains_leaf(app.tabs[hit.tab].root, hit.node) {
			switch_tab(hit.tab)
			app.tabs[hit.tab].focus = hit.node
			app.redraw = true
			update_ime_rect()
			break
		}
	}
	return true
}

// ---------- control API: `kuraokami ctl ...` over $KURAOKAMI_SOCKET ----------

Ctl_Req :: struct {
	fd:   i32,
	args: []string,
}

Ctl_Wait :: struct {
	fd:       i32,
	pane:     int,
	want:     Agent_State,
	deadline: f64,
}

ctl_mu: sync.Mutex
ctl_queue: [dynamic]Ctl_Req

// Called on the socket thread: hand the request to the UI thread.
ctl_enqueue :: proc(fd: i32, payload: []u8) {
	args := strings.split(string(payload), "\x00")
	sync.mutex_lock(&ctl_mu)
	append(&ctl_queue, Ctl_Req{fd, args})
	sync.mutex_unlock(&ctl_mu)
	push_wake()
}

find_pane :: proc(id: int) -> (^Node, int) {
	Find :: struct {id: int, n: ^Node}
	for tab, ti in app.tabs {
		f := Find{id, nil}
		for_leaves(tab.root, proc(n: ^Node, data: rawptr) {
			f := (^Find)(data)
			if n.term.pane_id == f.id do f.n = n
		}, &f)
		if f.n != nil do return f.n, ti
	}
	return nil, -1
}

pane_text :: proc(t: ^Term, lines: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	r := screen(t)
	end := r.count - t.rows + t.cy + 1 // up to the cursor line: below it is blank screen
	for i in max(0, end - lines) ..< end {
		line := strings.builder_make(context.temp_allocator)
		for c in ring_line(r, i) {
			if c.wide == 2 do continue
			buf: [4]u8
			strings.write_string(&line, cell_text(t, c.ch, &buf) if c.ch != 0 else " ")
		}
		strings.write_string(&b, strings.trim_right(strings.to_string(line), " "))
		strings.write_byte(&b, '\n')
	}
	return fmt.tprintf("%s\n", strings.trim_right(strings.to_string(b), "\n"))
}

ctl_process :: proc() {
	sync.mutex_lock(&ctl_mu)
	reqs := ctl_queue
	ctl_queue = {}
	sync.mutex_unlock(&ctl_mu)
	defer {for r in reqs do delete(r.args); delete(reqs)}
	for r in reqs {
		reply, keep := ctl_handle(r)
		if keep do continue // `wait`: answered later by ctl_check_waits
		ctl_reply(r.fd, reply)
	}
}

ctl_reply :: proc(fd: i32, s: string) {
	ctl_write(fd, s)
	ctl_close(fd)
}

USAGE_CTL :: `usage: kuraokami ctl <command>
  list                       panes: id, tab, agent state, agent, cwd, title
  state <id>                 agent state of a pane (none|working|blocked|idle|done)
  read <id> [lines]          last lines of a pane's screen (default 40)
  send <id> <text>           type text into a pane
  submit <id> <text>         paste text and press Enter
  new-tab [command...]       open a tab (optionally running a command); prints its id
  focus <id>                 switch to a pane
  wait <id> <state> [secs]   block until the pane reaches a state (default 600 s)
`

ctl_handle :: proc(r: Ctl_Req) -> (string, bool) {
	a := r.args
	if len(a) == 0 || a[0] == "" || a[0] == "help" do return USAGE_CTL, false
	pane :: proc(a: []string) -> (^Node, int, string) {
		if len(a) < 2 do return nil, -1, "error: pane id required\n"
		id, ok := strconv.parse_int(a[1])
		if !ok do return nil, -1, "error: bad pane id\n"
		n, tab := find_pane(id)
		if n == nil do return nil, -1, "error: no such pane\n"
		return n, tab, ""
	}
	switch a[0] {
	case "list":
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "id\ttab\tstate\tagent\tcwd\ttitle\n")
		Ctx :: struct {b: ^strings.Builder, tab: int}
		for tab, ti in app.tabs {
			ctx := Ctx{&b, ti + 1}
			for_leaves(tab.root, proc(n: ^Node, data: rawptr) {
				ctx := (^Ctx)(data)
				t := n.term
				sync.mutex_lock(&t.mu)
				defer sync.mutex_unlock(&t.mu)
				fmt.sbprintf(ctx.b, "%d\t%d\t%s\t%s\t%s\t%s\n", t.pane_id, ctx.tab, AGENT_STATE_NAMES[agent_state(t)], t.agent.name, t.cwd, t.title)
			}, &ctx)
		}
		return strings.to_string(b), false
	case "state":
		n, _, err := pane(a)
		if n == nil do return err, false
		sync.mutex_lock(&n.term.mu)
		s := agent_state(n.term)
		sync.mutex_unlock(&n.term.mu)
		return fmt.tprintf("%s\n", AGENT_STATE_NAMES[s]), false
	case "read":
		n, _, err := pane(a)
		if n == nil do return err, false
		lines := 40
		if len(a) >= 3 {if v, ok := strconv.parse_int(a[2]); ok do lines = clamp(v, 1, 10000)}
		return pane_text(n.term, lines), false
	case "send", "submit":
		n, _, err := pane(a)
		if n == nil do return err, false
		if len(a) < 3 do return "error: text required\n", false
		text := strings.join(a[2:], " ", context.temp_allocator)
		t := n.term
		if a[0] == "submit" {
			// Paste as a paste (so multi-line text stays one message), then press Enter.
			if t.bracketed do pty_write(t, transmute([]u8)fmt.tprintf("\x1b[200~%s\x1b[201~", text))
			else do pty_write(t, transmute([]u8)text)
			pty_write(t, transmute([]u8)string("\r"))
		} else do pty_write(t, transmute([]u8)text)
		agent_user_input(t)
		return "ok\n", false
	case "new-tab":
		cwd := shell_cwd(focused()) if len(app.tabs) > 0 else start_dir()
		argv: []string = a[1:] if len(a) > 1 else nil
		t := new_term(cwd, argv)
		if t == nil do return "error: could not start\n", false
		nn := new(Node)
		nn.term = t
		tab := new(Tab)
		tab.root, tab.focus = nn, nn
		append(&app.tabs, tab)
		switch_tab(len(app.tabs) - 1)
		layout()
		return fmt.tprintf("%d\n", t.pane_id), false
	case "focus":
		n, tab, err := pane(a)
		if n == nil do return err, false
		switch_tab(tab)
		app.tabs[tab].focus = n
		app.redraw = true
		return "ok\n", false
	case "wait":
		n, _, err := pane(a)
		if n == nil do return err, false
		if len(a) < 3 do return "error: state required\n", false
		want := Agent_State.None
		for s in Agent_State do if AGENT_STATE_NAMES[s] == a[2] do want = s
		if want == .None do return "error: state must be working|blocked|idle|done\n", false
		secs := 600.0
		if len(a) >= 4 {if v, ok := strconv.parse_f64(a[3]); ok do secs = clamp(v, 0, 86400)}
		append(&app.ctl_waits, Ctl_Wait{r.fd, n.term.pane_id, want, app.now + secs})
		return "", true
	}
	return fmt.tprintf("error: unknown command %q\n%s", a[0], USAGE_CTL), false
}

ctl_check_waits :: proc(rows: []Agent_Row) {
	for i := len(app.ctl_waits) - 1; i >= 0; i -= 1 {
		w := app.ctl_waits[i]
		n, _ := find_pane(w.pane)
		state := Agent_State.None
		if n != nil do for r in rows do if r.node == n do state = r.state
		switch {
		case n == nil: ctl_reply(w.fd, "error: pane closed\n")
		case state == w.want: ctl_reply(w.fd, fmt.tprintf("%s\n", AGENT_STATE_NAMES[state]))
		case app.now > w.deadline: ctl_reply(w.fd, fmt.tprintf("error: timeout (state %s)\n", AGENT_STATE_NAMES[state]))
		case: continue
		}
		unordered_remove(&app.ctl_waits, i)
	}
}
