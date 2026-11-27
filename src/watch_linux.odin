package kuraokami

import "core:strings"
import "core:sync"
import "core:thread"
import "core:sys/linux"

// Config hot reload via inotify: the thread blocks in read(), so there is no polling cost.
config_watch_start :: proc() {
	thread.create_and_start(proc() {
		fd, err := linux.inotify_init1({.CLOEXEC})
		if err != nil do return
		dir := strings.clone_to_cstring(config_dir(), context.temp_allocator)
		if _, werr := linux.inotify_add_watch(fd, dir, {.CLOSE_WRITE, .MOVED_TO, .CREATE}); werr != nil do return
		buf: [4096]u8
		for {
			n, rerr := linux.read(fd, buf[:])
			if rerr != nil || n <= 0 do return
			sync.atomic_store(&config_dirty, true)
			push_wake()
		}
	}, self_cleanup = true)
}
