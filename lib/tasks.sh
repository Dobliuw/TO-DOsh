# shellcheck shell=bash disable=SC2034
# tasks.sh — task business rules, shared by the CLI and the TUI.
#
# Mutations validate their input, hold the lock for the whole
# read-check-write sequence, record every change in the task history, and put
# their result in TD_RESULT (documented per function). Queries print JSON.
# Nothing here prints user-facing text other than errors. (SC2034 is disabled
# for this file: TD_RESULT and TD_SKIPPED are read by callers elsewhere.)
#
# Invariants kept by these functions:
#   - subtasks are one level deep: a task with a parent has no children;
#   - a closed (DONE/CANCELLED) parent has no open subtasks;
#   - a live task never has its parent in the trash.

TD_RESULT=""
TD_SKIPPED=""

readonly TD_MAX_TEXT=100000

td_status_is_closed() {
  [[ $1 == DONE || $1 == CANCELLED ]]
}

# td_transition_allowed FROM TO — open tasks may move to any other status;
# closed tasks can only go back to TODO.
td_transition_allowed() {
  case $1 in
    TODO | IN_PROGRESS | BLOCKED) [[ $2 != "$1" ]] && td_valid_status "$2" ;;
    DONE | CANCELLED) [[ $2 == TODO ]] ;;
    *) return 1 ;;
  esac
}

