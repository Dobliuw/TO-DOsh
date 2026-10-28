#!/usr/bin/env bats
# Focus and work sessions (lib/focus.sh) and their interaction with tasks.

load test_helper

setup() {
  td_test_setup
  td_load_lib
  td_paths_init
  td_config_load
  td_storage_init
}

add() { td_task_add "$1" "" med "${2:-}" "" "" >/dev/null; }
field() { jq -r "$2" "$TD_DATA_DIR/${3:-tasks}/$1.json"; }
focus_task() { jq -r '.task' "$TD_DATA_DIR/focus.json"; }

# backdate SECONDS — pretend the current session started SECONDS ago.
backdate() {
  local since
  since=$(date -u -d "-$1 seconds" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg s "$since" '.since = $s' "$TD_DATA_DIR/focus.json" >"$TD_DATA_DIR/f.tmp"
  mv "$TD_DATA_DIR/f.tmp" "$TD_DATA_DIR/focus.json"
}

sessions() { field "$1" '[.history[] | select(.type == "focus") | .seconds] | join(" ")'; }

@test "no focus by default" {
  local id since
  td_focus_read id since
  [ -z "$id" ]
}

@test "focusing a TODO task starts it; a BLOCKED one keeps its status" {
  add A
  add B
  td_task_set_status BLOCKED 0 "" 2
  td_focus_set 1
  [ "$TD_RESULT" = 1 ]
  [ "$(field 1 .status)" = IN_PROGRESS ]
  [ "$(focus_task)" = 1 ]
  td_focus_set 2
  [ "$(field 2 .status)" = BLOCKED ]
}

@test "focusing the focused task again changes nothing" {
  add A
  td_focus_set 1
  local before
  before=$(cat "$TD_DATA_DIR/focus.json")
  td_focus_set 1
  [ "$TD_RESULT" = 0 ]
  [ "$(cat "$TD_DATA_DIR/focus.json")" = "$before" ]
}

@test "moving the focus records the previous session" {
  add A
  add B
  td_focus_set 1
  backdate 3600
  td_focus_set 2
  run sessions 1
  [[ $output =~ ^36[0-9]{2}$ ]]
  [ "$(field 1 .status)" = IN_PROGRESS ]
  [ "$(field 1 '.history[-1] | has("since") and .at >= .since')" = true ]
  [ "$(focus_task)" = 2 ]
}

@test "unfocus records the session and clears the focus" {
  add A
  td_focus_set 1
  backdate 120
  td_focus_clear
  [ "$TD_RESULT" = 1 ]
  [ "$(focus_task)" = null ]
  [[ $(sessions 1) =~ ^12[0-9]$ ]]
  td_focus_clear
  [ -z "$TD_RESULT" ]
}

@test "zero-length sessions are not recorded" {
  add A
  td_focus_set 1
  jq '.since = "2999-01-01T00:00:00Z"' "$TD_DATA_DIR/focus.json" >"$TD_DATA_DIR/f.tmp"
  mv "$TD_DATA_DIR/f.tmp" "$TD_DATA_DIR/focus.json"
  td_focus_clear
  [ -z "$(sessions 1)" ]
}

@test "closed tasks cannot be focused" {
  add A
  td_task_set_status DONE 0 "" 1
  run td_focus_set 1
  [ "$status" -eq 4 ]
  run td_focus_set 9
  [ "$status" -eq 3 ]
}

@test "closing the focused task releases the focus" {
  add A
  td_focus_set 1
  backdate 60
  td_task_set_status DONE 0 "" 1
  [ "$(focus_task)" = null ]
  [ -n "$(sessions 1)" ]
  # The session is recorded before the status change.
  [ "$(field 1 '[.history[] | .type + ":" + (.event // "")] | .[-2:] | join(" ")')" = "focus: event:status" ]
}

@test "cascading close of a parent releases a focused subtask" {
  add P
  add C 1
  td_focus_set 2
  td_task_set_status CANCELLED 1 "" 1
  [ "$(focus_task)" = null ]
}

@test "blocking or reopening the focused task keeps the focus" {
  add A
  td_focus_set 1
  td_task_set_status BLOCKED 0 "" 1
  [ "$(focus_task)" = 1 ]
}

@test "deleting the focused task releases the focus; the session is kept" {
  add A
  td_focus_set 1
  backdate 60
  td_task_delete 0 1
  [ "$(focus_task)" = null ]
  [ -n "$(sessions 1)" ] || [ -n "$(field 1 '[.history[] | select(.type == "focus")] | length' trash)" ]
  [ "$(field 1 '[.history[] | select(.type == "focus")] | length' trash)" = 1 ]
}

@test "a focus file pointing to a missing task means no focus" {
  printf '{"task": 77, "since": "2026-01-01T00:00:00Z"}\n' >"$TD_DATA_DIR/focus.json"
  local id since
  td_focus_read id since
  [ -z "$id" ]
  add A
  td_focus_set 1
  [ "$(focus_task)" = 1 ]
}

@test "td_focus_read does not clobber caller variables named like its internals" {
  add A
  td_focus_set 1
  local id="" since=""
  td_focus_read id since
  [ "$id" = 1 ]
  [ -n "$since" ]
}

@test "due dates: stored, edited, cleared and sorted" {
  td_task_add Later "" med "" "" 2026-12-01
  td_task_add Sooner "" med "" "" 2026-11-01
  td_task_add None "" med "" "" ""
  [ "$(field 1 .due)" = 2026-12-01 ]
  [ "$(td_tasks_select '{}' | jq -c 'map(.id)')" = "[2,1,3]" ]
  local -A ch=([due]="")
  td_task_edit 1 ch
  [ "$(field 1 .due)" = null ]
  [ "$(field 1 '.history[-1] | "\(.field) \(.from) \(.to)"')" = "due 2026-12-01 null" ]
  run td_task_add Bad "" med "" "" 2026-02-30
  [ "$status" -eq 2 ]
}

@test "overdue filter: only open tasks due before today" {
  td_task_add Past "" med "" "" 2020-01-01
  td_task_add PastDone "" med "" "" 2020-01-01
  td_task_add Future "" med "" "" 2999-01-01
  td_task_set_status DONE 0 "" 2
  [ "$(td_tasks_select '{"overdue": true, "visibility": "all"}' | jq -c 'map(.id)')" = "[1]" ]
}
