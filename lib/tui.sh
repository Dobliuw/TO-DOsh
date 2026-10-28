# shellcheck shell=bash disable=SC2034,SC1111
# tui.sh — the interactive full-screen interface.
#
# The interface is an application of its own, not a view of the CLI: forms,
# pickers and dialogs replace command syntax, but every change still goes
# through the business layer (tasks.sh, focus.sh), so both stay consistent.
# Building blocks (layers, dialogs, forms) live in tui_ui.sh.
#
# Screen:
#   ┌ top bar ─ app · view tabs · filter ··············· focus ┐
#   │ TASKS                          │ DETAILS                    │
#   │ list with project groups       │ selected task: badges,     │
#   │ and subtask trees              │ notes, subtasks, activity  │
#   └ status bar ─ mode · key hints ··················· counts ┘
# (SC2034 is disabled: this file sets globals read by tui_ui.sh. SC1111:
# typographic quotes in messages are intended.)

readonly TD_TUI_VIEWS=(active all overdue blocked)
declare -grA TD_TUI_VIEW_LABEL=([active]=Active [all]=All [overdue]=Overdue [blocked]=Blocked)

# Rows of the list: parallel arrays, one entry per visible row.
declare -ga U_KIND=() U_GROUP=() U_DEPTH=() U_ID=() U_STATUS=() U_PRIO=() U_DUE=()
declare -ga U_DUESTATE=() U_PROG=() U_TAGS=() U_FOCUS=() U_TITLE=() U_LAST=() U_LEVEL=()
# The project tree (td_projects_tree), refreshed on reload.
TUI_TREE="[]"
declare -gA TUI_COLLAPSED=()
declare -ga TUI_DETAIL=()

TUI_ACTIVE=0 TUI_STTY="" TUI_ROWS=24 TUI_COLS=80 TUI_RESIZED=0
TUI_SEL=0 TUI_TOP=0 TUI_VIEW=active TUI_FILTER="" TUI_FCUR=0 TUI_MODE=normal
TUI_FOCUS="" TUI_FOCUS_SINCE="" TUI_FOCUS_EPOCH=0 TUI_FOCUS_TITLE=""
TUI_N_OPEN=0 TUI_N_OVERDUE=0 TUI_N_TODAY=0 TUI_LW=0 TUI_RW=0 TUI_DW=0
TUI_DETAIL_KEY="" TUI_KEY="" TUI_INPUT="" TUI_LAST_DELETED="" TUI_SID=""
# Compact index of every task ({id, title, status, parent, project, tags,
# due}), rebuilt on reload: handing full records to jq per key would be slow.
TUI_IDX="[]"

# Key bindings of the main screen: key -> action (see _tui_action).
# Keys are quoted: unquoted, shfmt would format [ctrl-d] as arithmetic.
declare -gA TUI_KEYMAP=(
  ["j"]=down ["down"]=down ["k"]=up ["up"]=up ["g"]=top ["home"]=top
  ["G"]=bottom ["end"]=bottom ["pgdn"]=page_down ["ctrl-d"]=page_down
  ["pgup"]=page_up ["ctrl-u"]=page_up ["h"]=collapse ["left"]=collapse
  ["l"]=expand ["right"]=expand ["enter"]=open ["n"]=new ["N"]=new_sub
  ["e"]=edit ["E"]=notes ["c"]=comment ["space"]=toggle_done ["s"]=start
  ["b"]=block ["d"]="done" ["x"]=cancel ["r"]=reopen ["p"]=priority
  ["+"]=prio_up ["="]=prio_up ["-"]=prio_down ["m"]=move ["t"]=tags
  ["P"]=new_project ["f"]=focus ["D"]=delete ["delete"]=delete ["u"]=undo ["/"]=filter
  ["tab"]=next_view ["btab"]=prev_view ["1"]=view_active ["2"]=view_all
  ["3"]=view_overdue ["4"]=view_blocked [":"]=palette [","]=settings
  ["?"]=help ["ctrl-l"]=redraw ["q"]=quit ["ctrl-c"]=quit ["ctrl-z"]=suspend
)

# --- entry point -----------------------------------------------------------

# td_tui_main — run the interface until the user quits.
td_tui_main() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    td_err "the interface needs an interactive terminal (try: todosh list)"
    return "$TD_E_USAGE"
  fi
  td_require_cmds tput stty || return
  td_storage_init || return
  TD_QUIET_ERRORS=1
  _tui_theme_init

  trap '_tui_leave' EXIT
  trap 'exit 130' INT TERM HUP
  trap 'TUI_RESIZED=1' WINCH
  _tui_enter
  _tui_size
  _tui_reload
  _tui_logo_check

  local last=0 now action
  while :; do
    _tui_base_build
    _tui_paint
    printf -v last '%(%s)T' -1
    while ! _tui_read_key; do
      # Timeout: redraw on resize, when a toast expires, or to tick the timer.
      printf -v now '%(%s)T' -1
      if ((TUI_RESIZED)); then
        _tui_size
        break
      fi
      [[ -n $TUI_TOAST ]] && ((now > TUI_TOAST_UNTIL)) && break
      [[ -n $TUI_FOCUS ]] && ((now - last >= 30)) && break
    done
    [[ -n $TUI_KEY ]] || continue
    if [[ $TUI_MODE == filter ]]; then
      _tui_filter_key "$TUI_KEY"
      continue
    fi
    [[ $TUI_KEY == eof ]] && break
    action=${TUI_KEYMAP[$TUI_KEY]:-}
    [[ -n $action ]] || continue
    [[ $action == quit ]] && break
    _tui_action "$action"
  done
  _tui_leave
  trap - EXIT INT TERM HUP WINCH
  return 0
}

_tui_theme_init() {
  td_term_init
  td_color_tier
  if ! td_theme_load "${TD_CONF[theme]:-tokyonight}" 2>/dev/null; then
    td_theme_load tokyonight 2>/dev/null || true
    _tui_toast error "Theme '${TD_CONF[theme]}' not found; using tokyonight"
  fi
  td_theme_sgr
  _tui_colors
  TUI_SSGR=([TODO]=${TD_TC[fg]} [IN_PROGRESS]=${TD_TC[bold]}${TD_TC[blue]} [BLOCKED]=${TD_TC[red]}
    [DONE]=${TD_TC[green]} [CANCELLED]=${TD_TC[muted]})
  TUI_DSGR=([overdue]=${TD_TC[bold]}${TD_TC[red]} [today]=${TD_TC[yellow]} [soon]=${TD_TC[fg]}
    [later]=${TD_TC[muted]})
  TUI_DETAIL_KEY=""
}
declare -gA TUI_SSGR=() TUI_DSGR=()

# --- terminal ----------------------------------------------------------------

_tui_enter() {
  TUI_STTY=$(stty -g </dev/tty)
  # Raw-ish mode: no echo, no line buffering, Ctrl-C/Ctrl-Z/Ctrl-S as keys.
  stty -echo -icanon -isig -ixon min 1 time 0 </dev/tty
  # Alternate screen, hidden cursor, no autowrap, background of the theme.
  printf '\e[?1049h\e[?25l\e[?7l%s\e[2J' "${TUI_B[main]}"
  TUI_ACTIVE=1
}

_tui_leave() {
  ((TUI_ACTIVE)) || return 0
  printf '\e[0m\e[2J\e[?7h\e[?25h\e[?1049l'
  [[ -n $TUI_STTY ]] && stty "$TUI_STTY" </dev/tty
  TUI_ACTIVE=0
}

_tui_suspend() {
  _tui_leave
  kill -TSTP $$
  _tui_enter
  _tui_size
}

