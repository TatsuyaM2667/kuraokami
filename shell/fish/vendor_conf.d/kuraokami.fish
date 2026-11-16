# kuraokami fish integration (loaded via XDG_DATA_DIRS/fish/vendor_conf.d).
# Restore XDG_DATA_DIRS so programs started from fish don't see our directory.
if set -q KURAOKAMI_SHELL_DIR
    set -gx XDG_DATA_DIRS (string match -v -- "$KURAOKAMI_SHELL_DIR/xdg" $XDG_DATA_DIRS)
    test (count $XDG_DATA_DIRS) -eq 0; and set -e XDG_DATA_DIRS
end
status is-interactive; or exit

function __ko_osc7 --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string replace -a ' ' '%20' -- $PWD)
end
function __ko_prompt --on-event fish_prompt
    set -l s $status
    if set -q __ko_running
        printf '\e]133;D;%s\a' $s
        set -e __ko_running
    end
    printf '\e]2;%s\a\e]133;A\a' (prompt_pwd)
end
function __ko_preexec --on-event fish_preexec
    set -g __ko_running 1
    printf '\e]133;C\a\e]2;%s\a' (string replace -ra '[[:cntrl:]]' '' -- $argv[1])
end
__ko_osc7