# _td_validate_ids ID... — every argument must be a well-formed ID.
_td_validate_ids() {
  local id
  if (($# == 0)); then
    td_err "no task id given"
    return "$TD_E_USAGE"
  fi
  for id in "$@"; do
    if ! td_valid_id "$id"; then
      td_err "invalid task id: '$id'"
      return "$TD_E_USAGE"
    fi
  done
}

# _td_validate_text LABEL TEXT — free text within limits.
_td_validate_text() {
  if ! td_valid_text "$2"; then
    td_err "$1 contains control characters"
    return "$TD_E_USAGE"
  fi
  if ((${#2} > TD_MAX_TEXT)); then
    td_err "$1 is too long (max $TD_MAX_TEXT characters)"
    return "$TD_E_USAGE"
  fi
}

_td_validate_title() {
  if ! td_valid_title "$1"; then
    td_err "invalid title: must be one line of 1-200 characters"
    return "$TD_E_USAGE"
  fi
}

_td_validate_names() {
  local label=$1 name
  shift
  for name in "$@"; do
    if ! td_valid_name "$name"; then
      td_err "invalid $label name: '$name' (letters, digits, '.', '_', '-'; max 32)"
      return "$TD_E_USAGE"
    fi
  done
}

# _td_missing ID — report a task that is not live, mentioning the trash.
_td_missing() {
  if [[ -f $TD_DATA_DIR/trash/$1.json ]]; then
    td_err "task #$1 is in the trash (restore it with: todosh undelete $1)"
  else
    td_err "task #$1 not found"
  fi
  return "$TD_E_NOTFOUND"
}

# _td_check_parent PARENT [CHILD] — PARENT can receive subtasks.
_td_check_parent() {
  local parent=$1 child=${2:-} info
  if [[ $parent == "$child" ]]; then
    td_err "a task cannot be its own parent"
    return "$TD_E_USAGE"
  fi
  [[ -f $TD_DATA_DIR/tasks/$parent.json ]] || {
    _td_missing "$parent"
    return
  }
  info=$(jq -r '"\(.parent // "")\t\(.status)"' "$TD_DATA_DIR/tasks/$parent.json") || {
    td_err "corrupted task file: $TD_DATA_DIR/tasks/$parent.json"
    return "$TD_E_ERR"
  }
  if [[ -n ${info%%$'\t'*} ]]; then
    td_err "task #$parent is itself a subtask; subtasks cannot be nested"
    return "$TD_E_CONFLICT"
  fi
  if td_status_is_closed "${info#*$'\t'}"; then
    td_err "task #$parent is ${info#*$'\t'}; reopen it before adding subtasks"
    return "$TD_E_CONFLICT"
  fi
}

# _td_child_ids ALL_JSON ID [open] — print IDs of the subtasks of ID.
_td_child_ids() {
  jq -r --argjson id "$2" --arg only "${3:-}" \
    '.[] | select(.parent == $id)
         | select($only != "open" or (.status | IN("DONE", "CANCELLED") | not))
         | .id' <<<"$1"
}

# --- create ----------------------------------------------------------------

# td_task_add TITLE PROJECT PRIORITY PARENT DESCRIPTION [TAG...]
# PARENT may be empty. An empty PROJECT means the parent's project, or the
# configured default_project for top-level tasks. TD_RESULT: the new task ID.
td_task_add() {
  local title=$1 project=$2 priority=$3 parent=$4 description=$5
  shift 5
  TD_RESULT=""
  _td_validate_title "$title" || return
  [[ -n $project ]] && { _td_validate_names project "$project" || return; }
  (($#)) && { _td_validate_names tag "$@" || return; }
  if ! td_valid_priority "$priority"; then
    td_err "invalid priority: '$priority' (urgent, high, med, low)"
    return "$TD_E_USAGE"
  fi
  if [[ -n $parent ]]; then
    _td_validate_ids "$parent" || return
  fi
  _td_validate_text description "$description" || return
  td_with_lock _td_task_add_locked "$title" "$project" "$priority" "$parent" "$description" "$@"
}

_td_task_add_locked() {
  local title=$1 project=$2 priority=$3 parent=$4 description=$5 id now record
  shift 5
  if [[ -n $parent ]]; then
    _td_check_parent "$parent" || return
    [[ -n $project ]] || project=$(jq -r .project "$TD_DATA_DIR/tasks/$parent.json") || return
  fi
  : "${project:=${TD_CONF[default_project]:-inbox}}"
  td_next_id id || return
  td_now_utc now
  record=$(jq -cn --argjson id "$id" --arg title "$title" --arg project "$project" \
    --arg priority "$priority" --arg parent "$parent" --arg description "$description" \
    --arg now "$now" '{
      id: $id, title: $title, description: $description,
      status: "TODO", priority: $priority, project: $project,
      tags: ($ARGS.positional | unique),
      parent: (if $parent == "" then null else ($parent | tonumber) end),
      due: null, created: $now, updated: $now, closed: null,
      history: [{type: "event", at: $now, event: "created"}]
    }' --args "$@") || return
  td_task_write "$id" "$record" || return
  TD_RESULT=$id
}

# --- edit ------------------------------------------------------------------

# td_task_edit ID CHANGES — CHANGES names an associative array with any of:
#   title, description, priority, project, parent (an ID or "none"),
#   tags_add, tags_remove (space-separated names),
#   if_title, if_description (only apply if the current value still matches:
#   protects edits made in an external editor against concurrent changes).
# TD_RESULT: 1 if the task changed, 0 if there was nothing to change.
td_task_edit() {
  local id=$1
  local -n _td_ch=$2
  local key
  local -a tags_add=() tags_remove=() pairs=()
  TD_RESULT=""
  _td_validate_ids "$id" || return
  for key in "${!_td_ch[@]}"; do
    case $key in
      title) _td_validate_title "${_td_ch[$key]}" || return ;;
      description) _td_validate_text description "${_td_ch[$key]}" || return ;;
      priority)
        td_valid_priority "${_td_ch[$key]}" || {
          td_err "invalid priority: '${_td_ch[$key]}' (urgent, high, med, low)"
          return "$TD_E_USAGE"
        }
        ;;
      project) _td_validate_names project "${_td_ch[$key]}" || return ;;
      parent)
        [[ ${_td_ch[$key]} == none ]] || _td_validate_ids "${_td_ch[$key]}" || return
        ;;
      tags_add | tags_remove)
        local -n _td_list=$key
        read -ra _td_list <<<"${_td_ch[$key]}"
        unset -n _td_list
        _td_validate_names tag "${tags_add[@]}" "${tags_remove[@]}" || return
        continue
        ;;
      if_title | if_description) ;;
      *)
        td_err "internal error: unknown edit field: $key"
        return "$TD_E_ERR"
        ;;
    esac
    pairs+=(--arg "$key" "${_td_ch[$key]}")
  done
  local changes
  changes=$(jq -cn '$ARGS.named
    | if has("parent") then .parent |= (if . == "none" then null else tonumber end) else . end' \
    "${pairs[@]}") || return
  changes=$(jq -c --argjson add "$(jq -cn '$ARGS.positional' --args "${tags_add[@]}")" \
    --argjson rm "$(jq -cn '$ARGS.positional' --args "${tags_remove[@]}")" \
    '. + {tags_add: $add, tags_remove: $rm}' <<<"$changes") || return
  td_with_lock _td_task_edit_locked "$id" "$changes"
}

