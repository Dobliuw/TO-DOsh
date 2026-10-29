# shellcheck shell=bash
# commands.sh — task commands: argument parsing and CLI presentation.
#
# Each command parses its arguments, calls the business layer (tasks.sh) and
# renders the result as text or, with --json, as exactly one JSON document.

# Parsed task fields (see _td_parse_reset).
declare -gA TD_P=()
declare -ga TD_P_TAGS=() TD_P_UNTAGS=()
TD_VAL=""
TD_SHIFT=0
# Temporary file of an editor session, kept if saving fails.
TD_EDIT_TMP=""

_td_parse_reset() {
  TD_P=()
  TD_P_TAGS=()
  TD_P_UNTAGS=()
}

# _td_take ARG... — value of an option given as `--opt value` or `--opt=value`.
# Sets TD_VAL and TD_SHIFT (how many arguments to consume).
_td_take() {
  if [[ $1 == --*=* ]]; then
    TD_VAL=${1#*=}
    TD_SHIFT=1
  elif (($# >= 2)); then
    TD_VAL=$2
    TD_SHIFT=2
  else
    td_usage_err "$TD_CMD" "option $1 needs a value"
    return
  fi
}

# _td_shorthand ARG — recognize an inline field token:
#   p:NAME  project:NAME   pri:LEVEL  !LEVEL   +TAG   ^ID  parent:ID   due:WHEN
# Only whole arguments are tokens, so quoted multi-word text stays literal.
_td_shorthand() {
  case $1 in
    p:?* | project:?*) TD_P[project]=${1#*:} ;;
    pri:?*) TD_P[priority]=${1#pri:} ;;
    '!'?*) TD_P[priority]=${1#!} ;;
    +?*) TD_P_TAGS+=("${1#+}") ;;
    '^'?*) TD_P[parent]=${1#^} ;;
    parent:?*) TD_P[parent]=${1#parent:} ;;
    due:*) TD_P[due]=${1#due:} ;;
    *) return 1 ;;
  esac
}

# _td_field_option ARG... — handle an option shared by add/edit/list.
# Returns 1 when ARG is not one of them; sets TD_SHIFT otherwise.
_td_field_option() {
  local key
  case $1 in
    --project | --project=*) key=project ;;
    --priority | --priority=*) key=priority ;;
    --tag | --tag=*) key=tag ;;
    --parent | --parent=*) key=parent ;;
    --due | --due=*) key=due ;;
    *) return 1 ;;
  esac
  # A missing value is a usage error, not "unrecognized".
  _td_take "$@" || return "$TD_E_USAGE"
  if [[ $key == tag ]]; then
    TD_P_TAGS+=("$TD_VAL")
  else
    TD_P[$key]=$TD_VAL
  fi
}

# _td_norm_priority — expand short priority names in TD_P[priority].
_td_norm_priority() {
  [[ -v TD_P[priority] ]] || return 0
  local p=${TD_P[priority],,}
  case $p in
    u) p=urgent ;;
    h) p=high ;;
    m | medium) p=med ;;
    l) p=low ;;
  esac
  TD_P[priority]=$p
}

# _td_parse_due VAR — normalize TD_P[due], if given, into VAR.
_td_parse_due() {
  local -n _td_pd=$1
  _td_pd=""
  [[ -v TD_P[due] ]] || return 0
  td_due_parse "$1" "${TD_P[due]}" || {
    printf "Try 'todosh %s --help'.\n" "$TD_CMD" >&2
    return "$TD_E_USAGE"
  }
}

# _td_read_stdin VAR — read all of stdin into VAR (trailing newlines dropped).
_td_read_stdin() {
  local -n _td_in=$1
  _td_in=$(cat)
}

