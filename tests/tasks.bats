#!/usr/bin/env bats
# Business rules (lib/tasks.sh), exercised directly without the CLI.

load test_helper

setup() {
  td_test_setup
  td_load_lib
  td_paths_init
  td_config_load
  td_storage_init
}

# add TITLE [PARENT] [PROJECT] — create a task and print its ID.
add() {
  td_task_add "$1" "${3:-}" med "${2:-}" "" "" >/dev/null || return
  printf '%s\n' "$TD_RESULT"
}

field() { jq -r "$2" "$TD_DATA_DIR/${3:-tasks}/$1.json"; }

@test "add stores a complete record with a creation event" {
  td_task_add "Review firewall rules" infra high "" "Check fw01" "" network audit network
  [ "$TD_RESULT" = 1 ]
  run jq -c '[.id, .title, .description, .status, .priority, .project, .tags, .parent,
              .due, .closed, (.created == .updated), (.history | map(.event))]' \
    "$TD_DATA_DIR/tasks/1.json"
  [ "$output" = '[1,"Review firewall rules","Check fw01","TODO","high","infra",["audit","network"],null,null,null,true,["created"]]' ]
}

@test "titles and descriptions are stored verbatim" {
  # shellcheck disable=SC2016 # literal on purpose: must never expand
  local title='Quotes "x" '\''y'\'' $(rm -rf /) `id` ; & | > ñ 日本 ✓'
  local desc=$'Line 1\n\n  indented $HOME\n\ttab'
  td_task_add "$title" inbox med "" "$desc" ""
  [ "$(field 1 .title)" = "$title" ]
  [ "$(field 1 .description)" = "$desc" ]
}

@test "add validates its input" {
  run td_task_add "" inbox med "" "" ""
  [ "$status" -eq 2 ]
  run td_task_add $'two\nlines' inbox med "" "" ""
  [ "$status" -eq 2 ]
  run td_task_add ok "bad project" med "" "" ""
  [ "$status" -eq 2 ]
  run td_task_add ok inbox highest "" "" ""
  [ "$status" -eq 2 ]
  run td_task_add ok inbox med "" "" "" "bad/tag"
  [ "$status" -eq 2 ]
  run td_task_add ok inbox med "abc" "" ""
  [ "$status" -eq 2 ]
  run td_task_add ok inbox med "" $'esc\033' ""
  [ "$status" -eq 2 ]
  [ -z "$(td_task_ids)" ]
}

@test "project defaults: parent's project, else default_project" {
  add Parent "" infra >/dev/null
  add Child 1 >/dev/null
  add Other 1 ops >/dev/null
  add Top >/dev/null
  [ "$(field 2 .project)" = infra ]
  [ "$(field 3 .project)" = ops ]
  [ "$(field 4 .project)" = inbox ]
  TD_CONF["default_project"]=work
  add Top2 >/dev/null
  [ "$(field 5 .project)" = work ]
}

@test "subtask rules: parent must exist, be top-level and open" {
  add Parent >/dev/null
  add Child 1 >/dev/null
  [ "$(field 2 .parent)" = 1 ]
  run td_task_add x "" med 99 "" ""
  [ "$status" -eq 3 ]
  run td_task_add x "" med 2 "" ""
  [ "$status" -eq 4 ]
  [[ $output == *"cannot be nested"* ]]
  td_task_set_status DONE 1 "" 1
  run td_task_add x "" med 1 "" ""
  [ "$status" -eq 4 ]
  [[ $output == *"reopen it"* ]]
}

@test "edit applies changes and records one event per field" {
  td_task_add Title inbox med "" "" "" a b
  local -A ch=([title]="New title" [priority]=urgent [project]=infra [tags_add]="c" [tags_remove]="a"
    [description]="Body")
  td_task_edit 1 ch
  [ "$TD_RESULT" = 1 ]
  run jq -c '[.title, .priority, .project, .tags, .description]' "$TD_DATA_DIR/tasks/1.json"
  [ "$output" = '["New title","urgent","infra",["b","c"],"Body"]' ]
  run jq -c '[.history[] | select(.event == "edit") | .field] | sort' "$TD_DATA_DIR/tasks/1.json"
  [ "$output" = '["description","priority","project","tags","title"]' ]
  # Descriptions can be long: their events carry no copy of the text.
  run jq -c '.history[] | select(.field == "description") | has("from")' "$TD_DATA_DIR/tasks/1.json"
  [ "$output" = false ]
}

@test "edit without effective changes leaves the file untouched" {
  td_task_add Same inbox med "" "" "" a
  local before
  before=$(cat "$TD_DATA_DIR/tasks/1.json")
  local -A ch=([title]=Same [tags_add]=a [priority]=med)
  td_task_edit 1 ch
  [ "$TD_RESULT" = 0 ]
  [ "$(cat "$TD_DATA_DIR/tasks/1.json")" = "$before" ]
}

