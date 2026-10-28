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

# _td_reject_due — due dates arrive with phase 3.
_td_reject_due() {
  if [[ -v TD_P[due] ]]; then
    td_usage_err "$TD_CMD" "due dates are not supported yet"
    return
  fi
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
    "  --project NAME       Project (default: the parent's, else config" \
    "                       'default_project', which defaults to inbox)" \
    "  --priority LEVEL     urgent | high | med | low (default: med)" \
    "  --tag NAME           Add a tag (repeatable)" \
    "  --parent ID          Create as a subtask of ID" \
    "  -d, --description T  Description text; '-' reads it from stdin" \
    "" \
    "Inline shorthand (whole words only; quoted phrases stay literal):" \
    "  p:infra   pri:high (or pri:h)   +network   ^42 (or parent:42)" \
    "  Use -- to stop parsing: todosh add -- +1 for the idea" \
    "  Note: '!high' also works, but most shells need it quoted: '!high'" \
    "" \
    "Examples:" \
    "  todosh add Review firewall rules p:infra pri:high +network" \
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
  _td_reject_due || return
  _td_norm_priority
  if ((${#words[@]} == 0)); then
    td_usage_err add "missing task title"
    return
  fi
  local description=${TD_P[description]:-}
  [[ $description == - ]] && _td_read_stdin description

  td_storage_init || return
  td_task_add "${words[*]}" "${TD_P[project]:-}" \
    "${TD_P[priority]:-med}" "${TD_P[parent]:-}" "$description" "${TD_P_TAGS[@]}" || return
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
    "  --status LIST       Only these statuses (comma-separated, e.g. todo,blocked)" \
    "  --project NAME      Filter by project (repeatable)       shorthand: p:NAME" \
    "  --priority LEVEL    Filter by priority (repeatable)      shorthand: pri:LEVEL" \
    "  --tag NAME          Require a tag (repeatable)           shorthand: +NAME" \
    "  --parent ID         Only subtasks of ID                  shorthand: ^ID" \
    "" \
    "Subtasks appear indented under their parent when both match." \
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
  local visibility=default rc s
  local -a statuses=() projects=() priorities=()
  while (($#)); do
    case $1 in
      -a | --all) visibility=all ;;
      -o | --open) visibility=open ;;
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
  _td_reject_due || return
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
    --arg parent "${TD_P[parent]:-}" \
    --arg statuses "${statuses[*]}" --arg priorities "${priorities[*]}" \
    --arg projects "${projects[*]}" --arg tags "${TD_P_TAGS[*]}" '
    def words: split(" ") | map(select(. != ""));
    {visibility: $vis, archive_days: $days,
     parent: (if $parent == "" then null else ($parent | tonumber) end),
     statuses: ($statuses | words), priorities: ($priorities | words),
     projects: ($projects | words), tags: ($tags | words)}') || return

  td_storage_init || return
  tasks=$(td_tasks_select "$filter") || return
  if ((TD_OPT_JSON)); then
    jq . <<<"$tasks"
  else
    _td_render_list "$tasks"
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

# _td_render_list JSON — print a task table for a terminal or a pipe.
_td_render_list() {
  local -a r_depth=() r_id=() r_status=() r_prio=() r_project=() r_tags=() r_progress=() r_title=()
  local d i s p pr tg pg t _parent
  while IFS=$'\x1f' read -r d i s p pr tg pg t _parent; do
    r_depth+=("$d") r_id+=("$i") r_status+=("$s") r_prio+=("$p") r_project+=("$pr")
    r_tags+=("$tg") r_progress+=("$pg") r_title+=("$t")
  done < <(jq -r '(map(.id)) as $ids | .[]
    | [(if .parent != null and (.parent | IN($ids[])) then 1 else 0 end),
       .id, .status, .priority, .project, (.tags | map("+" + .) | join(" ")),
       (if .subtasks then "\(.subtasks.done)/\(.subtasks.total)" else "" end),
       (.title | gsub("[[:cntrl:]]"; " ")), (.parent // "")]
    | map(tostring) | join("\u001f")' <<<"$1")

  local n=${#r_id[@]}
  if ((n == 0)); then
    [[ -t 1 ]] && printf 'No tasks to show. Add one with: todosh add <title>\n'
    return 0
  fi

  # Column widths. Text is padded by character count (${#}), not bytes, so
  # accented letters align; double-width glyphs may still shift a little.
  local idw=1 titlew=0 projw=0 tagw=0 cols
  for ((i = 0; i < n; i++)); do
    ((${#r_id[i]} > idw)) && idw=${#r_id[i]}
    ((${#r_title[i]} + 2 * r_depth[i] > titlew)) && titlew=$((${#r_title[i]} + 2 * r_depth[i]))
    ((${#r_project[i]} > projw)) && projw=${#r_project[i]}
    ((${#r_tags[i]} > tagw)) && tagw=${#r_tags[i]}
  done
  cols=$(td_term_cols)
  if ((cols > 0)); then
    local fixed=$((${#TD_SYM[TODO]} + 3 + idw + 3 + 2 + projw + 2 + tagw + 6))
    local avail=$((cols - fixed))
    ((avail < 16)) && avail=16
    ((titlew > avail)) && titlew=$avail
  fi

  local -A prio_letter=([urgent]=U [high]=H [med]=M [low]=L)
  local line indent shown pad dim reset=${TD_SGR[reset]}
  for ((i = 0; i < n; i++)); do
    dim=""
    td_status_is_closed "${r_status[i]}" && dim=${TD_SGR[dim]}
    indent=""
    ((r_depth[i])) && indent="  "
    td_truncate shown "${r_title[i]}" $((titlew - ${#indent}))
    pad=$((titlew - ${#indent} - ${#shown}))
    printf -v line '%s%s%s%s %s%s%s %s#%-*s%s %s%s%*s  %s%-*s%s  %s%-*s%s  %s' \
      "$dim" "$indent" "$(td_status_color "${r_status[i]}")" "${TD_SYM[${r_status[i]}]}" \
      "$reset$dim$(td_priority_color "${r_prio[i]}")" "${prio_letter[${r_prio[i]}]:-?}" "$reset$dim" \
      "${TD_SGR[gray]}" "$idw" "${r_id[i]}" "$reset$dim" \
      "${dim:-${TD_SGR[bold]}}" "$shown" "$pad" "" \
      "$reset$dim${TD_SGR[magenta]}" "$projw" "${r_project[i]}" "$reset$dim" \
      "${TD_SGR[cyan]}" "$tagw" "${r_tags[i]}" "$reset$dim" \
      "${r_progress[i]}"
    # Drop trailing padding so piped output has no dangling spaces.
    line=${line%%+( )}
    printf '%s%s\n' "$line" "$reset"
  done
}

# --- show / log ------------------------------------------------------------

td_register_cmd show Tasks "Show a task with its subtasks and history"
td_help_show() {
  printf '%s\n' \
    "Usage: todosh show <id>" \
    "" \
    "Shows fields, description, subtasks and the full history." \
    "Tasks in the trash can be shown too." \
    "With --json: {\"task\": {...}, \"subtasks\": [...], \"trashed\": bool}"
}

td_cmd_show() {
  if td_wants_help "$@"; then
    td_help_show
    return 0
  fi
  if (($# != 1)); then
    td_usage_err show "expected exactly one task id"
    return
  fi
  local id=$1 area=tasks record subtasks
  if ! td_valid_id "$id"; then
    td_usage_err show "invalid task id: '$id'"
    return
  fi
  td_storage_init || return
  [[ -f $TD_DATA_DIR/tasks/$id.json ]] || area=trash
  if [[ ! -f $TD_DATA_DIR/$area/$id.json ]]; then
    td_err "task #$id not found"
    return "$TD_E_NOTFOUND"
  fi
  record=$(td_task_read "$id" "$area") || return
  subtasks=$(td_tasks_select "{\"parent\": $id, \"visibility\": \"all\"}" "$area") || return

  if ((TD_OPT_JSON)); then
    jq -n --argjson task "$record" --argjson subtasks "$subtasks" --arg area "$area" \
      '{task: $task, subtasks: $subtasks, trashed: ($area == "trash")}'
    return
  fi
  local out
  out=$(_td_render_show "$record" "$subtasks" "$area") || return
  td_page "$out"
}

# _td_render_show RECORD SUBTASKS AREA
_td_render_show() {
  local record=$1 subtasks=$2 area=$3
  local -a f
  mapfile -d '' f < <(jq -j '
    def clean: split("\n") | map(gsub("[[:cntrl:]]"; " ")) | join("\n");
    def when: if . then fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M") else "" end;
    [.id, (.title | clean), .status, .priority, .project,
     (.tags | map("+" + .) | join(" ")), (.parent // ""), (.created | when),
     (.updated | when), (.closed | when), (.description | clean)]
    | map(tostring + "\u0000") | add' <<<"$record")
  local id=${f[0]} title=${f[1]} status=${f[2]} prio=${f[3]} project=${f[4]}
  local tags=${f[5]} parent=${f[6]} created=${f[7]} updated=${f[8]} closed=${f[9]} desc=${f[10]}
  local b=${TD_SGR[bold]} r=${TD_SGR[reset]} g=${TD_SGR[gray]}

  printf '%s#%s %s%s\n' "$b" "$id" "$title" "$r"
  [[ $area == trash ]] && printf '%s(in the trash: todosh undelete %s)%s\n' "${TD_SGR[red]}" "$id" "$r"
  printf '  %sStatus%s    %s%s %s%s\n' "$g" "$r" "$(td_status_color "$status")" \
    "${TD_SYM[$status]}" "$status" "$r"
  printf '  %sPriority%s  %s%s%s\n' "$g" "$r" "$(td_priority_color "$prio")" "$prio" "$r"
  printf '  %sProject%s   %s\n' "$g" "$r" "$project"
  [[ -n $tags ]] && printf '  %sTags%s      %s%s%s\n' "$g" "$r" "${TD_SGR[cyan]}" "$tags" "$r"
  if [[ -n $parent ]]; then
    local ptitle=""
    [[ -f $TD_DATA_DIR/$area/$parent.json ]] \
      && ptitle=$(jq -r '.title' "$TD_DATA_DIR/$area/$parent.json")
    printf '  %sParent%s    #%s %s\n' "$g" "$r" "$parent" "$ptitle"
  fi
  printf '  %sCreated%s   %s\n' "$g" "$r" "$created"
  printf '  %sUpdated%s   %s\n' "$g" "$r" "$updated"
  [[ -n $closed ]] && printf '  %sClosed%s    %s\n' "$g" "$r" "$closed"

  if [[ -n $desc ]]; then
    printf '\n%sDescription%s\n' "$b" "$r"
    printf '%s\n' "$desc" | sed 's/^/  /'
  fi
  if [[ $(jq length <<<"$subtasks") -gt 0 ]]; then
    printf '\n%sSubtasks%s\n' "$b" "$r"
    _td_render_list "$subtasks" | sed 's/^/  /'
  fi
  printf '\n%sHistory%s\n' "$b" "$r"
  _td_render_history "$record" all
}

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
  done < <(jq -j --arg kind "$2" --arg arrow "${TD_SYM[arrow]}" --arg none "${TD_SYM[dash]}" '
    def clean: split("\n") | map(gsub("[[:cntrl:]]"; " ")) | join("\n");
    def val: if . == null then $none elif type == "array" then (map("+" + .) | join(" ") | if . == "" then $none else . end)
             else tostring end;
    .history[]
    | select($kind == "all" or ($kind == "comments" and .type == "comment")
             or ($kind == "events" and .type != "comment"))
    | [(.at | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")), .type,
       (if .type == "comment" then .text
        elif .event == "created" then "created"
        elif .event == "status" then "status \(.from) \($arrow) \(.to)"
        elif .event == "edit" and .field == "description" then "description edited"
        elif .event == "edit" and .field == "parent" then
          "parent \(.from | if . then "#\(.)" else $none end) \($arrow) \(.to | if . then "#\(.)" else $none end)"
        elif .event == "edit" then "\(.field) \(.from | val) \($arrow) \(.to | val)"
        elif .event == "deleted" then "moved to the trash"
        elif .event == "restored" then "restored from the trash"
        else (.event // .type) end | clean)]
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
  _td_reject_due || return
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
  local id=$1
  local -n _td_c=$2
  local record title desc tmp content new_title new_desc
  [[ -f $TD_DATA_DIR/tasks/$id.json ]] || {
    _td_missing "$id"
    return
  }
  record=$(td_task_read "$id") || return
  title=$(jq -r .title <<<"$record")
  desc=$(jq -r .description <<<"$record")
  tmp=$(mktemp --suffix=.md -t "todosh-$id.XXXXXXXX") || {
    td_err "cannot create a temporary file"
    return "$TD_E_ERR"
  }
  if [[ -n $desc ]]; then
    printf '%s\n\n%s\n' "$title" "$desc" >"$tmp"
  else
    printf '%s\n\n' "$title" >"$tmp"
  fi
  td_run_editor "$tmp" || {
    local rc=$?
    rm -f -- "$tmp"
    return "$rc"
  }
  content=$(<"$tmp")
  new_title=${content%%$'\n'*}
  new_title=${new_title##+([[:space:]])}
  new_title=${new_title%%+([[:space:]])}
  new_desc=""
  if [[ $content == *$'\n'* ]]; then
    new_desc=${content#*$'\n'}
    while [[ $new_desc == $'\n'* ]]; do new_desc=${new_desc#$'\n'}; done
  fi
  if [[ -z $new_title ]]; then
    rm -f -- "$tmp"
    printf 'Empty title: nothing changed.\n' >&2
    return 0
  fi
  if [[ $new_title == "$title" && $new_desc == "$desc" ]]; then
    rm -f -- "$tmp"
    printf 'No changes to #%s\n' "$id" >&2
    return 0
  fi
  _td_c["title"]=$new_title
  _td_c["description"]=$new_desc
  _td_c["if_title"]=$title
  _td_c["if_description"]=$desc
  # The caller removes it after a successful save; otherwise the text is kept.
  TD_EDIT_TMP=$tmp
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
