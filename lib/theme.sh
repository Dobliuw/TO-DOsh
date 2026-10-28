# shellcheck shell=bash disable=SC2034
# theme.sh — TUI color themes, terminal color tiers and theme import.
#
# A theme is a `key = #rrggbb` file. Built-in themes live in $TD_SHARE_DIR/themes;
# user themes in $TD_CONFIG_DIR/themes take precedence. Like nvim, the TUI
# paints a solid background: bg (main area), surface (top and status bars),
# overlay (dialogs), selection (selected row).
#
# Color tiers (TD_TIER): 3 truecolor, 2 = 256 colors, 1 = 16 colors, 0 = none.
# Only truecolor and 256 use the theme's exact colors and paint backgrounds;
# with 16 colors the terminal's own palette and background are used.
# SC2034: the tables are read by tui.sh.

readonly TD_THEME_KEYS=(bg surface overlay fg muted accent border selection
  red orange yellow green cyan blue magenta)

# Fallback for keys a theme does not define (Tokyo Night).
declare -grA TD_THEME_DEFAULTS=(
  [bg]="#1a1b26" [surface]="#16161e" [overlay]="#24283b"
  [fg]="#c0caf5" [muted]="#565f89" [accent]="#7aa2f7" [border]="#3b4261"
  [selection]="#283457" [red]="#f7768e" [orange]="#ff9e64" [yellow]="#e0af68"
  [green]="#9ece6a" [cyan]="#7dcfff" [blue]="#7aa2f7" [magenta]="#bb9af7"
)

# Background roles: never painted below 256 colors.
readonly TD_THEME_BG_KEYS=(bg surface overlay selection)

# 16-color fallback (SGR parameters); selection uses reverse video.
declare -grA TD_THEME_ANSI=(
  [fg]=39 [muted]=90 [accent]=34 [border]=90 [red]=31 [orange]=33 [yellow]=33
  [green]=32 [cyan]=36 [blue]=34 [magenta]=35 [bg]=30 [surface]=30 [overlay]=30
  [selection]=39
)

# TD_TC: foreground sequence per key; TD_TB: background sequence per key.
declare -gA TD_THEME=() TD_TC=() TD_TB=()
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

# _td_rgb HEX — print "r;g;b".
_td_rgb() {
  local hex=${1#\#}
  printf '%s;%s;%s' $((16#${hex:0:2})) $((16#${hex:2:2})) $((16#${hex:4:2}))
}

# _td_rgb_opaque HEX — "r;g;b" with blue moved by one step. Some terminals
# (kitty with background_opacity < 1) draw a cell transparent when its
# background equals the terminal's own background, even when the application
# paints it explicitly. Themes usually share that color with the terminal, so
# painted backgrounds are nudged by an invisible step to always stay solid.
_td_rgb_opaque() {
  local hex=${1#\#} b
  b=$((16#${hex:4:2}))
  if ((b < 255)); then b=$((b + 1)); else b=$((b - 1)); fi
  printf '%s;%s;%s' $((16#${hex:0:2})) $((16#${hex:2:2})) "$b"
}

# td_hex_mix HEX1 HEX2 PERCENT — print HEX1 moved PERCENT% towards HEX2.
td_hex_mix() {
  local a=${1#\#} b=${2#\#} p=$3 i out="#" x y
  for i in 0 2 4; do
    x=$((16#${a:i:2})) y=$((16#${b:i:2}))
    printf -v out '%s%02x' "$out" $((x + (y - x) * p / 100))
  done
  printf '%s\n' "$out"
}

# td_theme_sgr — build TD_TC (foregrounds) and TD_TB (backgrounds) for the
# current TD_TIER, plus [reset], [bold], [dim], [italic] and [rev] in TD_TC.
td_theme_sgr() {
  local key rgb
  TD_TC=([reset]=$'\e[0m' [bold]=$'\e[1m' [dim]=$'\e[2m' [italic]=$'\e[3m' [rev]=$'\e[7m')
  TD_TB=()
  for key in "${TD_THEME_KEYS[@]}"; do
    case $TD_TIER in
      3)
        rgb=$(_td_rgb "${TD_THEME[$key]}")
        TD_TC[$key]=$'\e[38;2;'"${rgb}m"
        TD_TB[$key]=$'\e[48;2;'"${rgb}m"
        if [[ " ${TD_THEME_BG_KEYS[*]} " == *" $key "* ]]; then
          TD_TB[$key]=$'\e[48;2;'"$(_td_rgb_opaque "${TD_THEME[$key]}")m"
        fi
        ;;
      2)
        rgb=$(td_hex_to_256 "${TD_THEME[$key]}")
        TD_TC[$key]=$'\e[38;5;'"${rgb}m"
        TD_TB[$key]=$'\e[48;5;'"${rgb}m"
        ;;
      1)
        TD_TC[$key]=$'\e['"${TD_THEME_ANSI[$key]}m"
        # No painted backgrounds: colored "pills" use reverse video instead.
        TD_TB[$key]=$'\e[7m'
        ;;
      *)
        TD_TC[$key]=""
        TD_TB[$key]=$'\e[7m'
        ;;
    esac
  done
  if ((TD_TIER <= 1)); then
    for key in "${TD_THEME_BG_KEYS[@]}"; do TD_TB[$key]=""; done
    TD_TC[bg]="" TD_TC[surface]="" TD_TC[overlay]=""
    TD_TB[selection]=$'\e[7m'
  fi
  if ((TD_TIER == 0)); then
    TD_TC[bold]="" TD_TC[dim]="" TD_TC[italic]=""
  fi
  # Kept for the previous name used by `todosh theme show`.
  TD_TC[sel]=${TD_TB[selection]}
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
    [bg]="background" [surface]="" [overlay]=""
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
    # Bars and dialogs: the background, slightly darker and lighter.
    if [[ $key == surface && -n ${kc[background]:-} ]]; then
      value=$(td_hex_mix "${kc[background]}" "#000000" 18)
    elif [[ $key == overlay && -n ${kc[background]:-} ]]; then
      value=$(td_hex_mix "${kc[background]}" "${kc[foreground]:-#ffffff}" 8)
    fi
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
