# shellcheck shell=bash disable=SC2034,SC1111,SC2153
# tui_ui.sh — building blocks of the interface: line composition, layers,
# keyboard input, text editing, dialogs, pickers and forms.
#
# Rendering model: the main screen is built in memory as positioned lines and
# written with one printf. Dialogs are "layers" drawn on top of a dimmed copy
# of the main screen. Nothing here forks per key press.
#
# Key handlers never read the terminal themselves (only _tui_read_key does), so
# dialogs and forms can be driven with synthetic keys in tests.
# SC2034: state is shared with tui.sh through globals. SC2153: TD_TB comes
# from theme.sh. SC1111: typographic quotes in messages are intended.

TUI_DIM=0   # 1 while drawing the main screen behind a dialog
TUI_BASE="" # the main screen, as positioned lines, ready to print
declare -ga TUI_OV=() TUI_LAYERS=()
declare -gA TUI_B=()

# --- colors ----------------------------------------------------------------

# _tui_colors — base sequences for each surface. Every segment of a line
# starts with one of these, so backgrounds survive color changes.
_tui_colors() {
  local r=${TD_TC[reset]}
  TUI_B=(
    [main]=$r${TD_TB[bg]}${TD_TC[fg]}
    [bar]=$r${TD_TB[surface]}${TD_TC[fg]}
    [modal]=$r${TD_TB[overlay]}${TD_TC[fg]}
    [field]=$r${TD_TB[bg]}${TD_TC[fg]}
    [sel]=$r${TD_TB[selection]}${TD_TC[fg]}
  )
  # background = terminal: keep the terminal's own background (and its
  # transparency) in the main area; bars and dialogs stay solid.
  if [[ ${TD_CONF[background]:-solid} == terminal ]]; then
    TUI_B[main]=$r${TD_TC[fg]}
    TUI_B[field]=$r${TD_TB[surface]}${TD_TC[fg]}
  fi
  TD_TC["strike"]=""
  if ((TD_TIER >= 2)); then
    TD_TC["strike"]=$'\e[9m'
  fi
}

# --- line composition --------------------------------------------------------
# _tl_start WIDTH BASE; _tl_add SGR TEXT...; _tl_end   -> the line is in TL.
# Text is cut to the width (with an ellipsis) and padded with BASE.

TL="" TLW=0 TLMAX=0 TLBASE=""

_tl_start() {
  TL="" TLW=0 TLMAX=$1 TLBASE=${2:-${TUI_B[main]}}
}

