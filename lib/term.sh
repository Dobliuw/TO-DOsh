# shellcheck shell=bash disable=SC2034
# term.sh — terminal capabilities and interactive helpers shared by CLI and TUI:
# colors, status symbols, width, paging, confirmation and the external editor.
#
# CLI colors use the 16 basic ANSI colors on purpose: the terminal maps them to
# its own palette, so output matches the user's theme (e.g. Tokyo Night in kitty).
# SC2034: the tables below are read by the presentation code in other modules.

TD_COLOR=0
TD_UNICODE=0
declare -gA TD_SGR=() TD_SYM=()

# td_term_init — decide color and Unicode support for stdout.
td_term_init() {
  local mode=$TD_OPT_COLOR
  [[ $mode == auto ]] && mode=${TD_CONF[color]:-auto}
  case $mode in
    always) TD_COLOR=1 ;;
    never) TD_COLOR=0 ;;
    *) [[ -t 1 && ${TERM:-dumb} != dumb ]] && TD_COLOR=1 || TD_COLOR=0 ;;
  esac

  case ${TD_CONF[icons]:-auto} in
    ascii) TD_UNICODE=0 ;;
    unicode | nerd) TD_UNICODE=1 ;;
    *)
      local locale=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
      [[ $locale =~ [Uu][Tt][Ff]-?8 ]] && TD_UNICODE=1 || TD_UNICODE=0
      ;;
  esac

  TD_SGR=()
  local name code
  local -A codes=(
    [reset]=0 [bold]=1 [dim]=2 [red]=31 [green]=32 [yellow]=33
    [blue]=34 [magenta]=35 [cyan]=36 [gray]=90
  )
  for name in "${!codes[@]}"; do
    code=${codes[$name]}
    if ((TD_COLOR)); then TD_SGR[$name]=$'\e['"${code}m"; else TD_SGR[$name]=""; fi
  done

  if ((TD_UNICODE)); then
    TD_SYM=([TODO]="○" [IN_PROGRESS]="◐" [BLOCKED]="⊘" [DONE]="✓" [CANCELLED]="✗"
      [arrow]="→" [ellipsis]="…" [comment]="»" [event]="·" [child]="↳" [dash]="—"
      [focus]="◉" [warn]="⚠" [time]="⏱")
  else
    TD_SYM=([TODO]="[ ]" [IN_PROGRESS]="[~]" [BLOCKED]="[!]" [DONE]="[x]" [CANCELLED]="[-]"
      [arrow]="->" [ellipsis]="~" [comment]=">" [event]="*" [child]="\\" [dash]="-"
      [focus]="@" [warn]="!" [time]="~")
  fi
}

# td_status_color STATUS — print the SGR sequence for a status.
td_status_color() {
  case $1 in
    IN_PROGRESS) printf '%s' "${TD_SGR[bold]}${TD_SGR[blue]}" ;;
    BLOCKED) printf '%s' "${TD_SGR[red]}" ;;
    DONE) printf '%s' "${TD_SGR[green]}" ;;
    CANCELLED) printf '%s' "${TD_SGR[gray]}" ;;
  esac
}

# td_priority_color PRIORITY — print the SGR sequence for a priority.
td_priority_color() {
  case $1 in
    urgent) printf '%s' "${TD_SGR[bold]}${TD_SGR[red]}" ;;
    high) printf '%s' "${TD_SGR[yellow]}" ;;
    low) printf '%s' "${TD_SGR[gray]}" ;;
  esac
}

# td_term_cols — print the usable width of stdout, or 0 when not a terminal.
td_term_cols() {
  if [[ -t 1 ]]; then
    local cols
    cols=$(tput cols 2>/dev/null) || cols=${COLUMNS:-80}
    printf '%s\n' "${cols:-80}"
  else
    printf '0\n'
  fi
}

# td_truncate VAR TEXT WIDTH — store TEXT cut to WIDTH characters in VAR.
td_truncate() {
  local -n _td_t=$1
  local _td_text=$2 _td_width=$3
  if ((_td_width > 0 && ${#_td_text} > _td_width)); then
    _td_t=${_td_text:0:_td_width-1}${TD_SYM[ellipsis]}
  else
    _td_t=$_td_text
  fi
}

# td_page TEXT — print TEXT, through a pager when it does not fit the terminal.
td_page() {
  local text=$1 rows lines
  if [[ -t 1 ]] && rows=$(tput lines 2>/dev/null); then
    lines=$(printf '%s\n' "$text" | wc -l)
    if ((lines > rows - 1)); then
      local -a pager
      read -ra pager <<<"${PAGER:-less}"
      ((${#pager[@]})) || pager=(less)
      printf '%s\n' "$text" | LESS=${LESS:-FRX} "${pager[@]}"
      return 0
    fi
  fi
  printf '%s\n' "$text"
}

# td_confirm PROMPT — ask a yes/no question on the terminal; default is no.
td_confirm() {
  local answer
  [[ -r /dev/tty ]] || return 1
  printf '%s [y/N] ' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

# td_editor_cmd ARRAY — resolve the editor command into ARRAY.
# The value is split on whitespace (never eval'ed): `nvim -p` works, quoting does not.
td_editor_cmd() {
  local -n _td_cmd=$1
  local _td_editor=${TD_CONF[editor]:-${VISUAL:-${EDITOR:-vi}}}
  read -ra _td_cmd <<<"$_td_editor"
  ((${#_td_cmd[@]})) || _td_cmd=(vi)
}

# td_run_editor FILE — open FILE in the user's editor on the controlling terminal.
td_run_editor() {
  local -a cmd
  td_editor_cmd cmd
  if ! { : </dev/tty >/dev/tty; } 2>/dev/null; then
    td_err "editing requires a terminal"
    return "$TD_E_USAGE"
  fi
  if ! command -v -- "${cmd[0]}" >/dev/null 2>&1; then
    td_err "editor not found: ${cmd[0]} (set 'editor' in the config, or \$VISUAL/\$EDITOR)"
    return "$TD_E_ERR"
  fi
  if ! "${cmd[@]}" "$1" </dev/tty >/dev/tty; then
    td_err "editor exited with an error; nothing was changed"
    return "$TD_E_ERR"
  fi
}
