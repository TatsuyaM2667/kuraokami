package kuraokami

import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:image"
import "core:image/bmp"
import "core:image/jpeg"
import "core:image/png"
import "core:image/qoi"
import "core:image/tga"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

// Startup fetch logo (fetch-logo = ...):
//   ""/default   fastfetch's own logo           none        no logo
//   kuraokami / crystal                         kuraokami's ASCII art library
//   arch, freebsd, ... (any fastfetch logo)     fastfetch's built-in ASCII library
//   ~/art.txt                                   your ASCII art ($1..$9 = colors)
//   ~/pic.png|jpg|bmp|tga|qoi                   image (shown with the kitty protocol)
//   ~/anim.gif|webp|mp4|webm|mkv|mov            animated: frames decoded with ffmpeg and played by kuraokami


LOGO_ASCII := [?][2]string {
	{
		"kuraokami",
		`$1          ▁▂▃▄▅▆▇
$1      ▗▄▀▀       ▀▄▖   $2◆
$1    ▗▀   $2╱╲$1         ▀▖
$1   ▐    $2╱  ╲$1         ▌
$1   ▐   $2╱ >_ ╲$1        ▌
$1   ▝▖  $2╲    ╱$1      ▗▘
$1     ▀▄ $2╲  ╱$1     ▄▀
$1       ▀▄$2╲╱$1  ▄▄▀▘
$1  ~≈≈~   ▀▀▀▀▘  ~≈≈~`,
	},
	{
		"crystal",
		`$2       ▲
$2      ╱$1█$2╲
$2     ╱$1██$2 ╲
$2    ╱$1███$2  ╲
$1   ◢$2━━━━━━━$1◣
$1   █ $2>_$1    █
$1   █       █
$1   ◥◣     ◢◤
$1     ◥◣ ◢◤
$1       ▼`,
	},
}

ANIM_EXT := [?]string{".gif", ".webp", ".apng", ".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v"}
STATIC_EXT := [?]string{".jpg", ".jpeg", ".bmp", ".tga", ".qoi"}
TEXT_EXT := [?]string{".txt", ".ascii", ".ans"}

Logo_Anim :: struct {
	mu:      sync.Mutex,
	png:     string, // cache file fastfetch shows (frame 0); identifies the placed image
	frames:  [][]u8,
	w, h:    int,
	fps:     f64,
	ready:   bool,
	start:   f64,
	last:    int,
	stopped: bool,
}

logo_anim: Logo_Anim

cache_dir :: proc() -> string {
	when ODIN_OS == .Windows do return fmt.tprintf("%s/cache", config_dir())
	else {
		if x := os.get_env("XDG_CACHE_HOME", context.temp_allocator); x != "" do return fmt.tprintf("%s/kuraokami", x)
		return fmt.tprintf("%s/.cache/kuraokami", home_dir())
	}
}

shell_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return fmt.tprintf("'%s'", q)
}

expand_home :: proc(p: string) -> string {
	if strings.has_prefix(p, "~/") do return fmt.tprintf("%s/%s", home_dir(), p[2:])
	return p
}

has_ext :: proc(p: string, list: []string) -> bool {
	e := strings.to_lower(filepath.ext(p), context.temp_allocator)
	for x in list do if e == x do return true
	return false
}