_tl_add() {
  local sgr=$1 text=$2 room=$((TLMAX - TLW))
  ((room > 0)) || return 0
  ((${#text} > room)) && text=${text:0:room-1}${TD_SYM[ellipsis]}
  # Behind a dialog everything is drawn in the border color: a dimming effect.
  ((TUI_DIM)) && sgr=${TD_TC[border]}
  TL+=$TLBASE$sgr$text
  TLW=$((TLW + ${#text}))
}

# _tl_pill FG BG TEXT — TEXT on a colored background (theme keys).
_tl_pill() {
  if ((TUI_DIM)); then
    _tl_add "" " $3 "
  else
    _tl_add "${TD_TB[$2]}${TD_TC[$1]}${TD_TC[bold]}" " $3 "
  fi
}

_tl_gap() {
  (($1 > 0)) || return 0
  local spaces
  printf -v spaces '%*s' "$1" ''
  _tl_add "" "$spaces"
}

# _tl_right TEXT_LEN — pad so that TEXT_LEN more columns end at the right edge.
_tl_right() {
  _tl_gap $((TLMAX - TLW - $1))
}

_tl_end() {
  local pad=$((TLMAX - TLW))
  ((pad > 0)) && printf -v TL '%s%s%*s' "$TL" "$TLBASE" "$pad" ''
  TLW=$TLMAX
}

# _tui_rule VAR CHAR N — CHAR repeated N times, into VAR.
_tui_rule() {
  local -n _td_rule=$1
  printf -v _td_rule '%*s' "$3" ''
  _td_rule=${_td_rule// /$2}
}

# _tui_wrap WIDTH TEXT — word-wrap TEXT, one output line per wrapped line.
_tui_wrap() {
  local width=$1 para line word
  local -a words
  while IFS= read -r para || [[ -n $para ]]; do
    line=""
    read -ra words <<<"$para"
    if ((${#words[@]} == 0)); then
      printf '\n'
      continue
    fi
    for word in "${words[@]}"; do
      while ((${#word} > width)); do
        [[ -n $line ]] && printf '%s\n' "$line" && line=""
        printf '%s\n' "${word:0:width}"
        word=${word:width}
      done
      if [[ -z $line ]]; then
        line=$word
      elif ((${#line} + 1 + ${#word} <= width)); then
        line+=" $word"
      else
        printf '%s\n' "$line"
        line=$word
      fi
    done
    [[ -n $line ]] && printf '%s\n' "$line"
  done <<<"$2"
}

# _tui_bar VAR DONE TOTAL WIDTH — a progress bar (▰▰▱▱ or ##..) into VAR.
_tui_bar() {
  local -n _td_bar=$1
  local _td_n=0 _td_i on=▰ off=▱
  ((TD_UNICODE)) || on="#" off="."
  (($3 > 0)) && _td_n=$(($2 * $4 / $3))
  _td_bar=""
  for ((_td_i = 0; _td_i < $4; _td_i++)); do
    if ((_td_i < _td_n)); then _td_bar+=$on; else _td_bar+=$off; fi
  done
}

# --- layers ------------------------------------------------------------------

# _tui_ov ROW COL TEXT — queue a positioned line for the current layer.
_tui_ov() {
  TUI_OV+=("$1;$2H$3")
}

# _tui_paint — print the main screen and every layer in one write.
_tui_paint() {
  local out=$TUI_BASE layer item
  # Graphics (the kitty logo) are sent once per screen, before the cells
  # that show them.
  if [[ -n ${TUI_LOGO_TX:-} ]] && ((! TUI_LOGO_SENT)); then
    out=$TUI_LOGO_TX$out
    TUI_LOGO_SENT=1
  fi
  TUI_OV=()
  for layer in "${TUI_LAYERS[@]}"; do "$layer"; done
  [[ ${#TUI_LAYERS[@]} -eq 0 ]] && declare -F _tui_toast_layer >/dev/null && _tui_toast_layer
  for item in "${TUI_OV[@]}"; do
    out+=$'\e['$item
  done
  printf '%s%s' "$out" "${TD_TC[reset]}"
}

# _tui_modal LAYER KEYFN — run a dialog: LAYER draws it, KEYFN handles a key
# and returns 0 (keep going), 1 (done) or 2 (cancelled). Returns 0 when done.
_tui_modal() {
  local layer=$1 keyfn=$2 rc
  if ((${#TUI_LAYERS[@]} == 0)); then
    TUI_DIM=1
    _tui_base_build
    TUI_DIM=0
  fi
  TUI_LAYERS+=("$layer")
  while :; do
    _tui_paint
    if ! _tui_read_key; then
      if ((TUI_RESIZED)); then
        _tui_size
        TUI_DIM=1
        _tui_base_build
        TUI_DIM=0
      fi
      continue
    fi
    [[ -n $TUI_KEY ]] || continue
    [[ $TUI_KEY == eof ]] && TUI_KEY=esc
    rc=0
    "$keyfn" "$TUI_KEY" || rc=$?
    ((rc == 0)) || break
  done
  unset 'TUI_LAYERS[-1]'
  ((rc == 1))
}

# _tui_box TOP LEFT WIDTH HEIGHT TITLE — draw an empty dialog frame; the
# content rows are TOP+1 .. TOP+HEIGHT-2 at columns LEFT+2 .. LEFT+WIDTH-3.
_tui_box() {
  local top=$1 left=$2 w=$3 h=$4 title=$5 rule row
  local tl="╭" tr="╮" bl="╰" br="╯" hz="─" vt="│"
  ((TD_UNICODE)) || tl="+" tr="+" bl="+" br="+" hz="-" vt="|"
  local b=${TUI_B[modal]}${TD_TC[accent]}
  local t=" $title "
  _tui_rule rule "$hz" $((w - 3 - ${#t}))
  _tui_ov "$top" "$left" "$b$tl$hz${TD_TC[bold]}$t${TUI_B[modal]}${TD_TC[accent]}$rule$tr"
  local blank
  printf -v blank '%*s' $((w - 2)) ''
  for ((row = 1; row < h - 1; row++)); do
    _tui_ov $((top + row)) "$left" "$b$vt${TUI_B[modal]}$blank$b$vt"
  done
  _tui_rule rule "$hz" $((w - 2))
  _tui_ov $((top + h - 1)) "$left" "$b$bl$rule$br"
}

# _tui_center VAR_TOP VAR_LEFT WIDTH HEIGHT — position for a centered box.
_tui_center() {
  local -n _td_top=$1 _td_left=$2
  _td_top=$(((TUI_ROWS - $4) / 2 + 1))
  _td_left=$(((TUI_COLS - $3) / 2 + 1))
  ((_td_top < 1)) && _td_top=1
  if ((_td_left < 1)); then _td_left=1; fi
}

# --- keyboard ----------------------------------------------------------------

# _tui_read_key [TIMEOUT] — read one key into TUI_KEY: a character, or a name
# (up, down, left, right, home, end, pgup, pgdn, delete, enter, space, tab,
# btab, backspace, esc, ctrl-X). Returns 1 on timeout; "eof" at end of input.
_tui_read_key() {
  local k c rest rc
  TUI_KEY=""
  IFS= read -rsn1 -t "${1:-1}" -d '' k </dev/tty
  rc=$?
  if ((rc > 128)); then
    return 1
  elif ((rc != 0)) && [[ -z $k ]]; then
    TUI_KEY=eof
    return 0
  fi
  if [[ $k == $'\e' ]]; then
    if ! IFS= read -rsn1 -t 0.03 -d '' c </dev/tty; then
      TUI_KEY=esc
      return 0
    fi
    if [[ $c == '[' || $c == O ]]; then
      rest=""
      while IFS= read -rsn1 -t 0.03 -d '' c </dev/tty; do
        rest+=$c
        [[ $c == [A-Za-z~] ]] && break
      done
      case $rest in
        A) TUI_KEY=up ;;
        B) TUI_KEY=down ;;
        C) TUI_KEY=right ;;
        D) TUI_KEY=left ;;
        H | 1~ | 7~) TUI_KEY=home ;;
        F | 4~ | 8~) TUI_KEY=end ;;
        5~) TUI_KEY=pgup ;;
        6~) TUI_KEY=pgdn ;;
        3~) TUI_KEY=delete ;;
        Z) TUI_KEY=btab ;;
        *) TUI_KEY="" ;;
      esac
    else
      TUI_KEY=esc
    fi
    return 0
  fi
  case $k in
    $'\n' | $'\r') TUI_KEY=enter ;;
    ' ') TUI_KEY=space ;;
    $'\t') TUI_KEY=tab ;;
    $'\x7f' | $'\b') TUI_KEY=backspace ;;
    $'\x01') TUI_KEY=ctrl-a ;;
    $'\x03') TUI_KEY=ctrl-c ;;
    $'\x04') TUI_KEY=ctrl-d ;;
    $'\x05') TUI_KEY=ctrl-e ;;
    $'\x0b') TUI_KEY=ctrl-k ;;
    $'\x0c') TUI_KEY=ctrl-l ;;
    $'\x0e') TUI_KEY=ctrl-n ;;
    $'\x10') TUI_KEY=ctrl-p ;;
    $'\x13') TUI_KEY=ctrl-s ;;
    $'\x15') TUI_KEY=ctrl-u ;;
    $'\x17') TUI_KEY=ctrl-w ;;
    $'\x1a') TUI_KEY=ctrl-z ;;
    *) TUI_KEY=$k ;;
  esac
}