_tui_size() {
  local size
  size=$(stty size </dev/tty 2>/dev/null) || size="24 80"
  TUI_ROWS=${size% *}
  TUI_COLS=${size#* }
  TUI_RESIZED=0
  TUI_DETAIL_KEY=""
}

# --- data --------------------------------------------------------------------

# _tui_reload — reload tasks for the current view, keeping the selection.
_tui_reload() {
  local keep_kind=${U_KIND[TUI_SEL]:-} keep_id=${U_ID[TUI_SEL]:-} keep_group=${U_GROUP[TUI_SEL]:-}
  local filter today rows
  td_today today
  td_focus_read TUI_FOCUS TUI_FOCUS_SINCE
  TUI_IDX=$(td_tasks_select '{"visibility": "all"}' \
    | jq -c 'map({id, title, status, parent, project, tags, due})') || TUI_IDX="[]"
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

  # Projects form a tree; the active view without a filter shows every
  # project (empty ones too), other views only those with matching tasks.
  local all_nodes=false
  [[ $TUI_VIEW == active && -z $TUI_FILTER ]] && all_nodes=true
  TUI_TREE=$(td_projects_tree) || TUI_TREE="[]"

  U_KIND=() U_GROUP=() U_LEVEL=() U_DEPTH=() U_ID=() U_STATUS=() U_PRIO=() U_DUE=()
  U_DUESTATE=() U_PROG=() U_TAGS=() U_FOCUS=() U_TITLE=() U_LAST=()
  local kind group level depth id status prio due dstate prog tags foc last title
  while IFS=$'\x1f' read -r kind group level depth id status prio due dstate prog tags foc last title; do
    if [[ $kind == G ]]; then
      _tui_collapsed "$group" 0 && continue
    else
      _tui_collapsed "$group" 1 && continue
    fi
    U_KIND+=("$kind") U_GROUP+=("$group") U_LEVEL+=("$level") U_DEPTH+=("$depth") U_ID+=("$id")
    U_STATUS+=("$status") U_PRIO+=("$prio") U_DUE+=("$due") U_DUESTATE+=("$dstate")
    U_PROG+=("$prog") U_TAGS+=("$tags") U_FOCUS+=("$foc") U_LAST+=("$last") U_TITLE+=("$title")
  done < <(LC_TIME=C jq -r --arg today "$today" --arg focus "$TUI_FOCUS" \
    --argjson tree "$TUI_TREE" --argjson all_nodes "$all_nodes" "$TD_JQ_DUE"'
    (map(.id)) as $ids
    | (map({key: (.id | tostring), value: .project}) | from_entries) as $proj
    | [.[] | . + (if .parent != null and (.parent | IN($ids[]))
                  then {grp: $proj[.parent | tostring], depth: 1}
                  else {grp: .project, depth: 0} end)] as $rows
    | ($rows | map(.grp) | unique) as $used
    | (if $all_nodes then $tree
       else [$tree[] | .path as $p | select(any($used[]; . == $p or startswith($p + "/")))] end)[] as $node
    | ($rows | map(select(.grp == $node.path))) as $items
    | (["G", $node.path, $node.depth, 0, "", "", "", "", "", "\($node.done)/\($node.total)",
        "", 0, 0, $node.name] | map(tostring) | join("\u001f")),
      ($items | to_entries[] | .key as $k | .value | due_info as $d
       | ["T", $node.path, $node.depth, .depth, .id, .status, .priority, ($d.text // ""), ($d.state // ""),
          (if .subtasks then "\(.subtasks.done)/\(.subtasks.total)" else "" end),
          (.tags | map("#" + .) | join(" ")),
          (if (.id | tostring) == $focus then 1 else 0 end),
          (if .depth == 1 and ($items[$k + 1].depth // 0) == 0 then 1 else 0 end),
          (.title | gsub("[[:cntrl:]]"; " "))]
       | map(tostring) | join("\u001f"))' <<<"$rows")

  read -r TUI_N_OPEN TUI_N_OVERDUE TUI_N_TODAY < <(jq -r --arg today "$today" '
    map(select(.status | IN("TODO", "IN_PROGRESS", "BLOCKED")))
    | [length, (map(select(.due != null and .due < $today)) | length),
       (map(select(.due == $today)) | length)] | @tsv' <<<"$TUI_IDX")

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

# _tui_collapsed PATH SELF — succeed when PATH is hidden by a collapsed project:
# one of its parents, or (SELF=1) the project itself.
_tui_collapsed() {
  local path=$1 acc="" seg
  local -a segs
  IFS=/ read -ra segs <<<"$path"
  for seg in "${segs[@]}"; do
    acc+=${acc:+/}$seg
    [[ $acc == "$path" && $2 == 0 ]] && return 1
    [[ -v TUI_COLLAPSED[$acc] ]] && return 0
  done
  return 1
}

# --- main screen -----------------------------------------------------------------

# _tui_base_build — render the main screen into TUI_BASE (positioned lines).
_tui_base_build() {
  local frame row=1 line
  # The frame is rendered in a subshell; build the cached parts here first so
  # the caches survive it (details per selection, the banner per size).
  _tui_layout
  if ((TUI_RW > 0 && TUI_COLS >= 50 && TUI_ROWS >= 12)); then
    _tui_detail_build "$TUI_RW" $((TUI_ROWS - 4))
  fi
  frame=$(_tui_frame)
  TUI_BASE=""
  while IFS= read -r line; do
    TUI_BASE+=$'\e['"$row;1H$line"
    row=$((row + 1))
  done <<<"$frame"
}

# _tui_layout — panel widths: TUI_LW (list) and TUI_RW (details; 0 if no room).
_tui_layout() {
  if ((TUI_COLS >= 90)); then
    TUI_LW=$((TUI_COLS * 52 / 100))
  elif ((TUI_COLS >= 72)); then
    TUI_LW=$((TUI_COLS * 58 / 100))
  else
    TUI_LW=$TUI_COLS
  fi
  TUI_RW=$((TUI_COLS - TUI_LW - 1))
  if ((TUI_RW < 0)); then TUI_RW=0; fi
}

# _tui_frame — print the main screen, one line per row. Pure (no terminal
# I/O), so tests can render it at any size.
_tui_frame() {
  local W=$TUI_COLS H=$TUI_ROWS
  if ((W < 50 || H < 12)); then
    _tl_start "$W"
    _tl_add "${TD_TC[yellow]}" "Terminal too small (${W}x${H}); need 50x12. q quits."
    _tl_end
    printf '%s\n' "$TL"
    return
  fi
  _tui_layout
  local B=$((H - 4)) sep="│"
  ((TD_UNICODE)) || sep="|"
  _tui_topbar
  printf '%s\n' "$TL"
  _tl_start "$W"
  _tl_end
  printf '%s\n' "$TL"

  # Panel headers.
  _tl_start "$TUI_LW"
  local tasks=0 i
  for i in "${!U_KIND[@]}"; do [[ ${U_KIND[i]} == T ]] && tasks=$((tasks + 1)); done
  _tl_add "${TD_TC[muted]}${TD_TC[bold]}" "  TASKS "
  _tl_add "${TD_TC[border]}" "$tasks"
  _tl_end
  local header=$TL
  if ((TUI_RW > 0)); then
    _tl_start "$TUI_RW"
    _tl_add "${TD_TC[muted]}${TD_TC[bold]}" "  DETAILS"
    _tl_end
    header+=${TUI_B[main]}${TD_TC[border]}$sep$TL
  fi
  printf '%s\n' "$header"

  # Body.
  local n=${#U_KIND[@]} row left right
  ((TUI_SEL < TUI_TOP)) && TUI_TOP=$TUI_SEL
  ((TUI_SEL >= TUI_TOP + B)) && TUI_TOP=$((TUI_SEL - B + 1))
  ((TUI_TOP < 0)) && TUI_TOP=0
  ((TUI_RW > 0)) && _tui_detail_build "$TUI_RW" "$B"
  for ((row = 0; row < B; row++)); do
    i=$((TUI_TOP + row))
    if ((i < n)); then
      _tui_list_line "$i" "$TUI_LW"
    else
      _tl_start "$TUI_LW"
      if ((n == 0 && row == B / 2 - 1)); then
        local msg="Nothing here yet"
        [[ -n $TUI_FILTER ]] && msg="No task matches “$TUI_FILTER”"
        _tl_gap $(((TUI_LW - ${#msg}) / 2))
        _tl_add "${TD_TC[fg]}${TD_TC[bold]}" "$msg"
      elif ((n == 0 && row == B / 2)); then
        local hint="press n to create a task"
        [[ $TUI_VIEW != active ]] && hint="press 1 for the active tasks, n to create one"
        _tl_gap $(((TUI_LW - ${#hint}) / 2))
        _tl_add "${TD_TC[muted]}" "$hint"
      fi
      _tl_end
    fi
    left=$TL
    if ((TUI_RW > 0)); then
      right=${TUI_DETAIL[row]:-}
      if [[ -z $right ]]; then
        _tl_start "$TUI_RW"
        _tl_end
        right=$TL
      fi
      printf '%s%s%s%s\n' "$left" "${TUI_B[main]}${TD_TC[border]}" "$sep" "$right"
    else
      printf '%s\n' "$left"
    fi
  done
  _tui_statusbar
  printf '%s' "$TL${TD_TC[reset]}"
}

_tui_topbar() {
  local W=$TUI_COLS right="" rlen=0
  # Right side first, to know how much room the tabs have.
  if [[ -n $TUI_FOCUS ]]; then
    local now dur ft
    printf -v now '%(%s)T' -1
    td_fmt_duration -v dur $((now > TUI_FOCUS_EPOCH ? now - TUI_FOCUS_EPOCH : 0))
    td_truncate ft "$TUI_FOCUS_TITLE" $((W / 4))
    right="${TD_SYM[focus]} $ft · $dur"
  else
    right="no focus"
  fi
  rlen=$((${#right} + 3))
  _tl_start $((W - rlen)) "${TUI_B[bar]}"
  _tl_pill bg accent "${TD_SYM[app]} todosh"
  _tl_gap 1
  local v k=1
  for v in "${TD_TUI_VIEWS[@]}"; do
    if [[ $v == "$TUI_VIEW" ]]; then
      _tl_add "${TD_TB[bg]}${TD_TC[accent]}${TD_TC[bold]}" " $k ${TD_TUI_VIEW_LABEL[$v]} "
    else
      _tl_add "${TD_TC[muted]}" " $k ${TD_TUI_VIEW_LABEL[$v]} "
    fi
    k=$((k + 1))
  done
  if [[ -n $TUI_FILTER && $TUI_MODE != filter ]]; then
    _tl_gap 1
    _tl_pill bg yellow "${TD_SYM[search]} $TUI_FILTER"
  fi
  _tl_end
  TLMAX=$W
  if [[ -n $TUI_FOCUS ]]; then
    _tl_pill bg magenta "$right"
  else
    _tl_add "${TD_TC[muted]}" " $right "
  fi
  _tl_gap 1
  _tl_end
}

_tui_statusbar() {
  local W=$TUI_COLS stats
  stats="$TUI_N_OPEN open"
  ((TUI_N_OVERDUE)) && stats+=" · ${TD_SYM[warn]} $TUI_N_OVERDUE overdue"
  ((TUI_N_TODAY)) && stats+=" · $TUI_N_TODAY due today"
  # The hints get what the counts leave; _tl_add cuts at TLMAX.
  _tl_start $((W - ${#stats} - 2)) "${TUI_B[bar]}"
  if [[ $TUI_MODE == filter ]]; then
    _tl_pill bg yellow "FILTER"
    _tl_gap 1
    _tl_add "${TD_TC[yellow]}" "${TD_SYM[search]} "
    _tl_input "$TUI_FILTER" "$TUI_FCUR" 30 1
    _tl_add "${TD_TC[muted]}" "  ⏎ keep · Esc clear"
  else
    _tl_pill bg accent "NORMAL"
    _tl_gap 1
    local pair
    for pair in "n new" "e edit" "␣ done" "f focus" "c comment" "/ filter" ": actions" "? help"; do
      ((TD_UNICODE)) || pair=${pair/␣/space}
      _tl_add "${TD_TC[accent]}${TD_TC[bold]}" " ${pair%% *}"
      _tl_add "${TD_TC[muted]}" " ${pair#* } "
    done
  fi
  _tl_end
  TLMAX=$W
  if ((TUI_N_OVERDUE)); then
    _tl_add "${TD_TC[red]}" " $stats "
  else
    _tl_add "${TD_TC[muted]}" " $stats "
  fi
  _tl_end
}

# _tui_list_line INDEX WIDTH — one row of the list into TL.
_tui_list_line() {
  local i=$1 width=$2 sel=0 base=${TUI_B[main]}
  if ((i == TUI_SEL)); then
    sel=1
    base=${TUI_B[sel]}
  fi
  _tl_start "$width" "$base"
  if ((sel)); then
    _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "${TD_SYM[bar]}"
  else
    _tl_add "" " "
  fi

  # Subprojects (and their tasks) are indented by their level.
  _tl_gap $((2 * ${U_LEVEL[i]:-0}))
  if [[ ${U_KIND[i]} == G ]]; then
    local mark=${TD_SYM[down]} ndone=${U_PROG[i]%/*} total=${U_PROG[i]#*/} bar
    [[ -v TUI_COLLAPSED[${U_GROUP[i]}] ]] && mark=${TD_SYM[right]}
    _tl_add "${TD_TC[accent]}" " $mark "
    if ((${U_LEVEL[i]:-0} > 0)); then
      _tl_add "${TD_TC[magenta]}${TD_TC[bold]}" "${U_TITLE[i]}"
    else
      _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "${U_TITLE[i]}"
    fi
    _tui_bar bar "$ndone" "$total" 6
    _tl_right $((${#bar} + ${#U_PROG[i]} + 3))
    _tl_add "${TD_TC[green]}" "$bar"
    _tl_add "${TD_TC[muted]}" " ${U_PROG[i]}  "
    _tl_end
    return
  fi

  local status=${U_STATUS[i]} closed=0
  td_status_is_closed "$status" && closed=1
  if ((U_DEPTH[i])); then
    if ((U_LAST[i])); then
      _tl_add "${TD_TC[border]}" "   ${TD_SYM[tree_end]} "
    else
      _tl_add "${TD_TC[border]}" "   ${TD_SYM[tree_mid]} "
    fi
  else
    _tl_add "" " "
  fi
  _tl_add "${TUI_SSGR[$status]:-}" "${TD_SYM[$status]}"
  _tl_add "" " "
  if ((U_FOCUS[i])); then
    _tl_add "${TD_TC[magenta]}${TD_TC[bold]}" "${TD_SYM[focus]} "
  fi

  # Right side: priority, progress, due date, id.
  local prio=${U_PRIO[i]} ptxt="" psgr=""
  case $prio in
    urgent) ptxt="${TD_SYM[prio_urgent]} urgent" psgr=${TD_TC[red]}${TD_TC[bold]} ;;
    high) ptxt="${TD_SYM[prio_high]} high" psgr=${TD_TC[orange]} ;;
    low) ptxt="${TD_SYM[prio_low]} low" psgr=${TD_TC[muted]} ;;
  esac
  ((closed)) && ptxt=""
  local due=""
  [[ -n ${U_DUE[i]} ]] && due="${TD_SYM[due]} ${U_DUE[i]}"
  local idt="#${U_ID[i]}"
  local rlen=$((${#idt} + 2))
  [[ -n $ptxt ]] && rlen=$((rlen + ${#ptxt} + 2))
  [[ -n ${U_PROG[i]} ]] && rlen=$((rlen + ${#U_PROG[i]} + 2))
  [[ -n $due ]] && rlen=$((rlen + ${#due} + 2))

  local tsgr=${TD_TC[fg]} title=${U_TITLE[i]}
  if ((closed)); then
    tsgr=${TD_TC[muted]}${TD_TC[strike]}
  elif ((U_FOCUS[i])); then
    tsgr=${TD_TC[magenta]}${TD_TC[bold]}
  elif ((sel)); then
    tsgr=${TD_TC[fg]}${TD_TC[bold]}
  fi
  local room=$((width - TLW - rlen - 1))
  ((room < 8)) && room=8
  td_truncate title "$title" "$room"
  _tl_add "$tsgr" "$title"
  _tl_right "$rlen"
  if [[ -n $ptxt ]]; then
    _tl_add "$psgr" "$ptxt"
    _tl_gap 2
  fi
  if [[ -n ${U_PROG[i]} ]]; then
    _tl_add "${TD_TC[muted]}" "${U_PROG[i]}"
    _tl_gap 2
  fi
  if [[ -n $due ]]; then
    _tl_add "${TUI_DSGR[${U_DUESTATE[i]}]:-${TD_TC[muted]}}" "$due"
    _tl_gap 2
  fi
  _tl_add "${TD_TC[border]}" "$idt"
  _tl_end
}

# --- details panel ---------------------------------------------------------------
# Each helper appends one finished line of width TUI_DW to TUI_DETAIL.

_tui_dl_start() {
  _tl_start "$TUI_DW"
  _tl_gap 2
}
_tui_dl_end() {
  _tl_end
  TUI_DETAIL+=("$TL")
}
_tui_dl_text() {
  _tui_dl_start
  _tl_add "$1" "$2"
  _tui_dl_end
}
_tui_dl_blank() {
  _tl_start "$TUI_DW"
  _tl_end
  TUI_DETAIL+=("$TL")
}
_tui_dl_section() {
  local rule char="─"
  ((TD_UNICODE)) || char="-"
  _tui_dl_blank
  _tui_dl_start
  _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "$1 "
  [[ -n ${2:-} ]] && _tl_add "${TD_TC[muted]}" "$2 "
  _tui_rule rule "$char" $((TUI_DW - TLW - 2))
  _tl_add "${TD_TC[border]}" "$rule"
  _tui_dl_end
}

# _tui_detail_build WIDTH HEIGHT — fill TUI_DETAIL for the selected row.
_tui_detail_build() {
  local width=$1 height=$2 key
  key="${U_KIND[TUI_SEL]:-}:${U_ID[TUI_SEL]:-}:${U_GROUP[TUI_SEL]:-}:$width:$height:$TUI_FOCUS:$TUI_DIM"
  [[ $key == "$TUI_DETAIL_KEY" ]] && return 0
  TUI_DETAIL_KEY=$key
  TUI_DETAIL=()
  TUI_DW=$width
  if ((${#U_KIND[@]} == 0)); then
    _tui_detail_welcome
    _tui_banner_place "$height"
    return 0
  fi
  _tui_dl_blank
  if [[ ${U_KIND[TUI_SEL]:-} == G ]]; then
    _tui_detail_group "${U_GROUP[TUI_SEL]:-}"
  else
    _tui_detail_task "${U_ID[TUI_SEL]:-}" "$height"
  fi
  _tui_banner_place "$height"
  return 0
}

# --- banner --------------------------------------------------------------------
# Logo + title art + tagline at the bottom of the details panel, when there is
# room. Built once per width/theme (it may run chafa) and cached in TUI_BANNER.

declare -ga TUI_BANNER=()
TUI_BANNER_KEY=""

# _tui_banner_place HEIGHT — append the banner at the bottom of TUI_DETAIL.
_tui_banner_place() {
  ((TUI_DIM)) && return 0
  _tui_banner_build "$TUI_DW"
  local n=${#TUI_BANNER[@]} free=$(($1 - ${#TUI_DETAIL[@]}))
  ((n > 0 && free >= n + 2)) || return 0
  while ((${#TUI_DETAIL[@]} < $1 - n - 1)); do _tui_dl_blank; done
  TUI_DETAIL+=("${TUI_BANNER[@]}")
}

# _tui_expand_path PATH — PATH with a leading ~/ expanded (no eval).
_tui_expand_path() {
  if [[ $1 == \~/* ]]; then
    printf '%s\n' "$HOME/${1#\~/}"
  else
    printf '%s\n' "$1"
  fi
}

# _tui_logo_check — tell, once, why a configured logo cannot be shown.
_tui_logo_check() {
  local file
  [[ -n ${TD_CONF[logo]:-} ]] || return 0
  file=$(_tui_expand_path "${TD_CONF[logo]}")
  if [[ ! -r $file ]]; then
    _tui_toast error "Logo not found: ${TD_CONF[logo]}"
  elif [[ ${file,,} == *.@(png|jpg|jpeg|gif|webp|bmp) ]] && ! command -v chafa >/dev/null 2>&1; then
    _tui_toast info "Image logos need chafa (e.g. sudo pacman -S chafa)"
  fi
  return 0
}

# _tui_banner_art WIDTH — print the title art lines that fit WIDTH.
_tui_banner_art() {
  local width=$1 choice=${TD_CONF[banner]:-auto} file="" line max=0
  local -a lines=()
  case $choice in
    none) return 0 ;;
    big | small) file=$TD_SHARE_DIR/banners/$choice.txt ;;
    auto) file=$TD_SHARE_DIR/banners/big.txt ;;
    *) file=$(_tui_expand_path "$choice") ;;
  esac
  [[ -f $file && -r $file ]] || return 0
  mapfile -t lines <"$file"
  for line in "${lines[@]}"; do ((${#line} > max)) && max=${#line}; done
  # auto: the big art when it fits, else the small one.
  if ((max > width)) && [[ $choice == auto ]]; then
    mapfile -t lines <"$TD_SHARE_DIR/banners/small.txt"
    max=0
    for line in "${lines[@]}"; do ((${#line} > max)) && max=${#line}; done
  fi
  ((max <= width)) || return 0
  # Box-drawing art needs Unicode.
  if ((! TD_UNICODE)) && [[ ${lines[*]} == *[─│┌┐└┘┬┴├┤]* ]]; then
    printf 'TODOSH\n'
    return 0
  fi
  printf '%s\n' "${lines[@]}"
}

# _tui_logo_lines HEIGHT — print the logo (text file, or image through chafa)
# at most HEIGHT rows tall. Image renders are cached on disk.
_tui_logo_lines() {
  local rows=$1 file
  [[ -n ${TD_CONF[logo]:-} ]] || return 0
  file=$(_tui_expand_path "${TD_CONF[logo]}")
  [[ -f $file && -r $file ]] || return 0
  case ${file,,} in
    *.png | *.jpg | *.jpeg | *.gif | *.webp | *.bmp)
      command -v chafa >/dev/null 2>&1 || return 0
      local cache=${XDG_CACHE_HOME:-$HOME/.cache}/todosh key colors=full
      ((TD_TIER == 2)) && colors=256
      ((TD_TIER <= 1)) && colors=16
      key=$(stat -c '%s-%Y' -- "$file" 2>/dev/null)-$rows-$colors-${TD_THEME[bg]#\#}
      key=$(printf '%s %s' "$file" "$key" | cksum)
      key=${key%% *}
      if [[ ! -f $cache/logo-$key.ans ]]; then
        mkdir -p -- "$cache" 2>/dev/null || return 0
        # --probe=off and no stdin: by default chafa queries the terminal and
        # waits for the answers, which would arrive in the TUI as key presses.
        local -a guard=()
        command -v timeout >/dev/null 2>&1 && guard=(timeout 15)
        "${guard[@]}" chafa --probe=off --polite=on --format=symbols --colors="$colors" \
          --size=$((rows * 2))x"$rows" --bg="${TD_THEME[bg]}" --animate=off -- "$file" \
          >"$cache/logo-$key.ans" 2>/dev/null </dev/null || {
          rm -f -- "$cache/logo-$key.ans"
          return 0
        }
      fi
      # Keep only colors: drop cursor and mode sequences chafa may add.
      local line
      while IFS= read -r line; do
        line=${line//$'\e[?'*([0-9;])[a-zA-Z]/}
        printf '%s\n' "$line"
      done <"$cache/logo-$key.ans"
      ;;
    *) head -n "$rows" -- "$file" ;;
  esac
}

_tui_banner_build() {
  local width=$1 key="$1:${TD_THEME_NAME}:$TD_TIER:${TD_CONF[banner]}:${TD_CONF[logo]}:${TD_CONF[tagline]}"
  [[ $key == "$TUI_BANNER_KEY" ]] && return 0
  TUI_BANNER_KEY=$key
  TUI_BANNER=()
  ((width >= 24)) || return 0

  local -a art=() logo=()
  local line lw=0 aw=0 i n
  mapfile -t logo < <(_tui_logo_lines 8)
  for line in "${logo[@]}"; do
    local plain=${line//$'\e['*([0-9;])m/}
    ((${#plain} > lw)) && lw=${#plain}
  done
  ((lw > width / 3)) && logo=() lw=0
  local room=$((width - 4 - (lw ? lw + 3 : 0)))
  mapfile -t art < <(_tui_banner_art "$room")
  for line in "${art[@]}"; do ((${#line} > aw)) && aw=${#line}; done
  local tagline=${TD_CONF[tagline]:-}
  td_truncate tagline "$tagline" $((width - 4))
  ((${#art[@]} + ${#logo[@]})) || [[ -n $tagline ]] || return 0

  # Title art fades from the accent color to magenta, line by line.
  local -a colors=()
  n=${#art[@]}
  for ((i = 0; i < n; i++)); do
    if ((TD_TIER >= 2 && n > 1)); then
      local hex rgb
      hex=$(td_hex_mix "${TD_THEME[accent]}" "${TD_THEME[magenta]}" $((100 * i / (n - 1))))
      if ((TD_TIER == 3)); then
        rgb=$(_td_rgb "$hex")
        colors+=($'\e[38;2;'"${rgb}m")
      else
        colors+=($'\e[38;5;'"$(td_hex_to_256 "$hex")m")
      fi
    else
      colors+=("${TD_TC[accent]}")
    fi
  done

  local rows=$((${#art[@]} > ${#logo[@]} ? ${#art[@]} : ${#logo[@]}))
  local block=$(((lw ? lw + 3 : 0) + aw))
  local left=$((width - block - 2))
  ((left < 2)) && left=2
  local r plain
  for ((r = 0; r < rows; r++)); do
    _tl_start "$width"
    _tl_gap "$left"
    if ((lw)); then
      line=${logo[r]:-}
      plain=${line//$'\e['*([0-9;])m/}
      # Pre-colored text: appended as is, counted by its visible width.
      TL+=$TLBASE$line$TLBASE
      TLW=$((TLW + ${#plain}))
      _tl_gap $((lw - ${#plain} + 3))
    fi
    [[ -n ${art[r]:-} ]] && _tl_add "${colors[r]}${TD_TC[bold]}" "${art[r]}"
    _tl_end
    TUI_BANNER+=("$TL")
  done
  if [[ -n $tagline ]]; then
    _tl_start "$width"
    _tl_gap $((width - ${#tagline} - 2))
    _tl_add "${TD_TC[muted]}${TD_TC[italic]}" "$tagline"
    _tl_end
    TUI_BANNER+=("$TL")
  fi
}

# _tui_detail_welcome — the details panel when there is nothing to select.
# It names the data directory: an empty list is often just a different one.
_tui_detail_welcome() {
  local dir=$TD_DATA_DIR
  [[ $dir == "$HOME"/* ]] && dir="~${dir#"$HOME"}"
  _tui_dl_blank
  _tui_dl_text "${TD_TC[fg]}${TD_TC[bold]}" "Welcome to todosh"
  _tui_dl_text "${TD_TC[muted]}" "Tasks are read from $dir"
  ((TUI_N_OPEN)) || [[ -n $(td_task_ids) ]] \
    || _tui_dl_text "${TD_TC[muted]}" "(empty; TODOSH_DATA_DIR picks another directory)"
  _tui_dl_blank
  local pair
  for pair in "n|create a task" "P|create a project or subproject" ",|settings, theme, logo" \
    "?|every shortcut"; do
    _tui_dl_start
    _tl_add "${TD_TC[accent]}${TD_TC[bold]}" "${pair%%|*}  "
    _tl_add "${TD_TC[fg]}" "${pair#*|}"
    _tui_dl_end
  done
}

_tui_detail_group() {
  local g=$1 counts ndone total ip blocked todo bar
  counts=$(jq -r --arg g "$g" '[.[] | select(.project == $g or (.project | startswith($g + "/")))] as $t
    | [($t | map(select(.status == "DONE")) | length),
       ($t | map(select(.status != "CANCELLED")) | length),
       ($t | map(select(.status == "IN_PROGRESS")) | length),
       ($t | map(select(.status == "BLOCKED")) | length),
       ($t | map(select(.status == "TODO")) | length)] | @tsv' <<<"$TUI_IDX")
  read -r ndone total ip blocked todo <<<"$counts"
  _tui_dl_start
  _tl_add "${TD_TC[accent]}" "${TD_SYM[project]} "
  _tl_add "${TD_TC[fg]}${TD_TC[bold]}" "$g"
  _tui_dl_end
  if [[ $g == */* ]]; then
    _tui_dl_text "${TD_TC[muted]}" "Subproject of ${g%/*}"
  else
    _tui_dl_text "${TD_TC[muted]}" "Project"
  fi
  local subs
  subs=$(jq -r --arg g "$g" '[.[] | select(.path | startswith($g + "/")) | select((.path | split("/") | length) == ($g | split("/") | length) + 1) | .name] | join(", ")' <<<"$TUI_TREE")
  [[ -n $subs ]] && _tui_dl_text "${TD_TC[magenta]}" "${TD_SYM[project]} $subs"
  _tui_dl_blank
  _tui_bar bar "$ndone" "$total" $((TUI_DW > 34 ? 24 : TUI_DW - 10))
  _tui_dl_start
  _tl_add "${TD_TC[green]}" "$bar"
  _tl_add "${TD_TC[muted]}" "  $ndone/$total done"
  _tui_dl_end
  _tui_dl_blank
  _tui_dl_start
  _tl_pill bg blue "${TD_SYM[IN_PROGRESS]} $ip in progress"
  _tl_gap 1
  _tl_pill bg red "${TD_SYM[BLOCKED]} $blocked blocked"
  _tl_gap 1
  _tl_pill bg muted "${TD_SYM[TODO]} $todo to do"
  _tui_dl_end
  _tui_dl_blank
  _tui_dl_text "${TD_TC[muted]}" "Space: collapse · n: task · P: subproject"
}

_tui_detail_task() {
  local id=$1 height=$2 file=$TD_DATA_DIR/tasks/$1.json today now
  [[ -f $file ]] || return 0
  td_today today
  printf -v now '%(%s)T' -1
  local -a recs
  mapfile -d '' recs < <(LC_TIME=C jq -j --arg today "$today" --argjson now "$now" \
    --argjson all "$TUI_IDX" --arg arrow "${TD_SYM[arrow]}" --arg none "${TD_SYM[dash]}" \
    "$TD_JQ_DUE$TD_JQ_EVENT"'
    def ago: ($now - fromdateiso8601) | if . < 60 then "now" elif . < 3600 then "\(. / 60 | floor)m"
      elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    def since: ago | if . == "now" then "just now" else . + " ago" end;
    def rec($a; $b): [$a, $b] | join("\u001f") + "\u0000";
    . as $t
    | rec("title"; .title | clean),
      rec("meta"; "#\(.id) · created \(.created | since) · updated \(.updated | since)"),
      rec("badges"; [.status, .priority, .project] | join("\u001e")),
      (if (.tags | length) > 0 then rec("tags"; .tags | map("#" + .) | join("  ")) else empty end),
      (due_info as $d | if $d then rec("due"; "\($d.state)\u001e\(.due | strptime("%Y-%m-%d") | mktime | strftime("%a %d %b"))\u001e\($d.text)") else empty end),
      rec("worked"; [.history[] | select(.type == "focus") | .seconds] | add // 0 | tostring),
      (if .parent then rec("parent"; "#\(.parent) \([$all[] | select(.id == $t.parent) | .title][0] // "")") else empty end),
      (if .description != "" then rec("desc"; .description | clean) else empty end),
      ([$all[] | select(.parent == $t.id)] as $subs
       | if ($subs | length) > 0 then
           rec("subs"; "\($subs | map(select(.status == "DONE")) | length)/\($subs | map(select(.status != "CANCELLED")) | length)"),
           ($subs[] | rec("sub"; "\(.status)\u001e\(.title | clean)"))
         else empty end),
      rec("activity"; ""),
      (.history | reverse | .[0:15][]
       | rec("hist"; "\(.type)\u001e\(.at | ago)\u001e\(entry_text | split("\n")[0])"))' <"$file")

  local item style text line w=$((TUI_DW - 4)) a b c
  for item in "${recs[@]}"; do
    style=${item%%$'\x1f'*}
    text=${item#*$'\x1f'}
    case $style in
      title)
        while IFS= read -r line; do
          _tui_dl_text "${TD_TC[fg]}${TD_TC[bold]}" "$line"
        done < <(_tui_wrap "$w" "$text")
        ;;
      meta) _tui_dl_text "${TD_TC[border]}" "$text" ;;
      badges)
        IFS=$'\x1e' read -r a b c <<<"$text"
        _tui_dl_blank
        _tui_dl_start
        _tl_pill bg "$(_tui_option_color status "$a")" "${TD_SYM[$a]} ${a//_/ }"
        _tl_gap 1
        if [[ $b != med ]]; then
          _tl_pill bg "$(_tui_option_color priority "$b")" "$b"
          _tl_gap 1
        fi
        _tl_add "${TD_TC[magenta]}" "${TD_SYM[project]} $c"
        _tui_dl_end
        ;;
      tags) _tui_dl_text "${TD_TC[cyan]}" "$text" ;;
      due)
        IFS=$'\x1e' read -r a b c <<<"$text"
        _tui_dl_blank
        _tui_dl_start
        _tl_add "${TUI_DSGR[$a]:-}" "${TD_SYM[due]}  "
        _tl_add "${TD_TC[muted]}" "Due     "
        _tl_add "${TUI_DSGR[$a]:-${TD_TC[fg]}}" "$b"
        [[ $c != "${b,,}" ]] && _tl_add "${TD_TC[muted]}" " · $c"
        _tui_dl_end
        ;;
      worked)
        local secs=$text focus_now=0 d
        if [[ $id == "$TUI_FOCUS" ]]; then
          focus_now=$((now > TUI_FOCUS_EPOCH ? now - TUI_FOCUS_EPOCH : 0))
          secs=$((secs + focus_now))
        fi
        if ((secs > 0)) || [[ $id == "$TUI_FOCUS" ]]; then
          _tui_dl_start
          _tl_add "${TD_TC[magenta]}" "${TD_SYM[focus]}  "
          _tl_add "${TD_TC[muted]}" "Worked  "
          td_fmt_duration -v d "$secs"
          _tl_add "${TD_TC[fg]}" "$d"
          if [[ $id == "$TUI_FOCUS" ]]; then
            td_fmt_duration -v d "$focus_now"
            _tl_add "${TD_TC[magenta]}" " · in focus for $d"
          fi
          _tui_dl_end
        fi
        ;;
      parent)
        _tui_dl_start
        _tl_add "${TD_TC[muted]}" "${TD_SYM[child]}  Part of "
        _tl_add "${TD_TC[fg]}" "$text"
        _tui_dl_end
        ;;
      desc)
        _tui_dl_section "Notes"
        local count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if ((count > 6)); then
            _tui_dl_text "${TD_TC[muted]}${TD_TC[italic]}" "… ⏎ to read everything"
            break
          fi
          _tui_dl_text "${TD_TC[fg]}" "$line"
        done < <(_tui_wrap "$w" "$text")
        ;;
      subs)
        local bar
        _tui_bar bar "${text%/*}" "${text#*/}" 10
        _tui_dl_section "Subtasks" "$text"
        _tui_dl_text "${TD_TC[green]}" "$bar"
        ;;
      sub)
        a=${text%%$'\x1e'*} b=${text#*$'\x1e'}
        _tui_dl_start
        _tl_add "${TUI_SSGR[$a]:-}" "${TD_SYM[$a]} "
        if td_status_is_closed "$a"; then
          _tl_add "${TD_TC[muted]}${TD_TC[strike]}" "$b"
        else
          _tl_add "${TD_TC[fg]}" "$b"
        fi
        _tui_dl_end
        ;;
      activity) _tui_dl_section "Activity" ;;
      hist)
        IFS=$'\x1e' read -r a b c <<<"$text"
        local when
        printf -v when '%-4s' "$b"
        _tui_dl_start
        case $a in
          comment)
            _tl_add "${TD_TC[yellow]}" "${TD_SYM[dot]} "
            _tl_add "${TD_TC[muted]}" "$when"
            _tl_add "${TD_TC[fg]}" "$c"
            ;;
          focus)
            _tl_add "${TD_TC[magenta]}" "${TD_SYM[focus]} "
            _tl_add "${TD_TC[muted]}" "$when"
            _tl_add "${TD_TC[magenta]}" "$c"
            ;;
          *)
            _tl_add "${TD_TC[border]}" "${TD_SYM[event]} "
            _tl_add "${TD_TC[muted]}" "$when$c"
            ;;
        esac
        _tui_dl_end
        ;;
    esac
    ((${#TUI_DETAIL[@]} >= height)) && break
  done
}

# --- actions ---------------------------------------------------------------------

# _tui_sel_task — TUI_SID = the selected task ("" on a project row).
_tui_sel_task() {
  TUI_SID=""
  [[ ${U_KIND[TUI_SEL]:-} == T ]] && TUI_SID=${U_ID[TUI_SEL]:-}
  return 0
}

_tui_move() {
  local n=${#U_KIND[@]}
  TUI_SEL=$((TUI_SEL + $1))
  ((TUI_SEL >= n)) && TUI_SEL=$((n - 1))
  if ((TUI_SEL < 0)); then TUI_SEL=0; fi
}

# _tui_done RC MESSAGE — toast the outcome of a business call and reload.
_tui_done() {
  if (($1)); then
    _tui_toast error "${TD_LAST_ERROR:-something went wrong}"
  else
    _tui_toast ok "$2"
  fi
  _tui_reload
}

_tui_set_view() {
  TUI_VIEW=$1
  TUI_SEL=0 TUI_TOP=0
  _tui_reload
}

# _tui_action NAME — everything the user can do; keys and the palette call it.
_tui_action() {
  local id rc=0
  _tui_sel_task
  id=$TUI_SID
  case $1 in
    down) _tui_move 1 ;;
    up) _tui_move -1 ;;
    top) TUI_SEL=0 ;;
    bottom) _tui_move "${#U_KIND[@]}" ;;
    page_down) _tui_move $(((TUI_ROWS - 4) / 2)) ;;
    page_up) _tui_move $((-(TUI_ROWS - 4) / 2)) ;;
    collapse | expand | toggle_group)
      local g=${U_GROUP[TUI_SEL]:-}
      [[ -n $g ]] || return 0
      if [[ $1 == collapse || ($1 == toggle_group && ! -v TUI_COLLAPSED[$g]) ]]; then
        TUI_COLLAPSED[$g]=1
      else
        unset "TUI_COLLAPSED[$g]"
      fi
      _tui_reload
      [[ $1 == expand ]] || _tui_select_group "$g"
      ;;
    collapse_all | expand_all)
      local g
      TUI_COLLAPSED=()
      if [[ $1 == collapse_all ]]; then
        for g in "${U_GROUP[@]}"; do TUI_COLLAPSED[$g]=1; done
      fi
      _tui_reload
      ;;
    open)
      if [[ ${U_KIND[TUI_SEL]:-} == G ]]; then
        _tui_action toggle_group
      elif [[ -n $id ]]; then
        _tui_view_task "$id"
      fi
      ;;
    new) _tui_task_form new "" ;;
    new_project)
      local base=${U_GROUP[TUI_SEL]:-}
      if _tui_input "New project" "Name (use / for subprojects)" "${base:+$base/}" \
        "e.g. HardwareHacking/RF & SDR"; then
        local name=${TUI_INPUT%/}
        td_project_add "$name" || rc=$?
        if ((rc == 0)); then
          unset "TUI_COLLAPSED[${name%/*}]"
          _tui_reload
          _tui_select_group "$name"
          _tui_toast ok "Project $name created"
        else
          _tui_toast error "$TD_LAST_ERROR"
        fi
      fi
      ;;
    remove_project)
      local g=${U_GROUP[TUI_SEL]:-}
      [[ -n $g ]] || return 0
      _tui_confirm "Remove the empty project $g?" "Remove" || return 0
      td_project_remove "$g" || rc=$?
      _tui_done "$rc" "Project $g removed"
      ;;
    new_sub)
      [[ -n $id ]] || return 0
      local parent
      parent=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .parent // .id' <<<"$TUI_IDX")
      _tui_task_form new "$parent"
      ;;
    edit) [[ -n $id ]] && _tui_task_form edit "$id" ;;
    notes)
      [[ -n $id ]] || return 0
      local text
      text=$(jq -r .description "$TD_DATA_DIR/tasks/$id.json")
      _tui_edit_external text
      local -A ch=([description]=$text)
      td_task_edit "$id" ch || rc=$?
      _tui_done "$rc" "Notes saved"
      ;;
    comment)
      [[ -n $id ]] || return 0
      IN_EDITOR=1
      if _tui_input "Comment on #$id" "What happened?" ""; then
        td_task_comment "$id" "$TUI_INPUT" || rc=$?
        _tui_done "$rc" "Comment added"
      fi
      ;;
    toggle_done)
      [[ -n $id ]] || {
        _tui_action toggle_group
        return 0
      }
      if td_status_is_closed "${U_STATUS[TUI_SEL]:-}"; then
        _tui_status TODO
      else
        _tui_status DONE
      fi
      ;;
    start) _tui_status IN_PROGRESS ;;
    block) _tui_status BLOCKED ;;
    done) _tui_status DONE ;;
    cancel) _tui_status CANCELLED ;;
    reopen) _tui_status TODO ;;
    priority)
      [[ -n $id ]] || return 0
      TUI_PICK_INIT=${U_PRIO[TUI_SEL]:-}
      if _tui_pick "Priority of #$id" \
        "urgent"$'\x1f'"${TD_SYM[prio_urgent]} urgent"$'\x1f'"drop everything"$'\x1f'"red" \
        "high"$'\x1f'"${TD_SYM[prio_high]} high"$'\x1f'"soon"$'\x1f'"orange" \
        "med"$'\x1f'"${TD_SYM[dot]} med"$'\x1f'"normal"$'\x1f'"fg" \
        "low"$'\x1f'"${TD_SYM[prio_low]} low"$'\x1f'"someday"$'\x1f'"muted"; then
        local -A ch=([priority]=$TUI_PICKED)
        td_task_edit "$id" ch || rc=$?
        _tui_done "$rc" "Priority: $TUI_PICKED"
      fi
      ;;
    prio_up | prio_down) _tui_priority_step "$1" ;;
    move)
      [[ -n $id ]] || return 0
      _tui_projects_items
      TUI_PICK_INIT=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .project' <<<"$TUI_IDX")
      PK_CREATE=1
      if _tui_pick "Move #$id to project" "${TUI_ITEMS[@]}"; then
        if td_valid_project "$TUI_PICKED"; then
          local -A ch=([project]=$TUI_PICKED)
          td_task_edit "$id" ch || rc=$?
          _tui_done "$rc" "Moved to $TUI_PICKED"
        else
          _tui_toast error "Invalid project (up to 4 levels like a/b, 1-32 characters each)"
        fi
      fi
      ;;
    tags)
      [[ -n $id ]] || return 0
      local current
      current=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .tags | join(" ")' <<<"$TUI_IDX")
      _tui_tags_items
      TUI_PICK_INIT=$current PK_MULTI=1 PK_CREATE=1
      if _tui_pick "Tags of #$id" "${TUI_ITEMS[@]}"; then
        local add="" remove="" t
        for t in "${TUI_PICKED_LIST[@]}"; do [[ " $current " == *" $t "* ]] || add+="$t "; done
        for t in $current; do [[ " ${TUI_PICKED_LIST[*]} " == *" $t "* ]] || remove+="$t "; done
        local -A ch=([tags_add]=${add% } [tags_remove]=${remove% })
        td_task_edit "$id" ch || rc=$?
        _tui_done "$rc" "Tags saved"
      fi
      ;;
    focus)
      [[ -n $id ]] || return 0
      if [[ $id == "$TUI_FOCUS" ]]; then
        td_focus_clear || rc=$?
        _tui_done "$rc" "Focus released"
      else
        td_focus_set "$id" || rc=$?
        _tui_done "$rc" "${TD_SYM[focus]} Focusing on #$id"
      fi
      ;;
    delete)
      [[ -n $id ]] || return 0
      local kids q
      kids=$(jq -r --argjson id "$id" '[.[] | select(.parent == $id)] | length' <<<"$TUI_IDX")
      q="Move #$id “${U_TITLE[TUI_SEL]:-}” to the trash?"
      ((kids)) && q="Move #$id and its $kids subtask(s) to the trash?"
      _tui_confirm "$q" "Delete" || return 0
      td_task_delete 1 "$id" || rc=$?
      ((rc)) || TUI_LAST_DELETED=$id
      _tui_done "$rc" "Moved to the trash — press u to undo"
      ;;
    undo)
      if [[ -z $TUI_LAST_DELETED ]]; then
        _tui_toast info "Nothing to undo"
        return 0
      fi
      td_task_undelete "$TUI_LAST_DELETED" || rc=$?
      _tui_done "$rc" "#$TUI_LAST_DELETED restored"
      ((rc)) || TUI_LAST_DELETED=""
      ;;
    filter)
      TUI_MODE=filter
      TUI_FCUR=${#TUI_FILTER}
      ;;
    next_view | prev_view)
      local i step=1
      [[ $1 == prev_view ]] && step=$((${#TD_TUI_VIEWS[@]} - 1))
      for i in "${!TD_TUI_VIEWS[@]}"; do [[ ${TD_TUI_VIEWS[i]} == "$TUI_VIEW" ]] && break; done
      _tui_set_view "${TD_TUI_VIEWS[$(((i + step) % ${#TD_TUI_VIEWS[@]}))]}"
      ;;
    view_*) _tui_set_view "${1#view_}" ;;
    palette) _tui_palette ;;
    settings) _tui_settings ;;
    help) _tui_help ;;
    command)
      if _tui_input "Run a todosh command" "todosh …" "" "e.g. stats, purge, theme import kitty"; then
        _tui_split "$TUI_INPUT"
        [[ ${TUI_WORDS[0]:-} == todosh || ${TUI_WORDS[0]:-} == tdsh ]] && TUI_WORDS=("${TUI_WORDS[@]:1}")
        ((${#TUI_WORDS[@]})) && _tui_external _tui_run_command "${TUI_WORDS[@]}"
        td_config_load 2>/dev/null
        _tui_theme_init
        _tui_reload
      fi
      ;;
    redraw)
      _tui_size
      _tui_reload
      ;;
    suspend) _tui_suspend ;;
  esac
  return 0
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

_tui_select_task() {
  local i
  for i in "${!U_KIND[@]}"; do
    if [[ ${U_KIND[i]} == T && ${U_ID[i]} == "$1" ]]; then
      TUI_SEL=$i
      return
    fi
  done
}

# _tui_status STATUS — change the status of the selected task.
_tui_status() {
  local status=$1 id force=0 msg="" rc=0
  _tui_sel_task
  id=$TUI_SID
  [[ -n $id ]] || return 0
  [[ ${U_STATUS[TUI_SEL]:-} == "$status" ]] && return 0
  if [[ $status == BLOCKED ]]; then
    IN_ALLOW_EMPTY=1
    _tui_input "Block #$id" "What is it waiting for? (optional)" "" || return 0
    msg=$TUI_INPUT
  fi
  if td_status_is_closed "$status"; then
    local open
    open=$(jq -r --argjson id "$id" '[.[] | select(.parent == $id
      and (.status | IN("TODO", "IN_PROGRESS", "BLOCKED")))] | length' <<<"$TUI_IDX")
    if ((open > 0)); then
      _tui_confirm "#$id still has $open open subtask(s). Close them too?" "Close all" || return 0
      force=1
    fi
  fi
  td_task_set_status "$status" "$force" "$msg" "$id" || rc=$?
  _tui_done "$rc" "${TD_SYM[$status]} #$id is now ${status//_/ }"
}

_tui_priority_step() {
  local id cur next i rc=0
  local -a order=(low med high urgent)
  _tui_sel_task
  id=$TUI_SID
  [[ -n $id ]] || return 0
  cur=${U_PRIO[TUI_SEL]:-}
  for i in "${!order[@]}"; do [[ ${order[i]} == "$cur" ]] && break; done
  if [[ $1 == prio_up ]]; then i=$((i + 1)); else i=$((i - 1)); fi
  ((i < 0 || i > 3)) && return 0
  next=${order[i]}
  local -A ch=([priority]=$next)
  td_task_edit "$id" ch || rc=$?
  _tui_done "$rc" "Priority: $next"
}

# --- filter mode -------------------------------------------------------------------

_tui_filter_key() {
  case $1 in
    enter) TUI_MODE=normal ;;
    esc | ctrl-c)
      TUI_MODE=normal
      TUI_FILTER=""
      _tui_reload
      ;;
    *)
      local before=$TUI_FILTER
      _tui_edit TUI_FILTER TUI_FCUR "$1" || return 0
      if [[ $TUI_FILTER != "$before" ]]; then
        TUI_SEL=0
        _tui_reload
      fi
      ;;
  esac
}