// Extra fastfetch arguments for the configured logo (already shell-quoted). Prepares cache files.
fetch_logo_args :: proc() -> string {
	v := strings.trim_space(cfg.fetch_logo)
	if v == "" || v == "default" do return ""
	if v == "none" do return " --logo none"
	cols, rows := cfg.fetch_logo_size[0], cfg.fetch_logo_size[1]
	image_args :: proc(png: string, cols, rows: int) -> string {
		return fmt.tprintf(
			" --logo %s --logo-type kitty-direct --logo-width %d --logo-height %d",
			shell_quote(png),
			cols,
			rows,
		)
	}
	for a in LOGO_ASCII {
		if a[0] != v do continue
		path := fmt.tprintf("%s/logo-%s.txt", cache_dir(), a[0])
		_ = os.make_directory_all(cache_dir())
		_ = os.write_entire_file(path, transmute([]u8)a[1])
		return fmt.tprintf(
			" --logo %s --logo-type file --logo-color-1 %s --logo-color-2 %s",
			shell_quote(path),
			"magenta",
			"cyan",
		)
	}
	if !strings.contains_rune(v, '/') && !strings.has_prefix(v, "~") {
		// A fastfetch built-in logo name: only harmless characters reach the shell.
		for r in v do if !(r == '_' || r == '-' || r == '.' || r == ' ' || r == '+' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) {
			show_toast(fmt.tprintf("fetch-logo: 使えない文字があります: %s", v))
			return ""
		}
		return fmt.tprintf(" --logo %s --logo-type builtin", shell_quote(v))
	}
	path := expand_home(v)
	if !os.exists(path) {
		show_toast(fmt.tprintf("fetch-logo: ファイルがありません: %s", path))
		return ""
	}
	abs, _ := os.get_absolute_path(path, context.temp_allocator)
	switch {
	case has_ext(abs, TEXT_EXT[:]):
		return fmt.tprintf(" --logo %s --logo-type file", shell_quote(abs))
	case has_ext(abs, {".png"}):
		return image_args(abs, cols, rows)
	case has_ext(abs, STATIC_EXT[:]):
		if png := static_to_png(abs); png != "" do return image_args(png, cols, rows)
		show_toast(fmt.tprintf("fetch-logo: 画像を読めません: %s", abs))
	case has_ext(abs, ANIM_EXT[:]):
		if !in_path("ffmpeg") {
			show_toast("fetch-logo: GIF / 動画には ffmpeg が必要です")
			return ""
		}
		if png := anim_start(abs, cols, rows); png != "" do return image_args(png, cols, rows)
		show_toast(fmt.tprintf("fetch-logo: 動画を読めません: %s", abs))
	case:
		// Unknown extension: let fastfetch decide (it tries an image, then text).
		return fmt.tprintf(" --logo %s", shell_quote(abs))
	}
	return ""
}

cache_png_path :: proc(src: string) -> string {
	_ = os.make_directory_all(cache_dir())
	return fmt.tprintf("%s/logo-%x.png", cache_dir(), hash.fnv64a(transmute([]u8)src))
}

// JPEG/BMP/TGA/QOI -> RGBA PNG in the cache (decoded by Odin's core:image), downscaled to <= 640 px.
static_to_png :: proc(src: string) -> string {
	data, err := os.read_entire_file_from_path(src, context.temp_allocator)
	if err != nil do return ""
	img, ierr := image.load_from_bytes(data, {.alpha_add_if_missing})
	if ierr != nil do return ""
	defer image.destroy(img)
	px := image_bytes(img)
	if img.channels != 4 || img.depth != 8 do return ""
	rgba, w, h := downscale_rgba(px, img.width, img.height, 640, 640)
	out := cache_png_path(src)
	if os.write_entire_file(out, png_encode(rgba, w, h, 4)) != nil do return ""
	return out
}

// Box-filter downscale to fit within maxw x maxh (no-op if already small).
downscale_rgba :: proc(px: []u8, w, h, maxw, maxh: int) -> ([]u8, int, int) {
	k := max(1, max((w + maxw - 1) / maxw, (h + maxh - 1) / maxh))
	if k == 1 do return px, w, h
	nw, nh := w / k, h / k
	out := make([]u8, nw * nh * 4, context.temp_allocator)
	for y in 0 ..< nh do for x in 0 ..< nw {
		sum: [4]int
		for dy in 0 ..< k do for dx in 0 ..< k {
			o := ((y * k + dy) * w + (x * k + dx)) * 4
			for c in 0 ..< 4 do sum[c] += int(px[o + c])
		}
		for c in 0 ..< 4 do out[(y * nw + x) * 4 + c] = u8(sum[c] / (k * k))
	}
	return out, nw, nh
}

LOGO_FPS :: 15
LOGO_MAX_SECONDS :: 12
LOGO_MAX_PX :: 360

