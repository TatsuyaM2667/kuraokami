# kuraokami zsh integration + preset.
# Loaded before ~/.zshrc: anything set in .zshrc overrides it. Disable the preset with
# `shell-preset = false` in the kuraokami config (integration stays on).
[[ -o interactive ]] || return 0
zmodload zsh/parameter 2>/dev/null
autoload -Uz add-zsh-hook add-zle-hook-widget

# ---------------- shell integration (OSC 7 / 133 / title) ----------------
_ko_osc7() {
  local p=${PWD//\%/%25}; p=${p// /%20}
  print -n "\e]7;file://${HOST}${p}\a"
}
_ko_precmd() {
  local ret=$?
  _ko_last_status=$ret  # exit status for later hooks (the suggestion skips failed commands)
  if [[ -n $_ko_cmd_running ]]; then print -n "\e]133;D;${ret}\a"; fi
  _ko_cmd_running=
  _ko_osc7
  print -Pn "\e]2;%~\a"
  print -n "\e]133;A\a"
}
_ko_preexec() {
  _ko_cmd_running=1
  _ko_last_cmd=$1
  print -n "\e]133;C\a"
  print -rn -- $'\e]2;'"${1//[[:cntrl:]]/}"$'\a'
}
add-zsh-hook precmd _ko_precmd
add-zsh-hook preexec _ko_preexec

[[ ${KURAOKAMI_SHELL_PRESET:-1} == 1 ]] || return 0

# The preset already gives sensible defaults: skip zsh's new-user wizard (shown when ~/.zshrc is missing).
zsh-newuser-install() { : }

# ---------------- options & history ----------------
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT INTERACTIVE_COMMENTS NO_BEEP
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS EXTENDED_HISTORY HIST_VERIFY
setopt COMPLETE_IN_WORD ALWAYS_TO_END PROMPT_SUBST
: ${HISTFILE:=$HOME/.zsh_history}
(( HISTSIZE < 100000 )) && HISTSIZE=100000
(( SAVEHIST < 100000 )) && SAVEHIST=100000

# ---------------- aliases ----------------
alias ls='ls --color=auto' ll='ls -lah' la='ls -A' l='ls -CF'
alias grep='grep --color=auto' ..='cd ..' ...='cd ../..'
alias d='dirs -v | head -10'

# ---------------- keys (emacs mode, xterm sequences sent by kuraokami) ----------------
bindkey -e
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search   '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search '^[OB' down-line-or-beginning-search
bindkey '^[[H' beginning-of-line  '^[OH' beginning-of-line
bindkey '^[[F' end-of-line        '^[OF' end-of-line
bindkey '^[[3~' delete-char
bindkey '^[[1;5D' backward-word   '^[[1;5C' forward-word
bindkey '^[[1;3D' backward-word   '^[[1;3C' forward-word
bindkey '^H' backward-kill-word   '^[^?' backward-kill-word
bindkey '^[[3;5~' kill-word
bindkey '^[[Z' reverse-menu-complete
autoload -Uz edit-command-line; zle -N edit-command-line; bindkey '^X^E' edit-command-line

# ---------------- completion ----------------
zmodload zsh/complist 2>/dev/null
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{magenta}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{red}-- no matches --%f'
zstyle ':completion:*' squeeze-slashes true
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ${XDG_CACHE_HOME:-$HOME/.cache}/kuraokami/zcompcache

# ---------------- prompt ----------------
#   ╭─ user@host in ~/dir   main ●
#   ╰─❯                                            1.2s  ✘ 1  13:22:13
autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr '%F{#ffd58a}●%f'
zstyle ':vcs_info:*' stagedstr '%F{#7ee0a1}●%f'
zstyle ':vcs_info:git:*' formats '  %F{#c8a2ff} %b%f %u%c'
zstyle ':vcs_info:git:*' actionformats '  %F{#c8a2ff} %b%f %F{#ff7a8a}(%a)%f %u%c'
zmodload zsh/datetime 2>/dev/null
typeset -gF _ko_t0=0
_ko_prompt_exec() { _ko_t0=$EPOCHREALTIME }
_ko_prompt_pre() {
  vcs_info
  _ko_took=
  if (( _ko_t0 > 0 )); then
    local -F d=$(( EPOCHREALTIME - _ko_t0 ))
    (( d >= 1.0 )) && _ko_took="%F{#8b97b3}$(printf '%.1fs' $d)%f  "
    _ko_t0=0
  fi
}
add-zsh-hook preexec _ko_prompt_exec
add-zsh-hook precmd _ko_prompt_pre
PROMPT=$'\n%F{#4b5675}╭─%f %F{#c8a2ff}%n@%m%f %F{#4b5675}in%f %F{#7ab8ff}%B %(4~|…/%3~|%~)%b%f${vcs_info_msg_0_}\n%F{#4b5675}╰─%f%(?.%F{#7ab8ff}.%F{#ff7a8a})❯%f '
RPROMPT='${_ko_took}%(?..%F{#ff7a8a}✘ %?%f  )%(1j.%F{#ffd58a}✦%j%f  .)%F{#4b5675}%*%f'

# ---------------- fish-style abbreviations ----------------
# `gs<Space>` expands to `git status` in place, so history and the screen show the real command.
# Add your own in ~/.zshrc:  abbr dc='docker compose'   (list them with `abbr`, Ctrl+Space = no expansion)
typeset -gA _ko_abbr
abbr() {
  if (( $# == 0 )); then
    local k; for k in ${(ok)_ko_abbr}; do print -r -- "$k=${_ko_abbr[$k]}"; done
    return
  fi
  local a; for a in "$@"; do _ko_abbr[${a%%=*}]=${a#*=}; done
}
abbr gs='git status' ga='git add' gc='git commit' gco='git checkout' gsw='git switch' \
     gd='git diff' gp='git push' gpl='git pull' gl='git log --oneline --graph --decorate -20'
_ko_abbr_expand() {
  local w=${LBUFFER##*[[:space:]\;\|\&]}
  local pre=${LBUFFER%$w}
  local p=${pre//[[:space:]]/}
  [[ -n $w && -n ${_ko_abbr[$w]} && ( -z $p || $p == *[\;\|\&] ) ]] && LBUFFER=$pre${_ko_abbr[$w]}
}
_ko_abbr_space() { _ko_abbr_expand; zle self-insert }
_ko_abbr_enter() { _ko_abbr_expand; zle accept-line }
zle -N _ko_abbr_space
zle -N _ko_abbr_enter
bindkey ' ' _ko_abbr_space
bindkey '^M' _ko_abbr_enter
bindkey '^ ' magic-space

# ---------------- j: jump to frequently used directories (zoxide/z-like) ----------------
#   j kura   -> cd to the most used directory whose path contains "kura";  j  -> list
_ko_dirs=${XDG_DATA_HOME:-$HOME/.local/share}/kuraokami/dirs
_ko_chpwd_rank() {
  [[ $PWD == $HOME || $PWD == / ]] && return
  local -A s; local n d
  [[ -r $_ko_dirs ]] && while IFS=$'\t' read -r n d; do s[$d]=$n; done < $_ko_dirs
  s[$PWD]=$(( ${s[$PWD]:-0} + 1 ))
  mkdir -p ${_ko_dirs:h}
  { for d in ${(k)s}; do print -r -- "${s[$d]}"$'\t'"$d"; done } | sort -rn | head -500 >| $_ko_dirs
}
add-zsh-hook chpwd _ko_chpwd_rank
j() {
  [[ $# -eq 0 ]] && { sort -rn $_ko_dirs 2>/dev/null | head -20; return }
  local q=${(L)${(j:*:)@}} n d
  while IFS=$'\t' read -r n d; do
    [[ ${(L)d} == *${~q}* && -d $d ]] && { cd -- $d; return }
  done < <(sort -rn $_ko_dirs 2>/dev/null)
  print -u2 "j: '$*' に一致するディレクトリがありません"; return 1
}

# ---------------- "did you mean" for unknown commands ----------------
command_not_found_handler() {
  emulate -L zsh; setopt extended_glob
  print -u2 "zsh: command not found: $1"
  local e=1; (( $#1 > 5 )) && e=2
  local -a c=( ${(k)commands[(I)(#a$e)$1]} ${(k)functions[(I)(#a$e)$1]} ${(k)aliases[(I)(#a$e)$1]} )
  c=( ${${(u)c}[1,5]} )
  (( $#c )) && print -u2 "  もしかして: ${(j:, :)c}"
  return 127
}

# ---------------- small conveniences ----------------
mkcd() { mkdir -p -- "$1" && cd -- "$1" }
alias -- -='cd -'
bindkey '^R' history-incremental-pattern-search-backward
# Ctrl+Z on an empty line resumes the last suspended job (toggle with the job's own Ctrl+Z).
_ko_fg() { if [[ -z $BUFFER ]]; then BUFFER=fg; zle accept-line; else zle push-input; fi }
zle -N _ko_fg
bindkey '^Z' _ko_fg

# ---------------- after ~/.zshrc: completion init, suggestions, highlighting ----------------
_ko_late() {
  add-zsh-hook -d precmd _ko_late
  if (( ! $+functions[compdef] )); then
    autoload -Uz compinit
    local dump=${XDG_CACHE_HOME:-$HOME/.cache}/kuraokami/zcompdump
    mkdir -p ${dump:h}
    compinit -i -d $dump
  fi
  # Built-in history autosuggestions (skipped if zsh-autosuggestions is already loaded).
  if (( ! $+functions[_zsh_autosuggest_start] )); then
    # Commands that failed (typos, wrong flags) are not suggested again until they succeed.
    typeset -gA _ko_failed
    _ko_track_failed() {
      [[ -z $_ko_last_cmd ]] && return
      if (( _ko_last_status == 0 )); then unset "_ko_failed[$_ko_last_cmd]"
      elif (( _ko_last_status != 130 && _ko_last_status != 148 )); then _ko_failed[$_ko_last_cmd]=1  # not Ctrl+C / Ctrl+Z
      fi
      _ko_last_cmd=
    }
    add-zsh-hook precmd _ko_track_failed
    _ko_suggest() {
      emulate -L zsh
      region_highlight=( ${region_highlight:#*memo=kosug} )
      POSTDISPLAY=
      [[ -z $BUFFER || $CURSOR -ne $#BUFFER || $BUFFER == *$'\n'* ]] && return
      local s= k h
      # 1) newest history entry with this prefix that did not fail
      for k in ${${(On)${(k)history[(R)${(b)BUFFER}*]}}[1,200]}; do
        h=${history[$k]}
        [[ $h == $BUFFER || -n ${_ko_failed[$h]} ]] && continue
        s=${h#$BUFFER}; break
      done
      # 2) otherwise complete the file/directory name being typed (arguments, or anything with a /)
      if [[ -z $s && $BUFFER != *[[:space:]] && ( $BUFFER == *[[:space:]]* || $BUFFER == */* ) ]]; then
        local w=${BUFFER##*[[:space:]]} base
        base=$w; [[ $w == '~/'* ]] && base=$HOME/${w#\~/}
        local -a m=( ${~${(b)base}}*(N[1]) )
        if (( $#m )) && [[ $m[1] != $base ]]; then
          s=${m[1]#$base}
          [[ -d $m[1] ]] && s+=/
        fi
      fi
      [[ -z $s ]] && return
      POSTDISPLAY=$s
      region_highlight+=( "$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) fg=8 memo=kosug" )
    }
    # → / End / Ctrl+F: take the whole suggestion
    _ko_accept() {
      if [[ -n $POSTDISPLAY && $CURSOR -eq $#BUFFER ]]; then
        BUFFER+=$POSTDISPLAY; POSTDISPLAY=; CURSOR=$#BUFFER
      else
        zle .${WIDGET#_ko_accept_}
      fi
    }
    # Ctrl+→ / Alt+→ / Alt+F: take just the next word (fish-style)
    _ko_accept_word() {
      emulate -L zsh -o extended_glob
      if [[ -n $POSTDISPLAY && $CURSOR -eq $#BUFFER ]]; then
        local w=${(M)POSTDISPLAY##[[:space:]]#[^[:space:]/]#/#}
        [[ -z $w ]] && w=${POSTDISPLAY[1]}
        BUFFER+=$w; CURSOR=$#BUFFER
      else
        zle .forward-word
      fi
    }
    _ko_clear() { POSTDISPLAY=; region_highlight=( ${region_highlight:#*memo=kosug} ) }
    zle -N _ko_accept_forward-char _ko_accept
    zle -N _ko_accept_end-of-line _ko_accept
    zle -N _ko_accept_word
    add-zle-hook-widget line-pre-redraw _ko_suggest
    add-zle-hook-widget line-finish _ko_clear
    bindkey '^[[C' _ko_accept_forward-char '^[OC' _ko_accept_forward-char '^F' _ko_accept_forward-char
    bindkey '^[[F' _ko_accept_end-of-line '^[OF' _ko_accept_end-of-line '^E' _ko_accept_end-of-line
    bindkey '^[[1;5C' _ko_accept_word '^[[1;3C' _ko_accept_word '^[f' _ko_accept_word
  fi
  # Syntax highlighting: the real plugin if installed, else a light built-in (command valid/invalid).
  if (( ! $+functions[_zsh_highlight] )); then
    local f
    for f in /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
             /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
             /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
             /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
      [[ -r $f ]] && { source $f; break }
    done
    if (( ! $+functions[_zsh_highlight] )); then
      _ko_highlight() {
        region_highlight=( ${region_highlight:#*memo=kohl} )
        local lead=${BUFFER%%[^[:space:]]*}
        local w=${${(z)BUFFER}[1]}
        [[ -z $w ]] && return
        local style='fg=red,bold'
        if (( $+commands[$w] || $+functions[$w] || $+aliases[$w] || $+builtins[$w] || $+reswords[$w] )) || [[ -x $w || -d $w ]]; then
          style='fg=green'
        fi
        region_highlight+=( "$#lead $(( $#lead + $#w )) $style memo=kohl" )
      }
      add-zle-hook-widget line-pre-redraw _ko_highlight
    fi
  fi
}
add-zsh-hook precmd _ko_late
