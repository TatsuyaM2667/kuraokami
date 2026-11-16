# kuraokami bash integration (loaded via --rcfile; sources ~/.bashrc first).
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ $- == *i* ]] || return 0
_ko_precmd() {
  local ret=$?
  [[ -n $_ko_running ]] && printf '\e]133;D;%s\a' "$ret"
  _ko_running=
  printf '\e]7;file://%s%s\a' "$HOSTNAME" "${PWD// /%20}"
  printf '\e]2;%s\a' "${PWD/#$HOME/~}"
  printf '\e]133;A\a'
}
PROMPT_COMMAND="_ko_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS0='\[\e]133;C\a\]'"${PS0}"
trap '_ko_running=1' DEBUG
if [[ ${KURAOKAMI_SHELL_PRESET:-1} == 1 ]]; then
  shopt -s histappend checkwinsize globstar autocd 2>/dev/null
  HISTSIZE=100000; HISTFILESIZE=100000; HISTCONTROL=ignoreboth:erasedups
  bind '"\e[A": history-search-backward' 2>/dev/null
  bind '"\e[B": history-search-forward' 2>/dev/null
  bind 'set completion-ignore-case on' 2>/dev/null
  bind 'set show-all-if-ambiguous on' 2>/dev/null
  bind 'set colored-stats on' 2>/dev/null
  for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do [[ -r $f ]] && { source "$f"; break; }; done
  alias ls='ls --color=auto' ll='ls -lah' la='ls -A' grep='grep --color=auto'
fi

# j: jump to frequently used directories (shares its list with the zsh preset)
_ko_dirs=${XDG_DATA_HOME:-$HOME/.local/share}/kuraokami/dirs
_ko_rank() {
  [[ $PWD == "$_ko_lastpwd" || $PWD == "$HOME" || $PWD == / ]] && return
  _ko_lastpwd=$PWD
  mkdir -p "${_ko_dirs%/*}"
  { [[ -r $_ko_dirs ]] && cat "$_ko_dirs"; printf '1\t%s\n' "$PWD"; } |
    awk -F'\t' '{ s[$2] += $1 } END { for (d in s) printf "%d\t%s\n", s[d], d }' | sort -rn | head -500 > "$_ko_dirs.$$" &&
    mv -f "$_ko_dirs.$$" "$_ko_dirs"
}
PROMPT_COMMAND="_ko_rank;$PROMPT_COMMAND"
j() {
  [[ $# -eq 0 ]] && { sort -rn "$_ko_dirs" 2>/dev/null | head -20; return; }
  local q n d; q=$(printf '%s' "$*" | tr '[:upper:]' '[:lower:]')
  while IFS=$'\t' read -r n d; do
    [[ ${d,,} == *"$q"* && -d $d ]] && { cd -- "$d"; return; }
  done < <(sort -rn "$_ko_dirs" 2>/dev/null)
  echo "j: '$*' に一致するディレクトリがありません" >&2; return 1
}

# "did you mean" for unknown commands (same first two letters, similar length)
command_not_found_handle() {
  echo "bash: $1: command not found" >&2
  local c; c=$(compgen -c -- "${1:0:2}" 2>/dev/null | awk -v n=${#1} 'length($0) >= n-1 && length($0) <= n+1' | sort -u | head -5 | paste -sd, -)
  [[ -n $c ]] && echo "  もしかして: ${c//,/, }" >&2
  return 127
}
