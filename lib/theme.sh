# shellcheck shell=bash disable=SC2034
# theme.sh — TUI color themes, terminal color tiers and theme import.
#
# A theme is a `key = #rrggbb` file. Built-in themes live in $TD_SHARE_DIR/themes;
# user themes in $TD_CONFIG_DIR/themes take precedence. The TUI never paints
# the background, so terminal transparency and the user's background stay.
#
# Color tiers (TD_TIER): 3 truecolor, 2 = 256 colors, 1 = 16 colors, 0 = none.
# Only truecolor and 256 use the theme's exact colors; with 16 colors the
# terminal's own palette is used, which usually is the user's theme anyway.
# SC2034: the tables are read by tui.sh.

readonly TD_THEME_KEYS=(fg muted accent border selection red orange yellow green cyan blue magenta)

# Fallback for keys a theme does not define (Tokyo Night).
declare -grA TD_THEME_DEFAULTS=(
  [fg]="#c0caf5" [muted]="#565f89" [accent]="#7aa2f7" [border]="#3b4261"
  [selection]="#283457" [red]="#f7768e" [orange]="#ff9e64" [yellow]="#e0af68"
  [green]="#9ece6a" [cyan]="#7dcfff" [blue]="#7aa2f7" [magenta]="#bb9af7"
)

# 16-color fallback (SGR parameters); selection uses reverse video.
declare -grA TD_THEME_ANSI=(
  [fg]=39 [muted]=90 [accent]=34 [border]=90 [red]=31 [orange]=33 [yellow]=33
  [green]=32 [cyan]=36 [blue]=34 [magenta]=35
)

declare -gA TD_THEME=() TD_TC=()
TD_THEME_NAME=""
TD_TIER=0

# td_theme_path NAME — print the file of theme NAME (user dir first).
td_theme_path() {
  local name=$1 dir
  if ! td_valid_name "$name"; then
    td_err "invalid theme name: '$name'"
    return "$TD_E_USAGE"
  fi
  for dir in "$TD_CONFIG_DIR/themes" "$TD_SHARE_DIR/themes"; do
    if [[ -f $dir/$name.theme ]]; then
      printf '%s\n' "$dir/$name.theme"
      return 0
    fi
  done
  td_err "theme not found: $name (see: todosh theme list)"
  return "$TD_E_NOTFOUND"
}

# td_theme_list — print "NAME<TAB>SOURCE" for every theme, sorted.
td_theme_list() {
  local dir file name
  local -A seen=()
  for dir in "$TD_CONFIG_DIR/themes" "$TD_SHARE_DIR/themes"; do
    for file in "$dir"/*.theme; do
      [[ -f $file ]] || continue
      name=${file##*/}
      name=${name%.theme}
      td_valid_name "$name" || continue
      [[ -v seen[$name] ]] && continue
      seen[$name]=1
      if [[ $dir == "$TD_CONFIG_DIR/themes" ]]; then
        printf '%s\tuser\n' "$name"
      else
        printf '%s\tbuilt-in\n' "$name"
      fi
    done
  done | LC_ALL=C sort
}

# td_theme_load NAME — read a theme into TD_THEME. Unknown or invalid lines
# are warnings; missing keys take the default value.
td_theme_load() {
  local name=$1 path key line value lineno=0
  local re='^([a-z_]+)[[:space:]]*=[[:space:]]*(#[0-9A-Fa-f]{6})$'
  TD_THEME=()
  for key in "${TD_THEME_KEYS[@]}"; do
    TD_THEME[$key]=${TD_THEME_DEFAULTS[$key]}
  done
  path=$(td_theme_path "$name") || return
  while IFS= read -r line || [[ -n $line ]]; do
    ((++lineno))
    line=${line%$'\r'}
    line=${line##+([[:space:]])}
    line=${line%%+([[:space:]])}
    [[ -z $line || $line == '#'* ]] && continue
    if [[ ! $line =~ $re ]]; then
      td_warn "$path line $lineno: expected 'key = #rrggbb'"
      continue
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2],,}
    if [[ -v TD_THEME_DEFAULTS[$key] ]]; then
      TD_THEME[$key]=$value
    else
      td_warn "$path line $lineno: unknown key '$key'"
    fi
  done <"$path"
  TD_THEME_NAME=$name
}

# td_color_tier — detect color support of the terminal on stdout into TD_TIER.
td_color_tier() {
  local mode=$TD_OPT_COLOR colors
  [[ $mode == auto ]] && mode=${TD_CONF[color]:-auto}
  if [[ $mode == never ]]; then
    TD_TIER=0
    return
  fi
  if [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit || ${TERM:-} == xterm-kitty ||
    ${TERM:-} == *-direct ]]; then
    TD_TIER=3
    return
  fi
  colors=$(tput colors 2>/dev/null) || colors=0
  if ((colors >= 256)); then
    TD_TIER=2
  elif ((colors >= 8)); then
    TD_TIER=1
  elif [[ $mode == always ]]; then
    TD_TIER=1
  else
    TD_TIER=0
  fi
}

# _td_cube_step VALUE — map 0-255 to the xterm cube steps 0-5
# (0, 95, 135, 175, 215, 255), nearest match.
_td_cube_step() {
  if (($1 < 48)); then
    printf '0'
  elif (($1 < 115)); then
    printf '1'
  else
    printf '%s' $((($1 - 35) / 40))
  fi
}