# _tui_is_char KEY — a printable character (not a key name).
_tui_is_char() {
  [[ $1 == space ]] || { ((${#1} == 1)) && [[ $1 != [[:cntrl:]] ]]; }
}

# --- text editing --------------------------------------------------------------

# _tui_edit VALUE_VAR CURSOR_VAR KEY — apply KEY to a single-line text and its
# cursor. Returns 1 when KEY is not a text-editing key.
_tui_edit() {
  local -n _td_tv=$1 _td_tc=$2
  local _td_k=$3 _td_left
  case $_td_k in
    left) ((_td_tc > 0)) && _td_tc=$((_td_tc - 1)) ;;
    right) ((_td_tc < ${#_td_tv})) && _td_tc=$((_td_tc + 1)) ;;
    home | ctrl-a) _td_tc=0 ;;
    end | ctrl-e) _td_tc=${#_td_tv} ;;
    backspace)
      if ((_td_tc > 0)); then
        _td_tv=${_td_tv:0:_td_tc-1}${_td_tv:_td_tc}
        _td_tc=$((_td_tc - 1))
      fi
      ;;
    delete) _td_tv=${_td_tv:0:_td_tc}${_td_tv:_td_tc+1} ;;
    ctrl-u)
      _td_tv=${_td_tv:_td_tc}
      _td_tc=0
      ;;
    ctrl-k) _td_tv=${_td_tv:0:_td_tc} ;;
    ctrl-w)
      _td_left=${_td_tv:0:_td_tc}
      _td_left=${_td_left%%+([[:space:]])}
      _td_left=${_td_left%%+([^[:space:]])}
      _td_tv=$_td_left${_td_tv:_td_tc}
      _td_tc=${#_td_left}
      ;;
    *)
      _tui_is_char "$_td_k" || return 1
      [[ $_td_k == space ]] && _td_k=" "
      _td_tv=${_td_tv:0:_td_tc}$_td_k${_td_tv:_td_tc}
      _td_tc=$((_td_tc + 1))
      ;;
  esac
  return 0
}

