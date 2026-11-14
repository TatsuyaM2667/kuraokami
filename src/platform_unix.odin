#+build linux, darwin
package kuraokami

import "core:c"
import "core:c/libc"
import "core:sys/posix"
import "core:fmt"
import "core:strings"

when ODIN_OS == .Darwin {
	foreign import libc_ "system:System"
	TIOCSWINSZ :: 0x80087467
} else {
	foreign import libc_ "system:c"
	TIOCSWINSZ :: 0x5414
}

@(default_calling_convention = "c")
foreign libc_ {
	forkpty :: proc(amaster: ^c.int, name: cstring, termp: rawptr, winp: rawptr) -> c.int ---
	ioctl :: proc(fd: c.int, req: c.ulong, #c_vararg args: ..any) -> c.int ---
	execvp :: proc(file: cstring, argv: [^]cstring) -> c.int ---
	setenv :: proc(name, value: cstring, overwrite: c.int) -> c.int ---
	unsetenv :: proc(name: cstring) -> c.int ---
	chdir :: proc(path: cstring) -> c.int ---
	_exit :: proc(code: c.int) -> ! ---
	read :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	write :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	close :: proc(fd: c.int) -> c.int ---
	kill :: proc(pid: c.int, sig: c.int) -> c.int ---
	unlink :: proc(path: cstring) -> c.int ---
	readlink :: proc(path: cstring, buf: [^]u8, n: c.size_t) -> c.ssize_t ---
	fork :: proc() -> c.int ---
}

Winsize :: struct {
	row, col, xpixel, ypixel: u16,
}

Pty :: struct {
	fd:  i32,
	pid: i32,
}

platform_init :: proc() {
	libc.setlocale(.ALL, "") // xkb compose / dead keys need the user's locale
	posix.signal(.SIGCHLD, auto_cast posix.SIG_IGN) // auto-reap shells and helpers
}

pty_spawn :: proc(t: ^Term, cwd: string, argv_s: []string) -> bool {
	ws := Winsize{u16(t.rows), u16(t.cols), u16(t.cols * t.cell_w), u16(t.rows * t.cell_h)}
	// Everything the child needs is prepared before fork (no allocation after fork).
	argv: [64]cstring
	n := 0
	for part in argv_s {
		if n >= len(argv) - 1 do break
		argv[n] = strings.clone_to_cstring(part, context.temp_allocator)
		n += 1
	}
	if n == 0 do return false
	cwd_c := strings.clone_to_cstring(cwd, context.temp_allocator) if cwd != "" else nil
	fd: c.int
	pid := forkpty(&fd, nil, nil, &ws)
	if pid < 0 do return false
	if pid == 0 {
		posix.signal(.SIGCHLD, auto_cast posix.SIG_DFL) // shells need default SIGCHLD for job control
		setenv("TERM", "xterm-256color", 1)
		setenv("COLORTERM", "truecolor", 1)
		setenv("TERM_PROGRAM", "kuraokami", 1)
		setenv("TERM_PROGRAM_VERSION", VERSION, 1)
		unsetenv("TERMINFO")
		if cwd_c != nil do chdir(cwd_c)
		execvp(argv[0], &argv[0])
		_exit(127)
	}
	t.pty = {fd, pid}
	return true
}

pty_read :: proc(t: ^Term, buf: []u8) -> int {
	return int(read(t.pty.fd, raw_data(buf), uint(len(buf))))
}

pty_resize :: proc(t: ^Term) {
	ws := Winsize{u16(t.rows), u16(t.cols), u16(t.cols * t.cell_w), u16(t.rows * t.cell_h)}
	ioctl(t.pty.fd, TIOCSWINSZ, &ws)
}

pty_write :: proc(t: ^Term, data: []u8) {
	d := data
	for len(d) > 0 {
		n := write(t.pty.fd, raw_data(d), uint(len(d)))
		if n <= 0 do return
		d = d[n:]
	}
}

pty_close :: proc(t: ^Term) {
	if !t.exited do kill(t.pty.pid, 1) // exited pids are auto-reaped and may be reused
	close(t.pty.fd)
}

// Current directory of the shell (fallback when OSC 7 is not emitted).
pty_cwd :: proc(t: ^Term) -> string {
	when ODIN_OS == .Linux {
		buf: [4096]u8
		link := fmt.ctprintf("/proc/%d/cwd", t.pty.pid)
		n := readlink(link, &buf[0], len(buf))
		if n > 0 do return strings.clone(string(buf[:n]), context.temp_allocator)
	}
	return ""
}

// Fire-and-forget helper process (notify-send, xdg-open).
spawn_detached :: proc(args: []string) {
	argv: [16]cstring
	for a, i in args[:min(len(args), 15)] do argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	if fork() == 0 {
		execvp(argv[0], &argv[0])
		_exit(127)
	}
}

notify :: proc(title, body: string) {
	when ODIN_OS == .Darwin {
		esc :: proc(s: string) -> string {r, _ := strings.replace_all(s, "\"", "\\\"", context.temp_allocator); return r}
		spawn_detached({"osascript", "-e", fmt.tprintf("display notification \"%s\" with title \"%s\"", esc(body), esc(title))})
	} else {
		spawn_detached({"notify-send", "--", title, body})
	}
}

shm_read :: proc(name: string, size: int) -> ([]u8, bool) {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	when ODIN_OS == .Darwin do fd := posix.shm_open(cname, {})
	else do fd := posix.shm_open(cname, {}, {})
	if fd < 0 do return nil, false
	ptr := posix.mmap(nil, uint(size), {.READ}, {.SHARED}, fd, 0)
	close(i32(fd))
	posix.shm_unlink(cname)
	if ptr == posix.MAP_FAILED do return nil, false
	out := make([]u8, size)
	copy(out, ([^]u8)(ptr)[:size])
	posix.munmap(ptr, uint(size))
	return out, true
}

remove_file :: proc(path: string) {
	unlink(strings.clone_to_cstring(path, context.temp_allocator))
}