# _td_json_tasks AREA ID... — print the given tasks as a JSON array.
_td_json_tasks() {
  local area=$1 id
  local -a files=()
  shift
  for id in "$@"; do
    files+=("$TD_DATA_DIR/$area/$id.json")
  done
  if ((${#files[@]} == 0)); then
    printf '[]\n'
  else
    jq -s . "${files[@]}"
  fi
}

# _td_titles AREA ID... — print "ID<US>STATUS<US>TITLE" lines for messages.
_td_titles() {
  local area=$1 id
  local -a files=()
  shift
  for id in "$@"; do
    files+=("$TD_DATA_DIR/$area/$id.json")
  done
  ((${#files[@]})) || return 0
  jq -r '[.id, .status, (.title | gsub("[[:cntrl:]]"; " "))]
         | map(tostring) | join("\u001f")' "${files[@]}"
}

# _td_say_tasks AREA FORMAT ID... — one line per task; FORMAT gets the ID,
# the colored status and the title.
_td_say_tasks() {
  local area=$1 format=$2 id status title
  shift 2
  while IFS=$'\x1f' read -r id status title; do
    # shellcheck disable=SC2059 # FORMAT is a fixed internal template
    printf "$format\n" "$id" "$(td_status_color "$status")$status${TD_SGR[reset]}" "$title"
  done < <(_td_titles "$area" "$@")
}

# --- add -------------------------------------------------------------------

td_register_cmd add Tasks "Create a task"
td_help_add() {
  printf '%s\n' \
    "Usage: todosh add [options] <title words...>" \
    "" \
    "Options:" \
    "  --project PATH       Project; subprojects are paths: 'Hacking/RF & SDR'" \
    "                       (default: the parent's, else config" \
    "                       'default_project', which defaults to inbox)" \
    "  --priority LEVEL     urgent | high | med | low (default: med)" \
    "  --tag NAME           Add a tag (repeatable)" \
    "  --parent ID          Create as a subtask of ID" \
    "  --due WHEN           Due date: today, tomorrow, fri, +3d, +2w, 2026-11-03" \
    "  -d, --description T  Description text; '-' reads it from stdin" \
    "" \
    "Inline shorthand (whole words only; quoted phrases stay literal):" \
    "  p:infra   pri:high (or pri:h)   +network   ^42 (or parent:42)   due:fri" \
    "  Use -- to stop parsing: todosh add -- +1 for the idea" \
    "  Note: '!high' also works, but most shells need it quoted: '!high'" \
    "" \
    "Examples:" \
    "  todosh add Review firewall rules p:infra pri:high +network due:fri" \
    "  todosh add \"Export current rules\" ^42" \
    "  todosh add Write report --json | jq .id"
}

td_cmd_add() {
  if td_wants_help "$@"; then
    td_help_add
    return 0
  fi
  _td_parse_reset
  local -a words=()
  local literal=0 rc
  while (($#)); do
    if ((literal)); then
      words+=("$1")
      shift
      continue
    fi
    case $1 in
      --)
        literal=1
        shift
        continue
        ;;
      -d | --description | --description=*)
        _td_take "$@" || return
        TD_P[description]=$TD_VAL
        shift "$TD_SHIFT"
        continue
        ;;
    esac
    _td_field_option "$@" && {
      shift "$TD_SHIFT"
      continue
    }
    rc=$?
    ((rc == TD_E_USAGE)) && return "$rc"
    case $1 in
      -?*)
        td_usage_err add "unknown option: $1"
        return
        ;;
    esac
    _td_shorthand "$1" || words+=("$1")
    shift
  done
  local due
  _td_parse_due due || return
  _td_norm_priority
  if ((${#words[@]} == 0)); then
    td_usage_err add "missing task title"
    return
  fi
  local description=${TD_P[description]:-}
  [[ $description == - ]] && _td_read_stdin description

  td_storage_init || return
  td_task_add "${words[*]}" "${TD_P[project]:-}" \
    "${TD_P[priority]:-med}" "${TD_P[parent]:-}" "$description" "$due" "${TD_P_TAGS[@]}" || return
  local id=$TD_RESULT
  if ((TD_OPT_JSON)); then
    jq . "$TD_DATA_DIR/tasks/$id.json"
  else
    _td_say_tasks tasks "Created #%s %.0s%s" "$id"
  fi
}

# --- list ------------------------------------------------------------------

td_register_cmd list Tasks "List tasks (open and recently closed by default)"
td_help_list() {
  printf '%s\n' \
    "Usage: todosh list [options] [filters]" \
    "" \
    "Shows open tasks and tasks closed in the last 'archive_after_days' days." \
    "" \
    "Options:" \
    "  -a, --all           Include every closed task" \
    "  -o, --open          Only open tasks (TODO, IN_PROGRESS, BLOCKED)" \
    "  --overdue           Only open tasks past their due date" \
    "  --status LIST       Only these statuses (comma-separated, e.g. todo,blocked)" \
    "  --project NAME      Filter by project and its subprojects (repeatable)" \
    "                      shorthand: p:NAME, e.g. p:HardwareHacking" \
    "  --priority LEVEL    Filter by priority (repeatable)      shorthand: pri:LEVEL" \
    "  --tag NAME          Require a tag (repeatable)           shorthand: +NAME" \
    "  --parent ID         Only subtasks of ID                  shorthand: ^ID" \
    "" \
    "Subtasks appear indented under their parent when both match; the focused" \
    "task is marked. On a terminal, a last line warns about overdue tasks." \
    "" \
    "Examples:" \
    "  todosh list p:infra +network" \
    "  todosh list --status blocked --json | jq -r '.[].title'"
}

td_cmd_list() {
  if td_wants_help "$@"; then
    td_help_list
    return 0
  fi
  _td_parse_reset
  local visibility=default overdue=false rc s
  local -a statuses=() projects=() priorities=()
  while (($#)); do
    case $1 in
      -a | --all) visibility=all ;;
      -o | --open) visibility=open ;;
      --overdue) overdue=true ;;
      --status | --status=*)
        _td_take "$@" || return
        local -a parts
        IFS=, read -ra parts <<<"$TD_VAL"
        for s in "${parts[@]}"; do
          s=${s^^}
          if ! td_valid_status "$s"; then
            td_usage_err list "invalid status: '$s'"
            return
          fi
          statuses+=("$s")
        done
        shift "$TD_SHIFT"
        continue
        ;;
      *)
        if _td_field_option "$@"; then
          _td_collect_filters
          shift "$TD_SHIFT"
          continue
        fi
        rc=$?
        ((rc == TD_E_USAGE)) && return "$rc"
        if ! _td_shorthand "$1"; then
          td_usage_err list "unexpected argument: $1"
          return
        fi
        _td_collect_filters
        ;;
    esac
    shift
  done
  if [[ -v TD_P[due] ]]; then
    td_usage_err list "due: is not a list filter; use --overdue"
    return
  fi
  for s in "${projects[@]}"; do
    td_valid_project "$s" || {
      td_usage_err list "invalid project: '$s'"
      return
    }
  done
  for s in "${priorities[@]}"; do
    td_valid_priority "$s" || {
      td_usage_err list "invalid priority: '$s'"
      return
    }
  done
  if [[ -v TD_P[parent] ]] && ! td_valid_id "${TD_P[parent]}"; then
    td_usage_err list "invalid task id: '${TD_P[parent]}'"
    return
  fi

  local filter tasks
  filter=$(jq -cn --arg vis "$visibility" --argjson days "${TD_CONF[archive_after_days]}" \
    --argjson overdue "$overdue" \
    --arg parent "${TD_P[parent]:-}" \
    --arg statuses "${statuses[*]}" --arg priorities "${priorities[*]}" \
    --arg tags "${TD_P_TAGS[*]}" '
    def words: split(" ") | map(select(. != ""));
    {visibility: $vis, archive_days: $days, overdue: $overdue,
     parent: (if $parent == "" then null else ($parent | tonumber) end),
     statuses: ($statuses | words), priorities: ($priorities | words),
     projects: $ARGS.positional, tags: ($tags | words)}' --args "${projects[@]}") || return

  td_storage_init || return
  tasks=$(td_tasks_select "$filter") || return
  if ((TD_OPT_JSON)); then
    jq . <<<"$tasks"
  else
    _td_render_list "$tasks"
    _td_due_warnings
  fi
}

# _td_collect_filters — move a parsed project/priority into the repeatable
# filter lists of td_cmd_list (dynamic scope: projects, priorities).
_td_collect_filters() {
  if [[ -v TD_P[project] ]]; then
    projects+=("${TD_P[project]}")
    unset 'TD_P[project]'
  fi
  if [[ -v TD_P[priority] ]]; then
    _td_norm_priority
    priorities+=("${TD_P[priority]}")
    unset 'TD_P[priority]'
  fi
}

# _td_render_list JSON — print tasks as a project-grouped tree.
_td_render_list() {
  local -a r_depth=() r_id=() r_status=() r_prio=() r_project=() r_tags=() r_progress=()
  local -a r_title=() r_due=() r_due_state=() r_focus=()
  local d i s p pr tg pg t du ds fo today focused since
  td_today today
  td_focus_read focused since
  while IFS=$'\x1f' read -r d i s p pr tg pg du ds fo t; do
    r_depth+=("$d") r_id+=("$i") r_status+=("$s") r_prio+=("$p") r_project+=("$pr")
    r_tags+=("$tg") r_progress+=("$pg") r_due+=("$du") r_due_state+=("$ds")
    r_focus+=("$fo") r_title+=("$t")
  done < <(LC_TIME=C jq -r --arg today "$today" --arg focus "$focused" "$TD_JQ_DUE"'
    (map(.id)) as $ids | .[]
    | due_info as $due
    | [(if .parent != null and (.parent | IN($ids[])) then 1 else 0 end),
       .id, .status, .priority, .project, (.tags | map("+" + .) | join(" ")),
       (if .subtasks then "\(.subtasks.done)/\(.subtasks.total)" else "" end),
       ($due.text // ""), ($due.state // ""), (if (.id | tostring) == $focus then 1 else 0 end),
       (.title | gsub("[[:cntrl:]]"; " "))]
    | map(tostring) | join("")' <<<"$1")

  local n=${#r_id[@]}
  if ((n == 0)); then
    [[ -t 1 ]] && printf 'No tasks to show. Add one with: todosh add <title>\n'
    return 0
  fi

  # ── group by project ───────────────────────────────────────────────────────
  # Re-order so all tasks from the same project are adjacent (stable, by name),
  # keeping each depth-0 task with its depth-1 children.
  if ((n > 1)); then
    local -a _gs=() _gp=()
    for ((i = 0; i < n; i++)); do
      ((r_depth[i] == 0)) && _gs+=("$i") && _gp+=("${r_project[i]}")
    done
    local _ng=${#_gs[@]} _gi _gj _ts _tp
    for ((_gi = 1; _gi < _ng; _gi++)); do
      _gj=$_gi
      while ((_gj > 0)) && [[ "${_gp[_gj-1]}" > "${_gp[_gj]}" ]]; do
        _ts=${_gs[_gj-1]}; _gs[_gj-1]=${_gs[_gj]}; _gs[_gj]=$_ts
        _tp=${_gp[_gj-1]}; _gp[_gj-1]=${_gp[_gj]}; _gp[_gj]=$_tp
        ((_gj--))
      done
    done
    local -a _nd=() _ni=() _ns=() _nq=() _nproj=() _ntg=() _npg=()
    local -a _ntitle=() _ndu=() _nds=() _nfo=()
    for ((_gi = 0; _gi < _ng; _gi++)); do
      _ts=${_gs[_gi]}
      _nd+=("${r_depth[_ts]}") _ni+=("${r_id[_ts]}") _ns+=("${r_status[_ts]}")
      _nq+=("${r_prio[_ts]}") _nproj+=("${r_project[_ts]}") _ntg+=("${r_tags[_ts]}")
      _npg+=("${r_progress[_ts]}") _ndu+=("${r_due[_ts]}") _nds+=("${r_due_state[_ts]}")
      _nfo+=("${r_focus[_ts]}") _ntitle+=("${r_title[_ts]}")
      for ((i = _ts+1; i < n; i++)); do
        ((r_depth[i] == 0)) && break
        _nd+=("${r_depth[i]}") _ni+=("${r_id[i]}") _ns+=("${r_status[i]}")
        _nq+=("${r_prio[i]}") _nproj+=("${r_project[i]}") _ntg+=("${r_tags[i]}")
        _npg+=("${r_progress[i]}") _ndu+=("${r_due[i]}") _nds+=("${r_due_state[i]}")
        _nfo+=("${r_focus[i]}") _ntitle+=("${r_title[i]}")
      done
    done
    r_depth=("${_nd[@]}") r_id=("${_ni[@]}") r_status=("${_ns[@]}")
    r_prio=("${_nq[@]}") r_project=("${_nproj[@]}") r_tags=("${_ntg[@]}")
    r_progress=("${_npg[@]}") r_due=("${_ndu[@]}") r_due_state=("${_nds[@]}")
    r_focus=("${_nfo[@]}") r_title=("${_ntitle[@]}")
  fi

  # ── column widths ──────────────────────────────────────────────────────────
  local idw=1 tagw=0 duew=0 pgw=0 j
  local focus_mark="${TD_SYM[focus]} "
  for ((i = 0; i < n; i++)); do
    ((${#r_id[i]} > idw))       && idw=${#r_id[i]}
    ((${#r_tags[i]} > tagw))    && tagw=${#r_tags[i]}
    ((${#r_due[i]} > duew))     && duew=${#r_due[i]}
    ((${#r_progress[i]} > pgw)) && pgw=${#r_progress[i]}
  done
  local cols; cols=$(td_term_cols); ((cols <= 0)) && cols=80
  ((cols > 120)) && cols=120
  # depth-1 prefix is 8 chars (widest); sym(2)+prio(2)+#id_space(idw+2)+sep(1) = idw+7
  local right_w=$(( (duew>0 ? duew+2 : 0) + (pgw>0 ? pgw+2 : 0) + (tagw>0 ? tagw+2 : 0) ))
  local titlew=$(( cols - (8 + idw + 7) - right_w ))
  ((titlew < 12)) && titlew=12

  # ── tree metadata ──────────────────────────────────────────────────────────
  # is_last_in_proj[i]=1: no later depth-0 task shares the same project
  # is_last_child[i]=1:   no later depth-1 in the same parent run
  # parent_is_last[i]:    for depth-1, whether its preceding depth-0 is_last_in_proj
  local -a is_last_in_proj=() is_last_child=() parent_is_last=()
  for ((i = 0; i < n; i++)); do
    is_last_in_proj+=(1) is_last_child+=(1) parent_is_last+=(0)
  done
  for ((i = 0; i < n; i++)); do
    ((r_depth[i] == 0)) || continue
    for ((j = i+1; j < n; j++)); do
      ((r_depth[j] == 0)) && [[ "${r_project[j]}" == "${r_project[i]}" ]] \
        && is_last_in_proj[i]=0 && break
    done
  done
  local cur_plast=1
  for ((i = 0; i < n; i++)); do
    if ((r_depth[i] == 0)); then
      cur_plast=${is_last_in_proj[i]}
    else
      parent_is_last[i]=$cur_plast
      for ((j = i+1; j < n; j++)); do
        ((r_depth[j] == 0)) && break
        ((r_depth[j] == 1)) && is_last_child[i]=0 && break
      done
    fi
  done

  # ── render ─────────────────────────────────────────────────────────────────
  local -A prio_letter=([urgent]=U [high]=H [med]=M [low]=L)
  local reset=${TD_SGR[reset]} dim title_sgr due_sgr tree_pre tree_dim
  local shown pad pre_len title_avail prev_project=""
  local _rl_col _rl_i

  _rldash() { for ((_rl_i=0;_rl_i<$1;_rl_i++)); do printf '─'; done; }

  for ((i = 0; i < n; i++)); do

    # Project header — printed on project change for top-level tasks
    if ((r_depth[i] == 0)) && [[ "${r_project[i]}" != "$prev_project" ]]; then
      local _ph="${r_project[i]}" _ph_fill
      _ph_fill=$(( cols - ${#_ph} - 4 ))
      ((_ph_fill < 1)) && _ph_fill=1
      printf '\n  %s%s%s %s%s%s\n' \
        "${TD_SGR[bold]}" "$_ph" "$reset" \
        "${TD_SGR[gray]}" "$(_rldash $_ph_fill)" "$reset"
      prev_project="${r_project[i]}"
    fi

    # Tree connector (5 chars for depth-0, 8 chars for depth-1)
    if ((r_depth[i] == 0)); then
      ((is_last_in_proj[i])) && tree_pre="  └─ " || tree_pre="  ├─ "
    else
      local vbar; ((parent_is_last[i])) && vbar="     " || vbar="  │  "
      ((is_last_child[i])) && tree_pre="${vbar}└─ " || tree_pre="${vbar}├─ "
    fi

    # Dim closed tasks; bold/coloured open and focused
    dim=""; td_status_is_closed "${r_status[i]}" && dim=${TD_SGR[dim]}
    title_sgr=${dim:-${TD_SGR[bold]}}
    ((r_focus[i])) && title_sgr=${TD_SGR[bold]}${TD_SGR[magenta]}

    # Title — depth-0 prefix is 5 chars so gains 3 chars vs the depth-1 budget
    pre_len=${#tree_pre}
    title_avail=$(( titlew + 8 - pre_len ))
    ((r_focus[i])) && title_avail=$(( title_avail - ${#focus_mark} ))
    td_truncate shown "${r_title[i]}" "$title_avail"
    ((r_focus[i])) && shown="${focus_mark}${shown}"
    pad=$(( titlew + 8 - pre_len - ${#shown} ))
    ((pad < 0)) && pad=0

    # Due colour
    case ${r_due_state[i]} in
      overdue) due_sgr=${TD_SGR[bold]}${TD_SGR[red]} ;;
      today)   due_sgr=${TD_SGR[yellow]} ;;
      *)       due_sgr=${TD_SGR[gray]} ;;
    esac

    # Tree connector in muted colour; everything else uses dim for closed tasks
    tree_dim="${TD_SGR[gray]}${dim}"
    printf '%s%s%s%s%s %s%s %s#%-*s%s %s%s%*s' \
      "$tree_dim" "$tree_pre" "$reset$dim" \
      "$(td_status_color "${r_status[i]}")" "${TD_SYM[${r_status[i]}]}" \
      "$reset$dim$(td_priority_color "${r_prio[i]}")" "${prio_letter[${r_prio[i]}]:-?}" \
      "$reset$dim${TD_SGR[gray]}" "$idw" "${r_id[i]}" "$reset$dim" \
      "$title_sgr" "$shown" \
      "$pad" ""

    # Right-side columns (only when non-empty)
    [[ -n ${r_due[i]} ]]      && printf '  %s%-*s%s' "$due_sgr" "$duew" "${r_due[i]}" "$reset$dim"
    [[ -n ${r_progress[i]} ]] && printf '  %s%-*s%s' "${TD_SGR[gray]}" "$pgw" "${r_progress[i]}" "$reset$dim"
    [[ -n ${r_tags[i]} ]]     && printf '  %s%s%s'   "${TD_SGR[cyan]}" "${r_tags[i]}" "$reset"
    printf '\n'
  done
  printf '\n'

  unset -f _rldash
}

# _td_due_warnings — on a terminal, print a one-line summary of open tasks
# that are overdue or due today (the in-app reminder; there is no daemon).
_td_due_warnings() {
  [[ -t 1 ]] || return 0
  local today counts overdue due_today
  td_today today
  counts=$(td_tasks_select '{"visibility": "open"}' \
    | jq -r --arg today "$today" '[map(select(.due != null and .due < $today)) | length,
      map(select(.due == $today)) | length] | @tsv') || return 0
  read -r overdue due_today <<<"$counts"
  ((overdue + due_today)) || return 0
  local parts=()
  ((overdue)) && parts+=("${TD_SGR[bold]}${TD_SGR[red]}$overdue overdue${TD_SGR[reset]}")
  ((due_today)) && parts+=("${TD_SGR[yellow]}$due_today due today${TD_SGR[reset]}")
  local IFS='|'
  local joined=${parts[*]}
  printf '\n%s %s\n' "${TD_SYM[warn]}" "${joined//|/ · }"
}

# --- show / log ------------------------------------------------------------

td_register_cmd show Tasks "Show one or more tasks as cards"
td_help_show() {
  printf '%s\n' \
    "Usage: todosh show <id> [<id>...] [<from>-<to>]" \
    "" \
    "Show tasks as cards with fields, description, subtasks and history." \
    "IDs and ranges can be mixed:  todosh show 1 3 10-15 20" \
    "Tasks in the trash can be shown too." \
    "With --json: array of {task, subtasks, trashed} objects"
}

td_cmd_show() {
  if td_wants_help "$@"; then td_help_show; return 0; fi
  if (($# < 1)); then
    td_usage_err show "expected at least one task id or range (e.g. 5 or 1-10)"
    return
  fi

  # Parse IDs and ranges: each arg is a plain number or N-M.
  local -a ids=()
  local arg lo hi n
  for arg in "$@"; do
    if [[ $arg =~ ^([0-9]+)-([0-9]+)$ ]]; then
      lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[2]}
      ((lo > hi)) && { local tmp=$lo; lo=$hi; hi=$tmp; }
      for ((n = lo; n <= hi; n++)); do ids+=("$n"); done
    elif td_valid_id "$arg"; then
      ids+=("$arg")
    else
      td_usage_err show "invalid id or range: '$arg' (use plain numbers or N-M)"
      return
    fi
  done

  td_storage_init || return

  local id area record subtasks any_missing=0
  local -a cards=()

  for id in "${ids[@]}"; do
    area=tasks
    [[ -f $TD_DATA_DIR/tasks/$id.json ]] || area=trash
    if [[ ! -f $TD_DATA_DIR/$area/$id.json ]]; then
      if ((${#ids[@]} > 1)); then
        printf '%s#%s not found%s\n' "${TD_SGR[red]}" "$id" "${TD_SGR[reset]}" >&2
        any_missing=1; continue
      fi
      td_err "task #$id not found"; return "$TD_E_NOTFOUND"
    fi
    record=$(td_task_read "$id" "$area") || return
    subtasks=$(td_tasks_select "{\"parent\": $id, \"visibility\": \"all\"}" "$area") || return
    if ((TD_OPT_JSON)); then
      cards+=("$(jq -n --argjson t "$record" --argjson s "$subtasks" --arg a "$area" \
        '{task:$t,subtasks:$s,trashed:($a=="trash")}')")
    else
      cards+=("$(_td_show_card "$record" "$subtasks" "$area")")
    fi
  done

  if ((TD_OPT_JSON)); then
    if ((${#ids[@]} == 1 && !any_missing)); then printf '%s\n' "${cards[0]}"
    else
      printf '['; local sep=""
      for c in "${cards[@]}"; do printf '%s%s' "$sep" "$c"; sep=","; done
      printf ']\n'
    fi
    return
  fi

  local out; out=$(printf '%s\n' "${cards[@]}")
  td_page "$out"
}

# _td_card_dlen VAR TEXT — display width (strips ANSI, counts Unicode chars).
_td_card_dlen() {
  local -n _cdl=$1
  local _s; _s=$(printf '%s' "$2" | sed $'s/\033\\[[0-9;]*[mK]//g')
  _cdl=$(printf '%s' "$_s" | wc -m)
}

# _td_show_card RECORD SUBTASKS AREA
_td_show_card() {
  local record=$1 subtasks=$2 area=$3
  local -a f
  local today focused since
  td_today today
  td_focus_read focused since
  mapfile -d '' f < <(LC_TIME=C jq -j --arg today "$today" "$TD_JQ_DUE"'
    def clean: split("\n") | map(gsub("[[:cntrl:]]"; " ")) | join("\n");
    def when: if . then fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M") else "" end;
    [.id, (.title | clean), .status, .priority, .project,
     (.tags | map("+" + .) | join(" ")), (.parent // ""), (.created | when),
     (.updated | when), (.closed | when), (.due // ""), (due_info.text // ""),
     (due_info.state // ""), ([.history[] | select(.type == "focus") | .seconds] | add // 0),
     (.description // "" | clean)]
    | map(tostring + "\u0000") | add' <<<"$record")
  local id=${f[0]} title=${f[1]} status=${f[2]} prio=${f[3]} project=${f[4]}
  local tags=${f[5]} parent=${f[6]} created=${f[7]} updated=${f[8]} closed=${f[9]}
  local due=${f[10]} due_disp=${f[11]} due_state=${f[12]} worked=${f[13]} desc=${f[14]}

  local bld=${TD_SGR[bold]} rst=${TD_SGR[reset]} dim=${TD_SGR[gray]}
  local cyan=${TD_SGR[cyan]} mag=${TD_SGR[magenta]} red_c=${TD_SGR[red]} yel=${TD_SGR[yellow]}
  local st_c; st_c=$(td_status_color "$status")
  local pr_c; pr_c=$(td_priority_color "$prio")

  # Card width: fit terminal, cap 100, floor 64.
  local w; w=$(tput cols 2>/dev/null) || w=80
  ((w > 100)) && w=100; ((w < 64)) && w=64
  local iw=$((w - 4))

  # Inline helpers — _cw/_ciw capture width so helpers work inside subshells.
  local _cw=$w _ciw=$iw
  _dashes() { local i; for ((i=0;i<$1;i++)); do printf '─'; done; }
  _ln()    { local p=$((_ciw-$1)); ((p<0))&&p=0; printf '│ %s%*s │\n' "$2" "$p" ""; }
  _blank() { printf '│%*s│\n' $((_cw-2)) ""; }
  _sep()   {
    if [[ -n ${1:-} ]]; then
      local r=$((_cw-${#1}-5)); ((r<1))&&r=1
      printf '├─ %s %s┤\n' "${2:-$1}" "$(_dashes $r)"
    else printf '├%s┤\n' "$(_dashes $((_cw-2)))"; fi
  }

  # ── top border: ┌─ #ID ──── project ─┐ ──
  local id_v="─ #${id} " proj_v=" ${project} ─"
  local mid=$(( w - ${#id_v} - ${#proj_v} - 2 )); ((mid<1))&&mid=1
  printf '┌%s%s%s┐\n' \
    "${bld}${id_v}${rst}" \
    "$(_dashes $mid)" \
    "${dim}${proj_v}${rst}"

  # ── title (wrapped) ──
  # Use capture+herestring instead of process substitution — process substitution
  # inside a command substitution subshell is unreliable on some bash versions.
  _blank
  local _fold_title; _fold_title=$(printf '%s' "$title" | fold -sw "$iw")
  local tl; while IFS= read -r tl; do _ln "${#tl}" "${bld}${tl}${rst}"
  done <<< "$_fold_title"

  # ── trash notice ──
  if [[ $area == trash ]]; then
    _blank
    local tv="  In the trash  ·  todosh undelete $id"
    local tv_d; _td_card_dlen tv_d "$tv"
    _ln "$tv_d" "  ${red_c}${bld}In the trash${rst}  ·  todosh undelete $id"
  fi

  # ── badges: status · priority · due · focus ──
  _blank
  # TD_SYM chars = 1 display column each in modern terminals.
  local sym=${TD_SYM[$status]:-o}
  local st_d=$(( 2 + ${#status} ))
  local st_s="${st_c}${sym} ${status}${rst}"
  local pr_d=${#prio}
  local pr_s="${pr_c}${prio}${rst}"

  local due_d due_raw due_s
  if [[ -n $due_disp ]]; then
    due_raw="$due_disp"; due_d=${#due_disp}
    local dc=""; [[ $due_state == overdue ]] && dc="${bld}${red_c}"
    [[ $due_state == today ]] && dc="${yel}"
    due_s="${dc}${due_disp}${rst}"
  else
    due_raw="─"; due_d=1; due_s="${dim}─${rst}"
  fi

  local foc_d=0 foc_s="" foc_raw=""
  if [[ $id == "$focused" ]]; then
    local sess; sess=$(_td_seconds_since "$since"); worked=$((worked + sess))
    foc_raw="${TD_SYM[focus]} $(td_fmt_duration "$sess")"
    _td_card_dlen foc_d "$foc_raw"; foc_s="${mag}${foc_raw}${rst}"
  fi

  # Three equal columns + optional focus.
  local col=$(( iw / 4 ))
  local p1=$(( col > st_d+2 ? col-st_d : 2 ))
  local p2=$(( col > pr_d+2 ? col-pr_d : 2 ))
  local p3=$(( col > due_d+2 ? col-due_d : 2 ))
  local bv="${sym} ${status}$(printf '%*s' $p1 '')${prio}$(printf '%*s' $p2 '')${due_raw}"
  local bd=$(( st_d + p1 + pr_d + p2 + due_d ))
  local bs="${st_s}$(printf '%*s' $p1 '')${pr_s}$(printf '%*s' $p2 '')${due_s}"
  if [[ -n $foc_s ]]; then
    bv+="$(printf '%*s' $p3 '')${foc_raw}"
    bd=$(( bd + p3 + foc_d ))
    bs+="$(printf '%*s' $p3 '')${foc_s}"
  fi
  _ln "$bd" "$bs"

  # ── tags ──
  [[ -n $tags ]] && _ln "${#tags}" "${cyan}${tags}${rst}"

  # ── worked (outside focus) ──
  if ((worked > 0)) && [[ $id != "$focused" ]]; then
    local wv="⏱ $(td_fmt_duration "$worked") worked"
    local wd; _td_card_dlen wd "$wv"; _ln "$wd" "${dim}${wv}${rst}"
  fi

  # ── parent ──
  if [[ -n $parent ]]; then
    local ptitle=""
    [[ -f $TD_DATA_DIR/$area/$parent.json ]] \
      && ptitle=$(jq -r '.title' "$TD_DATA_DIR/$area/$parent.json")
    local pv="↑ Parent  #${parent}  ${ptitle}"
    local pd; _td_card_dlen pd "$pv"
    _ln "$pd" "${dim}↑ Parent  ${rst}#${parent}  ${ptitle}"
  fi

  # ── description ──
  if [[ -n $desc ]]; then
    _blank; _sep "Description" "${bld}Description${rst}"
    local _fold_desc; _fold_desc=$(printf '%s' "$desc" | fold -sw "$iw")
    local dl; while IFS= read -r dl; do _ln "${#dl}" "$dl"
    done <<< "$_fold_desc"
  fi

  # ── subtasks ──
  local nsubs; nsubs=$(jq length <<<"$subtasks")
  if ((nsubs > 0)); then
    local ndone; ndone=$(jq '[.[]|select(.status=="DONE")]|length' <<<"$subtasks")
    local slabel="${ndone}/${nsubs} done"
    _blank; _sep "Subtasks ($slabel)" "${bld}Subtasks${rst} ${dim}($slabel)${rst}"
    local _subs_lines
    _subs_lines=$(jq -r '.[]|[(.id|tostring),.status,(.title|gsub("[[:cntrl:]]";"+"))]|join("")' <<<"$subtasks" | head -20)
    local sid sstatus stitle ssym ssc slv sld
    while IFS=$'' read -r sid sstatus stitle; do
      ssym=${TD_SYM[$sstatus]:-o}; ssc=$(td_status_color "$sstatus")
      slv="  ${ssym} #${sid}  ${stitle}"
      _td_card_dlen sld "$slv"
      _ln "$sld" "  ${ssc}${ssym}${rst} ${dim}#${sid}${rst}  ${stitle}"
    done <<< "$_subs_lines"
  fi

  # ── history ──
  _blank; _sep "History" "${bld}History${rst}"
  local hl hld
  local _hist_out; _hist_out=$(_td_render_history "$record" all)
  while IFS= read -r hl; do _td_card_dlen hld "$hl"; _ln "$hld" "$hl"
  done <<< "$_hist_out"

  # ── footer ──
  _blank; _sep
  local dv="Created ${created}  ·  Updated ${updated}"
  local ds="${dim}Created ${rst}${created}${dim}  ·  Updated ${rst}${updated}"
  [[ -n $closed ]] && dv+="  ·  Closed ${closed}" \
    && ds+="${dim}  ·  Closed ${rst}${closed}"
  _ln "${#dv}" "$ds"
  printf '└%s┘\n' "$(_dashes $((w-2)))"

  unset -f _ln _blank _sep _dashes
}

# _td_seconds_since TIMESTAMP — print seconds elapsed since a UTC timestamp.
_td_seconds_since() {
  local start now
  start=$(date -u -d "$1" +%s 2>/dev/null) || {
    printf '0\n'
    return 0
  }
  printf -v now '%(%s)T' -1
  printf '%s\n' $((now > start ? now - start : 0))
}

# jq definitions shared by the CLI and the TUI: entry_text describes one
# history entry. Needs --arg arrow and --arg none (symbols).
# shellcheck disable=SC2016 # jq code
readonly TD_JQ_EVENT='
def clean: split("\n") | map(gsub("[[:cntrl:]]"; " ")) | join("\n");
def dur: if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m"
  else "\(. / 3600 | floor)h\(. % 3600 / 60 | floor | tostring | if length < 2 then "0" + . else . end)m" end;
def val: if . == null then $none
  elif type == "array" then (map("+" + .) | join(" ") | if . == "" then $none else . end)
  else tostring end;
def entry_text:
  (if .type == "comment" then .text
   elif .event == "created" then "created"
   elif .event == "status" then "status \(.from) \($arrow) \(.to)"
   elif .event == "edit" and .field == "description" then "description edited"
   elif .event == "edit" and .field == "parent" then
     "parent \(.from | if . then "#\(.)" else $none end) \($arrow) \(.to | if . then "#\(.)" else $none end)"
   elif .event == "edit" then "\(.field) \(.from | val) \($arrow) \(.to | val)"
   elif .event == "deleted" then "moved to the trash"
   elif .event == "restored" then "restored from the trash"
   elif .type == "focus" then "focus session \(.seconds | dur)"
   else (.event // .type) end) | clean;
'

# _td_render_history RECORD KIND — KIND: all | comments | events
_td_render_history() {
  local at type text first rest
  while IFS=$'\x1f' read -r -d '' at type text; do
    if [[ $type == comment ]]; then
      first=${text%%$'\n'*}
      printf '  %s%s%s  %s%s%s %s\n' "${TD_SGR[gray]}" "$at" "${TD_SGR[reset]}" \
        "${TD_SGR[yellow]}" "${TD_SYM[comment]}" "${TD_SGR[reset]}" "$first"
      if [[ $text == *$'\n'* ]]; then
        rest=${text#*$'\n'}
        printf '%s\n' "$rest" | sed 's/^/                      /'
      fi
    else
      printf '  %s%s  %s %s%s\n' "${TD_SGR[gray]}" "$at" "${TD_SYM[event]}" "$text" "${TD_SGR[reset]}"
    fi
  done < <(jq -j --arg kind "$2" --arg arrow "${TD_SYM[arrow]}" --arg none "${TD_SYM[dash]}" \
    "$TD_JQ_EVENT"'
    .history[]
    | select($kind == "all" or ($kind == "comments" and .type == "comment")
             or ($kind == "events" and .type != "comment"))
    | [(.at | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")), .type, entry_text]
    | join("\u001f") + "\u0000"' <<<"$1")
}

td_register_cmd log History "Show the history of a task"
td_help_log() {
  printf '%s\n' \
    "Usage: todosh log <id> [--comments | --events]" \
    "" \
    "  --comments   Only comments written by you" \
    "  --events     Only automatic events (status, edits, trash)"
}

td_cmd_log() {
  if td_wants_help "$@"; then
    td_help_log
    return 0
  fi
  local kind=all id=""
  while (($#)); do
    case $1 in
      --comments) kind=comments ;;
      --events) kind=events ;;
      -?*)
        td_usage_err log "unknown option: $1"
        return
        ;;
      *)
        if [[ -n $id ]]; then
          td_usage_err log "expected exactly one task id"
          return
        fi
        id=$1
        ;;
    esac
    shift
  done
  if ! td_valid_id "$id"; then
    td_usage_err log "invalid task id: '$id'"
    return
  fi
  td_storage_init || return
  local area=tasks record
  [[ -f $TD_DATA_DIR/tasks/$id.json ]] || area=trash
  if [[ ! -f $TD_DATA_DIR/$area/$id.json ]]; then
    td_err "task #$id not found"
    return "$TD_E_NOTFOUND"
  fi
  record=$(td_task_read "$id" "$area") || return
  if ((TD_OPT_JSON)); then
    jq --arg kind "$kind" '.history | map(select($kind == "all"
      or ($kind == "comments" and .type == "comment")
      or ($kind == "events" and .type != "comment")))' <<<"$record"
    return
  fi
  local out
  out=$(_td_render_history "$record" "$kind") || return
  td_page "$out"
}

# --- edit ------------------------------------------------------------------

td_register_cmd edit Tasks "Change a task (opens your editor without options)"
td_help_edit() {
  printf '%s\n' \
    "Usage: todosh edit <id> [options]" \
    "" \
    "Without options, opens the title and description in your editor:" \
    "the first line is the title, everything after it is the description" \
    "(Markdown welcome). Editor: config 'editor', then \$VISUAL, \$EDITOR, vi." \
    "" \
    "Options:" \
    "  --title TEXT          New title" \
    "  -d, --description T   New description; '-' reads stdin, '' clears it" \
    "  --priority LEVEL      urgent | high | med | low     shorthand: pri:LEVEL" \
    "  --project NAME        Move to project               shorthand: p:NAME" \
    "  --tag NAME            Add a tag (repeatable)        shorthand: +NAME" \
    "  --untag NAME          Remove a tag (repeatable)" \
    "  --parent ID|none      Make it a subtask, or top-level shorthand: ^ID" \
    "  --due WHEN|none       Set or clear the due date      shorthand: due:WHEN" \
    "" \
    "Example:" \
    "  todosh edit 42 pri:urgent +security --untag network"
}

td_cmd_edit() {
  if td_wants_help "$@"; then
    td_help_edit
    return 0
  fi
  _td_parse_reset
  local id="" rc
  while (($#)); do
    case $1 in
      --title | --title=*)
        _td_take "$@" || return
        TD_P[title]=$TD_VAL
        shift "$TD_SHIFT"
        continue
        ;;
      -d | --description | --description=*)
        _td_take "$@" || return
        TD_P[description]=$TD_VAL
        shift "$TD_SHIFT"
        continue
        ;;
      --untag | --untag=*)
        _td_take "$@" || return
        TD_P_UNTAGS+=("$TD_VAL")
        shift "$TD_SHIFT"
        continue
        ;;
    esac
    _td_field_option "$@" && {
      shift "$TD_SHIFT"
      continue
    }
    rc=$?
    ((rc == TD_E_USAGE)) && return "$rc"
    case $1 in
      -?*)
        td_usage_err edit "unknown option: $1"
        return
        ;;
    esac
    if ! _td_shorthand "$1"; then
      if [[ -n $id ]]; then
        td_usage_err edit "unexpected argument: $1 (use --title to rename)"
        return
      fi
      id=$1
    fi
    shift
  done
  local due
  _td_parse_due due || return
  _td_norm_priority
  if ! td_valid_id "$id"; then
    td_usage_err edit "invalid task id: '$id'"
    return
  fi
  td_storage_init || return

  local -A changes=()
  local key
  for key in title description priority project parent; do
    [[ -v TD_P[$key] ]] && changes[$key]=${TD_P[$key]}
  done
  [[ -v TD_P[due] ]] && changes[due]=$due
  [[ ${changes[description]-} == - ]] && _td_read_stdin 'changes[description]'
  ((${#TD_P_TAGS[@]})) && changes[tags_add]=${TD_P_TAGS[*]}
  ((${#TD_P_UNTAGS[@]})) && changes[tags_remove]=${TD_P_UNTAGS[*]}

  TD_EDIT_TMP=""
  if ((${#changes[@]} == 0)); then
    _td_edit_in_editor "$id" changes || return
    # Nothing to apply (unchanged, or aborted with a message already shown).
    ((${#changes[@]})) || return 0
  fi
  td_task_edit "$id" changes || {
    rc=$?
    [[ -n $TD_EDIT_TMP ]] && td_err "your text was kept in $TD_EDIT_TMP"
    return "$rc"
  }
  [[ -n $TD_EDIT_TMP ]] && rm -f -- "$TD_EDIT_TMP"
  if ((TD_OPT_JSON)); then
    jq . "$TD_DATA_DIR/tasks/$id.json"
  elif ((TD_RESULT)); then
    _td_say_tasks tasks "Updated #%s %.0s%s" "$id"
  else
    printf 'No changes to #%s\n' "$id"
  fi
}

# _td_edit_in_editor ID CHANGES — fill CHANGES from an editor session.
_td_edit_in_editor() {
  local _td_eid=$1
  local -n _td_c=$2
  local _td_rec _td_title _td_desc _td_tmp _td_content _td_new_title _td_new_desc
  [[ -f $TD_DATA_DIR/tasks/$_td_eid.json ]] || {
    _td_missing "$_td_eid"
    return
  }
  _td_rec=$(td_task_read "$_td_eid") || return
  _td_title=$(jq -r .title <<<"$_td_rec")
  _td_desc=$(jq -r .description <<<"$_td_rec")
  _td_tmp=$(mktemp --suffix=.md -t "todosh-$_td_eid.XXXXXXXX") || {
    td_err "cannot create a temporary file"
    return "$TD_E_ERR"
  }
  if [[ -n $_td_desc ]]; then
    printf '%s\n\n%s\n' "$_td_title" "$_td_desc" >"$_td_tmp"
  else
    printf '%s\n\n' "$_td_title" >"$_td_tmp"
  fi
  td_run_editor "$_td_tmp" || {
    local rc=$?
    rm -f -- "$_td_tmp"
    return "$rc"
  }
  _td_content=$(<"$_td_tmp")
  _td_new_title=${_td_content%%$'\n'*}
  _td_new_title=${_td_new_title##+([[:space:]])}
  _td_new_title=${_td_new_title%%+([[:space:]])}
  _td_new_desc=""
  if [[ $_td_content == *$'\n'* ]]; then
    _td_new_desc=${_td_content#*$'\n'}
    while [[ $_td_new_desc == $'\n'* ]]; do _td_new_desc=${_td_new_desc#$'\n'}; done
  fi
  if [[ -z $_td_new_title ]]; then
    rm -f -- "$_td_tmp"
    printf 'Empty title: nothing changed.\n' >&2
    return 0
  fi
  if [[ $_td_new_title == "$_td_title" && $_td_new_desc == "$_td_desc" ]]; then
    rm -f -- "$_td_tmp"
    printf 'No changes to #%s\n' "$_td_eid" >&2
    return 0
  fi
  _td_c["title"]=$_td_new_title
  _td_c["description"]=$_td_new_desc
  _td_c["if_title"]=$_td_title
  _td_c["if_description"]=$_td_desc
  # The caller removes it after a successful save; otherwise the text is kept.
  TD_EDIT_TMP=$_td_tmp
}

# --- status ----------------------------------------------------------------

td_register_cmd start Status "Set tasks IN_PROGRESS"
td_register_cmd block Status "Set tasks BLOCKED (say why with -m)"
td_register_cmd "done" Status "Set tasks DONE"
td_register_cmd cancel Status "Set tasks CANCELLED"
td_register_cmd reopen Status "Set tasks back to TODO"

_td_help_status() {
  local cmd=$1 status=$2 extra=$3
  printf '%s\n' \
    "Usage: todosh $cmd <id>... [-m TEXT]$extra" \
    "" \
    "Sets the tasks to $status. All tasks are checked before any is changed." \
    "" \
    "  -m, --message TEXT   Also add TEXT as a comment to each task"
  case $cmd in
    "done" | cancel)
      printf '%s\n' \
        "  --force              Also close open subtasks" \
        "" \
        "A task with open subtasks is refused unless they are listed too or --force."
      ;;
    reopen)
      printf '%s\n' "" \
        "Reopens closed tasks and pauses tasks in progress. Reopening a subtask" \
        "of a closed task reopens the parent too."
      ;;
    *)
      printf '%s\n' "" "Closed tasks must be reopened first (todosh reopen <id>)."
      ;;
  esac
}
td_help_start() { _td_help_status start IN_PROGRESS ""; }
td_help_block() { _td_help_status block BLOCKED ""; }
td_help_done() { _td_help_status "done" DONE " [--force]"; }
td_help_cancel() { _td_help_status cancel CANCELLED " [--force]"; }
td_help_reopen() { _td_help_status reopen TODO ""; }

td_cmd_start() { _td_status_cmd start IN_PROGRESS "$@"; }
td_cmd_block() { _td_status_cmd block BLOCKED "$@"; }
td_cmd_done() { _td_status_cmd "done" DONE "$@"; }
td_cmd_cancel() { _td_status_cmd cancel CANCELLED "$@"; }
td_cmd_reopen() { _td_status_cmd reopen TODO "$@"; }

# _td_status_cmd CMD STATUS ARG...
_td_status_cmd() {
  local cmd=$1 status=$2
  shift 2
  if td_wants_help "$@"; then
    "td_help_$cmd"
    return 0
  fi
  local force=0 message=""
  local -a ids=()
  while (($#)); do
    case $1 in
      --force) force=1 ;;
      -m | --message | --message=*)
        _td_take "$@" || return
        message=$TD_VAL
        shift "$TD_SHIFT"
        continue
        ;;
      -?*)
        td_usage_err "$cmd" "unknown option: $1"
        return
        ;;
      *) ids+=("$1") ;;
    esac
    shift
  done
  if ((${#ids[@]} == 0)); then
    td_usage_err "$cmd" "missing task id"
    return
  fi
  td_storage_init || return
  td_task_set_status "$status" "$force" "$message" "${ids[@]}" || return

  local -a changed skipped
  read -ra changed <<<"$TD_RESULT"
  read -ra skipped <<<"$TD_SKIPPED"
  if ((TD_OPT_JSON)); then
    _td_json_tasks tasks "${changed[@]}"
    return
  fi
  local id
  for id in "${skipped[@]}"; do
    printf '#%s is already %s\n' "$id" "$status" >&2
  done
  ((${#changed[@]})) && _td_say_tasks tasks "#%s ${TD_SYM[arrow]} %s  %s" "${changed[@]}"
  return 0
}

# --- comment ---------------------------------------------------------------

td_register_cmd comment History "Add a comment to a task"
td_help_comment() {
  printf '%s\n' \
    "Usage: todosh comment <id> [text...]" \
    "" \
    "Without text: reads the comment from stdin when it is piped, otherwise" \
    "opens your editor (multi-line comments welcome). '-' forces stdin." \
    "" \
    "Examples:" \
    "  todosh comment 42 Found an unexpected inbound rule on 8080" \
    "  iptables -S | todosh comment 42"
}

td_cmd_comment() {
  if td_wants_help "$@"; then
    td_help_comment
    return 0
  fi
  local id=${1:-}
  (($#)) && shift
  [[ ${1:-} == -- ]] && shift
  if ! td_valid_id "$id"; then
    td_usage_err comment "invalid task id: '$id'"
    return
  fi
  local text="$*"
  td_storage_init || return
  if [[ $text == - ]] || [[ -z $text && ! -t 0 ]]; then
    _td_read_stdin text
  elif [[ -z $text ]]; then
    [[ -f $TD_DATA_DIR/tasks/$id.json ]] || {
      _td_missing "$id"
      return
    }
    local tmp
    tmp=$(mktemp --suffix=.md -t "todosh-$id-comment.XXXXXXXX") || return
    td_run_editor "$tmp" || {
      local rc=$?
      rm -f -- "$tmp"
      return "$rc"
    }
    text=$(<"$tmp")
    rm -f -- "$tmp"
    if [[ -z ${text//[[:space:]]/} ]]; then
      printf 'Empty comment: nothing added.\n' >&2
      return 0
    fi
  fi
  td_task_comment "$id" "$text" || return
  if ((TD_OPT_JSON)); then
    jq . "$TD_DATA_DIR/tasks/$id.json"
  else
    _td_say_tasks tasks "Comment added to #%s %.0s%s" "$id"
  fi
}

# --- trash -----------------------------------------------------------------

td_register_cmd delete Trash "Move tasks to the trash"
td_help_delete() {
  printf '%s\n' \
    "Usage: todosh delete <id>... [--force]" \
    "" \
    "Moves tasks to the trash; nothing is lost until 'todosh purge'." \
    "A task with subtasks needs --force; its subtasks go to the trash with it." \
    "Undo with: todosh undelete <id>"
}

td_cmd_delete() {
  if td_wants_help "$@"; then
    td_help_delete
    return 0
  fi
  local force=0
  local -a ids=()
  while (($#)); do
    case $1 in
      --force) force=1 ;;
      -?*)
        td_usage_err delete "unknown option: $1"
        return
        ;;
      *) ids+=("$1") ;;
    esac
    shift
  done
  if ((${#ids[@]} == 0)); then
    td_usage_err delete "missing task id"
    return
  fi
  td_storage_init || return
  td_task_delete "$force" "${ids[@]}" || return
  local -a moved
  read -ra moved <<<"$TD_RESULT"
  if ((TD_OPT_JSON)); then
    _td_json_tasks trash "${moved[@]}"
  else
    _td_say_tasks trash "Trashed #%s %.0s%s" "${moved[@]}"
    printf '%sUndo with: todosh undelete %s%s\n' "${TD_SGR[gray]}" "${ids[*]}" "${TD_SGR[reset]}"
  fi
}

td_register_cmd undelete Trash "Restore tasks from the trash"
td_help_undelete() {
  printf '%s\n' \
    "Usage: todosh undelete <id>..." \
    "" \
    "Restores tasks with their trashed subtasks. A subtask whose parent is" \
    "also in the trash is restored by restoring the parent."
}

td_cmd_undelete() {
  if td_wants_help "$@"; then
    td_help_undelete
    return 0
  fi
  if (($# == 0)); then
    td_usage_err undelete "missing task id"
    return
  fi
  local arg
  for arg in "$@"; do
    if [[ $arg == -* ]]; then
      td_usage_err undelete "unknown option: $arg"
      return
    fi
  done
  td_storage_init || return
  td_task_undelete "$@" || return
  local -a restored
  read -ra restored <<<"$TD_RESULT"
  if ((TD_OPT_JSON)); then
    _td_json_tasks tasks "${restored[@]}"
  else
    _td_say_tasks tasks "Restored #%s %.0s%s" "${restored[@]}"
  fi
}

td_register_cmd trash Trash "List tasks in the trash"
td_help_trash() {
  printf '%s\n' "Usage: todosh trash" "" "Lists deleted tasks. See also: undelete, purge."
}

td_cmd_trash() {
  if td_wants_help "$@"; then
    td_help_trash
    return 0
  fi
  if (($#)); then
    td_usage_err trash "unexpected argument: $1"
    return
  fi
  td_storage_init || return
  local tasks
  tasks=$(td_tasks_select '{"visibility": "all"}' trash) || return
  if ((TD_OPT_JSON)); then
    jq . <<<"$tasks"
  elif [[ $tasks == "[]" ]]; then
    [[ -t 1 ]] && printf 'The trash is empty.\n'
    return 0
  else
    _td_render_list "$tasks"
  fi
}

td_register_cmd purge Trash "Permanently delete tasks from the trash"
td_help_purge() {
  printf '%s\n' \
    "Usage: todosh purge [<id>...] [--yes]" \
    "" \
    "Permanently deletes the given trashed tasks, or the whole trash." \
    "Asks for confirmation; non-interactive use requires --yes."
}

td_cmd_purge() {
  if td_wants_help "$@"; then
    td_help_purge
    return 0
  fi
  local yes=0
  local -a ids=()
  while (($#)); do
    case $1 in
      -y | --yes) yes=1 ;;
      -?*)
        td_usage_err purge "unknown option: $1"
        return
        ;;
      *) ids+=("$1") ;;
    esac
    shift
  done
  td_storage_init || return
  local count=${#ids[@]}
  if ((count == 0)); then
    count=$(td_task_ids trash | wc -l)
    if ((count == 0)); then
      if ((TD_OPT_JSON)); then
        jq -n '{purged: []}'
      else
        printf 'The trash is empty.\n'
      fi
      return 0
    fi
  fi
  if ((! yes)); then
    if [[ ! -t 0 ]]; then
      td_usage_err purge "refusing to purge without confirmation; use --yes"
      return
    fi
    if ! td_confirm "Permanently delete $count task(s) from the trash?"; then
      printf 'Nothing was deleted.\n' >&2
      return "$TD_E_ERR"
    fi
  fi
  td_task_purge "${ids[@]}" || return
  local -a purged
  read -ra purged <<<"$TD_RESULT"
  if ((TD_OPT_JSON)); then
    jq -n '{purged: ($ARGS.positional | map(tonumber))}' --args "${purged[@]}"
  else
    printf 'Permanently deleted %s task(s).\n' "${#purged[@]}"
  fi
}

# --- focus -----------------------------------------------------------------

td_register_cmd focus Focus "Focus a task, or show the focused task's memory card"
td_help_focus() {
  printf '%s\n' \
    "Usage: todosh focus [<id>]" \
    "" \
    "With an id: puts that task in focus (a TODO task becomes IN_PROGRESS)" \
    "and starts a work session. Only one task is in focus at a time." \
    "Without an id: shows the memory card of the focused task: status," \
    "time worked, due date, subtasks and the latest comments." \
    "" \
    "The session ends with 'todosh unfocus', when another task is focused," \
    "or when the task is closed or deleted; its time is kept in the history."
}

td_cmd_focus() {
  if td_wants_help "$@"; then
    td_help_focus
    return 0
  fi
  if (($# > 1)); then
    td_usage_err focus "expected at most one task id"
    return
  fi
  td_storage_init || return
  if (($# == 1)); then
    td_focus_set "$1" || return
    if ((! TD_OPT_JSON && ! TD_RESULT)); then
      printf '#%s is already in focus.\n\n' "$1"
    fi
  fi
  _td_focus_card
}

# _td_focus_card — print the memory card (or its JSON) of the focused task.
_td_focus_card() {
  local id since record subtasks session now
  td_focus_read id since
  if [[ -z $id ]]; then
    if ((TD_OPT_JSON)); then
      jq -n '{focus: null}'
    else
      printf 'No task in focus. Pick one with: todosh focus <id>\n'
    fi
    return 0
  fi
  record=$(td_task_read "$id") || return
  subtasks=$(td_tasks_select "{\"parent\": $id, \"visibility\": \"all\"}") || return
  session=$(_td_seconds_since "$since")
  printf -v now '%(%s)T' -1

  if ((TD_OPT_JSON)); then
    local parent='null' pid
    pid=$(jq -r '.parent // ""' <<<"$record")
    [[ -n $pid && -f $TD_DATA_DIR/tasks/$pid.json ]] \
      && parent=$(jq -c 'del(.history)' "$TD_DATA_DIR/tasks/$pid.json")
    jq -n --argjson task "$record" --argjson subtasks "$subtasks" --argjson parent "$parent" \
      --arg since "$since" --argjson session "$session" '{focus: {
        task: ($task | del(.history)), since: $since, session_seconds: $session,
        total_seconds: (([$task.history[] | select(.type == "focus") | .seconds] | add // 0) + $session),
        parent: $parent, subtasks: $subtasks,
        recent_comments: ([$task.history[] | select(.type == "comment")] | .[-3:])}}'
    return
  fi
  _td_render_card "$record" "$subtasks" "$session" "$now"
}

# _td_vlen VAR TEXT — visible length of TEXT (SGR color sequences removed).
_td_vlen() {
  local -n _td_len=$1
  local _td_plain=${2//$'\e['*([0-9;])m/}
  _td_len=${#_td_plain}
}

# _td_render_card RECORD SUBTASKS SESSION_SECONDS NOW_EPOCH
_td_render_card() {
  local record=$1 subtasks=$2 session=$3 now=$4 today
  local b=${TD_SGR[bold]} r=${TD_SGR[reset]} g=${TD_SGR[gray]}
  td_today today

  local -a f
  mapfile -d '' f < <(LC_TIME=C jq -j --arg today "$today" "$TD_JQ_DUE"'
    def clean: gsub("[[:cntrl:]]"; " ");
    [.id, (.title | clean), .status, .priority, .project,
     (.tags | map("+" + .) | join(" ")), (.parent // ""),
     (due_info.text // ""), (due_info.state // ""), (.due // ""),
     ([.history[] | select(.type == "focus") | .seconds] | add // 0),
     (.description | split("\n") | map(clean | select(test("\\S"))) | .[0:3] | join("\n"))]
    | map(tostring + "\u0000") | add' <<<"$record")
  local id=${f[0]} title=${f[1]} status=${f[2]} prio=${f[3]} project=${f[4]} tags=${f[5]}
  local parent=${f[6]} due_text=${f[7]} due_state=${f[8]} due=${f[9]} worked=${f[10]} desc=${f[11]}

  local cols width inner
  cols=$(td_term_cols)
  width=$((cols > 0 ? (cols < 88 ? cols : 88) : 76))
  inner=$((width - 4))

  # Body lines (may contain colors); each must fit in $inner visible columns.
  local -a body=()
  local text shown
  local meta="$project"
  [[ -n $tags ]] && meta+="  $tags"
  meta+="  ${TD_SYM[time]} $(td_fmt_duration "$session") now, $(td_fmt_duration $((worked + session))) total"
  td_truncate shown "$meta" "$inner"
  body+=("$g$shown$r")
  if [[ -n $due_text ]]; then
    local due_sgr=""
    [[ $due_state == overdue ]] && due_sgr=$b${TD_SGR[red]}
    [[ $due_state == today ]] && due_sgr=${TD_SGR[yellow]}
    text="Due: $due_text"
    [[ $due_text != "$due" ]] && text+=" ($due)"
    body+=("$due_sgr$text$r")
  fi
  if [[ -n $parent && -f $TD_DATA_DIR/tasks/$parent.json ]]; then
    text="Part of #$parent $(jq -r '.title | gsub("[[:cntrl:]]"; " ")' "$TD_DATA_DIR/tasks/$parent.json")"
    td_truncate shown "$text" "$inner"
    body+=("$shown")
  fi
  if [[ -n $desc ]]; then
    local line
    while IFS= read -r line; do
      td_truncate shown "$line" "$inner"
      body+=("$g$shown$r")
    done <<<"$desc"
  fi

  local -a subs=()
  local sid sstatus stitle total=0 done_n=0
  while IFS=$'\x1f' read -r sid sstatus stitle; do
    [[ $sstatus == CANCELLED ]] || total=$((total + 1))
    [[ $sstatus == DONE ]] && done_n=$((done_n + 1))
    if ((${#subs[@]} < 8)); then
      td_truncate shown "#$sid $stitle" $((inner - ${#TD_SYM[TODO]} - 3))
      local dim=""
      td_status_is_closed "$sstatus" && dim=${TD_SGR[dim]}
      subs+=("  $(td_status_color "$sstatus")${TD_SYM[$sstatus]}$r $dim$shown$r")
    fi
  done < <(jq -r '.[] | [.id, .status, (.title | gsub("[[:cntrl:]]"; " "))]
                  | map(tostring) | join("\u001f")' <<<"$subtasks")
  local nsubs
  nsubs=$(jq length <<<"$subtasks")
  ((nsubs > 8)) && subs+=("  $g… and $((nsubs - 8)) more (todosh show $id)$r")

  local -a notes=()
  local ago ctext
  while IFS=$'\x1f' read -r ago ctext; do
    text="$(td_fmt_ago "$ago")  $ctext"
    td_truncate shown "$text" $((inner - 2))
    notes+=("  ${TD_SGR[yellow]}${TD_SYM[comment]}$r $shown")
  done < <(jq -r --argjson now "$now" '[.history[] | select(.type == "comment")] | .[-3:][]
    | [($now - (.at | fromdateiso8601) | if . < 0 then 0 else . end),
       (.text | split("\n")[0] | gsub("[[:cntrl:]]"; " "))]
    | map(tostring) | join("\u001f")' <<<"$record")

  # Frame.
  local tl tr bl br h v ml mr
  if ((TD_UNICODE)); then
    tl="╭" tr="╮" bl="╰" br="╯" h="─" v="│" ml="├" mr="┤"
  else
    tl="+" tr="+" bl="+" br="+" h="-" v="|" ml="+" mr="+"
  fi
  local rule
  printf -v rule '%*s' "$inner" ''
  rule=${rule// /$h}

  local right="$status · $prio" label left_len right_len fill
  td_truncate label "${TD_SYM[focus]} FOCUS #$id $title" $((inner - ${#right} - 4))
  left_len=${#label}
  right_len=${#right}
  fill=$((width - 2 - 3 - left_len - 2 - right_len - 1))
  ((fill < 1)) && fill=1
  local fill_str
  printf -v fill_str '%*s' "$fill" ''
  printf '%s%s%s %s%s%s%s %s %s%s%s %s%s%s\n' "$g" "$tl$h" "$r" "$b${TD_SGR[magenta]}" "$label" "$r" \
    "$g" "${fill_str// /$h}" "$r$(td_status_color "$status")" "$right" "$r" "$g" "$h$tr" "$r"

  _td_card_row() {
    local vis pad
    _td_vlen vis "$1"
    pad=$((inner - vis))
    ((pad < 0)) && pad=0
    printf '%s%s%s %s%*s %s%s%s\n' "$g" "$v" "$r" "$1" "$pad" '' "$g" "$v" "$r"
  }
  local row
  for row in "${body[@]}"; do _td_card_row "$row"; done
  if ((${#subs[@]})); then
    printf '%s%s%s%s%s\n' "$g" "$ml$h" "$rule" "$h$mr" "$r"
    _td_card_row "${b}Subtasks $done_n/$total$r"
    for row in "${subs[@]}"; do _td_card_row "$row"; done
  fi
  if ((${#notes[@]})); then
    printf '%s%s%s%s%s\n' "$g" "$ml$h" "$rule" "$h$mr" "$r"
    _td_card_row "${b}Latest comments$r"
    for row in "${notes[@]}"; do _td_card_row "$row"; done
  fi
  printf '%s%s%s%s%s\n' "$g" "$bl$h" "$rule" "$h$br" "$r"
  unset -f _td_card_row
}

td_register_cmd unfocus Focus "Release the focus and close the work session"
td_help_unfocus() {
  printf '%s\n' "Usage: todosh unfocus" "" \
    "Ends the current work session (its time is kept in the task history)." \
    "The task keeps its status."
}

td_cmd_unfocus() {
  if td_wants_help "$@"; then
    td_help_unfocus
    return 0
  fi
  if (($#)); then
    td_usage_err unfocus "unexpected argument: $1"
    return
  fi
  td_storage_init || return
  local id since session=0
  td_focus_read id since
  [[ -n $id ]] && session=$(_td_seconds_since "$since")
  td_focus_clear || return
  if ((TD_OPT_JSON)); then
    jq -n --arg id "$id" --argjson s "$session" \
      '{released: (if $id == "" then null else ($id | tonumber) end), session_seconds: $s}'
  elif [[ -n $id ]]; then
    _td_say_tasks tasks "Released focus on #%s %.0s%s (session: $(td_fmt_duration "$session"))" "$id"
  else
    printf 'No task was in focus.\n'
  fi
}

td_register_cmd prompt Focus "Print a short focus line for your shell prompt"
td_help_prompt() {
  printf '%s\n' \
    "Usage: todosh prompt [--max N] [--time] [--no-icon]" \
    "" \
    "Prints e.g. '◉ #42 Review firewall' when a task is in focus, and nothing" \
    "otherwise. Never fails and never creates files, so it is safe in prompts." \
    "" \
    "  --max N     Truncate the title to N characters (default 24)" \
    "  --time      Append the current session time" \
    "  --no-icon   Leave out the focus symbol" \
    "" \
    "zsh:   setopt PROMPT_SUBST; RPROMPT='\$(tdsh prompt --time)'" \
    "bash:  PS1='\$(tdsh prompt) '\"\$PS1\""
}

td_cmd_prompt() {
  if td_wants_help "$@"; then
    td_help_prompt
    return 0
  fi
  local max=24 with_time=0 icon=1
  while (($#)); do
    case $1 in
      --max | --max=*)
        _td_take "$@" || return
        if [[ ! $TD_VAL =~ ^[1-9][0-9]{0,2}$ ]]; then
          td_usage_err prompt "invalid --max: '$TD_VAL'"
          return
        fi
        max=$TD_VAL
        shift "$TD_SHIFT"
        continue
        ;;
      --time) with_time=1 ;;
      --no-icon) icon=0 ;;
      *)
        td_usage_err prompt "unexpected argument: $1"
        return
        ;;
    esac
    shift
  done
  # From here on, problems print nothing instead of breaking the prompt.
  local id since title out
  # shellcheck disable=SC2034 # read by td_err/td_warn
  TD_QUIET_ERRORS=1
  td_focus_read id since
  if [[ -z $id ]]; then
    ((TD_OPT_JSON)) && printf 'null\n'
    return 0
  fi
  title=$(jq -r '.title | gsub("[[:cntrl:]]"; " ")' "$TD_DATA_DIR/tasks/$id.json" 2>/dev/null) || return 0
  local session
  session=$(_td_seconds_since "$since")
  if ((TD_OPT_JSON)); then
    jq -n --argjson id "$id" --arg title "$title" --argjson s "$session" \
      '{task: $id, title: $title, session_seconds: $s}'
    return 0
  fi
  td_truncate title "$title" "$max"
  out="#$id $title"
  ((icon)) && out="${TD_SYM[focus]} $out"
  ((with_time)) && out+=" · $(td_fmt_duration "$session")"
  printf '%s\n' "$out"
}

# --- interface and themes --------------------------------------------------

td_register_cmd tui General "Open the full-screen interface (same as bare todosh)"
td_help_tui() {
  printf '%s\n' "Usage: todosh tui" "" \
    "Opens the interactive interface. Press ? inside it for the keys." \
    "Bare 'todosh' does the same when run in a terminal."
}

td_cmd_tui() {
  if td_wants_help "$@"; then
    td_help_tui
    return 0
  fi
  if (($#)); then
    td_usage_err tui "unexpected argument: $1"
    return
  fi
  td_tui_main
}

td_register_cmd theme General "List, preview, set or import interface themes"
td_help_theme() {
  printf '%s\n' \
    "Usage: todosh theme [list | show [NAME] | set NAME | import kitty [FILE]]" \
    "" \
    "  list          Available themes; * marks the current one (default)" \
    "  show [NAME]   Preview the colors of a theme" \
    "  set NAME      Use NAME (saved as 'theme' in the config file)" \
    "  import kitty  Create the theme 'kitty' from your kitty colors and use it" \
    "" \
    "Themes are 'key = #rrggbb' files. Your own go in" \
    "  ${TD_CONFIG_DIR:-~/.config/todosh}/themes/NAME.theme" \
    "Keys: ${TD_THEME_KEYS[*]}"
}

td_cmd_theme() {
  if td_wants_help "$@"; then
    td_help_theme
    return 0
  fi
  local sub=${1:-list}
  (($#)) && shift
  case $sub in
    list)
      (($#)) && {
        td_usage_err theme "unexpected argument: $1"
        return
      }
      local name src
      if ((TD_OPT_JSON)); then
        td_theme_list | jq -R --arg cur "${TD_CONF[theme]}" -n '[inputs | split("\t")
          | {name: .[0], source: .[1], current: (.[0] == $cur)}]'
        return
      fi
      while IFS=$'\t' read -r name src; do
        if [[ $name == "${TD_CONF[theme]}" ]]; then
          printf '* %-14s %s\n' "$name" "$src"
        else
          printf '  %-14s %s\n' "$name" "$src"
        fi
      done < <(td_theme_list)
      ;;
    show)
      local name=${1:-${TD_CONF[theme]}}
      td_theme_load "$name" || return
      if ((TD_OPT_JSON)); then
        local -a pairs=()
        local key
        for key in "${TD_THEME_KEYS[@]}"; do pairs+=(--arg "$key" "${TD_THEME[$key]}"); done
        jq -n --arg name "$name" '{name: $name, colors: $ARGS.named | del(.name)}' "${pairs[@]}"
        return
      fi
      td_color_tier
      td_theme_sgr
      printf 'Theme %s (color tier %s)\n' "$name" "$TD_TIER"
      local key
      for key in "${TD_THEME_KEYS[@]}"; do
        if [[ " ${TD_THEME_BG_KEYS[*]} " == *" $key "* ]]; then
          printf '  %-10s %s  %s  sample text  %s\n' "$key" "${TD_THEME[$key]}" \
            "${TD_TB[$key]}${TD_TC[fg]}" "${TD_TC[reset]}"
        else
          printf '  %-10s %s  %s███ sample%s\n' "$key" "${TD_THEME[$key]}" "${TD_TC[$key]}" "${TD_TC[reset]}"
        fi
      done
      ;;
    set)
      if (($# != 1)); then
        td_usage_err theme "usage: todosh theme set NAME"
        return
      fi
      td_theme_path "$1" >/dev/null || return
      td_config_set theme "$1" || return
      ((TD_OPT_JSON)) && jq -n --arg t "$1" '{theme: $t}' || printf 'Theme set to %s\n' "$1"
      ;;
    import)
      if [[ ${1:-} != kitty ]]; then
        td_usage_err theme "only 'todosh theme import kitty [FILE]' is supported"
        return
      fi
      td_theme_import_kitty "${2:-}" || return
      local file=$TD_RESULT
      td_config_set theme kitty || return
      if ((TD_OPT_JSON)); then
        jq -n --arg f "$file" '{theme: "kitty", file: $f}'
      else
        printf 'Imported your kitty colors into %s\nTheme set to kitty\n' "$file"
      fi
      ;;
    *) td_usage_err theme "unknown subcommand: $sub" ;;
  esac
}

# --- projects --------------------------------------------------------------

td_register_cmd project Tasks "Create, list or remove projects and subprojects"
td_register_cmd projects Tasks "List projects as a tree (same as: project list)"
td_help_project() {
  printf '%s\n' \
    "Usage: todosh project [list | add PATH | remove PATH]" \
    "" \
    "Projects nest like paths: 'HardwareHacking/RF & SDR' is a subproject of" \
    "'HardwareHacking' (up to 4 levels). A project exists while it has tasks;" \
    "'add' creates it in advance so it shows up empty. Filters include" \
    "subprojects: todosh list p:HardwareHacking" \
    "" \
    "  list          Tree with open/done counts (default)" \
    "  add PATH      Create a project (and its parents)" \
    "  remove PATH   Remove a project and its subprojects." \
    "                If the project has tasks you will be shown a red warning" \
    "                and asked to confirm with a 6-character code that contains" \
    "                at least one uppercase W (e.g. W3rm4n, dW4rp9)." \
    "                Live tasks are moved to the trash; trashed tasks are left." \
    "" \
    "Examples:" \
    "  todosh project add 'HardwareHacking/RF & SDR'" \
    "  todosh project remove 'HardwareHacking/P1 Fundamentos'" \
    "  todosh add Learn the fundamentals 'p:HardwareHacking/RF & SDR'"
}
td_help_projects() { td_help_project; }

td_cmd_projects() {
  if td_wants_help "$@"; then
    td_help_project
    return 0
  fi
  td_cmd_project list "$@"
}

td_cmd_project() {
  if td_wants_help "$@"; then
    td_help_project
    return 0
  fi
  local sub=${1:-list}
  (($#)) && shift
  td_storage_init || return
  case $sub in
    list)
      if (($#)); then
        td_usage_err project "unexpected argument: $1"
        return
      fi
      local tree
      tree=$(td_projects_tree) || return
      if ((TD_OPT_JSON)); then
        jq . <<<"$tree"
        return
      fi
      _td_render_projects "$tree"
      ;;
    add | remove)
      if (($# != 1)); then
        td_usage_err project "usage: todosh project $sub PATH"
        return
      fi
      if [[ $sub == add ]]; then
        td_project_add "$1" || return
        if ((TD_OPT_JSON)); then
          jq -n --arg p "$1" --argjson new "$TD_RESULT" '{project: $p, created: ($new == 1)}'
        elif ((TD_RESULT)); then
          printf 'Created project %s\n' "$1"
        else
          printf 'Project %s already exists\n' "$1"
        fi
      else
        _td_cmd_project_remove "$1" || return
      fi
      ;;
    *) td_usage_err project "unknown subcommand: $sub" ;;
  esac
}

# _td_cmd_project_remove PATH — remove a project, prompting for a warning code
# when the project has live or trashed tasks.
_td_cmd_project_remove() {
  local p=$1 live=0 trashed=0
  td_project_task_count "$p" live trashed || return

  local total=$((live + trashed))
  if ((total == 0)); then
    # No tasks — remove without any ceremony.
    td_project_remove "$p" || return
    ((TD_OPT_JSON)) && jq -n --arg p "$p" '{removed: $p, tasks_trashed: 0}' \
      || printf 'Removed project %s\n' "$p"
    return 0
  fi

  # Project has tasks — show a captcha-style confirmation code.
  local red=${TD_SGR[red]}${TD_SGR[bold]} reset=${TD_SGR[reset]} bold=${TD_SGR[bold]}

  printf '%sWARNING: project '\''%s'\'' has %d task(s)%s\n' \
    "$red" "$p" "$total" "$reset" >&2
  ((live > 0)) && printf '%s  %d live task(s) will be moved to the trash.%s\n' \
    "$red" "$live" "$reset" >&2
  ((trashed > 0)) && printf '%s  %d task(s) are already in the trash and will remain there.%s\n' \
    "$red" "$trashed" "$reset" >&2
  printf '%s  Deleting a project with tasks cannot be undone without manual recovery.%s\n' \
    "$red" "$reset" >&2

  local confirm_code
  td_project_gen_code confirm_code
  printf '\n%sType this code to confirm:%s %s%s%s\n' \
    "$bold" "$reset" "${TD_SGR[yellow]}$bold" "$confirm_code" "$reset" >&2
  printf '%s> %s' "$bold" "$reset" >&2

  local typed=""
  IFS= read -r typed

  if [[ $typed != "$confirm_code" ]]; then
    td_err "incorrect code (expected $confirm_code, got '$typed')"
    return "$TD_E_USAGE"
  fi

  td_project_remove_force "$p" || return

  if ((TD_OPT_JSON)); then
    jq -n --arg p "$p" --argjson t "$live" '{removed: $p, tasks_trashed: $t}'
  else
    local msg="Removed project $p"
    ((live > 0)) && msg+=" ($live task(s) moved to trash)"
    printf '%s\n' "$msg"
  fi
}

# _td_render_projects TREE_JSON — the project tree with counts.
_td_render_projects() {
  local path name depth open done_n total prefix w=0
  local -a rows=()
  while IFS=$'\x1f' read -r path name depth open done_n total; do
    rows+=("$path"$'\x1f'"$name"$'\x1f'"$depth"$'\x1f'"$open"$'\x1f'"$done_n"$'\x1f'"$total")
    ((${#name} + 2 * depth > w)) && w=$((${#name} + 2 * depth))
  done < <(jq -r '.[] | [.path, .name, .depth, .open, .done, .total] | map(tostring) | join("\u001f")' <<<"$1")
  if ((${#rows[@]} == 0)); then
    [[ -t 1 ]] && printf 'No projects yet. Create one with: todosh project add NAME\n'
    return 0
  fi
  local row pad
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r path name depth open done_n total <<<"$row"
    prefix=""
    ((depth > 0)) && printf -v prefix '%*s%s ' $((2 * depth - 2)) '' "${TD_SYM[child]}"
    pad=$((w + 2 - ${#prefix} - ${#name}))
    printf '%s%s%s%s%*s%s%s open%s  %s/%s done%s\n' "${TD_SGR[gray]}" "$prefix" "${TD_SGR[reset]}" \
      "${TD_SGR[magenta]}$name${TD_SGR[reset]}" "$pad" "" "${TD_SGR[bold]}" "$open" \
      "${TD_SGR[reset]}${TD_SGR[gray]}" "$done_n" "$total" "${TD_SGR[reset]}"
  done
}