# _tl_input VALUE CURSOR WIDTH FOCUSED [PLACEHOLDER] — a text box segment of
# exactly WIDTH columns, scrolled so the cursor is visible.
_tl_input() {
  local value=$1 cur=$2 width=$3 focused=$4 ph=${5:-} start=0 shown
  local base=${TUI_B[field]}
  local save=$TLBASE
  TLBASE=$base
  if [[ -z $value && -n $ph ]]; then
    # Empty: the placeholder, behind the cursor when focused.
    _tl_add "" " "
    if ((focused)); then _tl_add "${TD_TC[rev]}" " "; else _tl_add "" " "; fi
    td_truncate ph "$ph" $((width - 3))
    _tl_add "${TD_TC[muted]}${TD_TC[italic]}" "$ph"
    _tl_gap $((width - 2 - ${#ph}))
    TLBASE=$save
    return
  fi
  ((cur > width - 3)) && start=$((cur - width + 3))
  shown=${value:start:width-2}
  if ((focused)); then
    local before=${shown:0:cur-start} at=${shown:cur-start:1} after=${shown:cur-start+1}
    [[ -z $at ]] && at=" "
    _tl_add "" " $before"
    _tl_add "${TD_TC[rev]}" "$at"
    _tl_add "" "$after"
    _tl_gap $((width - 2 - ${#before} - 1 - ${#after}))
    _tl_add "" " "
  else
    _tl_add "" " $shown"
    _tl_gap $((width - 1 - ${#shown}))
  fi
  TLBASE=$save
}

# --- toast -------------------------------------------------------------------

TUI_TOAST="" TUI_TOAST_KIND=ok TUI_TOAST_UNTIL=0

# _tui_toast KIND TEXT — show TEXT for a few seconds (KIND: ok | error | info).
_tui_toast() {
  TUI_TOAST_KIND=$1
  TUI_TOAST=$2
  local secs=3
  [[ $1 == error ]] && secs=5
  printf -v TUI_TOAST_UNTIL '%(%s)T' -1
  TUI_TOAST_UNTIL=$((TUI_TOAST_UNTIL + secs))
}

_tui_toast_layer() {
  [[ -n $TUI_TOAST ]] || return 0
  local now icon color
  printf -v now '%(%s)T' -1
  if ((now > TUI_TOAST_UNTIL)); then
    TUI_TOAST=""
    return 0
  fi
  case $TUI_TOAST_KIND in
    error) icon=${TD_SYM[error]} color=red ;;
    info) icon=${TD_SYM[info]} color=accent ;;
    *) icon=${TD_SYM[ok]} color=green ;;
  esac
  local text="$icon  $TUI_TOAST" w
  w=$((${#text} + 4))
  ((w > TUI_COLS - 4)) && w=$((TUI_COLS - 4))
  _tl_start "$w" "${TUI_B[modal]}"
  _tl_add "${TD_TB[$color]}" " "
  _tl_add "${TD_TC[$color]}${TD_TC[bold]}" " $icon "
  _tl_add "${TD_TC[fg]}" " $TUI_TOAST"
  _tl_end
  _tui_ov 3 $((TUI_COLS - w - 1)) "$TL${TD_TC[reset]}"
}

# --- confirm -------------------------------------------------------------------

CF_MSG="" CF_YES="" CF_SEL=1

# _tui_confirm MESSAGE [YES_LABEL] — Yes/No dialog; succeeds on Yes.
_tui_confirm() {
  CF_MSG=$1 CF_YES=${2:-Yes} CF_SEL=1
  _tui_modal _tui_confirm_layer _tui_confirm_key
}

_tui_confirm_layer() {
  local w=$((${#CF_MSG} + 8)) top left
  ((w < 36)) && w=36
  ((w > TUI_COLS - 4)) && w=$((TUI_COLS - 4))
  _tui_center top left "$w" 7
  _tui_box "$top" "$left" "$w" 7 "Confirm"
  _tl_start $((w - 4)) "${TUI_B[modal]}"
  _tl_add "${TD_TC[fg]}${TD_TC[bold]}" "$CF_MSG"
  _tl_end
  _tui_ov $((top + 2)) $((left + 2)) "$TL"
  _tl_start $((w - 4)) "${TUI_B[modal]}"
  local yes=" $CF_YES " no=" No "
  _tl_right $((${#yes} + ${#no} + 2))
  if ((CF_SEL == 0)); then _tl_pill bg red "$CF_YES"; else _tl_add "${TD_TC[muted]}" "$yes"; fi
  _tl_gap 2
  if ((CF_SEL == 1)); then _tl_pill bg accent "No"; else _tl_add "${TD_TC[muted]}" "$no"; fi
  _tl_end
  _tui_ov $((top + 4)) $((left + 2)) "$TL"
}

_tui_confirm_key() {
  case $1 in
    y | Y) return 1 ;;
    n | N | esc | q | ctrl-c) return 2 ;;
    left | right | tab | btab | h | l) CF_SEL=$((1 - CF_SEL)) ;;
    enter | space) ((CF_SEL == 0)) && return 1 || return 2 ;;
  esac
  return 0
}

# --- single-line input dialog --------------------------------------------------

IN_TITLE="" IN_LABEL="" IN_VAL="" IN_CUR=0 IN_HINT="" IN_EDITOR=0 IN_ALLOW_EMPTY=0

# _tui_input TITLE LABEL INITIAL [HINT] — ask for a line of text; the result is
# in TUI_INPUT. Ctrl-E opens $EDITOR when IN_EDITOR=1 (set before calling).
# Returns 1 when cancelled or (unless IN_ALLOW_EMPTY=1) left empty.
_tui_input() {
  IN_TITLE=$1 IN_LABEL=$2 IN_VAL=${3:-} IN_HINT=${4:-}
  IN_CUR=${#IN_VAL}
  local ok=0
  _tui_modal _tui_input_layer _tui_input_key && ok=1
  TUI_INPUT=$IN_VAL
  IN_EDITOR=0
  local empty=$IN_ALLOW_EMPTY
  IN_ALLOW_EMPTY=0
  ((ok)) || return 1
  ((empty)) || [[ -n ${IN_VAL//[[:space:]]/} ]]
}

_tui_input_layer() {
  local w=$((TUI_COLS * 2 / 3)) top left h=8
  ((w < 40)) && w=$((TUI_COLS - 4))
  ((w > 90)) && w=90
  _tui_center top left "$w" "$h"
  _tui_box "$top" "$left" "$w" "$h" "$IN_TITLE"
  _tl_start $((w - 4)) "${TUI_B[modal]}"
  _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "$IN_LABEL"
  _tl_end
  _tui_ov $((top + 2)) $((left + 2)) "$TL"
  _tl_start $((w - 4)) "${TUI_B[modal]}"
  _tl_input "$IN_VAL" "$IN_CUR" $((w - 4)) 1
  _tl_end
  _tui_ov $((top + 3)) $((left + 2)) "$TL"
  _tl_start $((w - 4)) "${TUI_B[modal]}"
  local hint="⏎ confirm · Esc cancel"
  ((IN_EDITOR)) && hint+=" · Ctrl-E editor"
  [[ -n $IN_HINT ]] && hint="$IN_HINT · $hint"
  _tl_add "${TD_TC[muted]}" "$hint"
  _tl_end
  _tui_ov $((top + 5)) $((left + 2)) "$TL"
}

_tui_input_key() {
  case $1 in
    enter) return 1 ;;
    esc | ctrl-c) return 2 ;;
    ctrl-e)
      if ((IN_EDITOR)); then
        _tui_edit_external IN_VAL
        IN_CUR=${#IN_VAL}
        [[ -n ${IN_VAL//[[:space:]]/} ]] && return 1
      else
        _tui_edit IN_VAL IN_CUR end
      fi
      ;;
    *) _tui_edit IN_VAL IN_CUR "$1" ;;
  esac
  return 0
}

# _tui_edit_external VAR — edit the text in VAR with $EDITOR (leaves the screen).
_tui_edit_external() {
  local -n _td_ext=$1
  local _td_tmp
  _td_tmp=$(mktemp --suffix=.md -t todosh-edit.XXXXXXXX) || return 1
  printf '%s\n' "$_td_ext" >"$_td_tmp"
  _tui_leave
  if TD_QUIET_ERRORS=0 td_run_editor "$_td_tmp"; then
    _td_ext=$(<"$_td_tmp")
  fi
  rm -f -- "$_td_tmp"
  _tui_enter
  _tui_size
  TUI_DIM=1
  _tui_base_build
  TUI_DIM=0
}

# --- picker --------------------------------------------------------------------
# Items are "VALUE<US>LABEL<US>DETAIL<US>STYLE" (STYLE: a theme color key, or
# empty). Typing filters; with PK_CREATE=1 a typed name that matches nothing
# can be created. PK_MULTI=1 toggles items with space and returns a list.

declare -ga PK_ITEMS=() PK_VIEW=() TUI_PICKED_LIST=()
# Keys of PK_ON are "k" + value: an associative array cannot have an empty key.
declare -gA PK_ON=()
PK_TITLE="" PK_FILTER="" PK_FCUR=0 PK_SEL=0 PK_TOP=0 PK_MULTI=0 PK_CREATE=0
PK_ONMOVE="" TUI_PICKED=""

# _tui_pick TITLE ITEM... — choose one item; its VALUE goes to TUI_PICKED.
# Set PK_MULTI, PK_CREATE, PK_ONMOVE (function called with the highlighted
# value), and TUI_PICK_INIT (initially highlighted / selected values,
# space-separated) before calling. Returns 1 when cancelled.
TUI_PICK_INIT=""
_tui_pick() {
  PK_TITLE=$1
  shift
  PK_ITEMS=("$@") PK_FILTER="" PK_FCUR=0 PK_SEL=0 PK_TOP=0 PK_ON=()
  local v init=" $TUI_PICK_INIT "
  local item
  for item in "${PK_ITEMS[@]}"; do
    v=${item%%$'\x1f'*}
    if [[ -n $v && $init == *" $v "* ]]; then
      PK_ON[k$v]=1
    fi
  done
  _tui_pick_filter
  if ((! PK_MULTI)); then
    local i
    for i in "${!PK_VIEW[@]}"; do
      [[ ${PK_VIEW[i]%%$'\x1f'*} == "${TUI_PICK_INIT%% *}" ]] && PK_SEL=$i && break
    done
  fi
  local ok=1
  _tui_modal _tui_pick_layer _tui_pick_key || ok=0
  TUI_PICK_INIT="" PK_ONMOVE=""
  local multi=$PK_MULTI
  PK_MULTI=0 PK_CREATE=0
  ((ok)) || return 1
  if ((multi)); then
    TUI_PICKED_LIST=()
    for item in "${PK_ITEMS[@]}"; do
      v=${item%%$'\x1f'*}
      [[ -v PK_ON[k$v] ]] && TUI_PICKED_LIST+=("$v")
    done
    # Created entries are not in PK_ITEMS.
    for v in "${!PK_ON[@]}"; do
      v=${v#k}
      [[ " ${TUI_PICKED_LIST[*]} " == *" $v "* ]] || TUI_PICKED_LIST+=("$v")
    done
  fi
  return 0
}

_tui_pick_filter() {
  local item label q=${PK_FILTER,,}
  PK_VIEW=()
  for item in "${PK_ITEMS[@]}"; do
    label=${item#*$'\x1f'}
    label=${label%%$'\x1f'*}
    [[ -z $q || ${label,,} == *"$q"* || ${item%%$'\x1f'*} == *"$q"* ]] && PK_VIEW+=("$item")
  done
  if ((PK_CREATE)) && [[ -n $PK_FILTER ]]; then
    local exact=0
    for item in "${PK_ITEMS[@]}"; do
      [[ ${item%%$'\x1f'*} == "$PK_FILTER" ]] && exact=1
    done
    # Last, so Enter picks the best existing match first.
    ((exact)) || PK_VIEW+=("$PK_FILTER"$'\x1f'"Create “$PK_FILTER”"$'\x1f'"create"$'\x1f'"green")
  fi
  PK_SEL=0 PK_TOP=0
}

_tui_pick_layer() {
  local w=56 h top left rows n=${#PK_VIEW[@]}
  ((w > TUI_COLS - 4)) && w=$((TUI_COLS - 4))
  rows=$((n < 3 ? 3 : n))
  ((rows > TUI_ROWS - 10)) && rows=$((TUI_ROWS - 10))
  ((rows < 3)) && rows=3
  h=$((rows + 5))
  _tui_center top left "$w" "$h"
  _tui_box "$top" "$left" "$w" "$h" "$PK_TITLE"
  local iw=$((w - 4))
  _tl_start "$iw" "${TUI_B[modal]}"
  _tl_add "${TD_TC[accent]}" "${TD_SYM[search]} "
  _tl_input "$PK_FILTER" "$PK_FCUR" $((iw - 2)) 1
  _tl_end
  _tui_ov $((top + 1)) $((left + 2)) "$TL"

  ((PK_SEL < PK_TOP)) && PK_TOP=$PK_SEL
  ((PK_SEL >= PK_TOP + rows)) && PK_TOP=$((PK_SEL - rows + 1))
  local r i item value label detail style base mark
  for ((r = 0; r < rows; r++)); do
    i=$((PK_TOP + r))
    base=${TUI_B[modal]}
    ((i == PK_SEL)) && base=${TUI_B[sel]}
    _tl_start "$iw" "$base"
    if ((i < n)); then
      item=${PK_VIEW[i]}
      IFS=$'\x1f' read -r value label detail style <<<"$item"
      if ((i == PK_SEL)); then _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "${TD_SYM[bar]} "; else _tl_add "" "  "; fi
      if ((PK_MULTI)); then
        mark=${TD_SYM[unchecked]}
        [[ -v PK_ON[k$value] ]] && mark=${TD_SYM[checked]}
        _tl_add "${TD_TC[green]}" "$mark "
      fi
      _tl_add "${TD_TC[${style:-fg}]:-${TD_TC[fg]}}" "$label"
      if [[ -n $detail ]]; then
        _tl_right $((${#detail} + 1))
        _tl_add "${TD_TC[muted]}" "$detail "
      fi
    elif ((n == 0 && r == 0)); then
      _tl_add "${TD_TC[muted]}${TD_TC[italic]}" "  nothing matches"
    fi
    _tl_end
    _tui_ov $((top + 2 + r)) $((left + 2)) "$TL"
  done
  _tl_start "$iw" "${TUI_B[modal]}"
  local hint="↑↓ move · ⏎ choose · Esc cancel · type to filter"
  ((PK_MULTI)) && hint="↑↓ move · Space toggle · ⏎ done · Esc cancel · type to filter"
  _tl_add "${TD_TC[muted]}" "$hint"
  _tl_end
  _tui_ov $((top + h - 2)) $((left + 2)) "$TL"
}

_tui_pick_key() {
  local n=${#PK_VIEW[@]} v
  case $1 in
    esc | ctrl-c) return 2 ;;
    up | ctrl-p) ((PK_SEL > 0)) && PK_SEL=$((PK_SEL - 1)) ;;
    down | ctrl-n | tab) ((PK_SEL < n - 1)) && PK_SEL=$((PK_SEL + 1)) ;;
    pgup) PK_SEL=$((PK_SEL > 8 ? PK_SEL - 8 : 0)) ;;
    pgdn) PK_SEL=$((PK_SEL + 8 < n ? PK_SEL + 8 : (n > 0 ? n - 1 : 0))) ;;
    ctrl-s) ((PK_MULTI)) && return 1 ;;
    enter)
      if ((n == 0)); then
        ((PK_MULTI)) && return 1
        return 0
      fi
      v=${PK_VIEW[PK_SEL]%%$'\x1f'*}
      if ((PK_MULTI)); then
        # Enter on a "create" row, or on a filtered item, means "this one":
        # check it and finish. Space checks several without leaving.
        [[ -n $PK_FILTER ]] && PK_ON[k$v]=1
        return 1
      fi
      TUI_PICKED=$v
      return 1
      ;;
    space)
      if ((PK_MULTI)); then
        ((n > 0)) || return 0
        v=${PK_VIEW[PK_SEL]%%$'\x1f'*}
        if [[ -v PK_ON[k$v] ]]; then unset "PK_ON[k$v]"; else PK_ON[k$v]=1; fi
        return 0
      fi
      _tui_edit PK_FILTER PK_FCUR space && _tui_pick_filter
      ;;
    *)
      _tui_edit PK_FILTER PK_FCUR "$1" && [[ $1 != left && $1 != right ]] && _tui_pick_filter
      ;;
  esac
  if [[ -n $PK_ONMOVE ]] && ((${#PK_VIEW[@]})); then
    "$PK_ONMOVE" "${PK_VIEW[PK_SEL]%%$'\x1f'*}"
  fi
  return 0
}

# --- scrollable text view --------------------------------------------------------
# Lines are "STYLE<US>TEXT" (STYLE: a theme color key, "head" or empty).

declare -ga VW_LINES=()
VW_TITLE="" VW_TOP=0

_tui_view() {
  VW_TITLE=$1
  shift
  VW_LINES=("$@") VW_TOP=0
  _tui_modal _tui_view_layer _tui_view_key || true
}

_tui_view_layer() {
  local w=$((TUI_COLS - 8)) h=$((TUI_ROWS - 4)) top left
  ((w > 100)) && w=100
  _tui_center top left "$w" "$h"
  _tui_box "$top" "$left" "$w" "$h" "$VW_TITLE"
  local rows=$((h - 4)) r i style text n=${#VW_LINES[@]}
  ((VW_TOP > n - rows)) && VW_TOP=$((n - rows))
  ((VW_TOP < 0)) && VW_TOP=0
  for ((r = 0; r < rows; r++)); do
    i=$((VW_TOP + r))
    _tl_start $((w - 4)) "${TUI_B[modal]}"
    if ((i < n)); then
      style=${VW_LINES[i]%%$'\x1f'*}
      text=${VW_LINES[i]#*$'\x1f'}
      case $style in
        head) _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "$text" ;;
        key)
          _tl_add "${TD_TC[yellow]}${TD_TC[bold]}" "${text%%$'\x1e'*}"
          _tl_add "${TD_TC[fg]}" "${text#*$'\x1e'}"
          ;;
        "") _tl_add "${TD_TC[fg]}" "$text" ;;
        *) _tl_add "${TD_TC[$style]:-}" "$text" ;;
      esac
    fi
    _tl_end
    _tui_ov $((top + 1 + r)) $((left + 2)) "$TL"
  done
  _tl_start $((w - 4)) "${TUI_B[modal]}"
  local more=""
  ((n > rows)) && more="$((VW_TOP + 1))-$((VW_TOP + rows < n ? VW_TOP + rows : n)) of $n · "
  _tl_add "${TD_TC[muted]}" "${more}j/k scroll · Esc close"
  _tl_end
  _tui_ov $((top + h - 2)) $((left + 2)) "$TL"
}

_tui_view_key() {
  case $1 in
    esc | q | enter | ctrl-c | '?') return 2 ;;
    j | down) VW_TOP=$((VW_TOP + 1)) ;;
    k | up) ((VW_TOP > 0)) && VW_TOP=$((VW_TOP - 1)) ;;
    pgdn | space | ctrl-d) VW_TOP=$((VW_TOP + TUI_ROWS / 2)) ;;
    pgup | ctrl-u) VW_TOP=$((VW_TOP > TUI_ROWS / 2 ? VW_TOP - TUI_ROWS / 2 : 0)) ;;
    g | home) VW_TOP=0 ;;
    G | end) VW_TOP=${#VW_LINES[@]} ;;
  esac
  return 0
}

# --- forms -----------------------------------------------------------------------
# A form is a list of fields. Types:
#   text     single-line text                      F_VAL
#   segment  one of F_OPTS (space-separated); ←/→   F_VAL
#   check    on/off with Space                     F_VAL (0/1)
#   pick     chosen from a picker run by F_OPTS (a function name), which sets
#            F_VAL and F_SHOW (the label shown)
#   date     text with a live preview of the parsed date; ⏎ opens presets
#   notes    multi-line text; ⏎ or Ctrl-E opens $EDITOR
#   button   F_OPTS = submit | cancel
# Keys: Tab/↓ next, Shift-Tab/↑ previous, Ctrl-S save, Esc cancel.

declare -ga F_KEYS=()
declare -gA F_TYPE=() F_LABEL=() F_VAL=() F_CUR=() F_OPTS=() F_SHOW=() F_HINT=() F_ORIG=()
F_TITLE="" F_FOCUS=0 F_ERR="" F_ERR_FIELD="" F_VALIDATE=""

# _tui_form_reset TITLE VALIDATE_FN — start a new form. VALIDATE_FN is called
# on save; it returns non-zero after setting F_ERR (and F_ERR_FIELD).
_tui_form_reset() {
  F_KEYS=() F_TYPE=() F_LABEL=() F_VAL=() F_CUR=() F_OPTS=() F_SHOW=() F_HINT=() F_ORIG=()
  F_TITLE=$1 F_VALIDATE=${2:-} F_FOCUS=0 F_ERR="" F_ERR_FIELD=""
}

# _tui_form_add KEY TYPE LABEL VALUE [OPTS] [HINT]
_tui_form_add() {
  F_KEYS+=("$1")
  F_TYPE[$1]=$2 F_LABEL[$1]=$3 F_VAL[$1]=$4 F_OPTS[$1]=${5:-} F_HINT[$1]=${6:-}
  F_CUR[$1]=${#4}
  F_ORIG[$1]=$4
  F_SHOW[$1]=$4
}

# _tui_form_run — show the form; succeeds when it was submitted and validated.
_tui_form_run() {
  _tui_modal _tui_form_layer _tui_form_key
}

_tui_form_dirty() {
  local k
  for k in "${F_KEYS[@]}"; do
    [[ ${F_VAL[$k]} == "${F_ORIG[$k]}" ]] || return 0
  done
  return 1
}

# _tui_form_key KEY — 0 continue, 1 submitted, 2 cancelled.
_tui_form_key() {
  local key=${F_KEYS[F_FOCUS]} type n=${#F_KEYS[@]}
  type=${F_TYPE[$key]}
  case $1 in
    esc | ctrl-c)
      if _tui_form_dirty && ! _tui_confirm "Discard your changes?" "Discard"; then
        return 0
      fi
      return 2
      ;;
    tab | down | ctrl-n)
      F_FOCUS=$(((F_FOCUS + 1) % n))
      return 0
      ;;
    btab | up | ctrl-p)
      F_FOCUS=$(((F_FOCUS - 1 + n) % n))
      return 0
      ;;
    ctrl-s)
      _tui_form_submit
      return
      ;;
  esac
  case $type in
    text)
      if [[ $1 == enter ]]; then
        F_FOCUS=$(((F_FOCUS + 1) % n))
      else
        _tui_edit "F_VAL[$key]" "F_CUR[$key]" "$1"
      fi
      ;;
    date)
      if [[ $1 == enter ]]; then
        _tui_pick_date "$key"
      else
        _tui_edit "F_VAL[$key]" "F_CUR[$key]" "$1"
      fi
      ;;
    segment)
      local -a opts
      read -ra opts <<<"${F_OPTS[$key]}"
      local i
      for i in "${!opts[@]}"; do [[ ${opts[i]} == "${F_VAL[$key]}" ]] && break; done
      case $1 in
        left | h) ((i > 0)) && F_VAL[$key]=${opts[i - 1]} ;;
        right | l | space) ((i < ${#opts[@]} - 1)) && F_VAL[$key]=${opts[i + 1]} ;;
        enter) F_FOCUS=$(((F_FOCUS + 1) % n)) ;;
        *)
          # The first letter of an option selects it.
          local o
          for o in "${opts[@]}"; do
            [[ ${o:0:1} == "$1" ]] && F_VAL[$key]=$o && break
          done
          ;;
      esac
      ;;
    check)
      case $1 in
        space | enter | x) F_VAL[$key]=$((1 - F_VAL[$key])) ;;
      esac
      ;;
    pick)
      if [[ $1 == enter || $1 == space ]] || _tui_is_char "$1"; then
        "${F_OPTS[$key]}" "$key"
      fi
      ;;
    notes)
      if [[ $1 == enter || $1 == ctrl-e ]]; then
        _tui_edit_external "F_VAL[$key]"
      fi
      ;;
    button)
      if [[ $1 == enter || $1 == space ]]; then
        if [[ ${F_OPTS[$key]} == submit ]]; then
          _tui_form_submit
          return
        fi
        return 2
      fi
      [[ $1 == left ]] && F_FOCUS=$(((F_FOCUS - 1 + n) % n))
      [[ $1 == right ]] && F_FOCUS=$(((F_FOCUS + 1) % n))
      ;;
  esac
  return 0
}

