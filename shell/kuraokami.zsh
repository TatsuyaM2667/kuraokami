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
  if [[ -n $_ko_cmd_running ]]; then print -n "\e]133;D;${ret}\a"; fi
  _ko_cmd_running=
  _ko_osc7
  print -Pn "\e]2;%~\a"
  print -n "\e]133;A\a"
}
_ko_preexec() {
  _ko_cmd_running=1
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
    _ko_suggest() {
      region_highlight=( ${region_highlight:#*memo=kosug} )
      POSTDISPLAY=
      [[ -z $BUFFER || $CURSOR -ne $#BUFFER || $BUFFER == *$'\n'* ]] && return
      local -a ks=( ${(k)history[(R)${(b)BUFFER}*]} )
      (( $#ks )) || return
      local h=${history[${${(On)ks}[1]}]}
      [[ $h == $BUFFER ]] && return
      POSTDISPLAY=${h#$BUFFER}
      region_highlight+=( "$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) fg=8 memo=kosug" )
    }
    _ko_accept() {
      if [[ -n $POSTDISPLAY && $CURSOR -eq $#BUFFER ]]; then
        BUFFER+=$POSTDISPLAY; POSTDISPLAY=; CURSOR=$#BUFFER
      else
        zle .${WIDGET#_ko_accept_}
      fi
    }
    _ko_clear() { POSTDISPLAY=; region_highlight=( ${region_highlight:#*memo=kosug} ) }
    zle -N _ko_accept_forward-char _ko_accept
    zle -N _ko_accept_end-of-line _ko_accept
    add-zle-hook-widget line-pre-redraw _ko_suggest
    add-zle-hook-widget line-finish _ko_clear
    bindkey '^[[C' _ko_accept_forward-char '^[OC' _ko_accept_forward-char '^F' _ko_accept_forward-char
    bindkey '^[[F' _ko_accept_end-of-line '^[OF' _ko_accept_end-of-line '^E' _ko_accept_end-of-line
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