# td_hex_to_256 HEX — print the nearest xterm-256 color cube index.
td_hex_to_256() {
  local hex=${1#\#} r g b
  r=$(_td_cube_step $((16#${hex:0:2})))
  g=$(_td_cube_step $((16#${hex:2:2})))
  b=$(_td_cube_step $((16#${hex:4:2})))
  printf '%s\n' $((16 + 36 * r + 6 * g + b))
}

# td_theme_sgr — build TD_TC: one SGR sequence per theme key (foreground) for
# the current TD_TIER, plus [sel] (selection background), [bold], [dim], [reset].
td_theme_sgr() {
  local key hex
  TD_TC=([reset]=$'\e[0m' [bold]=$'\e[1m' [dim]=$'\e[2m')
  for key in "${TD_THEME_KEYS[@]}"; do
    [[ $key == selection ]] && continue
    hex=${TD_THEME[$key]#\#}
    case $TD_TIER in
      3) TD_TC[$key]=$'\e[38;2;'"$((16#${hex:0:2}));$((16#${hex:2:2}));$((16#${hex:4:2}))m" ;;
      2) TD_TC[$key]=$'\e[38;5;'"$(td_hex_to_256 "$hex")m" ;;
      1) TD_TC[$key]=$'\e['"${TD_THEME_ANSI[$key]}m" ;;
      *) TD_TC[$key]="" ;;
    esac
  done
  hex=${TD_THEME[selection]#\#}
  case $TD_TIER in
    3) TD_TC[sel]=$'\e[48;2;'"$((16#${hex:0:2}));$((16#${hex:2:2}));$((16#${hex:4:2}))m" ;;
    2) TD_TC[sel]=$'\e[48;5;'"$(td_hex_to_256 "$hex")m" ;;
    *) TD_TC[sel]=$'\e[7m' ;;
  esac
  if ((TD_TIER == 0)); then
    TD_TC[bold]="" TD_TC[dim]=""
    # Without colors the selection still needs to be visible.
    TD_TC[sel]=$'\e[7m'
  fi
}

# td_theme_import_kitty [CONF] — write the kitty colors as the user theme
# "kitty" (follows `include` lines). TD_RESULT: the written file.
td_theme_import_kitty() {
  local conf=${1:-${KITTY_CONFIG_DIRECTORY:-${XDG_CONFIG_HOME:-$HOME/.config}/kitty}/kitty.conf}
  TD_RESULT=""
  if [[ ! -f $conf ]]; then
    td_err "kitty config not found: $conf"
    return "$TD_E_NOTFOUND"
  fi
  local -A kc=()
  _td_kitty_read "$conf" kc 0 || return
  if [[ -z ${kc[foreground]:-} && -z ${kc[color4]:-} ]]; then
    td_err "no colors found in $conf (or its includes)"
    return "$TD_E_NOTFOUND"
  fi
  # Map the terminal palette onto theme roles; missing ones keep the defaults.
  local -A map=(
    [fg]="foreground color7" [muted]="color8 color0" [accent]="color4"
    [border]="color8 color0" [selection]="selection_background color0"
    [red]="color1" [orange]="color11 color3" [yellow]="color3" [green]="color2"
    [cyan]="color6" [blue]="color4" [magenta]="color5"
  )
  local key src value out tmp
  out="# Imported from $conf on $(date +%F)"$'\n'
  for key in "${TD_THEME_KEYS[@]}"; do
    value=${TD_THEME_DEFAULTS[$key]}
    for src in ${map[$key]}; do
      if [[ -n ${kc[$src]:-} ]]; then
        value=${kc[$src]}
        break
      fi
    done
    printf -v out '%s%-9s = %s\n' "$out" "$key" "$value"
  done
  if ! mkdir -p -- "$TD_CONFIG_DIR/themes"; then
    td_err "cannot create $TD_CONFIG_DIR/themes"
    return "$TD_E_ERR"
  fi
  tmp=$(mktemp -- "$TD_CONFIG_DIR/themes/.tmp.XXXXXXXX") || return "$TD_E_ERR"
  if ! printf '%s' "$out" >"$tmp" || ! mv -f -- "$tmp" "$TD_CONFIG_DIR/themes/kitty.theme"; then
    rm -f -- "$tmp"
    td_err "cannot write $TD_CONFIG_DIR/themes/kitty.theme"
    return "$TD_E_ERR"
  fi
  TD_RESULT=$TD_CONFIG_DIR/themes/kitty.theme
}

# _td_kitty_read FILE ARRAY DEPTH — collect `key #hex` color settings.
_td_kitty_read() {
  local _td_f=$1 _td_depth=$3 _td_line _td_key _td_val _td_inc
  local -n _td_kc=$2
  ((_td_depth > 4)) && return 0
  while IFS= read -r _td_line || [[ -n $_td_line ]]; do
    _td_line=${_td_line##+([[:space:]])}
    [[ -z $_td_line || $_td_line == '#'* ]] && continue
    _td_key=${_td_line%%[[:space:]]*}
    _td_val=${_td_line#"$_td_key"}
    _td_val=${_td_val##+([[:space:]])}
    _td_val=${_td_val%%+([[:space:]])}
    if [[ $_td_key == include ]]; then
      _td_inc=$_td_val
      [[ $_td_inc == /* ]] || _td_inc=${_td_f%/*}/$_td_inc
      [[ -f $_td_inc ]] && _td_kitty_read "$_td_inc" "$2" $((_td_depth + 1))
    elif [[ $_td_val =~ ^#[0-9A-Fa-f]{6}$ ]] \
      && [[ $_td_key =~ ^(foreground|background|selection_background|color([0-9]|1[0-5]))$ ]]; then
      _td_kc["$_td_key"]=${_td_val,,}
    fi
  done <"$_td_f"
}