_tui_form_submit() {
  F_ERR="" F_ERR_FIELD=""
  if [[ -n $F_VALIDATE ]] && ! "$F_VALIDATE"; then
    local i
    for i in "${!F_KEYS[@]}"; do
      [[ ${F_KEYS[i]} == "$F_ERR_FIELD" ]] && F_FOCUS=$i
    done
    return 0
  fi
  return 1
}

# _tui_pick_date KEY — presets for a date field.
_tui_pick_date() {
  local key=$1 d label
  local -a items=()
  local p
  for p in today tomorrow "+2d" mon tue wed thu fri sat sun "+1w" "+2w" "+1m"; do
    td_due_parse d "$p" 2>/dev/null || continue
    label=$(LC_ALL=C date -d "$d" '+%a %d %b')
    case $p in
      +2d) p="in 2 days" ;;
      +1w) p="in a week" ;;
      +2w) p="in 2 weeks" ;;
      +1m) p="in a month" ;;
    esac
    items+=("$d"$'\x1f'"$p"$'\x1f'"$label"$'\x1f')
  done
  items+=(""$'\x1f'"No date"$'\x1f'$'\x1f'"muted")
  TUI_PICK_INIT=${F_VAL[$key]}
  if _tui_pick "Due date" "${items[@]}"; then
    F_VAL[$key]=$TUI_PICKED
    F_CUR[$key]=${#TUI_PICKED}
  fi
}

