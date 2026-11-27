package kuraokami

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Config :: struct {
	font_family:        string,
	font_size:          f32,
	ligatures:          bool,
	fg, bg, cursor:     u32,
	selection_bg:       u32,
	selection_fg:       u32, // NO_COLOR = keep text color
	opacity_cells:      bool, // translucent colored cell backgrounds too (like ghostty background-opacity-cells)
	palette:            [16]u32,
	opacity:            f32,
	scrollback:         int,
	shell:              string,
	padding:            int,
	copy_on_select:     bool,
	cursor_style:       int,
	// animation
	animation:          bool,
	cursor_blink:       bool,
	cursor_trail:       bool,
	smooth_scroll:      bool,
	visual_bell:        bool,
	custom_shader:      string,
	shader_animation:   bool,
	// startup
	startup_fetch:      bool,
	shell_integration:  bool,
	shell_preset:       bool,
	clipboard_write:    bool,
	paste_protection:   bool,
	notify_after:       f64, // seconds; 0 = off
	restore_session:    bool,
	quick_autohide:     bool,
	click_to_move:      bool,
	renderer:           string, // "" auto | "gles"
	tab_bar:            string, // always | auto | never
	agent_commands: string, // command names treated as AI agents
	agent_sidebar:  string, // auto | always | never
	agent_notify:   bool,
	ui_font:            string, // proportional font for the tab bar
	ui_font_scale:      f32,
	working_dir:        string, // home | inherit | <path>
	fetch_logo:         string,
	fetch_logo_size:    [2]int, // cells (width, height) for image logos
	fetch_logo_seconds: f64, // how long an animated logo plays; 0 = forever
	fetch_command:      string,
	binds:              [dynamic]Keybind,
}

NO_COLOR :: u32(0xFFFFFFFF)

// Default look: deep navy glass (matches the ame-shell Ghostty setup).
DEFAULT_PALETTE := [16]u32 {
	0x45475a,
	0xf38ba8,
	0xa6e3a1,
	0xf9e2af,
	0x89b4fa,
	0xf5c2e7,
	0x7fdceb,
	0xbac2de,
	0x585b70,
	0xf38ba8,
	0xa6e3a1,
	0xf9e2af,
	0x89b4fa,
	0xf5c2e7,
	0x94e2d5,
	0xa6adc8,
}

cfg: Config
config_mtime: time.Time

config_defaults :: proc() {
	delete(cfg.binds)
	cfg = Config {
		font_family        = "JetBrains Mono, JetBrainsMono Nerd Font Mono, JetBrainsMono Nerd Font, monospace",
		font_size          = 12,
		ligatures          = true,
		fg                 = 0xcdd6f4,
		bg                 = 0x060913,
		cursor             = 0xcdd6f4,
		selection_bg       = 0x89b4fa,
		selection_fg       = 0x060913,
		opacity_cells      = true,
		cursor_style       = 6,
		palette            = DEFAULT_PALETTE,
		opacity            = 0.7,
		scrollback         = 10000,
		padding            = 24,
		copy_on_select     = true,
		animation          = true,
		cursor_blink       = true,
		cursor_trail       = true,
		smooth_scroll      = true,
		visual_bell        = true,
		shader_animation   = true,
		startup_fetch      = true,
		shell_integration  = true,
		shell_preset       = true,
		clipboard_write    = true,
		paste_protection   = true,
		notify_after       = 10,
		restore_session    = false,
		quick_autohide     = true,
		click_to_move      = true,
		tab_bar            = "always",
		agent_commands = "claude, opencode, agy, antigravity, codex, gemini, aider, cursor-agent, goose, amp, crush, qwen, kimi",
		agent_sidebar = "auto",
		agent_notify = true,
		ui_font            = "Noto Sans CJK JP, Noto Sans, Inter, Cantarell, DejaVu Sans, sans-serif",
		ui_font_scale      = 0.9,
		fetch_logo_size    = {30, 14},
		fetch_logo_seconds = 30,
		fetch_command      = "fastfetch",
	}
	binds_defaults()
}

home_dir :: proc() -> string {
	when ODIN_OS == .Windows do return os.get_env("USERPROFILE", context.temp_allocator)
	else do return os.get_env("HOME", context.temp_allocator)
}

