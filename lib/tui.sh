# shellcheck shell=bash disable=SC2034
# tui.sh — the interactive full-screen interface.
#
# Pure Bash: alternate screen, raw keyboard input, and a full redraw per change
# written with a single printf, so the screen does not flicker. Every action
# goes through the business layer (tasks.sh, focus.sh) or, for typed commands,
# through the very same parser as the CLI (commands.sh): TUI and CLI cannot
# drift apart. (SC2034 is disabled: this file sets globals read by other modules.)
#
# Layout (master-detail; a single list panel below 72 columns):
#   ╭─ TODOSH ──────────────────────────────── ◉ #42 Review FW · 25m ─╮
#   │ View: active   Filter: —                           ⚠ 1 overdue  │
#   ├──────────────────────────────┬──────────────────────────────────┤
#   │ ▾ infra                 1/3  │ #42 Review firewall rules        │
#   │ ❯ ◐ H #42 Review FW  1/2 fri │ IN_PROGRESS · high · infra       │
#   ├──────────────────────────────┴──────────────────────────────────┤
#   │ n new  e edit  c comment  f focus  d done  / filter  ? help     │
#   ╰─────────────────────────────────────────────────────────────────╯

readonly TD_TUI_VIEWS=(active all overdue blocked)

# Rows of the list: parallel arrays, one entry per visible row.
declare -ga U_KIND=() U_GROUP=() U_DEPTH=() U_ID=() U_STATUS=() U_PRIO=()
declare -ga U_DUE=() U_DUESTATE=() U_PROG=() U_TAGS=() U_FOCUS=() U_TITLE=()
declare -gA TUI_COLLAPSED=()
declare -ga TUI_DETAIL=()

TUI_ACTIVE=0 TUI_STTY="" TUI_ROWS=24 TUI_COLS=80 TUI_RESIZED=0
TUI_SEL=0 TUI_TOP=0 TUI_VIEW=active TUI_FILTER="" TUI_MSG="" TUI_MSG_KIND=info
TUI_FOCUS="" TUI_FOCUS_SINCE="" TUI_FOCUS_EPOCH=0 TUI_FOCUS_TITLE="" TUI_WARN=""
# Compact index of every task ({id, title, status, parent, project}), rebuilt on
# reload; passing full records to jq on every key press would be slow.
TUI_IDX="[]"
# Selected task ID ("" on a project row), set by _tui_sel_task.
TUI_SID=""
# Color tables per status, priority and due state (built with the theme).
declare -gA TUI_SSGR=() TUI_PSGR=() TUI_DSGR=()
TUI_DETAIL_KEY="" TUI_KEY="" TUI_INPUT="" TUI_LAST_DELETED=""
declare -ga TUI_WORDS=()

# --- entry point -----------------------------------------------------------

# td_tui_main — run the interface until the user quits.
td_tui_main() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    td_err "the interface needs an interactive terminal (try: todosh list)"
    return "$TD_E_USAGE"
  fi
  td_require_cmds tput stty less || return
  td_storage_init || return
  TD_QUIET_ERRORS=1
  _tui_theme_init

  trap '_tui_leave' EXIT
  trap 'exit 130' INT TERM HUP
  trap 'TUI_RESIZED=1' WINCH
  trap '_tui_suspend' TSTP
  _tui_enter
  _tui_size
  _tui_reload

  local last_draw=0 now
  while :; do
    _tui_draw
    printf -v last_draw '%(%s)T' -1
    while ! _tui_read_key; do
      # Timeout: redraw on resize, and refresh the focus timer now and then.
      if ((TUI_RESIZED)); then
        _tui_size
        break
      fi
      printf -v now '%(%s)T' -1
      [[ -n $TUI_FOCUS ]] && ((now - last_draw >= 30)) && break
    done
    [[ -n $TUI_KEY ]] || continue
    _tui_handle "$TUI_KEY" || break
  done
  _tui_leave
  trap - EXIT INT TERM HUP WINCH TSTP
  return 0
}

_tui_theme_init() {
  td_color_tier
  if ! td_theme_load "${TD_CONF[theme]:-tokyonight}"; then
    td_theme_load tokyonight 2>/dev/null || true
    TUI_MSG="theme '${TD_CONF[theme]}' not found; using tokyonight"
    TUI_MSG_KIND=error
  fi
  td_theme_sgr
  TUI_SSGR=([TODO]=${TD_TC[fg]} [IN_PROGRESS]=${TD_TC[bold]}${TD_TC[blue]} [BLOCKED]=${TD_TC[red]}
    [DONE]=${TD_TC[green]} [CANCELLED]=${TD_TC[muted]})
  TUI_PSGR=([urgent]=${TD_TC[bold]}${TD_TC[red]} [high]=${TD_TC[orange]} [med]=${TD_TC[fg]}
    [low]=${TD_TC[muted]})
  TUI_DSGR=([overdue]=${TD_TC[bold]}${TD_TC[red]} [today]=${TD_TC[yellow]} [soon]=${TD_TC[fg]}
    [later]=${TD_TC[muted]})
}

# --- terminal handling -----------------------------------------------------

_tui_enter() {
  TUI_STTY=$(stty -g </dev/tty)
  stty -echo -icanon min 1 time 0 </dev/tty
  # Alternate screen, hidden cursor, no autowrap (so the last column is safe).
  printf '\e[?1049h\e[?25l\e[?7l'
  TUI_ACTIVE=1
}

_tui_leave() {
  ((TUI_ACTIVE)) || return 0
  printf '\e[0m\e[?7h\e[?25h\e[?1049l'
  [[ -n $TUI_STTY ]] && stty "$TUI_STTY" </dev/tty
  TUI_ACTIVE=0
}