# --- item lists for pickers -----------------------------------------------------------

declare -ga TUI_ITEMS=()

# Projects in tree order, subprojects indented; the value is the full path.
_tui_projects_items() {
  TUI_ITEMS=()
  local path name depth open pad
  while IFS=$'\x1f' read -r path name depth open; do
    printf -v pad '%*s' $((2 * depth)) ''
    TUI_ITEMS+=("$path"$'\x1f'"$pad${TD_SYM[project]} $name"$'\x1f'"$open open"$'\x1f')
  done < <(jq -r --arg def "${TD_CONF[default_project]}" '
    (if any(.[]; .path == $def) then . else . + [{path: $def, name: $def, depth: 0, open: 0}] end)[]
    | [.path, .name, .depth, .open] | map(tostring) | join("\u001f")' <<<"$TUI_TREE")
}

_tui_tags_items() {
  TUI_ITEMS=()
  local t c
  while IFS=$'\t' read -r t c; do
    [[ -n $t ]] && TUI_ITEMS+=("$t"$'\x1f'"#$t"$'\x1f'"$c"$'\x1f'"cyan")
  done < <(jq -r '[.[].tags[]] | group_by(.) | map({t: .[0], c: length})
    | sort_by(-.c, .t)[] | "\(.t)\t\(.c)"' <<<"$TUI_IDX")
}

# _tui_parent_items EXCLUDE_ID — open top-level tasks that can take subtasks.
_tui_parent_items() {
  TUI_ITEMS=(""$'\x1f'"No parent (top-level task)"$'\x1f'$'\x1f'"muted")
  local id title project
  while IFS=$'\x1f' read -r id title project; do
    TUI_ITEMS+=("$id"$'\x1f'"#$id $title"$'\x1f'"$project"$'\x1f')
  done < <(jq -r --arg ex "${1:-}" '.[] | select(.parent == null
      and (.status | IN("TODO", "IN_PROGRESS", "BLOCKED")) and ((.id | tostring) != $ex))
    | [.id, (.title | gsub("[[:cntrl:]]"; " ")), .project] | map(tostring) | join("\u001f")' <<<"$TUI_IDX")
}

# --- task form ----------------------------------------------------------------------

TUI_FORM_MODE="" TUI_FORM_ID=""

# _tui_task_form new PARENT | edit ID
_tui_task_form() {
  local mode=$1 arg=$2 rec project priority=med due="" tags="" parent="" notes="" title="" status=TODO
  TUI_FORM_MODE=$mode TUI_FORM_ID=""
  if [[ $mode == edit ]]; then
    TUI_FORM_ID=$arg
    rec=$(td_task_read "$arg") || {
      _tui_toast error "$TD_LAST_ERROR"
      return 0
    }
    local -a f
    mapfile -d '' f < <(jq -j '[.title, .status, .priority, .project, (.due // ""),
      (.tags | join(" ")), (.parent // "" | tostring), .description] | map(. + "\u0000") | add' <<<"$rec")
    title=${f[0]} status=${f[1]} priority=${f[2]} project=${f[3]} due=${f[4]}
    tags=${f[5]} parent=${f[6]} notes=${f[7]}
    _tui_form_reset "Edit #$arg" _tui_task_form_save
  else
    parent=$arg
    project=${TD_CONF[default_project]:-inbox}
    if [[ -n $parent ]]; then
      project=$(jq -r --argjson id "$parent" '.[] | select(.id == $id) | .project' <<<"$TUI_IDX")
      _tui_form_reset "New subtask of #$parent" _tui_task_form_save
    else
      [[ -n ${U_GROUP[TUI_SEL]:-} ]] && project=${U_GROUP[TUI_SEL]:-}
      _tui_form_reset "New task" _tui_task_form_save
    fi
  fi
  _tui_form_add title text "Title" "$title" "" "What needs to be done?"
  [[ $mode == edit ]] && _tui_form_add status segment "Status" "$status" "TODO IN_PROGRESS BLOCKED DONE CANCELLED"
  _tui_form_add project pick "Project" "$project" _tui_form_pick_project
  _tui_form_add priority segment "Priority" "$priority" "low med high urgent"
  _tui_form_add due date "Due" "$due" "" "none · fri, +3d, 2026-11-03"
  _tui_form_add tags pick "Tags" "$tags" _tui_form_pick_tags "none"
  F_SHOW[tags]=$(_tui_tags_label "$tags")
  _tui_form_add parent pick "Subtask of" "$parent" _tui_form_pick_parent
  F_SHOW[parent]=$(_tui_parent_label "$parent")
  _tui_form_add notes notes "Notes" "$notes" "" "optional · ⏎ opens your editor"
  if [[ $mode == new ]]; then
    _tui_form_add focus check "Focus" 0 "" "start working on it right away"
    _tui_form_add save button "Create" "" submit
  else
    _tui_form_add save button "Save" "" submit
  fi
  _tui_form_add cancel button "Cancel" "" cancel
  _tui_form_run || return 0
  _tui_reload
  [[ -n $TUI_FORM_ID ]] && _tui_select_task "$TUI_FORM_ID"
  return 0
}

_tui_tags_label() {
  local t out=""
  for t in $1; do out+="#$t "; done
  printf '%s' "${out% }"
}

_tui_parent_label() {
  if [[ -z $1 ]]; then
    printf 'none'
    return
  fi
  jq -r --argjson id "$1" '.[] | select(.id == $id) | "#\(.id) \(.title)"' <<<"$TUI_IDX"
}

_tui_form_pick_project() {
  _tui_projects_items
  TUI_PICK_INIT=${F_VAL[$1]} PK_CREATE=1
  if _tui_pick "Project" "${TUI_ITEMS[@]}"; then
    F_VAL[$1]=$TUI_PICKED F_SHOW[$1]=$TUI_PICKED
  fi
}

_tui_form_pick_tags() {
  _tui_tags_items
  TUI_PICK_INIT=${F_VAL[$1]} PK_MULTI=1 PK_CREATE=1
  if _tui_pick "Tags" "${TUI_ITEMS[@]}"; then
    F_VAL[$1]=${TUI_PICKED_LIST[*]}
    F_SHOW[$1]=$(_tui_tags_label "${F_VAL[$1]}")
  fi
}

_tui_form_pick_parent() {
  _tui_parent_items "$TUI_FORM_ID"
  TUI_PICK_INIT=${F_VAL[$1]}
  if _tui_pick "Subtask of" "${TUI_ITEMS[@]}"; then
    F_VAL[$1]=$TUI_PICKED
    F_SHOW[$1]=$(_tui_parent_label "$TUI_PICKED")
  fi
}

# _tui_task_form_save — validate and apply the form (create or edit). On
# failure F_ERR/F_ERR_FIELD say what is wrong and the form stays open.
_tui_task_form_save() {
  local title=${F_VAL[title]} due="" t
  title=${title##+([[:space:]])}
  title=${title%%+([[:space:]])}
  if ! td_valid_title "$title"; then
    F_ERR="A title is required (one line, up to 200 characters)" F_ERR_FIELD=title
    return 1
  fi
  if ! td_valid_project "${F_VAL[project]}"; then
    F_ERR="Invalid project (up to 4 levels like a/b, 1-32 characters each)" F_ERR_FIELD=project
    return 1
  fi
  for t in ${F_VAL[tags]}; do
    if ! td_valid_name "$t"; then
      F_ERR="Invalid tag: $t" F_ERR_FIELD=tags
      return 1
    fi
  done
  if [[ -n ${F_VAL[due]//[[:space:]]/} ]] && ! td_due_parse due "${F_VAL[due]}" 2>/dev/null; then
    F_ERR="Unrecognized date: ${F_VAL[due]}" F_ERR_FIELD=due
    return 1
  fi

  if [[ $TUI_FORM_MODE == new ]]; then
    local -a tags=()
    read -ra tags <<<"${F_VAL[tags]}"
    if ! td_task_add "$title" "${F_VAL[project]}" "${F_VAL[priority]}" "${F_VAL[parent]}" \
      "${F_VAL[notes]}" "$due" "${tags[@]}"; then
      F_ERR=$TD_LAST_ERROR
      return 1
    fi
    local id=$TD_RESULT msg="Created #$TD_RESULT"
    TUI_FORM_ID=$id
    if ((F_VAL[focus])); then
      td_focus_set "$id" && msg="Created #$id — focusing on it"
    fi
    _tui_toast ok "$msg"
    return 0
  fi

  local id=$TUI_FORM_ID
  local -A ch=()
  [[ $title != "${F_ORIG[title]}" ]] && ch[title]=$title
  [[ ${F_VAL[priority]} != "${F_ORIG[priority]}" ]] && ch[priority]=${F_VAL[priority]}
  [[ ${F_VAL[project]} != "${F_ORIG[project]}" ]] && ch[project]=${F_VAL[project]}
  [[ ${F_VAL[notes]} != "${F_ORIG[notes]}" ]] && ch[description]=${F_VAL[notes]}
  [[ ${F_VAL[due]} != "${F_ORIG[due]}" ]] && ch[due]=$due
  [[ ${F_VAL[parent]} != "${F_ORIG[parent]}" ]] && ch[parent]=${F_VAL[parent]:-none}
  local add="" remove=""
  for t in ${F_VAL[tags]}; do [[ " ${F_ORIG[tags]} " == *" $t "* ]] || add+="$t "; done
  for t in ${F_ORIG[tags]}; do [[ " ${F_VAL[tags]} " == *" $t "* ]] || remove+="$t "; done
  [[ -n $add ]] && ch[tags_add]=${add% }
  [[ -n $remove ]] && ch[tags_remove]=${remove% }
  if ((${#ch[@]})) && ! td_task_edit "$id" ch; then
    F_ERR=$TD_LAST_ERROR
    return 1
  fi
  if [[ ${F_VAL[status]} != "${F_ORIG[status]}" ]]; then
    local force=0 open
    if td_status_is_closed "${F_VAL[status]}"; then
      open=$(jq -r --argjson id "$id" '[.[] | select(.parent == $id
        and (.status | IN("TODO", "IN_PROGRESS", "BLOCKED")))] | length' <<<"$TUI_IDX")
      if ((open > 0)); then
        if ! _tui_confirm "#$id has $open open subtask(s). Close them too?" "Close all"; then
          F_ERR="Status not changed: the task has open subtasks" F_ERR_FIELD=status
          return 1
        fi
        force=1
      fi
    fi
    if ! td_task_set_status "${F_VAL[status]}" "$force" "" "$id"; then
      F_ERR=$TD_LAST_ERROR F_ERR_FIELD=status
      return 1
    fi
  fi
  _tui_toast ok "Saved #$id"
  return 0
}

# --- palette, settings, help, full view ------------------------------------------------

_tui_palette() {
  local -a items=()
  local entry a label key
  for entry in \
    "new|New task|n" "new_sub|New subtask|N" "new_project|New project / subproject|P" "remove_project|Remove empty project|" "edit|Edit task|e" "notes|Edit notes in editor|E" \
    "comment|Add a comment|c" "toggle_done|Done / reopen|space" "start|Start|s" "block|Block|b" \
    "cancel|Cancel task|x" "reopen|Reopen|r" "priority|Change priority|p" "move|Move to project|m" \
    "tags|Edit tags|t" "focus|Focus / release focus|f" "delete|Delete task|D" "undo|Undo delete|u" \
    "filter|Filter tasks|/" "view_active|View: active|1" "view_all|View: all|2" \
    "view_overdue|View: overdue|3" "view_blocked|View: blocked|4" "collapse_all|Collapse all projects|" \
    "expand_all|Expand all projects|" "settings|Settings & theme|," "help|Keyboard shortcuts|?" \
    "command|Run a todosh command…|" "quit|Quit|q"; do
    IFS='|' read -r a label key <<<"$entry"
    items+=("$a"$'\x1f'"$label"$'\x1f'"$key"$'\x1f')
  done
  _tui_pick "Actions" "${items[@]}" || return 0
  if [[ $TUI_PICKED == quit ]]; then
    _tui_leave
    exit 0
  fi
  _tui_action "$TUI_PICKED"
}

TUI_SETTINGS_THEME=""

_tui_settings() {
  TUI_SETTINGS_THEME=${TD_CONF[theme]}
  _tui_form_reset "Settings" _tui_settings_save
  _tui_form_add theme pick "Theme" "${TD_CONF[theme]}" _tui_settings_pick_theme
  _tui_form_add icons segment "Icons" "${TD_CONF[icons]}" "auto unicode nerd ascii"
  _tui_form_add color segment "Colors" "${TD_CONF[color]}" "auto always never"
  _tui_form_add background segment "Background" "${TD_CONF[background]}" "solid terminal"
  _tui_form_add archive_after_days text "Archive" "${TD_CONF[archive_after_days]}" "" \
    "days before done tasks leave Active (0 = never)"
  _tui_form_add default_project text "Project" "${TD_CONF[default_project]}" "" "default project for new tasks"
  _tui_form_add editor text "Editor" "${TD_CONF[editor]}" "" "\$VISUAL / \$EDITOR, else nvim, vim, nano"
  local banner=${TD_CONF[banner]}
  td_in_list "$banner" auto big small none || banner=auto
  _tui_form_add banner segment "Banner" "$banner" "auto big small none"
  _tui_form_add logo text "Logo" "${TD_CONF[logo]}" "" "path, e.g. ~/logo.png (needs chafa) or ~/logo.txt"
  _tui_form_add tagline text "Tagline" "${TD_CONF[tagline]}" "" "one line under the title"
  _tui_form_add save button "Save" "" submit
  _tui_form_add cancel button "Cancel" "" cancel
  if ! _tui_form_run; then
    # Cancelled: undo the live theme preview.
    TD_CONF[theme]=$TUI_SETTINGS_THEME
    _tui_theme_init
  fi
  _tui_reload
}

_tui_settings_pick_theme() {
  local -a items=()
  local name src
  while IFS=$'\t' read -r name src; do
    items+=("$name"$'\x1f'"$name"$'\x1f'"$src"$'\x1f')
  done < <(td_theme_list)
  TUI_PICK_INIT=${F_VAL[$1]} PK_ONMOVE=_tui_preview_theme
  if _tui_pick "Theme (preview as you move)" "${items[@]}"; then
    F_VAL[$1]=$TUI_PICKED F_SHOW[$1]=$TUI_PICKED
  fi
  _tui_preview_theme "${F_VAL[$1]}"
}

_tui_preview_theme() {
  TD_CONF[theme]=$1
  _tui_theme_init
  TUI_DIM=1
  _tui_base_build
  TUI_DIM=0
}

_tui_settings_save() {
  local key
  for key in theme icons color background archive_after_days default_project editor banner logo tagline; do
    if ! td_config_valid "$key" "${F_VAL[$key]}"; then
      F_ERR="Invalid value for ${F_LABEL[$key],,}: '${F_VAL[$key]}'" F_ERR_FIELD=$key
      return 1
    fi
  done
  for key in theme icons color background archive_after_days default_project editor banner logo tagline; do
    [[ ${F_VAL[$key]} == "${F_ORIG[$key]}" && $key != theme ]] && continue
    if ! td_config_set "$key" "${F_VAL[$key]}"; then
      F_ERR=$TD_LAST_ERROR F_ERR_FIELD=$key
      return 1
    fi
  done
  TUI_SETTINGS_THEME=${TD_CONF[theme]}
  _tui_theme_init
  _tui_toast ok "Settings saved"
  return 0
}

_tui_help() {
  local K=$'\x1e' S=$'\x1f'
  _tui_view "Keyboard shortcuts" \
    "head${S}Move" \
    "key${S}  j k  ↑ ↓     ${K}move · g G first / last · PgUp PgDn page" \
    "key${S}  h l  ← →     ${K}collapse / expand a project" \
    "key${S}  Tab  1-4     ${K}views: active, all, overdue, blocked" \
    "key${S}  /            ${K}filter as you type (Esc clears)" \
    "${S}" "head${S}Tasks" \
    "key${S}  n  N         ${K}new task / new subtask (a form)" \
    "key${S}  e            ${K}edit everything in a form" \
    "key${S}  E            ${K}edit the notes in your editor" \
    "key${S}  ⏎            ${K}read the whole task" \
    "key${S}  c            ${K}comment" \
    "key${S}  p  + -       ${K}priority (pick, raise, lower)" \
    "key${S}  m  t         ${K}move to project · tags" \
    "key${S}  P            ${K}new project or subproject (a/b)" \
    "key${S}  D  u         ${K}delete · undo" \
    "${S}" "head${S}Status and focus" \
    "key${S}  Space        ${K}done / reopen" \
    "key${S}  s b d x r    ${K}start · block · done · cancel · reopen" \
    "key${S}  f            ${K}focus on the task (again to release it)" \
    "${S}" "head${S}Everything else" \
    "key${S}  :            ${K}all actions, searchable" \
    "key${S}  ,            ${K}settings and theme (live preview)" \
    "key${S}  ?  Ctrl-L  q ${K}help · redraw · quit" \
    "${S}" "head${S}In forms" \
    "key${S}  Tab ⇧Tab ↑↓  ${K}move between fields" \
    "key${S}  ← →          ${K}choose an option · ⏎ open a list" \
    "key${S}  Ctrl-S       ${K}save from anywhere · Esc cancel" \
    "${S}" "muted${S}Theme: ${TD_THEME_NAME} · colors: tier $TD_TIER (3 truecolor, 2 256, 1 16, 0 none)"
}

# _tui_view_task ID — the whole task, scrollable.
_tui_view_task() {
  local id=$1 rec w=$((TUI_COLS - 12)) line S=$'\x1f'
  ((w > 92)) && w=92
  rec=$(td_task_read "$id") || return 0
  local -a lines=() f
  mapfile -d '' f < <(jq -j --arg arrow "${TD_SYM[arrow]}" --arg none "${TD_SYM[dash]}" "$TD_JQ_EVENT"'
    [.title, "\(.status) · \(.priority) · \(.project)",
     (if (.tags | length) > 0 then .tags | map("#" + .) | join(" ") else "" end),
     (.due // ""), .description,
     ([.history[] | "\(.at | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M"))\u001e\(.type)\u001e\(entry_text)"] | join("\u001d"))]
    | map(. + "\u0000") | add' <<<"$rec")
  while IFS= read -r line; do lines+=("head${S}$line"); done < <(_tui_wrap "$w" "#$id ${f[0]}")
  lines+=("muted${S}${f[1]}")
  [[ -n ${f[2]} ]] && lines+=("cyan${S}${f[2]}")
  [[ -n ${f[3]} ]] && lines+=("yellow${S}Due ${f[3]}")
  if [[ -n ${f[4]} ]]; then
    lines+=("${S}" "head${S}Notes")
    while IFS= read -r line; do lines+=("${S}$line"); done < <(_tui_wrap "$w" "${f[4]}")
  fi
  lines+=("${S}" "head${S}History")
  local entry when type text rest
  local -a entries
  IFS=$'\x1d' read -r -d '' -a entries <<<"${f[5]}"
  for entry in "${entries[@]}"; do
    entry=${entry%$'\n'}
    IFS=$'\x1e' read -r -d '' when type text <<<"$entry"
    text=${text%$'\n'}
    if [[ $type == comment ]]; then
      lines+=("yellow${S}$when  ${TD_SYM[dot]} ${text%%$'\n'*}")
      rest=""
      [[ $text == *$'\n'* ]] && rest=${text#*$'\n'}
      while IFS= read -r line; do
        [[ -n $line ]] && lines+=("${S}                     $line")
      done <<<"$rest"
    else
      lines+=("muted${S}$when  ${TD_SYM[event]} $text")
    fi
  done
  _tui_view "Task #$id" "${lines[@]}"
}

# --- typed commands -----------------------------------------------------------------

# _tui_split LINE — split a command line into TUI_WORDS, honoring '...' and
# "..." quotes and backslash escapes. Nothing is evaluated.
declare -ga TUI_WORDS=()
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

# _tui_external CMD ARG... — run CMD on the normal screen, then wait for a key.
_tui_external() {
  _tui_leave
  (
    TD_QUIET_ERRORS=0
    "$@"
  )
  printf '\n%s-- press any key to return --%s' "${TD_SGR[gray]}" "${TD_SGR[reset]}"
  IFS= read -rsn1 -d '' _ </dev/tty
  _tui_enter
  _tui_size
  _tui_reload
}

_tui_run_command() {
  printf '%s$ todosh %s%s\n' "${TD_SGR[gray]}" "$*" "${TD_SGR[reset]}"
  TD_OPT_JSON=0
  td_main "$@"
}