@test "edit refuses to overwrite concurrent changes (if_title)" {
  add Original >/dev/null
  local -A ch=([title]="Mine" [if_title]="Something else")
  run td_task_edit 1 ch
  [ "$status" -eq 4 ]
  [ "$(field 1 .title)" = Original ]
}

@test "edit parent: nesting and parents with subtasks are refused; none detaches" {
  add A >/dev/null
  add B >/dev/null
  add A1 1 >/dev/null
  local -A ch=([parent]=1)
  run td_task_edit 2 ch
  [ "$status" -eq 0 ]
  local -A ch2=([parent]=2)
  run td_task_edit 1 ch2
  [ "$status" -eq 4 ]
  local -A ch3=([parent]=3)
  run td_task_edit 3 ch3
  [ "$status" -eq 2 ]
  td_task_edit 2 ch
  local -A ch4=([parent]=none)
  td_task_edit 2 ch4
  [ "$(field 2 .parent)" = null ]
}

@test "status transitions: open tasks move freely, closed ones only reopen" {
  add T >/dev/null
  for s in IN_PROGRESS BLOCKED TODO DONE; do
    td_task_set_status "$s" 0 "" 1
    [ "$(field 1 .status)" = "$s" ]
  done
  run td_task_set_status IN_PROGRESS 0 "" 1
  [ "$status" -eq 4 ]
  [[ $output == *"reopen it"* ]]
  td_task_set_status TODO 0 "" 1
  [ "$(field 1 .status)" = TODO ]
  [ "$(field 1 '[.history[] | select(.event == "status") | "\(.from)>\(.to)"] | join(" ")')" = \
    "TODO>IN_PROGRESS IN_PROGRESS>BLOCKED BLOCKED>TODO TODO>DONE DONE>TODO" ]
}

@test "closing sets the closed timestamp, reopening clears it" {
  add T >/dev/null
  td_task_set_status CANCELLED 0 "" 1
  [ "$(field 1 .closed)" != null ]
  td_task_set_status TODO 0 "" 1
  [ "$(field 1 .closed)" = null ]
}

@test "same status is skipped without a new event" {
  add T >/dev/null
  td_task_set_status TODO 0 "" 1
  [ -z "$TD_RESULT" ]
  [ "$TD_SKIPPED" = 1 ]
  [ "$(field 1 '.history | length')" = 1 ]
}

@test "a batch is all-or-nothing" {
  add A >/dev/null
  add B >/dev/null
  td_task_set_status DONE 0 "" 2
  run td_task_set_status IN_PROGRESS 0 "" 1 2
  [ "$status" -eq 4 ]
  run td_task_set_status IN_PROGRESS 0 "" 1 99
  [ "$status" -eq 3 ]
  [ "$(field 1 .status)" = TODO ]
}

@test "a message becomes a comment on the named tasks only" {
  add P >/dev/null
  add C 1 >/dev/null
  td_task_set_status DONE 1 "shipped" 1
  [ "$(field 1 '[.history[] | select(.type == "comment") | .text] | join(",")')" = shipped ]
  [ "$(field 2 '[.history[] | select(.type == "comment")] | length')" = 0 ]
}

@test "closing a parent with open subtasks needs --force or naming them" {
  add P >/dev/null
  add C1 1 >/dev/null
  add C2 1 >/dev/null
  td_task_set_status DONE 0 "" 2
  run td_task_set_status DONE 0 "" 1
  [ "$status" -eq 4 ]
  [[ $output == *"#3"* && $output != *"#2"* ]]
  td_task_set_status DONE 0 "" 1 3
  [ "$TD_RESULT" = "3 1" ]
  [ "$(field 1 .status)" = DONE ]
}

@test "--force cascades the status to open subtasks, subtasks first" {
  add P >/dev/null
  add C1 1 >/dev/null
  add C2 1 >/dev/null
  td_task_set_status DONE 0 "" 2
  td_task_set_status CANCELLED 1 "" 1
  [ "$TD_RESULT" = "3 1" ]
  [ "$(field 2 .status)" = DONE ]
  [ "$(field 3 .status)" = CANCELLED ]
}

@test "reopening a subtask of a closed parent reopens the parent first" {
  add P >/dev/null
  add C 1 >/dev/null
  td_task_set_status DONE 1 "" 1
  td_task_set_status TODO 0 "" 2
  [ "$TD_RESULT" = "1 2" ]
  [ "$(field 1 .status)" = TODO ]
}

@test "comments are appended; empty or trashed targets are refused" {
  add T >/dev/null
  td_task_comment 1 $'first\nsecond line'
  td_task_comment 1 "again"
  [ "$(field 1 '[.history[] | select(.type == "comment") | .text] | length')" = 2 ]
  [ "$(field 1 '.history[1].text')" = $'first\nsecond line' ]
  run td_task_comment 1 "   "
  [ "$status" -eq 2 ]
  td_task_delete 0 1
  run td_task_comment 1 "late"
  [ "$status" -eq 3 ]
  [[ $output == *"in the trash"* ]]
}

