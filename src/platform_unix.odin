#+build linux, darwin, freebsd, openbsd, netbsd
package kuraokami

import "core:c"
import "core:c/libc"
import "core:sys/posix"
import "core:os"
import "core:thread"
import "core:fmt"
import "core:strings"

when ODIN_OS == .Darwin {
	foreign import libc_ "system:System"
	TIOCSWINSZ :: 0x80087467
} else when ODIN_OS == .Linux {
	foreign import libc_ "system:c"
	TIOCSWINSZ :: 0x5414
} else {
	// BSDs: forkpty lives in libutil; ioctl numbers follow the BSD encoding.
	foreign import libc_ {"system:c", "system:util"}
	TIOCSWINSZ :: 0x80087467
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

pty_spawn :: proc(t: ^Term, cwd: string, argv_s: []string, env: [][2]string = nil) -> bool {
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
	env_c := make([][2]cstring, len(env), context.temp_allocator)
	for e, i in env do env_c[i] = {strings.clone_to_cstring(e[0], context.temp_allocator), strings.clone_to_cstring(e[1], context.temp_allocator)}
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
		for e in env_c do setenv(e[0], e[1], 1)
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

// Blocking write; only the per-pane writer thread calls this (see pty_queue.odin).
pty_write_raw :: proc(t: ^Term, data: []u8) -> bool {
	d := data
	for len(d) > 0 {
		n := write(t.pty.fd, raw_data(d), uint(len(d)))
		if n <= 0 do return false
		d = d[n:]
	}
	return true
}

// Called once every thread is done with the Term: only then may the fd number be reused.
pty_free :: proc(t: ^Term) {
	close(t.pty.fd)
}

// Hang up the session (shell + foreground job). The fd stays open until pty_free so that the
// reader/writer threads can never touch a reused fd number.
pty_close :: proc(t: ^Term) {
	if t.exited do return // exited pids are auto-reaped and may be reused
	fg := posix.tcgetpgrp(posix.FD(t.pty.fd))
	if fg > 0 && i32(fg) != t.pty.pid do kill(-i32(fg), 1)
	kill(t.pty.pid, 1)
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
	// Mapping past the end of the object would SIGBUS the whole terminal: trust only its real size.
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || int(st.st_size) < size || !posix.S_ISREG(st.st_mode) {
		close(i32(fd))
		return nil, false
	}
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


// ---------- quick terminal IPC (unix socket in XDG_RUNTIME_DIR) ----------

quick_socket_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" do return fmt.tprintf("/tmp/kuraokami-quick-%d.sock", posix.getuid())
	return fmt.tprintf("%s/kuraokami-quick.sock", dir)
}

quick_addr :: proc() -> (addr: posix.sockaddr_un, ok: bool) {
	p := quick_socket_path()
	if len(p) >= len(addr.sun_path) do return addr, false
	addr.sun_family = .UNIX
	for i in 0 ..< len(p) do addr.sun_path[i] = c.char(p[i])
	return addr, true
}

// Ask a running quick terminal to toggle. Returns false if none is running.
quick_send_toggle :: proc() -> bool {
	addr, ok := quick_addr()
	if !ok do return false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK do return false
	msg := "toggle\n"
	write(i32(fd), raw_data(msg), uint(len(msg)))
	return true
}

// Become the quick terminal: accept toggle requests in a background thread.
quick_listen :: proc(on_toggle: proc()) -> bool {
	addr, ok := quick_addr()
	if !ok do return false
	_ = posix.unlink(strings.clone_to_cstring(quick_socket_path(), context.temp_allocator)) // stale socket from a crash
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 4) != .OK {
		posix.close(fd)
		return false
	}
	thread.create_and_start_with_poly_data2(fd, on_toggle, proc(fd: posix.FD, on_toggle: proc()) {
		for {
			c := posix.accept(fd, nil, nil)
			if c < 0 do continue
			buf: [16]u8
			n := read(i32(c), &buf[0], len(buf))
			posix.close(c)
			if n > 0 do on_toggle()
		}
	}, self_cleanup = true)
	return true
}

quick_cleanup :: proc() {
	_ = posix.unlink(strings.clone_to_cstring(quick_socket_path(), context.temp_allocator))
}

// Run a helper (no shell) and return its stdout, at most `limit` bytes. Used for ffmpeg.
run_capture :: proc(args: []string, limit: int) -> ([]u8, bool) {
	if len(args) == 0 do return nil, false
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args do argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return nil, false
	pid := fork()
	if pid < 0 {posix.close(fds[0]); posix.close(fds[1]); return nil, false}
	if pid == 0 {
		posix.dup2(fds[1], 1)
		posix.close(fds[0])
		posix.close(fds[1])
		execvp(argv[0], raw_data(argv))
		_exit(127)
	}
	posix.close(fds[1])
	defer posix.close(fds[0])
	out := make([dynamic]u8)
	buf: [65536]u8
	for {
		n := read(i32(fds[0]), &buf[0], len(buf))
		if n <= 0 do break
		if len(out) + int(n) > limit {kill(pid, 9); delete(out); return nil, false}
		append(&out, ..buf[:n])
	}
	return out[:], len(out) > 0
}