# Date previews are cached: parsing forks `date`.
declare -gA TUI_DATE_CACHE=()
_tui_date_preview() {
  local -n _td_prev=$1
  # Keys are prefixed: an associative array cannot have an empty key.
  local _td_in=$2 _td_d _td_key="k$2"
  if [[ -v TUI_DATE_CACHE[$_td_key] ]]; then
    _td_prev=${TUI_DATE_CACHE[$_td_key]}
    return
  fi
  if [[ -z ${_td_in//[[:space:]]/} ]]; then
    _td_prev="ok"$'\x1f'"no date"
  elif TD_QUIET_ERRORS=1 td_due_parse _td_d "$_td_in" 2>/dev/null; then
    _td_prev="ok"$'\x1f'"${TD_SYM[arrow]} $(LC_ALL=C date -d "$_td_d" '+%a %d %b %Y')"
  else
    _td_prev="bad"$'\x1f'"not a date (try: fri, +3d, 2026-11-03)"
  fi
  TUI_DATE_CACHE[$_td_key]=$_td_prev
}

_tui_form_layer() {
  local n=${#F_KEYS[@]} w=74 top left
  ((w > TUI_COLS - 4)) && w=$((TUI_COLS - 4))
  # Rows: title gap, fields (buttons share one row), gap, error, hints.
  local nf=0 k
  for k in "${F_KEYS[@]}"; do [[ ${F_TYPE[$k]} == button ]] || nf=$((nf + 1)); done
  local h=$((nf + 7))
  _tui_center top left "$w" "$h"
  _tui_box "$top" "$left" "$w" "$h" "$F_TITLE"
  local iw=$((w - 4)) lw=12 row=$((top + 2)) i key type focused fw
  fw=$((iw - lw - 2))
  local buttons_row=0
  for i in "${!F_KEYS[@]}"; do
    key=${F_KEYS[i]}
    type=${F_TYPE[$key]}
    focused=0
    ((i == F_FOCUS)) && focused=1
    if [[ $type == button ]]; then
      buttons_row=1
      continue
    fi
    _tl_start "$iw" "${TUI_B[modal]}"
    if ((focused)); then
      _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "${TD_SYM[bar]}"
      _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "${F_LABEL[$key]}"
    else
      _tl_add "" " "
      _tl_add "${TD_TC[muted]}" "${F_LABEL[$key]}"
    fi
    _tl_gap $((lw - ${#F_LABEL[$key]}))
    case $type in
      text) _tl_input "${F_VAL[$key]}" "${F_CUR[$key]}" "$fw" "$focused" "${F_HINT[$key]}" ;;
      date)
        local prev pw
        _tui_date_preview prev "${F_VAL[$key]}"
        pw=$((fw / 2))
        _tl_input "${F_VAL[$key]}" "${F_CUR[$key]}" "$pw" "$focused" "${F_HINT[$key]}"
        if [[ -z ${F_VAL[$key]//[[:space:]]/} ]]; then
          _tl_add "${TD_TC[muted]}" "  ${prev#*$'\x1f'}"
        elif [[ ${prev%%$'\x1f'*} == ok ]]; then
          _tl_add "${TD_TC[green]}" "  ${prev#*$'\x1f'}"
        else
          _tl_add "${TD_TC[red]}" "  ${prev#*$'\x1f'}"
        fi
        ;;
      segment)
        local -a opts
        local o
        read -ra opts <<<"${F_OPTS[$key]}"
        _tl_add "" " "
        for o in "${opts[@]}"; do
          if [[ $o == "${F_VAL[$key]}" ]]; then
            _tl_pill bg "$(_tui_option_color "$key" "$o")" "$(_tui_option_label "$key" "$o")"
          else
            _tl_add "${TD_TC[muted]}" " $(_tui_option_label "$key" "$o") "
          fi
          _tl_add "" " "
        done
        ;;
      check)
        if ((F_VAL[$key])); then
          _tl_add "${TD_TC[green]}${TD_TC[bold]}" " ${TD_SYM[checked]} "
        else
          _tl_add "${TD_TC[muted]}" " ${TD_SYM[unchecked]} "
        fi
        _tl_add "${TD_TC[fg]}" "${F_HINT[$key]}"
        ;;
      pick)
        local shown=${F_SHOW[$key]:-${F_HINT[$key]}}
        local base=$TLBASE
        TLBASE=${TUI_B[field]}
        _tl_add "${TD_TC[fg]}" " $shown"
        _tl_gap $((fw - 3 - ${#shown}))
        _tl_add "${TD_TC[accent]}" "${TD_SYM[down]} "
        TLBASE=$base
        ;;
      notes)
        local first=${F_VAL[$key]%%$'\n'*} more=""
        [[ ${F_VAL[$key]} == *$'\n'* ]] && more=" …"
        local base=$TLBASE
        TLBASE=${TUI_B[field]}
        if [[ -z ${F_VAL[$key]} ]]; then
          _tl_add "${TD_TC[muted]}${TD_TC[italic]}" " ${F_HINT[$key]}"
          _tl_gap $((fw - 1 - ${#F_HINT[$key]}))
        else
          td_truncate first "$first$more" $((fw - 2))
          _tl_add "${TD_TC[fg]}" " $first"
          _tl_gap $((fw - 1 - ${#first}))
        fi
        TLBASE=$base
        ;;
    esac
    _tl_end
    _tui_ov "$row" $((left + 2)) "$TL"
    row=$((row + 1))
  done

  if ((buttons_row)); then
    row=$((row + 1))
    _tl_start "$iw" "${TUI_B[modal]}"
    local total=0
    for i in "${!F_KEYS[@]}"; do
      key=${F_KEYS[i]}
      [[ ${F_TYPE[$key]} == button ]] || continue
      total=$((total + ${#F_LABEL[$key]} + 4))
    done
    _tl_right "$total"
    for i in "${!F_KEYS[@]}"; do
      key=${F_KEYS[i]}
      [[ ${F_TYPE[$key]} == button ]] || continue
      if ((i == F_FOCUS)); then
        if [[ ${F_OPTS[$key]} == submit ]]; then _tl_pill bg green "${F_LABEL[$key]}"; else _tl_pill bg red "${F_LABEL[$key]}"; fi
      elif [[ ${F_OPTS[$key]} == submit ]]; then
        _tl_add "${TD_TC[green]}${TD_TC[bold]}" "[${F_LABEL[$key]}]"
      else
        _tl_add "${TD_TC[muted]}" "[${F_LABEL[$key]}]"
      fi
      _tl_gap 2
    done
    _tl_end
    _tui_ov "$row" $((left + 2)) "$TL"
  fi

  _tl_start "$iw" "${TUI_B[modal]}"
  [[ -n $F_ERR ]] && _tl_add "${TD_TC[red]}${TD_TC[bold]}" "${TD_SYM[error]} $F_ERR"
  _tl_end
  _tui_ov $((top + h - 3)) $((left + 2)) "$TL"
  _tl_start "$iw" "${TUI_B[modal]}"
  local ftype=${F_TYPE[${F_KEYS[F_FOCUS]}]} hint="Tab next · ⇧Tab back · Ctrl-S save · Esc cancel"
  case $ftype in
    segment) hint="←/→ choose · $hint" ;;
    pick) hint="⏎ choose · $hint" ;;
    date) hint="type or ⏎ for presets · $hint" ;;
    notes) hint="⏎ open editor · $hint" ;;
    check) hint="Space toggle · $hint" ;;
  esac
  _tl_add "${TD_TC[muted]}" "$hint"
  _tl_end
  _tui_ov $((top + h - 2)) $((left + 2)) "$TL"
}

# Labels and colors of segment options; tui.sh may override per field.
_tui_option_label() {
  case $2 in
    TODO) printf '%s To do' "${TD_SYM[TODO]}" ;;
    IN_PROGRESS) printf '%s Doing' "${TD_SYM[IN_PROGRESS]}" ;;
    BLOCKED) printf '%s Blocked' "${TD_SYM[BLOCKED]}" ;;
    DONE) printf '%s Done' "${TD_SYM[DONE]}" ;;
    CANCELLED) printf '%s Cancelled' "${TD_SYM[CANCELLED]}" ;;
    *) printf '%s' "$2" ;;
  esac
}

_tui_option_color() {
  case $2 in
    urgent | BLOCKED) printf red ;;
    high) printf orange ;;
    low | CANCELLED) printf muted ;;
    IN_PROGRESS) printf blue ;;
    DONE) printf green ;;
    *) printf accent ;;
  esac
}
