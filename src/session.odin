package kuraokami

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Session restore: closing the window saves tabs, splits, ratios and each pane's cwd;
// the next launch rebuilds them. Exiting every shell yourself starts fresh next time.
// shortcut: scrollback contents are not saved (only layout + directories).

session_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return fmt.tprintf("%s/session", config_dir())
	} else {
		if x := os.get_env("XDG_STATE_HOME", context.temp_allocator); x != "" do return fmt.tprintf("%s/kuraokami/session", x)
		return fmt.tprintf("%s/.local/state/kuraokami/session", home_dir())
	}
}

collect_leaves :: proc(n: ^Node, out: ^[dynamic]^Node) {
	if n.term != nil {append(out, n); return}
	collect_leaves(n.a, out)
	collect_leaves(n.b, out)
}

session_save :: proc() {
	if len(app.tabs) == 0 do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "kuraokami-session 1\nfont %v\nactive %d\n", app.font_pt, app.cur)
	write_node :: proc(b: ^strings.Builder, n: ^Node) {
		if n.term != nil {
			cwd := shell_cwd(n.term)
			cwd, _ = strings.replace_all(cwd, "\n", "", context.temp_allocator)
			fmt.sbprintf(b, "leaf %s\n", cwd)
			return
		}
		fmt.sbprintf(b, "split %s %v\n", "v" if n.vertical else "h", n.ratio)
		write_node(b, n.a)
		write_node(b, n.b)
	}
	for tab in app.tabs {
		leaves := make([dynamic]^Node, context.temp_allocator)
		collect_leaves(tab.root, &leaves)
		focus := 0
		for l, i in leaves do if l == tab.focus do focus = i
		fmt.sbprintf(&b, "tab %d\n", focus)
		write_node(&b, tab.root)
	}
	path := session_path()
	_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

session_forget :: proc() {_ = os.remove(session_path())}

// Rebuilds tabs from the saved session. Returns false (and creates nothing) if there is none.
session_restore :: proc() -> bool {
	data, err := os.read_entire_file_from_path(session_path(), context.temp_allocator)
	if err != nil do return false
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	if len(lines) == 0 || lines[0] != "kuraokami-session 1" do return false
	active := 0
	i := 1
	parse_node :: proc(lines: []string, i: ^int) -> ^Node {
		if i^ >= len(lines) do return nil
		line := lines[i^]
		i^ += 1
		if strings.has_prefix(line, "leaf ") || line == "leaf" {
			cwd := strings.trim_space(line[min(5, len(line)):])
			if cwd != "" && !os.is_dir(cwd) do cwd = "" // directory gone since last time
			t := new_term(cwd)
			if t == nil do return nil
			n := new(Node)
			n.term = t
			return n
		}
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 3 || f[0] != "split" do return nil
		ratio, _ := strconv.parse_f32(f[2])
		a := parse_node(lines, i)
		b := parse_node(lines, i)
		if a == nil do return b
		if b == nil do return a
		n := new(Node)
		n.vertical, n.ratio, n.a, n.b = f[1] == "v", clamp(ratio, 0.1, 0.9), a, b
		a.parent, b.parent = n, n
		return n
	}
	for i < len(lines) {
		f := strings.fields(lines[i], context.temp_allocator)
		i += 1
		if len(f) != 2 do continue
		switch f[0] {
		case "font":
			if pt, ok := strconv.parse_f32(f[1]); ok && pt >= 4 && pt <= 200 && pt != app.font_pt do set_font_size(pt)
		case "active":
			active, _ = strconv.parse_int(f[1])
		case "tab":
			focus, _ := strconv.parse_int(f[1])
			root := parse_node(lines, &i)
			if root == nil do continue
			leaves := make([dynamic]^Node, context.temp_allocator)
			collect_leaves(root, &leaves)
			tab := new(Tab)
			tab.root, tab.focus = root, leaves[clamp(focus, 0, len(leaves) - 1)]
			append(&app.tabs, tab)
		}
	}
	if len(app.tabs) == 0 do return false
	app.cur = clamp(active, 0, len(app.tabs) - 1)
	layout()
	return true
}
