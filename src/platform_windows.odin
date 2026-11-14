#+build windows
package kuraokami

import "core:strings"
import "core:unicode/utf16"
import "core:os"
import win "core:sys/windows"

// ConPTY entry points (not in core:sys/windows).
HPCON :: distinct rawptr
foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	CreatePseudoConsole :: proc(size: win.COORD, hInput, hOutput: win.HANDLE, flags: win.DWORD, phPC: ^HPCON) -> win.HRESULT ---
	ResizePseudoConsole :: proc(hPC: HPCON, size: win.COORD) -> win.HRESULT ---
	ClosePseudoConsole :: proc(hPC: HPCON) ---
	InitializeProcThreadAttributeList :: proc(list: rawptr, count: win.DWORD, flags: win.DWORD, size: ^uint) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: win.DWORD, attr: uint, value: rawptr, size: uint, prev: rawptr, ret: ^uint) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
}
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

Pty :: struct {
	hpc:      HPCON,
	in_w:     win.HANDLE, // we write keystrokes here
	out_r:    win.HANDLE, // we read output here
	process:  win.HANDLE,
	pid:      i32,
	attrs:    []u8,
}

platform_init :: proc() {}

wide :: proc(s: string) -> cstring16 {
	return cstring16(raw_data(utf16_encode(s)))
}

utf16_encode :: proc(s: string) -> []u16 {
	buf := make([]u16, len(s) * 2 + 1, context.temp_allocator)
	n := utf16.encode_string(buf, s)
	buf[n] = 0
	return buf[:n + 1]
}

pty_spawn :: proc(t: ^Term, cwd: string, argv: []string, env: [][2]string = nil) -> bool {
	in_r, in_w, out_r, out_w: win.HANDLE
	if !win.CreatePipe(&in_r, &in_w, nil, 0) do return false
	if !win.CreatePipe(&out_r, &out_w, nil, 0) do return false
	hpc: HPCON
	if CreatePseudoConsole({i16(t.cols), i16(t.rows)}, in_r, out_w, 0, &hpc) < 0 do return false
	win.CloseHandle(in_r)
	win.CloseHandle(out_w)
	size: uint
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	attrs := make([]u8, size)
	if !InitializeProcThreadAttributeList(raw_data(attrs), 1, 0, &size) do return false
	if !UpdateProcThreadAttribute(raw_data(attrs), 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, rawptr(hpc), size_of(HPCON), nil, nil) do return false
	si: STARTUPINFOEXW
	si.StartupInfo.cb = size_of(STARTUPINFOEXW)
	si.lpAttributeList = raw_data(attrs)
	cmd := strings.join(argv, " ", context.temp_allocator)
	pi: win.PROCESS_INFORMATION
	os.set_env("TERM", "xterm-256color")
	os.set_env("COLORTERM", "truecolor")
	os.set_env("TERM_PROGRAM", "kuraokami")
	dir := wide(cwd) if cwd != "" else nil
	if !win.CreateProcessW(nil, wide(cmd), nil, nil, false, win.EXTENDED_STARTUPINFO_PRESENT, nil, dir, &si.StartupInfo, &pi) do return false
	win.CloseHandle(pi.hThread)
	t.pty = Pty{hpc = hpc, in_w = in_w, out_r = out_r, process = pi.hProcess, pid = i32(pi.dwProcessId), attrs = attrs}
	return true
}

pty_read :: proc(t: ^Term, buf: []u8) -> int {
	n: win.DWORD
	if !win.ReadFile(t.pty.out_r, raw_data(buf), win.DWORD(len(buf)), &n, nil) do return -1
	return int(n)
}

pty_write :: proc(t: ^Term, data: []u8) {
	n: win.DWORD
	win.WriteFile(t.pty.in_w, raw_data(data), win.DWORD(len(data)), &n, nil)
}

pty_resize :: proc(t: ^Term) {
	ResizePseudoConsole(t.pty.hpc, {i16(t.cols), i16(t.rows)})
}

pty_close :: proc(t: ^Term) {
	ClosePseudoConsole(t.pty.hpc) // ends the client and unblocks the reader
	win.CloseHandle(t.pty.in_w)
	if !t.exited do win.TerminateProcess(t.pty.process, 1)
	win.CloseHandle(t.pty.process)
	DeleteProcThreadAttributeList(raw_data(t.pty.attrs))
}

pty_cwd :: proc(t: ^Term) -> string {return ""}

spawn_detached :: proc(args: []string) {
	if len(args) == 0 do return
	win.ShellExecuteW(nil, wide("open"), wide(args[0]), wide(strings.join(args[1:], " ", context.temp_allocator)) if len(args) > 1 else nil, nil, win.SW_SHOWNORMAL)
}

notify :: proc(title, body: string) {} // shortcut: no toast notifications on Windows; needs WinRT

shm_read :: proc(name: string, size: int) -> ([]u8, bool) {return nil, false}

remove_file :: proc(path: string) {_ = os.remove(path)}