@test "delete moves to the trash; subtasks require --force and follow" {
  add P >/dev/null
  add C 1 >/dev/null
  run td_task_delete 0 1
  [ "$status" -eq 4 ]
  td_task_delete 1 1
  [ "$TD_RESULT" = "2 1" ]
  [ ! -e "$TD_DATA_DIR/tasks/1.json" ]
  [ "$(field 1 '.history[-1].event' trash)" = deleted ]
  [ -z "$(td_task_ids)" ]
}

@test "undelete restores with subtasks; orphans need their parent" {
  add P >/dev/null
  add C 1 >/dev/null
  td_task_delete 1 1
  run td_task_undelete 2
  [ "$status" -eq 4 ]
  td_task_undelete 1
  [ "$TD_RESULT" = "1 2" ]
  [ "$(td_task_ids | xargs)" = "1 2" ]
  [ "$(field 2 '.history[-1].event')" = restored ]
  run td_task_undelete 1
  [ "$status" -eq 3 ]
}

@test "purging a parent also purges its trashed subtasks" {
  add P >/dev/null
  add C 1 >/dev/null
  td_task_delete 0 2
  td_task_delete 0 1
  td_task_purge 1
  [ "$TD_RESULT" = "1 2" ]
  [ -z "$(td_task_ids trash)" ]
}

@test "a subtask whose parent file is gone comes back as top-level" {
  add P >/dev/null
  add C 1 >/dev/null
  td_task_delete 1 1
  # Simulates data edited by hand or restored partially.
  rm "$TD_DATA_DIR/trash/1.json"
  td_task_undelete 2
  [ "$(field 2 .parent)" = null ]
}

@test "purge removes trashed files for good and IDs are never reused" {
  add A >/dev/null
  add B >/dev/null
  td_task_delete 0 1 2
  run td_task_purge 99
  [ "$status" -eq 3 ]
  td_task_purge
  [ "$TD_RESULT" = "1 2" ]
  [ -z "$(td_task_ids trash)" ]
  add C >/dev/null
  [ "$(td_task_ids)" = 3 ]
}

@test "select: tree order, progress and default visibility" {
  add Low >/dev/null
  add Urgent >/dev/null
  add Sub 1 >/dev/null
  add Sub2 1 >/dev/null
  add Gone 1 >/dev/null
  local -A ch=([priority]=urgent)
  td_task_edit 2 ch
  td_task_set_status IN_PROGRESS 0 "" 1
  td_task_set_status DONE 0 "" 3
  td_task_set_status CANCELLED 0 "" 5
  run td_tasks_select '{}'
  [ "$(jq -c 'map(.id)' <<<"$output")" = "[1,4,3,5,2]" ]
  [ "$(jq -c '.[0].subtasks' <<<"$output")" = '{"done":1,"total":2}' ]
  [ "$(jq -c 'map(has("history")) | any' <<<"$output")" = false ]

  # Closed long ago: hidden by default, shown with "all" or archive_days 0.
  td_lock
  td_task_write 3 "$(jq -c '.closed = "2020-01-01T00:00:00Z"' "$TD_DATA_DIR/tasks/3.json")"
  td_unlock
  run td_tasks_select '{"archive_days": 7}'
  [ "$(jq -c 'map(.id)' <<<"$output")" = "[1,4,5,2]" ]
  run td_tasks_select '{"visibility": "all"}'
  [ "$(jq length <<<"$output")" = 5 ]
  run td_tasks_select '{"archive_days": 0}'
  [ "$(jq length <<<"$output")" = 5 ]
  run td_tasks_select '{"visibility": "open"}'
  [ "$(jq -c 'map(.id)' <<<"$output")" = "[1,4,2]" ]
}

@test "select filters: statuses, projects, all tags, parent, text" {
  td_task_add "Fix DNS" infra high "" "" "" net dns
  td_task_add "Fix VPN" infra low "" "" "" net
  td_task_add "Write docs" docs med "" "" ""
  td_task_add "Sub" "" med 1 "" ""
  td_task_set_status BLOCKED 0 "" 2
  [ "$(td_tasks_select '{"statuses": ["BLOCKED"]}' | jq -c 'map(.id)')" = "[2]" ]
  [ "$(td_tasks_select '{"projects": ["docs"]}' | jq -c 'map(.id)')" = "[3]" ]
  [ "$(td_tasks_select '{"tags": ["net", "dns"]}' | jq -c 'map(.id)')" = "[1]" ]
  [ "$(td_tasks_select '{"priorities": ["low", "high"]}' | jq -c 'map(.id) | sort')" = "[1,2]" ]
  [ "$(td_tasks_select '{"parent": 1}' | jq -c 'map(.id)')" = "[4]" ]
  [ "$(td_tasks_select '{"text": "fix"}' | jq -c 'map(.id) | sort')" = "[1,2]" ]
}
