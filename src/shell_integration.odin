package kuraokami

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Shell scripts are embedded in the binary and written to the data dir at startup.
ZSH_ENV :: #load("../shell/zshenv", string)
ZSH_INTEG :: #load("../shell/kuraokami.zsh", string)
BASH_INTEG :: #load("../shell/kuraokami.bash", string)

integration_dir :: proc() -> string {
	when ODIN_OS == .Windows do return ""
	else {
		if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" do return fmt.tprintf("%s/kuraokami/shell", x)
		return fmt.tprintf("%s/.local/share/kuraokami/shell", home_dir())
	}
}

integration_ready: bool

// Writes the scripts (only when changed). Integration is disabled if this fails.
install_shell_integration :: proc() {
	dir := integration_dir()
	if dir == "" || !cfg.shell_integration do return
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist do return // Exist = already there
	files := [?][2]string{{".zshenv", ZSH_ENV}, {"kuraokami.zsh", ZSH_INTEG}, {"kuraokami.bash", BASH_INTEG}}
	for f in files {
		path := fmt.tprintf("%s/%s", dir, f[0])
		if old, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil && string(old) == f[1] do continue
		if os.write_entire_file(path, transmute([]u8)f[1]) != nil do return
	}
	integration_ready = true
}

// Adds shell integration for zsh/bash: zsh via ZDOTDIR injection, bash via --rcfile.
integrate :: proc(argv: []string) -> ([]string, [][2]string) {
	if !integration_ready || len(argv) == 0 do return argv, nil
	env := make([dynamic][2]string, context.temp_allocator)
	dir := integration_dir()
	append(&env, [2]string{"KURAOKAMI_SHELL_PRESET", "1" if cfg.shell_preset else "0"})
	append(&env, [2]string{"KURAOKAMI_SHELL_DIR", dir})
	switch filepath.base(argv[0]) {
	case "zsh":
		if orig, ok := os.lookup_env("ZDOTDIR", context.temp_allocator); ok do append(&env, [2]string{"KURAOKAMI_ORIG_ZDOTDIR", orig})
		append(&env, [2]string{"ZDOTDIR", dir})
		return argv, env[:]
	case "bash":
		if len(argv) == 1 { // only plain interactive bash; explicit args are left alone
			out := make([]string, 3, context.temp_allocator)
			out[0], out[1], out[2] = argv[0], "--rcfile", fmt.tprintf("%s/kuraokami.bash", dir)
			return out, env[:]
		}
	}
	return argv, nil
}

@(private) _keep_strings :: strings.Builder