# Ctrl-Z: give the terminal back, stop, and take it again on `fg`.
_tui_suspend() {
  _tui_leave
  trap - TSTP
  kill -TSTP $$
  trap '_tui_suspend' TSTP
  _tui_enter
  TUI_RESIZED=1
}

_tui_size() {
  local size
  size=$(stty size </dev/tty 2>/dev/null) || size="24 80"
  TUI_ROWS=${size% *}
  TUI_COLS=${size#* }
  TUI_RESIZED=0
  TUI_DETAIL_KEY=""
}

# _tui_read_key — read one key into TUI_KEY (named keys: up, down, enter...).
# Returns 1 on timeout. End of input reads as "eof".
_tui_read_key() {
  local k c rest rc
  TUI_KEY=""
  IFS= read -rsn1 -t 1 -d '' k </dev/tty
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
    $'\x04') TUI_KEY=ctrl-d ;;
    $'\x15') TUI_KEY=ctrl-u ;;
    $'\x0c') TUI_KEY=ctrl-l ;;
    *) TUI_KEY=$k ;;
  esac
}

# --- data ------------------------------------------------------------------

# _tui_reload — reload tasks for the current view, keeping the selection.
_tui_reload() {
  local keep_kind=${U_KIND[TUI_SEL]:-} keep_id=${U_ID[TUI_SEL]:-} keep_group=${U_GROUP[TUI_SEL]:-}
  local filter today rows
  td_today today
  td_focus_read TUI_FOCUS TUI_FOCUS_SINCE
  TUI_IDX=$(td_tasks_select '{"visibility": "all"}' \
    | jq -c 'map({id, title, status, parent, project, due})') || TUI_IDX="[]"
  TUI_FOCUS_TITLE="" TUI_FOCUS_EPOCH=0
  if [[ -n $TUI_FOCUS ]]; then
    TUI_FOCUS_TITLE=$(jq -r --argjson id "$TUI_FOCUS" '.[] | select(.id == $id) | .title' <<<"$TUI_IDX")
    TUI_FOCUS_EPOCH=$(date -u -d "$TUI_FOCUS_SINCE" +%s 2>/dev/null) || TUI_FOCUS_EPOCH=0
  fi
  filter=$(jq -cn --arg view "$TUI_VIEW" --arg text "$TUI_FILTER" \
    --argjson days "${TD_CONF[archive_after_days]}" '
    {archive_days: $days, text: $text}
    + (if $view == "all" then {visibility: "all"}
       elif $view == "overdue" then {overdue: true}
       elif $view == "blocked" then {statuses: ["BLOCKED"]}
       else {visibility: "default"} end)')
  rows=$(td_tasks_select "$filter") || rows="[]"

  U_KIND=() U_GROUP=() U_DEPTH=() U_ID=() U_STATUS=() U_PRIO=() U_DUE=()
  U_DUESTATE=() U_PROG=() U_TAGS=() U_FOCUS=() U_TITLE=()
  local kind group depth id status prio due dstate prog tags foc title
  while IFS=$'\x1f' read -r kind group depth id status prio due dstate prog tags foc title; do
    [[ $kind == T && -v TUI_COLLAPSED[$group] ]] && continue
    U_KIND+=("$kind") U_GROUP+=("$group") U_DEPTH+=("$depth") U_ID+=("$id")
    U_STATUS+=("$status") U_PRIO+=("$prio") U_DUE+=("$due") U_DUESTATE+=("$dstate")
    U_PROG+=("$prog") U_TAGS+=("$tags") U_FOCUS+=("$foc") U_TITLE+=("$title")
  done < <(LC_TIME=C jq -r --arg today "$today" --arg focus "$TUI_FOCUS" "$TD_JQ_DUE"'
    (map(.id)) as $ids
    | (map({key: (.id | tostring), value: .project}) | from_entries) as $proj
    | map(. + (if .parent != null and (.parent | IN($ids[]))
               then {grp: $proj[.parent | tostring], depth: 1}
               else {grp: .project, depth: 0} end)) as $rows
    | ($rows | map(.grp) | unique | sort_by(if . == "inbox" then "" else . end))[] as $g
    | ($rows | map(select(.grp == $g))) as $items
    | (["G", $g, 0, "", "", "", "", "",
        "\($items | map(select(.status == "DONE")) | length)/\($items | map(select(.status != "CANCELLED")) | length)",
        "", 0, ""] | map(tostring) | join("\u001f")),
      ($items[] | due_info as $d
       | ["T", $g, .depth, .id, .status, .priority, ($d.text // ""), ($d.state // ""),
          (if .subtasks then "\(.subtasks.done)/\(.subtasks.total)" else "" end),
          (.tags | map("+" + .) | join(" ")),
          (if (.id | tostring) == $focus then 1 else 0 end),
          (.title | gsub("[[:cntrl:]]"; " "))]
       | map(tostring) | join("\u001f"))' <<<"$rows")

  # Warnings over all open tasks, whatever the view.
  local overdue due_today
  read -r overdue due_today < <(jq -r --arg today "$today" '
    map(select(.status | IN("TODO", "IN_PROGRESS", "BLOCKED")))
    | [map(select(.due != null and .due < $today)) | length,
       map(select(.due == $today)) | length] | @tsv' <<<"$TUI_IDX")
  TUI_WARN=""
  ((overdue)) && TUI_WARN+="$overdue overdue"
  ((due_today)) && TUI_WARN+="${TUI_WARN:+ · }$due_today due today"

  # Restore the selection: same task, else same group, else clamp.
  local i n=${#U_KIND[@]}
  TUI_SEL=$((TUI_SEL < n ? TUI_SEL : (n > 0 ? n - 1 : 0)))
  for ((i = 0; i < n; i++)); do
    if [[ $keep_kind == T && ${U_KIND[i]} == T && ${U_ID[i]} == "$keep_id" ]] \
      || [[ $keep_kind == G && ${U_KIND[i]} == G && ${U_GROUP[i]} == "$keep_group" ]]; then
      TUI_SEL=$i
      break
    fi
  done
  TUI_DETAIL_KEY=""
}

# --- drawing helpers -------------------------------------------------------

# A line is built from colored segments while counting visible characters:
#   _tl_start WIDTH [BASE]; _tl_add SGR TEXT...; _tl_end  -> result in TL
# BASE is re-applied before every segment (e.g. the selection background).
TL="" TLW=0 TLMAX=0 TLBASE=""

_tl_start() {
  TL="" TLW=0 TLMAX=$1 TLBASE=$'\e[0m'${2:-}
}

_tl_add() {
  local sgr=$1 text=$2 room=$((TLMAX - TLW))
  ((room > 0)) || return 0
  if ((${#text} > room)); then
    text=${text:0:room-1}${TD_SYM[ellipsis]}
  fi
  TL+=$TLBASE$sgr$text
  TLW=$((TLW + ${#text}))
}

# _tl_gap N — add N spaces.
_tl_gap() {
  (($1 > 0)) || return 0
  local spaces
  printf -v spaces '%*s' "$1" ''
  _tl_add "" "$spaces"
}

_tl_end() {
  local pad=$((TLMAX - TLW))
  ((pad > 0)) && printf -v TL '%s%s%*s' "$TL" "$TLBASE" "$pad" ''
  TL+=$'\e[0m'
  TLW=$TLMAX
}

# _tui_rule VAR CHAR N — store CHAR repeated N times in VAR.
_tui_rule() {
  local -n _td_rule=$1
  printf -v _td_rule '%*s' "$3" ''
  _td_rule=${_td_rule// /$2}
}

# _tui_wrap WIDTH TEXT — word-wrap TEXT to WIDTH columns, one line per output line.
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

# --- frame -----------------------------------------------------------------

# _tui_frame — print the whole screen, one line per row, without moving the
# cursor (testable: no terminal needed). Uses TUI_ROWS x TUI_COLS.
_tui_frame() {
  local W=$TUI_COLS H=$TUI_ROWS
  local tl tr bl br h v lt rt tt bt
  if ((TD_UNICODE)); then
    tl="╭" tr="╮" bl="╰" br="╯" h="─" v="│" lt="├" rt="┤" tt="┬" bt="┴"
  else
    tl="+" tr="+" bl="+" br="+" h="-" v="|" lt="+" rt="+" tt="+" bt="+"
  fi
  if ((W < 40 || H < 10)); then
    printf '%s\n' "Terminal too small (${W}x${H}); need 40x10. Press q to quit."
    return
  fi
  local B=$((H - 6)) LW RW split=0
  if ((W >= 72)); then
    split=1
    LW=$((W * 55 / 100 - 1))
    RW=$((W - LW - 3))
  else
    LW=$((W - 2))
    RW=0
  fi
  local bd=${TD_TC[border]} r=${TD_TC[reset]}

  # Top border with the title and the focus.
  local focus_txt="" title=" TODOSH "
  if [[ -n $TUI_FOCUS ]]; then
    local ftitle now dur
    printf -v now '%(%s)T' -1
    td_fmt_duration -v dur $((now > TUI_FOCUS_EPOCH ? now - TUI_FOCUS_EPOCH : 0))
    td_truncate ftitle "$TUI_FOCUS_TITLE" $((W / 3))
    focus_txt=" ${TD_SYM[focus]} #$TUI_FOCUS $ftitle · $dur "
  fi
  # Corners and the dashes next to them take 4 columns.
  local fill=$((W - 4 - ${#title} - ${#focus_txt}))
  ((fill < 1)) && focus_txt="" && fill=$((W - 4 - ${#title}))
  local rule_top rule_l rule_r rule_w
  _tui_rule rule_top "$h" "$fill"
  _tui_rule rule_l "$h" "$LW"
  _tui_rule rule_r "$h" "$RW"
  _tui_rule rule_w "$h" $((W - 2))
  printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$bd" "$tl$h" "$r" "${TD_TC[bold]}${TD_TC[accent]}" "$title" "$r" \
    "$bd" "$rule_top" "$r${TD_TC[magenta]}" "$focus_txt" "$r$bd$h$tr$r"

  # Status line: view, filter, warnings.
  local warn="" left
  [[ -n $TUI_WARN ]] && warn="${TD_SYM[warn]} $TUI_WARN"
  _tl_start $((W - 4))
  _tl_add "${TD_TC[muted]}" "View: "
  _tl_add "${TD_TC[fg]}" "$TUI_VIEW"
  _tl_add "${TD_TC[muted]}" "   Filter: "
  _tl_add "${TD_TC[fg]}" "${TUI_FILTER:-${TD_SYM[dash]}}"
  left=$TLW
  if [[ -n $warn ]] && ((left + ${#warn} + 2 <= W - 4)); then
    _tl_gap $((W - 4 - left - ${#warn}))
    _tl_add "${TD_TC[bold]}${TD_TC[red]}" "$warn"
  fi
  _tl_end
  printf '%s%s%s %s %s%s%s\n' "$bd" "$v" "$r" "$TL" "$bd" "$v" "$r"

  if ((split)); then
    printf '%s%s%s%s%s%s\n' "$bd" "$lt" "$rule_l" "$tt" "$rule_r" "$rt$r"
  else
    printf '%s%s%s%s%s\n' "$bd" "$lt" "$rule_l" "$rt" "$r"
  fi

  # Body: list (left) and detail (right).
  local n=${#U_KIND[@]}
  ((TUI_SEL < TUI_TOP)) && TUI_TOP=$TUI_SEL
  ((TUI_SEL >= TUI_TOP + B)) && TUI_TOP=$((TUI_SEL - B + 1))
  ((TUI_TOP < 0)) && TUI_TOP=0
  ((split)) && _tui_detail_build $((RW - 2)) "$B"
  local row i left_line right_line
  for ((row = 0; row < B; row++)); do
    i=$((TUI_TOP + row))
    if ((i < n)); then
      _tui_list_line "$i" "$LW"
    elif ((n == 0 && row == 1)); then
      _tl_start "$LW"
      _tl_add "${TD_TC[muted]}" "  No tasks here. Press n to add one, v to change view."
      _tl_end
    else
      _tl_start "$LW"
      _tl_end
    fi
    left_line=$TL
    if ((split)); then
      _tl_start $((RW - 2))
      [[ -n ${TUI_DETAIL[row]:-} ]] && _tui_detail_line "${TUI_DETAIL[row]}"
      _tl_end
      right_line=$TL
      printf '%s%s%s%s%s%s%s %s %s%s%s\n' "$bd" "$v" "$r" "$left_line" "$bd" "$v" "$r" \
        "$right_line" "$bd" "$v" "$r"
    else
      printf '%s%s%s%s%s%s%s\n' "$bd" "$v" "$r" "$left_line" "$bd" "$v" "$r"
    fi
  done

  if ((split)); then
    printf '%s%s%s%s%s%s\n' "$bd" "$lt" "$rule_l" "$bt" "$rule_r" "$rt$r"
  else
    printf '%s%s%s%s%s\n' "$bd" "$lt" "$rule_l" "$rt" "$r"
  fi

  # Hints, or the message of the last action.
  _tl_start $((W - 4))
  if [[ -n $TUI_MSG ]]; then
    if [[ $TUI_MSG_KIND == error ]]; then
      _tl_add "${TD_TC[bold]}${TD_TC[red]}" "$TUI_MSG"
    else
      _tl_add "${TD_TC[green]}" "$TUI_MSG"
    fi
  else
    local pair key label
    for pair in "n:new" "e:edit" "c:comment" "f:focus" "s:start" "d:done" "/:filter" \
      "v:view" ":cmd" "?:help" "q:quit"; do
      key=${pair%%:*}
      label=${pair#*:}
      [[ $pair == ":cmd" ]] && key=":" label="cmd"
      _tl_add "${TD_TC[bold]}${TD_TC[accent]}" "$key"
      _tl_add "${TD_TC[muted]}" " $label  "
    done
  fi
  _tl_end
  printf '%s%s%s %s %s%s%s\n' "$bd" "$v" "$r" "$TL" "$bd" "$v" "$r"
  printf '%s%s%s%s%s' "$bd" "$bl" "$rule_w" "$br" "$r"
}

# _tui_list_line INDEX WIDTH — one row of the list into TL.
_tui_list_line() {
  local i=$1 width=$2 base="" sel=0
  if ((i == TUI_SEL)); then
    base=${TD_TC[sel]}
    sel=1
  fi
  _tl_start "$width" "$base"
  if [[ ${U_KIND[i]} == G ]]; then
    local mark="▾"
    ((TD_UNICODE)) || mark="-"
    if [[ -v TUI_COLLAPSED[${U_GROUP[i]}] ]]; then
      mark="▸"
      ((TD_UNICODE)) || mark="+"
    fi
    local pointer=" "
    ((sel)) && pointer=${TD_SYM[select]}
    _tl_add "${TD_TC[bold]}${TD_TC[accent]}" "$pointer $mark ${U_GROUP[i]}"
    local prog=${U_PROG[i]}
    local gap=$((width - TLW - ${#prog} - 1))
    _tl_gap "$gap"
    _tl_add "${TD_TC[muted]}" "$prog"
    _tl_end
    return
  fi

  local status=${U_STATUS[i]} closed=0 tsgr
  td_status_is_closed "$status" && closed=1
  local -A letter=([urgent]=U [high]=H [med]=M [low]=L)
  local right=""
  [[ -n ${U_PROG[i]} ]] && right=${U_PROG[i]}
  [[ -n ${U_DUE[i]} ]] && right+="${right:+ }${U_DUE[i]}"

  if ((sel)); then _tl_add "${TD_TC[bold]}${TD_TC[magenta]}" "${TD_SYM[select]}"; else _tl_add "" " "; fi
  _tl_add "" " "
  ((U_DEPTH[i])) && _tl_add "${TD_TC[border]}" "  "
  _tl_add "${TUI_SSGR[$status]:-}" "${TD_SYM[$status]}"
  _tl_add "" " "
  _tl_add "${TUI_PSGR[${U_PRIO[i]}]:-}" "${letter[${U_PRIO[i]}]:-?}"
  _tl_add "${TD_TC[muted]}" " #${U_ID[i]} "
  if ((U_FOCUS[i])); then
    _tl_add "${TD_TC[bold]}${TD_TC[magenta]}" "${TD_SYM[focus]} "
  fi
  if ((closed)); then
    tsgr=${TD_TC[muted]}
  elif ((U_FOCUS[i])); then
    tsgr=${TD_TC[bold]}${TD_TC[magenta]}
  else
    tsgr=${TD_TC[fg]}
  fi
  # Leave room for the right-aligned progress and due date.
  local room=$((width - TLW - (${#right} ? ${#right} + 2 : 1)))
  local title=${U_TITLE[i]}
  ((room < 4)) && room=4
  td_truncate title "$title" "$room"
  _tl_add "$tsgr" "$title"
  if [[ -n $right ]]; then
    local gap=$((width - TLW - ${#right} - 1))
    _tl_gap "$gap"
    [[ -n ${U_PROG[i]} ]] && _tl_add "${TD_TC[muted]}" "${U_PROG[i]}"
    if [[ -n ${U_DUE[i]} ]]; then
      [[ -n ${U_PROG[i]} ]] && _tl_add "" " "
      _tl_add "${TUI_DSGR[${U_DUESTATE[i]}]:-}" "${U_DUE[i]}"
    fi
  fi
  _tl_end
}

# --- detail panel ----------------------------------------------------------

# Detail lines are "STYLE<US>TEXT" (style names below), built per task and width.
_tui_detail_line() {
  local style=${1%%$'\x1f'*} text=${1#*$'\x1f'}
  case $style in
    title) _tl_add "${TD_TC[bold]}${TD_TC[fg]}" "$text" ;;
    head) _tl_add "${TD_TC[bold]}${TD_TC[accent]}" "$text" ;;
    muted) _tl_add "${TD_TC[muted]}" "$text" ;;
    focus) _tl_add "${TD_TC[magenta]}" "$text" ;;
    comment)
      _tl_add "${TD_TC[yellow]}" "${TD_SYM[comment]} "
      _tl_add "${TD_TC[fg]}" "$text"
      ;;
    status-*) _tl_add "${TUI_SSGR[${style#status-}]:-}" "$text" ;;
    due-*) _tl_add "${TUI_DSGR[${style#due-}]:-}" "$text" ;;
    *) _tl_add "${TD_TC[fg]}" "$text" ;;
  esac
}

# _tui_detail_build WIDTH HEIGHT — fill TUI_DETAIL for the selected row.
_tui_detail_build() {
  local width=$1 height=$2 key
  key="${U_KIND[TUI_SEL]:-}:${U_ID[TUI_SEL]:-}:${U_GROUP[TUI_SEL]:-}:$width:$height:$TUI_FOCUS"
  [[ $key == "$TUI_DETAIL_KEY" ]] && return 0
  TUI_DETAIL_KEY=$key
  TUI_DETAIL=()
  ((${#U_KIND[@]})) || return 0
  local US=$'\x1f'

  if [[ ${U_KIND[TUI_SEL]} == G ]]; then
    local g=${U_GROUP[TUI_SEL]}
    TUI_DETAIL+=("head${US}Project $g")
    TUI_DETAIL+=("muted${US}${U_PROG[TUI_SEL]} done")
    TUI_DETAIL+=("${US}")
    local line
    while IFS= read -r line; do
      TUI_DETAIL+=("$line")
    done < <(jq -r --arg g "$g" '
      [.[] | select(.project == $g)] as $t
      | ($t | map(select(.status == "IN_PROGRESS")) | length) as $ip
      | ($t | map(select(.status == "BLOCKED")) | length) as $bl
      | ($t | map(select(.status == "TODO")) | length) as $todo
      | "status-IN_PROGRESS\u001f\($ip) in progress", "status-BLOCKED\u001f\($bl) blocked",
        "\u001f\($todo) to do"' <<<"$TUI_IDX")
    TUI_DETAIL+=("${US}")
    TUI_DETAIL+=("muted${US}space/enter: collapse or expand")
    return 0
  fi

  local id=${U_ID[TUI_SEL]} file record today now
  local area=tasks
  file=$TD_DATA_DIR/tasks/$id.json
  [[ -f $file ]] || return 0
  record=$(<"$file")
  td_today today
  printf -v now '%(%s)T' -1

  local -a recs
  mapfile -d '' recs < <(LC_TIME=C jq -j --arg today "$today" --argjson now "$now" \
    --argjson all "$TUI_IDX" --arg arrow "${TD_SYM[arrow]}" --arg none "${TD_SYM[dash]}" \
    "$TD_JQ_DUE$TD_JQ_EVENT"'
    def ago: ($now - (fromdateiso8601)) | if . < 60 then "now" elif . < 3600 then "\(. / 60 | floor)m"
      elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    def rec($a; $b): [$a, $b] | join("\u001f") + "\u0000";
    . as $t
    | rec("title"; "#\(.id) \(.title | clean)"),
      rec("status-\(.status)"; "\(.status) · \(.priority) · \(.project)"),
      (if (.tags | length) > 0 then rec("muted"; .tags | map("+" + .) | join(" ")) else empty end),
      (due_info as $d | if $d then rec("due-\($d.state)"; "Due \(.due) (\($d.text))") else empty end),
      rec("worked"; [.history[] | select(.type == "focus") | .seconds] | add // 0 | tostring),
      (if .parent then rec("muted"; "Part of #\(.parent) \([$all[] | select(.id == $t.parent) | .title][0] // "")") else empty end),
      (if .description != "" then rec("gap"; ""), rec("head"; "Description"), rec("desc"; .description | clean) else empty end),
      ([$all[] | select(.parent == $t.id)] as $subs
       | if ($subs | length) > 0 then
           rec("gap"; ""),
           rec("head"; "Subtasks \($subs | map(select(.status == "DONE")) | length)/\($subs | map(select(.status != "CANCELLED")) | length)"),
           ($subs[] | rec("sub-\(.status)"; "#\(.id) \(.title | clean)"))
         else empty end),
      rec("gap"; ""), rec("head"; "History"),
      (.history | reverse | .[0:12][]
       | rec(if .type == "comment" then "comment" else "event" end;
             "\(.at | ago)\u001e\(entry_text | split("\n")[0])"))' <<<"$record")

  local item style text line worked=0 w=$width
  for item in "${recs[@]}"; do
    style=${item%%$'\x1f'*}
    text=${item#*$'\x1f'}
    case $style in
      title | desc)
        while IFS= read -r line; do
          TUI_DETAIL+=("$([[ $style == title ]] && printf title || printf '')${US}$line")
        done < <(_tui_wrap "$w" "$text")
        ;;
      worked)
        worked=$text
        local focus_line=""
        if [[ $id == "$TUI_FOCUS" ]]; then
          local s d
          printf -v s '%(%s)T' -1
          s=$((s > TUI_FOCUS_EPOCH ? s - TUI_FOCUS_EPOCH : 0))
          worked=$((worked + s))
          td_fmt_duration -v d "$s"
          focus_line="${TD_SYM[focus]} in focus for $d"
        fi
        [[ -n $focus_line ]] && TUI_DETAIL+=("focus${US}$focus_line")
        if ((worked > 0)); then
          local wd
          td_fmt_duration -v wd "$worked"
          TUI_DETAIL+=("muted${US}${TD_SYM[time]} worked $wd")
        fi
        ;;
      gap) TUI_DETAIL+=("${US}") ;;
      sub-*)
        local st=${style#sub-}
        TUI_DETAIL+=("status-$st${US}${TD_SYM[$st]} $text")
        ;;
      comment | event)
        local when=${text%%$'\x1e'*} body=${text#*$'\x1e'}
        if [[ $style == comment ]]; then
          TUI_DETAIL+=("comment${US}$when  $body")
        else
          TUI_DETAIL+=("muted${US}$when  ${TD_SYM[event]} $body")
        fi
        ;;
      *) TUI_DETAIL+=("$style${US}$text") ;;
    esac
    ((${#TUI_DETAIL[@]} >= height)) && break
  done
  : "$area"
}

# --- drawing ---------------------------------------------------------------

_tui_draw() {
  local frame row=1 line out=""
  frame=$(_tui_frame)
  while IFS= read -r line; do
    out+=$'\e['"$row;1H$line"
    row=$((row + 1))
  done <<<"$frame"
  # Clear anything below (e.g. after a resize) and draw in one write.
  printf '%s\e[%d;1H\e[J' "$out" "$row"
  TUI_MSG=""
  TUI_MSG_KIND=info
}

# --- input helpers ---------------------------------------------------------

# _tui_prompt PROMPT [INITIAL] — read a line at the bottom of the screen into
# TUI_INPUT, with line editing. Returns 1 when cancelled (Ctrl-C or empty).
_tui_prompt() {
  local rc
  printf '\e[%d;1H\e[0m\e[2K\e[?25h' "$TUI_ROWS"
  stty "$TUI_STTY" </dev/tty
  # readline restarts the line on Ctrl-C instead of returning, so the line is
  # read in a subshell that Ctrl-C kills. Meanwhile this shell survives it
  # through a no-op trap (a trap, not an ignore, so the subshell still gets
  # the default action).
  trap ':' INT
  TUI_INPUT=$(
    IFS= read -e -r -p "$1" -i "${2:-}" line </dev/tty 2>/dev/tty >/dev/tty || exit 1
    printf '%s' "$line"
  )
  rc=$?
  trap 'exit 130' INT
  stty -echo -icanon min 1 time 0 </dev/tty
  printf '\e[?25l'
  ((rc == 0)) || return 1
  [[ -n ${TUI_INPUT//[[:space:]]/} ]]
}

# _tui_confirm QUESTION — single-key yes/no on the bottom line.
_tui_confirm() {
  printf '\e[%d;1H\e[0m\e[2K%s%s [y/N]%s ' "$TUI_ROWS" "${TD_TC[bold]}${TD_TC[yellow]}" "$1" "${TD_TC[reset]}"
  local k
  IFS= read -rsn1 -d '' k </dev/tty
  [[ $k == [yY] ]]
}

# _tui_split LINE — split a command line into TUI_WORDS, honoring '...' and
# "..." quotes and backslash escapes. Nothing is evaluated.
_tui_split() {
  local s=$1 c word="" quote="" have=0 i
  TUI_WORDS=()
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if [[ -n $quote ]]; then
      if [[ $c == "$quote" ]]; then
        quote=""
      elif [[ $c == "\\" && $quote == '"' && $((i + 1)) -lt ${#s} ]]; then
        i=$((i + 1))
        word+=${s:i:1}
      else
        word+=$c
      fi
    elif [[ $c == "'" || $c == '"' ]]; then
      quote=$c
      have=1
    elif [[ $c == "\\" && $((i + 1)) -lt ${#s} ]]; then
      i=$((i + 1))
      word+=${s:i:1}
      have=1
    elif [[ $c == [[:space:]] ]]; then
      if ((have)); then
        TUI_WORDS+=("$word")
        word="" have=0
      fi
    else
      word+=$c
      have=1
    fi
  done
  ((have)) && TUI_WORDS+=("$word")
  return 0
}

# _tui_cli CMD ARG... — run a CLI command without leaving the screen; its
# output becomes the status message.
_tui_cli() {
  local out rc
  out=$(
    TD_OPT_JSON=0 TD_OPT_COLOR=never TD_QUIET_ERRORS=0 TD_CMD=$1
    td_term_init
    "td_cmd_$1" "${@:2}" 2>&1 </dev/null
  )
  rc=$?
  out=$(grep -v "^Try 'todosh" <<<"$out")
  out=${out//todosh: /}
  TUI_MSG=${out##*$'\n'}
  ((rc)) && TUI_MSG_KIND=error
  _tui_reload
  return "$rc"
}

# _tui_external WAIT CMD ARG... — run CMD on the normal screen (editor, pager,
# typed commands), then come back. WAIT=1 waits for a key first.
_tui_external() {
  local wait=$1 rc
  shift
  _tui_leave
  (
    TD_QUIET_ERRORS=0
    "$@"
  )
  rc=$?
  if ((wait)); then
    printf '\n%s-- press any key to return --%s' "${TD_SGR[gray]}" "${TD_SGR[reset]}"
    IFS= read -rsn1 -d '' _ </dev/tty
  fi
  _tui_enter
  _tui_size
  _tui_reload
  return "$rc"
}

_tui_pager() {
  local text=$1
  printf '%s\n' "$text" | less -R
}

_tui_show() {
  local area=tasks out subtasks
  [[ -f $TD_DATA_DIR/tasks/$1.json ]] || area=trash
  subtasks=$(td_tasks_select "{\"parent\": $1, \"visibility\": \"all\"}" "$area") || return
  out=$(_td_render_show "$(td_task_read "$1" "$area")" "$subtasks" "$area") || return
  _tui_pager "$out"
}

_tui_help() {
  _tui_pager "$(
    printf '%s\n' \
      "TODOSH — keys" \
      "" \
      "Move      j/k or ↓/↑   g/G or Home/End   PgDn/PgUp, Ctrl-D/Ctrl-U" \
      "Groups    h/←  collapse      l/→  expand      space/enter on a project: toggle" \
      "" \
      "Tasks     n  new task (shorthand works: p:infra pri:high +tag due:fri)" \
      "          N  new subtask of the selected task" \
      "          enter  full details (in a pager)" \
      "          e  edit title and description in \$EDITOR" \
      "          m  modify fields: pri:high +tag --untag x due:fri p:work" \
      "          +/-  raise or lower the priority" \
      "          c  comment     C  comment in \$EDITOR" \
      "Status    s  start   b  block   d  done   x  cancel   r  reopen" \
      "Focus     f  focus the task (again to release it)" \
      "Trash     D  delete   u  undo the last delete" \
      "" \
      "Views     v  cycle: active, all, overdue, blocked     a  toggle all" \
      "          /  filter by title (empty to clear)" \
      "Other     :  run any todosh command (e.g. :theme set nord, :purge)" \
      "          Ctrl-L  redraw     ?  this help     q  quit" \
      "" \
      "Theme: ${TD_THEME_NAME:-default}   Colors: tier $TD_TIER (3 truecolor, 2 256, 1 16, 0 none)"
  )"
}

# --- actions ---------------------------------------------------------------

# _tui_sel_task — set TUI_SID to the selected task ("" on a project row).
_tui_sel_task() {
  TUI_SID=""
  [[ ${U_KIND[TUI_SEL]:-} == T ]] && TUI_SID=${U_ID[TUI_SEL]}
  return 0
}

_tui_move() {
  local n=${#U_KIND[@]}
  TUI_SEL=$((TUI_SEL + $1))
  ((TUI_SEL >= n)) && TUI_SEL=$((n - 1))
  ((TUI_SEL < 0)) && TUI_SEL=0
}

# _tui_after RC — report the result of a direct business call.
_tui_after() {
  if (($1)); then
    TUI_MSG=$TD_LAST_ERROR
    TUI_MSG_KIND=error
  elif [[ -n ${2:-} ]]; then
    TUI_MSG=$2
  fi
  _tui_reload
}

# _tui_status STATUS — change the status of the selected task.
_tui_status() {
  local status=$1 id force=0 msg="" rc=0
  _tui_sel_task
  id=$TUI_SID
  [[ -n $id ]] || return 0
  if [[ $status == BLOCKED ]]; then
    _tui_prompt "Why is #$id blocked? (optional, enter to skip) " "" && msg=$TUI_INPUT
  fi
  if td_status_is_closed "$status"; then
    local open
    open=$(jq -r --argjson id "$id" '[.[] | select(.parent == $id
      and (.status | IN("TODO", "IN_PROGRESS", "BLOCKED")))] | length' <<<"$TUI_IDX")
    if ((open > 0)); then
      _tui_confirm "#$id has $open open subtask(s). Set them to $status too?" || return 0
      force=1
    fi
  fi
  td_task_set_status "$status" "$force" "$msg" "$id" || rc=$?
  _tui_after "$rc" "#$id ${TD_SYM[arrow]} $status"
}

_tui_priority() {
  local id cur next
  _tui_sel_task
  id=$TUI_SID
  [[ -n $id ]] || return 0
  cur=${U_PRIO[TUI_SEL]}
  local -a order=(low med high urgent)
  local i
  for i in "${!order[@]}"; do [[ ${order[i]} == "$cur" ]] && break; done
  i=$((i + $1))
  ((i < 0 || i > 3)) && return 0
  next=${order[i]}
  local -A ch=([priority]=$next)
  local rc=0
  td_task_edit "$id" ch || rc=$?
  _tui_after "$rc" "#$id priority $next"
}

# _tui_handle KEY — act on a key; returns 1 to quit.
_tui_handle() {
  local key=$1 id
  _tui_sel_task
  id=$TUI_SID
  case $key in
    q | eof) return 1 ;;
    j | down) _tui_move 1 ;;
    k | up) _tui_move -1 ;;
    g | home) TUI_SEL=0 ;;
    G | end) _tui_move "${#U_KIND[@]}" ;;
    pgdn | ctrl-d) _tui_move $(((TUI_ROWS - 6) / 2)) ;;
    pgup | ctrl-u) _tui_move $((-(TUI_ROWS - 6) / 2)) ;;
    ctrl-l | R)
      _tui_size
      _tui_reload
      ;;
    h | left)
      local g=${U_GROUP[TUI_SEL]:-}
      [[ -n $g ]] && TUI_COLLAPSED[$g]=1 && _tui_reload && _tui_select_group "$g"
      ;;
    l | right)
      local g=${U_GROUP[TUI_SEL]:-}
      [[ -n $g ]] && unset "TUI_COLLAPSED[$g]" && _tui_reload
      ;;
    space | enter)
      if [[ ${U_KIND[TUI_SEL]:-} == G ]]; then
        local g=${U_GROUP[TUI_SEL]}
        if [[ -v TUI_COLLAPSED[$g] ]]; then unset "TUI_COLLAPSED[$g]"; else TUI_COLLAPSED[$g]=1; fi
        _tui_reload
      elif [[ -n $id && $key == enter ]]; then
        _tui_external 0 _tui_show "$id"
      fi
      ;;
    n)
      local initial=""
      [[ -n ${U_GROUP[TUI_SEL]:-} && ${U_GROUP[TUI_SEL]} != "${TD_CONF[default_project]}" ]] \
        && initial="p:${U_GROUP[TUI_SEL]} "
      if _tui_prompt "New task: " "$initial"; then
        _tui_split "$TUI_INPUT"
        _tui_cli add "${TUI_WORDS[@]}"
      fi
      ;;
    N)
      [[ -n $id ]] || return 0
      local parent=$id
      local p
      p=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .parent // ""' <<<"$TUI_IDX")
      [[ -n $p ]] && parent=$p
      if _tui_prompt "New subtask of #$parent: " ""; then
        _tui_split "$TUI_INPUT"
        _tui_cli add "^$parent" "${TUI_WORDS[@]}"
      fi
      ;;
    m)
      [[ -n $id ]] || return 0
      if _tui_prompt "Modify #$id (pri:high +tag --untag x due:fri p:work --title ...): " ""; then
        _tui_split "$TUI_INPUT"
        _tui_cli edit "$id" "${TUI_WORDS[@]}"
      fi
      ;;
    e) [[ -n $id ]] && _tui_external 0 td_cmd_edit "$id" ;;
    c)
      [[ -n $id ]] || return 0
      if _tui_prompt "Comment on #$id: " ""; then
        local rc=0
        td_task_comment "$id" "$TUI_INPUT" || rc=$?
        _tui_after "$rc" "Comment added to #$id"
      fi
      ;;
    C) [[ -n $id ]] && _tui_external 0 td_cmd_comment "$id" ;;
    f)
      [[ -n $id ]] || return 0
      local rc=0
      if [[ $id == "$TUI_FOCUS" ]]; then
        td_focus_clear || rc=$?
        _tui_after "$rc" "Focus released"
      else
        td_focus_set "$id" || rc=$?
        _tui_after "$rc" "${TD_SYM[focus]} Focus on #$id"
      fi
      ;;
    s) _tui_status IN_PROGRESS ;;
    b) _tui_status BLOCKED ;;
    d) _tui_status DONE ;;
    x) _tui_status CANCELLED ;;
    r) _tui_status TODO ;;
    + | =) _tui_priority 1 ;;
    -) _tui_priority -1 ;;
    D | delete)
      [[ -n $id ]] || return 0
      local kids rc=0
      kids=$(jq -r --argjson id "$id" '[.[] | select(.parent == $id)] | length' <<<"$TUI_IDX")
      local q="Delete #$id?"
      ((kids)) && q="Delete #$id and its $kids subtask(s)?"
      _tui_confirm "$q" || return 0
      td_task_delete 1 "$id" || rc=$?
      ((rc)) || TUI_LAST_DELETED=$id
      _tui_after "$rc" "#$id moved to the trash (u to undo)"
      ;;
    u)
      if [[ -z $TUI_LAST_DELETED ]]; then
        TUI_MSG="Nothing to undo"
        return 0
      fi
      local rc=0
      td_task_undelete "$TUI_LAST_DELETED" || rc=$?
      _tui_after "$rc" "#$TUI_LAST_DELETED restored"
      ((rc)) || TUI_LAST_DELETED=""
      ;;
    /)
      if _tui_prompt "Filter (title contains): " "$TUI_FILTER"; then
        TUI_FILTER=$TUI_INPUT
      else
        TUI_FILTER=""
      fi
      TUI_SEL=0
      _tui_reload
      ;;
    v)
      local i
      for i in "${!TD_TUI_VIEWS[@]}"; do [[ ${TD_TUI_VIEWS[i]} == "$TUI_VIEW" ]] && break; done
      TUI_VIEW=${TD_TUI_VIEWS[$(((i + 1) % ${#TD_TUI_VIEWS[@]}))]}
      TUI_SEL=0
      _tui_reload
      ;;
    a)
      if [[ $TUI_VIEW == all ]]; then TUI_VIEW=active; else TUI_VIEW=all; fi
      _tui_reload
      ;;
    :)
      if _tui_prompt ":" ""; then
        _tui_split "$TUI_INPUT"
        [[ ${TUI_WORDS[0]:-} == todosh || ${TUI_WORDS[0]:-} == tdsh ]] && TUI_WORDS=("${TUI_WORDS[@]:1}")
        if ((${#TUI_WORDS[@]})); then
          _tui_external 1 _tui_run_command "${TUI_WORDS[@]}"
          # The command may have changed the theme or other settings.
          td_config_load 2>/dev/null
          _tui_theme_init
          _tui_reload
        fi
      fi
      ;;
    '?') _tui_external 0 _tui_help ;;
    esc) TUI_MSG="" ;;
  esac
  return 0
}

# _tui_run_command ARG... — a typed command, run exactly like the CLI would.
_tui_run_command() {
  printf '%s$ todosh %s%s\n' "${TD_SGR[gray]}" "$*" "${TD_SGR[reset]}"
  TD_OPT_JSON=0
  td_main "$@"
}

_tui_select_group() {
  local i
  for i in "${!U_KIND[@]}"; do
    if [[ ${U_KIND[i]} == G && ${U_GROUP[i]} == "$1" ]]; then
      TUI_SEL=$i
      return
    fi
  done
}
