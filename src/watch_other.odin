#+build !linux
package kuraokami

// No inotify here: the config mtime is checked when the window regains focus (see on focus handler).
config_watch_start :: proc() {}