// Decode frame 0 now (fastfetch needs the PNG immediately) and the rest in the background.
anim_start :: proc(src: string, cols, rows: int) -> string {
	w := min(cols * max(fonts.cell_w, 1), LOGO_MAX_PX)
	h := min(rows * max(fonts.cell_h, 1), LOGO_MAX_PX)
	w, h = w &~ 1, h &~ 1
	filter :: proc(w, h: int, fps: bool) -> string {
		f := fmt.tprintf(
			"scale=%d:%d:force_original_aspect_ratio=decrease,format=rgba,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black@0",
			w,
			h,
			w,
			h,
		)
		return fmt.tprintf("fps=%d,%s", LOGO_FPS, f) if fps else f
	}
	first, ok := run_capture(
		{
			"ffmpeg",
			"-v",
			"error",
			"-i",
			src,
			"-frames:v",
			"1",
			"-vf",
			filter(w, h, false),
			"-f",
			"rawvideo",
			"-pix_fmt",
			"rgba",
			"-",
		},
		w * h * 4 + 1,
	)
	if !ok || len(first) != w * h * 4 do return ""
	defer delete(first)
	png := cache_png_path(src)
	if os.write_entire_file(png, png_encode(first, w, h, 4)) != nil do return ""
	logo_anim.png = strings.clone(png)
	logo_anim.w, logo_anim.h, logo_anim.fps = w, h, LOGO_FPS
	Job :: struct {
		src, vf: string,
		w, h:    int,
	}
	job := new(Job)
	job^ = {strings.clone(src), strings.clone(filter(w, h, true)), w, h}
	thread.create_and_start_with_poly_data(
		job,
		proc(job: ^Job) {
			defer {delete(job.src); delete(job.vf); free(job)}
			size := job.w * job.h * 4
			raw, ok := run_capture(
				{
					"ffmpeg",
					"-v",
					"error",
					"-t",
					fmt.tprint(LOGO_MAX_SECONDS),
					"-i",
					job.src,
					"-vf",
					job.vf,
					"-f",
					"rawvideo",
					"-pix_fmt",
					"rgba",
					"-",
				},
				size * LOGO_FPS * LOGO_MAX_SECONDS + 1,
			)
			if !ok || len(raw) < size * 2 do return // a single frame: nothing to animate
			n := len(raw) / size
			frames := make([][]u8, n)
			for i in 0 ..< n do frames[i] = raw[i * size:(i + 1) * size]
			sync.mutex_lock(&logo_anim.mu)
			logo_anim.frames = frames
			logo_anim.ready = true
			sync.mutex_unlock(&logo_anim.mu)
			push_wake()
		},
		self_cleanup = true,
	)
	return png
}

// Advance the animated fetch logo. Returns ms until the next frame, or -1 when idle/finished.
logo_anim_tick :: proc() -> i32 {
	a := &logo_anim
	if !a.ready || a.stopped || len(app.tabs) == 0 do return -1
	if a.start != 0 && cfg.fetch_logo_seconds > 0 && app.now - a.start > cfg.fetch_logo_seconds {
		a.stopped = true // power: stop after the configured time, keep the current frame
		return -1
	}
	Find :: struct {
		t:   ^Term,
		img: ^Image,
	}
	f := Find{}
	for_leaves(current_tab().root, proc(n: ^Node, data: rawptr) {
			f := (^Find)(data)
			if f.img != nil do return
			t := n.term
			sync.mutex_lock(&t.mu)
			defer sync.mutex_unlock(&t.mu)
			top := view_abs(t, 0)
			for _, img in t.gfx.images {
				if img.src != logo_anim.png || img.w != logo_anim.w || img.h != logo_anim.h do continue
				for p in t.gfx.placements {
					if p.img == img.id && p.abs_row + i64(p.rows) > top && p.abs_row < top + i64(t.rows) {f.t, f.img = t, img; return}
				}
			}
		}, &f)
	if f.img == nil do return -1 // not on screen: nothing to do (and no wakeups)
	if a.start == 0 do a.start = app.now
	total := int((app.now - a.start) * a.fps)
	idx := total % len(a.frames)
	if idx != a.last {
		sync.mutex_lock(&f.t.mu)
		if len(f.img.pixels) == len(a.frames[idx]) {
			copy(f.img.pixels, a.frames[idx])
			f.img.version += 1
			f.t.dirty = true
		}
		sync.mutex_unlock(&f.t.mu)
		a.last = idx
		app.redraw = true
	}
	next := (f64(total + 1) / a.fps) - (app.now - a.start)
	return max(1, i32(next * 1000))
}
