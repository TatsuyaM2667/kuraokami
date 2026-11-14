package kuraokami

import "core:sync"

// Writes to the PTY go through a per-pane queue drained by a writer thread, so a huge paste
// (or a program that stops reading its input) can never freeze the UI.

MAX_WRITE_QUEUE :: 64 << 20

pty_write :: proc(t: ^Term, data: []u8) {
	if len(data) == 0 do return
	sync.mutex_lock(&t.wmu)
	if len(t.wq) + len(data) <= MAX_WRITE_QUEUE do append(&t.wq, ..data)
	sync.mutex_unlock(&t.wmu)
	sync.cond_signal(&t.wcond)
}

writer_proc :: proc(t: ^Term) {
	buf: [dynamic]u8
	defer delete(buf)
	for {
		sync.mutex_lock(&t.wmu)
		for len(t.wq) == 0 && !sync.atomic_load(&t.closing) do sync.cond_wait(&t.wcond, &t.wmu)
		if sync.atomic_load(&t.closing) {sync.mutex_unlock(&t.wmu); break}
		buf, t.wq = t.wq, buf // swap: the UI keeps queueing into the (now empty) other buffer
		clear(&t.wq)
		sync.mutex_unlock(&t.wmu)
		if !pty_write_raw(t, buf[:]) do break
		clear(&buf)
	}
	term_release(t)
}

// Stop the reader/writer threads (pane closed or the shell exited).
term_stop :: proc(t: ^Term) {
	sync.atomic_store(&t.closing, true)
	sync.mutex_lock(&t.wmu)
	sync.mutex_unlock(&t.wmu)
	sync.cond_broadcast(&t.wcond)
}
