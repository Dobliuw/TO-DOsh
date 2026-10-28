# shellcheck shell=bash disable=SC2034
# focus.sh — the single focused task and its work sessions.
#
# focus.json holds {"task": ID|null, "since": TIMESTAMP|null}. A session runs
# from `since` until the focus moves, is released, or the task is closed or
# deleted. It is then stored in the task history as
#   {"type": "focus", "at": END, "since": START, "seconds": N}
# (`at` is when the entry was recorded, like every other history entry)
# so time spent survives in the task itself, even after the focus moves.
# (SC2034 is disabled for this file: TD_RESULT is read by callers elsewhere.)

# td_focus_read ID_VAR SINCE_VAR — current focus, or "" when there is none
# (also when focus.json points to a task that is no longer live).
td_focus_read() {
  local -n _td_fid=$1 _td_fsince=$2
  # Locals are prefixed so they cannot shadow the caller's variable names.
  local _td_file=$TD_DATA_DIR/focus.json _td_info _td_id
  _td_fid="" _td_fsince=""
  [[ -f $_td_file ]] || return 0
  if ! _td_info=$(jq -r '"\(.task // "")\t\(.since // "")"' "$_td_file" 2>/dev/null); then
    td_warn "ignoring corrupted $_td_file"
    return 0
  fi
  _td_id=${_td_info%%$'\t'*}
  if td_valid_id "$_td_id" && [[ -f $TD_DATA_DIR/tasks/$_td_id.json ]]; then
    _td_fid=$_td_id
    _td_fsince=${_td_info#*$'\t'}
  fi
}

# td_focus_set ID — focus a task. A TODO task becomes IN_PROGRESS; the
# previous focus session (if any) is closed. Closed tasks cannot be focused.
# TD_RESULT: 1 if the focus changed, 0 if ID already had it.
td_focus_set() {
  TD_RESULT=""
  _td_validate_ids "$1" || return
  td_with_lock _td_focus_set_locked "$1"
}

_td_focus_set_locked() {
  local id=$1 status current since now
  [[ -f $TD_DATA_DIR/tasks/$id.json ]] || {
    _td_missing "$id"
    return
  }
  status=$(jq -r .status "$TD_DATA_DIR/tasks/$id.json") || return
  if td_status_is_closed "$status"; then
    td_err "task #$id is $status; reopen it before focusing it"
    return "$TD_E_CONFLICT"
  fi
  td_focus_read current since
  if [[ $current == "$id" ]]; then
    TD_RESULT=0
    return 0
  fi
  _td_focus_end || return
  if [[ $status == TODO ]]; then
    td_task_set_status IN_PROGRESS 0 "" "$id" || return
  fi
  td_now_utc now
  td_write_json "$TD_DATA_DIR/focus.json" \
    "$(jq -cn --argjson id "$id" --arg now "$now" '{task: $id, since: $now}')" || return
  TD_RESULT=1
}

# td_focus_clear — release the focus. TD_RESULT: the released ID, or "".
td_focus_clear() {
  TD_RESULT=""
  td_with_lock _td_focus_clear_locked
}

_td_focus_clear_locked() {
  local id since
  td_focus_read id since
  _td_focus_end || return
  TD_RESULT=$id
}

# _td_focus_end — close the running session, if any, and clear focus.json.
# Requires the lock. Used by focus changes and by tasks.sh when the focused
# task is closed or deleted.
_td_focus_end() {
  local id since now record new
  td_focus_read id since
  [[ -n $id || -f $TD_DATA_DIR/focus.json ]] || return 0
  td_now_utc now
  if [[ -n $id ]]; then
    record=$(td_task_read "$id") || return
    new=$(jq -c --arg since "$since" --arg now "$now" '
      (try (($now | fromdateiso8601) - ($since | fromdateiso8601)) catch 0) as $s
      | if $s > 0
        then .history += [{type: "focus", at: $now, since: $since, seconds: $s}] | .updated = $now
        else . end' <<<"$record") || return
    if [[ $new != "$record" ]]; then
      td_task_write "$id" "$new" || return
    fi
  fi
  td_write_json "$TD_DATA_DIR/focus.json" '{"task": null, "since": null}'
}