config_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		return fmt.tprintf("%s/kuraokami", os.get_env("APPDATA", context.temp_allocator))
	} else {
		if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" do return fmt.tprintf("%s/kuraokami", x)
		return fmt.tprintf("%s/.config/kuraokami", home_dir())
	}
}

config_path :: proc() -> string {return fmt.tprintf("%s/config", config_dir())}

config_file_mtime :: proc() -> time.Time {
	fi, err := os.stat(config_path(), context.temp_allocator)
	if err != nil do return {}
	return fi.modification_time
}

col :: proc(v: string) -> (u32, bool) {
	return parse_color_spec(
		v if strings.has_prefix(v, "#") || strings.has_prefix(v, "rgb:") else strings.concatenate({"#", v}, context.temp_allocator),
	)
}

set_col :: proc(dst: ^u32, v: string) -> bool {
	c, ok := col(v)
	if ok do dst^ = c
	return ok
}

parse_bool :: proc(v: string) -> bool {return v == "true" || v == "yes" || v == "on" || v == "1"}

// Applies `key = value` lines. Returns a list of problems for the user.
config_apply_text :: proc(text: string, errs: ^[dynamic]string, allow_theme := true) {
	for line, ln in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 {append(errs, fmt.tprintf("line %d: expected key = value", ln + 1)); continue}
		k, v := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		bad := false
		switch k {
		case "font-family":
			cfg.font_family = strings.clone(v)
		case "font-size":
			if f, ok := strconv.parse_f32(v); ok && f >= 4 && f <= 200 do cfg.font_size = f
			else do bad = true
		case "font-ligatures":
			cfg.ligatures = parse_bool(v)
		case "foreground":
			bad = !set_col(&cfg.fg, v)
		case "background":
			bad = !set_col(&cfg.bg, v)
		case "cursor-color":
			bad = !set_col(&cfg.cursor, v)
		case "selection-background":
			bad = !set_col(&cfg.selection_bg, v)
		case "selection-foreground":
			if v == "none" do cfg.selection_fg = NO_COLOR
			else do bad = !set_col(&cfg.selection_fg, v)
		case "background-opacity-cells":
			cfg.opacity_cells = parse_bool(v)
		case "background-opacity":
			if f, ok := strconv.parse_f32(v); ok do cfg.opacity = clamp(f, 0, 1)
		case "scrollback-limit":
			if n, ok := strconv.parse_int(v); ok do cfg.scrollback = clamp(n, 0, 1_000_000)
		case "command", "shell":
			cfg.shell = strings.clone(v)
		case "window-padding":
			if n, ok := strconv.parse_int(v); ok do cfg.padding = clamp(n, 0, 200)
		case "copy-on-select":
			cfg.copy_on_select = parse_bool(v)
		case "cursor-style":
			switch v {
			case "block":
				cfg.cursor_style = 2
			case "underline":
				cfg.cursor_style = 4
			case "bar":
				cfg.cursor_style = 6
			case:
				bad = true
			}
		case "palette":
			e := strings.index_byte(v, '=')
			bad = true
			if e > 0 {
				if n, ok := strconv.parse_int(strings.trim_space(v[:e])); ok && n >= 0 && n < 16 {
					bad = !set_col(&cfg.palette[n], strings.trim_space(v[e + 1:]))
				}
			}
		case "theme":
			if !allow_theme {bad = true; break}
			src, ok := theme_source(v)
			if ok do cfg.selection_fg = NO_COLOR // themes without selection-foreground keep the text color
			if !ok {append(errs, fmt.tprintf("unknown theme %q", v)); continue}
			config_apply_text(src, errs, false)
		case "animation":
			cfg.animation = parse_bool(v)
		case "cursor-blink":
			cfg.cursor_blink = parse_bool(v)
		case "cursor-trail":
			cfg.cursor_trail = parse_bool(v)
		case "smooth-scroll":
			cfg.smooth_scroll = parse_bool(v)
		case "visual-bell":
			cfg.visual_bell = parse_bool(v)
		case "custom-shader":
			cfg.custom_shader = strings.clone(v)
		case "custom-shader-animation":
			cfg.shader_animation = parse_bool(v)
		case "startup-fetch":
			cfg.startup_fetch = parse_bool(v)
		case "shell-integration":
			cfg.shell_integration = parse_bool(v)
		case "shell-preset":
			cfg.shell_preset = parse_bool(v)
		case "clipboard-write":
			cfg.clipboard_write = v == "allow" || parse_bool(v)
		case "clipboard-paste-protection":
			cfg.paste_protection = parse_bool(v)
		case "restore-session":
			cfg.restore_session = parse_bool(v)
		case "quick-terminal-autohide":
			cfg.quick_autohide = parse_bool(v)
		case "cursor-click-to-move":
			cfg.click_to_move = parse_bool(v)
		case "working-directory":
			cfg.working_dir = strings.clone(v)
		case "ui-font":
			cfg.ui_font = strings.clone(v)
		case "ui-font-scale":
			if f, ok := strconv.parse_f32(v); ok && f >= 0.5 && f <= 2 do cfg.ui_font_scale = f
			else do bad = true
		case "agent-commands": cfg.agent_commands = strings.clone(v)
		case "agent-notify": cfg.agent_notify = parse_bool(v)
		case "agent-sidebar":
			if v == "auto" || v == "always" || v == "never" do cfg.agent_sidebar = strings.clone(v)
			else do bad = true
		case "tab-bar":
			if v == "always" || v == "auto" || v == "never" do cfg.tab_bar = strings.clone(v)
			else do bad = true
		case "renderer":
			if v == "auto" || v == "gl" do cfg.renderer = ""
			else if v == "gles" do cfg.renderer = "gles"
			else do bad = true
		case "fetch-logo":
			cfg.fetch_logo = strings.clone(v)
		case "fetch-logo-size":
			bad = true
			if x := strings.index_any(v, "xX*"); x > 0 {
				w, ok1 := strconv.parse_int(strings.trim_space(v[:x]))
				h, ok2 := strconv.parse_int(strings.trim_space(v[x + 1:]))
				if ok1 &&
				   ok2 &&
				   w >= 4 &&
				   h >= 2 &&
				   w <= 200 &&
				   h <= 100 {cfg.fetch_logo_size = {w, h}; bad = false}
			}
		case "fetch-logo-animate-seconds":
			if f, ok := strconv.parse_f64(v); ok && f >= 0 do cfg.fetch_logo_seconds = f
			else do bad = true
		case "notify-on-command-finish-after":
			if f, ok := strconv.parse_f64(v); ok && f >= 0 do cfg.notify_after = f
			else do bad = true
		case "fetch-command":
			cfg.fetch_command = strings.clone(v)
		case "keybind":
			if v == "clear" do clear(&cfg.binds)
			else if !bind_add(v) do bad = true
		case:
			append(errs, fmt.tprintf("unknown key %q", k)); continue
		}
		if bad do append(errs, fmt.tprintf("bad value for %s: %q", k, v))
	}
}