_td_task_edit_locked() {
  local id=$1 changes=$2 record new now parent
  [[ -f $TD_DATA_DIR/tasks/$id.json ]] || {
    _td_missing "$id"
    return
  }
  record=$(td_task_read "$id") || return
  if ! jq -e --argjson ch "$changes" '
      (if $ch | has("if_title") then .title == $ch.if_title else true end) and
      (if $ch | has("if_description") then .description == $ch.if_description else true end)' \
    <<<"$record" >/dev/null; then
    td_err "task #$id was modified by another process while you were editing"
    return "$TD_E_CONFLICT"
  fi

  parent=$(jq -r 'if has("parent") then (.parent // "none") else "" end' <<<"$changes")
  if [[ -n $parent && $parent != none ]]; then
    _td_check_parent "$parent" "$id" || return
    local all
    all=$(td_tasks_load) || return
    if [[ -n $(_td_child_ids "$all" "$id") ]]; then
      td_err "task #$id has subtasks, so it cannot become a subtask itself"
      return "$TD_E_CONFLICT"
    fi
  fi

  td_now_utc now
  new=$(jq -c --argjson ch "$changes" --arg now "$now" '
    (.history | length) as $before
    | reduce ($ch | to_entries[]
        | select(.key | IN("title", "description", "priority", "project", "parent"))) as $e (.;
        if .[$e.key] == $e.value then .
        else .history += [{type: "event", at: $now, event: "edit", field: $e.key}
               + (if $e.key == "description" then {} else {from: .[$e.key], to: $e.value} end)]
             | .[$e.key] = $e.value
        end)
    | .tags as $old
    | .tags = ((.tags + $ch.tags_add - $ch.tags_remove) | unique)
    | if .tags != $old
      then .history += [{type: "event", at: $now, event: "edit", field: "tags", from: $old, to: .tags}]
      else . end
    | if (.history | length) > $before then .updated = $now else . end' <<<"$record") || return

  if [[ $new == "$record" ]]; then
    TD_RESULT=0
    return 0
  fi
  td_task_write "$id" "$new" || return
  TD_RESULT=1
}

# --- status ----------------------------------------------------------------

# td_task_set_status STATUS FORCE MESSAGE ID...
# Closing a task with open subtasks requires FORCE=1, which closes them too
# (subtasks named in the same call count as handled). Reopening a subtask of a
# closed parent reopens the parent. MESSAGE (optional) is added as a comment to
# the named tasks. All checks run before any write.
# TD_RESULT: changed IDs in write order; TD_SKIPPED: IDs already in STATUS.
td_task_set_status() {
  local status=$1 force=$2 message=$3
  shift 3
  TD_RESULT="" TD_SKIPPED=""
  if ! td_valid_status "$status"; then
    td_err "invalid status: '$status'"
    return "$TD_E_USAGE"
  fi
  _td_validate_ids "$@" || return
  _td_validate_text message "$message" || return
  td_with_lock _td_task_status_locked "$status" "$force" "$message" "$@"
}

_td_task_status_locked() {
  local status=$1 force=$2 message=$3
  shift 3
  local all id info cur parent kid
  local -a plan=() plan_status=() plan_msg=() kids=() skipped=()
  local -A planned=() named=()
  all=$(td_tasks_load) || return
  for id in "$@"; do named[$id]=1; done

  # _plan ID STATUS WITH_MESSAGE
  _plan() {
    [[ -v planned[$1] ]] && return 0
    planned[$1]=1
    plan+=("$1")
    plan_status+=("$2")
    plan_msg+=("$3")
  }

  for id in "$@"; do
    [[ -v planned[$id] ]] && continue
    info=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | "\(.status)\t\(.parent // "")"' <<<"$all")
    if [[ -z $info ]]; then
      _td_missing "$id"
      return
    fi
    cur=${info%%$'\t'*}
    parent=${info#*$'\t'}
    if [[ $cur == "$status" ]]; then
      skipped+=("$id")
      continue
    fi
    if ! td_transition_allowed "$cur" "$status"; then
      td_err "task #$id is $cur; reopen it before setting it to $status"
      return "$TD_E_CONFLICT"
    fi

    if td_status_is_closed "$status"; then
      mapfile -t kids < <(_td_child_ids "$all" "$id" open)
      local -a unhandled=()
      for kid in "${kids[@]}"; do
        [[ -v named[$kid] ]] || unhandled+=("#$kid")
      done
      if ((${#unhandled[@]} && ! force)); then
        td_err "task #$id has open subtasks (${unhandled[*]}); close them first or use --force"
        return "$TD_E_CONFLICT"
      fi
      for kid in "${kids[@]}"; do
        _plan "$kid" "$status" "${named[$kid]:-0}"
      done
    elif [[ -n $parent ]]; then
      local pstatus
      pstatus=$(jq -r --argjson id "$parent" '.[] | select(.id == $id) | .status' <<<"$all")
      if td_status_is_closed "$pstatus"; then
        _plan "$parent" TODO 0
      fi
    fi
    _plan "$id" "$status" 1
  done
  unset -f _plan

  local i now record new
  td_now_utc now
  for i in "${!plan[@]}"; do
    id=${plan[i]}
    record=$(td_task_read "$id") || return
    local msg=""
    ((plan_msg[i])) && msg=$message
    new=$(jq -c --arg s "${plan_status[i]}" --arg now "$now" --arg msg "$msg" '
      .history += [{type: "event", at: $now, event: "status", from: .status, to: $s}]
      | if $msg != "" then .history += [{type: "comment", at: $now, text: $msg}] else . end
      | .status = $s | .updated = $now
      | .closed = (if $s == "DONE" or $s == "CANCELLED" then $now else null end)' \
      <<<"$record") || return
    td_task_write "$id" "$new" || return
  done
  TD_RESULT=${plan[*]}
  TD_SKIPPED=${skipped[*]}
}

# --- comments --------------------------------------------------------------

# td_task_comment ID TEXT — append a comment to the task history.
td_task_comment() {
  local id=$1 text=$2
  _td_validate_ids "$id" || return
  if [[ -z ${text//[[:space:]]/} ]]; then
    td_err "empty comment"
    return "$TD_E_USAGE"
  fi
  _td_validate_text comment "$text" || return
  td_with_lock _td_task_comment_locked "$id" "$text"
}

_td_task_comment_locked() {
  local id=$1 text=$2 record new now
  [[ -f $TD_DATA_DIR/tasks/$id.json ]] || {
    _td_missing "$id"
    return
  }
  record=$(td_task_read "$id") || return
  td_now_utc now
  new=$(jq -c --arg now "$now" --arg text "$text" \
    '.history += [{type: "comment", at: $now, text: $text}] | .updated = $now' <<<"$record") || return
  td_task_write "$id" "$new"
}

# --- trash -----------------------------------------------------------------

# td_task_delete FORCE ID... — move tasks to the trash. A task with subtasks
# needs FORCE=1 (or its subtasks named too); its subtasks go with it.
# TD_RESULT: moved IDs.
td_task_delete() {
  local force=$1
  shift
  TD_RESULT=""
  _td_validate_ids "$@" || return
  td_with_lock _td_task_delete_locked "$force" "$@"
}

_td_task_delete_locked() {
  local force=$1
  shift
  local all id kid now record new
  local -a plan=() kids=() unhandled=()
  local -A planned=() named=()
  all=$(td_tasks_load) || return
  for id in "$@"; do named[$id]=1; done
  for id in "$@"; do
    [[ -f $TD_DATA_DIR/tasks/$id.json ]] || {
      _td_missing "$id"
      return
    }
    mapfile -t kids < <(_td_child_ids "$all" "$id")
    unhandled=()
    for kid in "${kids[@]}"; do
      [[ -v named[$kid] ]] || unhandled+=("#$kid")
    done
    if ((${#unhandled[@]} && ! force)); then
      td_err "task #$id has subtasks (${unhandled[*]}); use --force to delete them too"
      return "$TD_E_CONFLICT"
    fi
    for kid in "${kids[@]}" "$id"; do
      [[ -v planned[$kid] ]] && continue
      planned[$kid]=1
      plan+=("$kid")
    done
  done

  td_now_utc now
  for id in "${plan[@]}"; do
    record=$(td_task_read "$id") || return
    new=$(jq -c --arg now "$now" \
      '.history += [{type: "event", at: $now, event: "deleted"}] | .updated = $now' \
      <<<"$record") || return
    td_task_write "$id" "$new" || return
    td_task_move "$id" tasks trash || return
  done
  TD_RESULT=${plan[*]}
}

# td_task_undelete ID... — restore tasks from the trash, with their trashed
# subtasks. A subtask whose parent is still in the trash needs the parent
# restored too; one whose parent was purged becomes a top-level task.
# TD_RESULT: restored IDs.
td_task_undelete() {
  TD_RESULT=""
  _td_validate_ids "$@" || return
  td_with_lock _td_task_undelete_locked "$@"
}

_td_task_undelete_locked() {
  local trash id parent kid now record new
  local -a plan=() kids=() detach=()
  local -A planned=() named=()
  trash=$(td_tasks_load trash) || return
  for id in "$@"; do named[$id]=1; done

  _plan() {
    [[ -v planned[$1] ]] && return 0
    planned[$1]=1
    plan+=("$1")
  }

  for id in "$@"; do
    if [[ ! -f $TD_DATA_DIR/trash/$id.json ]]; then
      if [[ -f $TD_DATA_DIR/tasks/$id.json ]]; then
        td_err "task #$id is not in the trash"
      else
        td_err "task #$id not found in the trash"
      fi
      unset -f _plan
      return "$TD_E_NOTFOUND"
    fi
    parent=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .parent // ""' <<<"$trash")
    if [[ -n $parent && ! -f $TD_DATA_DIR/tasks/$parent.json ]]; then
      if [[ -f $TD_DATA_DIR/trash/$parent.json ]]; then
        if [[ ! -v named[$parent] ]]; then
          td_err "the parent of #$id (#$parent) is in the trash; restore it instead: todosh undelete $parent"
          unset -f _plan
          return "$TD_E_CONFLICT"
        fi
        _plan "$parent"
      else
        detach+=("$id")
      fi
    fi
    _plan "$id"
    mapfile -t kids < <(_td_child_ids "$trash" "$id")
    for kid in "${kids[@]}"; do _plan "$kid"; done
  done
  unset -f _plan

  local -A detached=()
  for id in "${detach[@]}"; do detached[$id]=1; done
  td_now_utc now
  for id in "${plan[@]}"; do
    record=$(td_task_read "$id" trash) || return
    new=$(jq -c --arg now "$now" --arg detach "${detached[$id]:-0}" '
      .history += [{type: "event", at: $now, event: "restored"}]
      | if $detach == "1"
        then .history += [{type: "event", at: $now, event: "edit", field: "parent", from: .parent, to: null}]
             | .parent = null
        else . end
      | .updated = $now' <<<"$record") || return
    td_task_write "$id" "$new" trash || return
    td_task_move "$id" trash tasks || return
  done
  TD_RESULT=${plan[*]}
}

# td_task_purge [ID...] — permanently delete tasks from the trash (all of
# them when no ID is given), including trashed subtasks of the named tasks.
# TD_RESULT: purged IDs.
td_task_purge() {
  TD_RESULT=""
  (($#)) && { _td_validate_ids "$@" || return; }
  td_with_lock _td_task_purge_locked "$@"
}

_td_task_purge_locked() {
  local trash id kid
  local -a plan=() kids=()
  local -A planned=()
  if (($# == 0)); then
    mapfile -t plan < <(td_task_ids trash)
  else
    trash=$(td_tasks_load trash) || return
    for id in "$@"; do
      if [[ ! -f $TD_DATA_DIR/trash/$id.json ]]; then
        td_err "task #$id not found in the trash"
        return "$TD_E_NOTFOUND"
      fi
      mapfile -t kids < <(_td_child_ids "$trash" "$id")
      for kid in "$id" "${kids[@]}"; do
        [[ -v planned[$kid] ]] && continue
        planned[$kid]=1
        plan+=("$kid")
      done
    done
  fi
  for id in "${plan[@]}"; do
    td_task_remove "$id" trash || return
  done
  TD_RESULT=${plan[*]}
}

# --- queries ---------------------------------------------------------------

# td_tasks_select FILTER_JSON [AREA] — print matching tasks, without history,
# in display order: open before closed, then priority, then ID; subtasks right
# after their parent when both match. Each task with subtasks gains
# "subtasks": {"done": N, "total": M} (cancelled subtasks are not counted).
#
# FILTER_JSON keys (all optional):
#   statuses, priorities, projects: arrays (match any); tags: array (match all)
#   parent: ID (only its subtasks); text: case-insensitive substring of title
#   visibility: "default" (open + closed within archive_days), "open", "all"
#   archive_days: number (0 = never hide closed tasks)
# An explicit "statuses" filter overrides visibility.
td_tasks_select() {
  local filter=$1 area=${2:-tasks} all now
  all=$(td_tasks_load "$area") || return
  now=$(date +%s)
  jq -c --argjson f "$filter" --argjson now "$now" '
    def srank: {"IN_PROGRESS": 0, "BLOCKED": 1, "TODO": 2, "DONE": 3, "CANCELLED": 4}[.status] // 5;
    def prank: {"urgent": 0, "high": 1, "med": 2, "low": 3}[.priority] // 4;
    def closed: .status == "DONE" or .status == "CANCELLED";
    def visible:
      if ($f.statuses // []) | length > 0 then .status | IN($f.statuses[])
      elif $f.visibility == "all" then true
      elif $f.visibility == "open" then closed | not
      else (closed | not) or (($f.archive_days // 7) == 0)
        or (((.closed // .updated) | fromdateiso8601) > $now - ($f.archive_days // 7) * 86400)
      end;
    def matches:
      visible
      and (($f.priorities // []) as $p | $p == [] or (.priority | IN($p[])))
      and (($f.projects // []) as $p | $p == [] or (.project | IN($p[])))
      and (($f.tags // []) as $t | $t - .tags == [])
      and ($f.parent == null or .parent == $f.parent)
      and (($f.text // "") as $q | $q == ""
           or (.title | ascii_downcase | contains($q | ascii_downcase)));

    . as $all
    | (reduce ($all[] | select(.parent != null)) as $c ({};
        .[$c.parent | tostring] |= ((. // {done: 0, total: 0})
          | if $c.status == "CANCELLED" then .
            else .total += 1 | if $c.status == "DONE" then .done += 1 else . end end))) as $progress
    | [$all[] | select(matches) | del(.history)
       | if $progress[.id | tostring] then .subtasks = $progress[.id | tostring] else . end] as $hits
    | ($hits | map(.id)) as $ids
    | ($hits | map(select(.parent == null or (.parent | IN($ids[]) | not)))
             | sort_by([(closed | if . then 1 else 0 end), srank, prank, .id])) as $top
    | [$top[] as $t
       | $t,
         ($hits | map(select(.parent == $t.id)) | sort_by([srank, .id]) | .[])]' <<<"$all"
}
