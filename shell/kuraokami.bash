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