// Resets to defaults and reads the config file. Returns problems found (temp-allocated).
config_load :: proc() -> []string {
	config_defaults()
	errs := make([dynamic]string, context.temp_allocator)
	config_mtime = config_file_mtime()
	data, err := os.read_entire_file_from_path(config_path(), context.temp_allocator)
	if err == nil do config_apply_text(string(data), &errs)
	return errs[:]
}

theme_source :: proc(name: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/themes/%s", config_dir(), name),
		context.temp_allocator,
	)
	if err == nil do return string(data), true
	for th in BUILTIN_THEMES do if th.name == name do return th.src, true
	return "", false
}

Theme :: struct {
	name, src: string,
}

BUILTIN_THEMES := [?]Theme {
	{
		"kuraokami",
		`background = #060913
foreground = #cdd6f4
cursor-color = #cdd6f4
selection-background = #89b4fa
selection-foreground = #060913
palette = 0=#45475a
palette = 1=#f38ba8
palette = 2=#a6e3a1
palette = 3=#f9e2af
palette = 4=#89b4fa
palette = 5=#f5c2e7
palette = 6=#7fdceb
palette = 7=#bac2de
palette = 8=#585b70
palette = 9=#f38ba8
palette = 10=#a6e3a1
palette = 11=#f9e2af
palette = 12=#89b4fa
palette = 13=#f5c2e7
palette = 14=#94e2d5
palette = 15=#a6adc8`,
	},
	{
		"tokyonight",
		`background = #1a1b26
foreground = #c0caf5
cursor-color = #c0caf5
selection-background = #283457
palette = 0=#15161e
palette = 1=#f7768e
palette = 2=#9ece6a
palette = 3=#e0af68
palette = 4=#7aa2f7
palette = 5=#bb9af7
palette = 6=#7dcfff
palette = 7=#a9b1d6
palette = 8=#414868
palette = 9=#f7768e
palette = 10=#9ece6a
palette = 11=#e0af68
palette = 12=#7aa2f7
palette = 13=#bb9af7
palette = 14=#7dcfff
palette = 15=#c0caf5`,
	},
	{
		"catppuccin-mocha",
		`background = #1e1e2e
foreground = #cdd6f4
cursor-color = #f5e0dc
selection-background = #585b70
palette = 0=#45475a
palette = 1=#f38ba8
palette = 2=#a6e3a1
palette = 3=#f9e2af
palette = 4=#89b4fa
palette = 5=#f5c2e7
palette = 6=#94e2d5
palette = 7=#bac2de
palette = 8=#585b70
palette = 9=#f38ba8
palette = 10=#a6e3a1
palette = 11=#f9e2af
palette = 12=#89b4fa
palette = 13=#f5c2e7
palette = 14=#94e2d5
palette = 15=#a6adc8`,
	},
	{
		"dracula",
		`background = #282a36
foreground = #f8f8f2
cursor-color = #f8f8f2
selection-background = #44475a
palette = 0=#21222c
palette = 1=#ff5555
palette = 2=#50fa7b
palette = 3=#f1fa8c
palette = 4=#bd93f9
palette = 5=#ff79c6
palette = 6=#8be9fd
palette = 7=#f8f8f2
palette = 8=#6272a4
palette = 9=#ff6e6e
palette = 10=#69ff94
palette = 11=#ffffa5
palette = 12=#d6acff
palette = 13=#ff92df
palette = 14=#a4ffff
palette = 15=#ffffff`,
	},
	{
		"gruvbox-dark",
		`background = #282828
foreground = #ebdbb2
cursor-color = #ebdbb2
selection-background = #504945
palette = 0=#282828
palette = 1=#cc241d
palette = 2=#98971a
palette = 3=#d79921
palette = 4=#458588
palette = 5=#b16286
palette = 6=#689d6a
palette = 7=#a89984
palette = 8=#928374
palette = 9=#fb4934
palette = 10=#b8bb26
palette = 11=#fabd2f
palette = 12=#83a598
palette = 13=#d3869b
palette = 14=#8ec07c
palette = 15=#ebdbb2`,
	},
	{
		"nord",
		`background = #2e3440
foreground = #d8dee9
cursor-color = #d8dee9
selection-background = #434c5e
palette = 0=#3b4252
palette = 1=#bf616a
palette = 2=#a3be8c
palette = 3=#ebcb8b
palette = 4=#81a1c1
palette = 5=#b48ead
palette = 6=#88c0d0
palette = 7=#e5e9f0
palette = 8=#4c566a
palette = 9=#bf616a
palette = 10=#a3be8c
palette = 11=#ebcb8b
palette = 12=#81a1c1
palette = 13=#b48ead
palette = 14=#8fbcbb
palette = 15=#eceff4`,
	},
	{
		"solarized-dark",
		`background = #002b36
foreground = #839496
cursor-color = #93a1a1
selection-background = #073642
palette = 0=#073642
palette = 1=#dc322f
palette = 2=#859900
palette = 3=#b58900
palette = 4=#268bd2
palette = 5=#d33682
palette = 6=#2aa198
palette = 7=#eee8d5
palette = 8=#002b36
palette = 9=#cb4b16
palette = 10=#586e75
palette = 11=#657b83
palette = 12=#839496
palette = 13=#6c71c4
palette = 14=#93a1a1
palette = 15=#fdf6e3`,
	},
}
