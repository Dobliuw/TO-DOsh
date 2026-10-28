#!/usr/bin/env bats
# Projects and subprojects (lib/projects.sh) and their commands.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  td_test_setup
  td_load_lib
  td_paths_init
  td_config_load
  td_storage_init
}

@test "project paths: up to 4 levels, spaces and symbols allowed" {
  td_valid_project inbox
  td_valid_project "HardwareHacking/RF & SDR"
  td_valid_project "a/b/c/d"
  td_valid_project "Año 2026 (Q4)"
  for bad in "" "/a" "a/" "a//b" "a/b/c/d/e" " lead" "trail " "a/./b" "a/../b" \
    "$(printf 'x%.0s' {1..33})" $'a\tb' $'new\nline'; do
    refute td_valid_project "$bad"
  done
}

@test "tasks accept subproject paths; filters include subprojects" {
  td_task_add "Fundamentals" "HardwareHacking/RF & SDR" med "" "" ""
  td_task_add "ChipWhisperer" "HardwareHacking/Fault Injection" med "" "" ""
  td_task_add "Other" "HardwareHackingX" med "" "" ""
  [ "$(td_tasks_select '{"projects": ["HardwareHacking"]}' | jq -c 'map(.id) | sort')" = "[1,2]" ]
  [ "$(td_tasks_select '{"projects": ["HardwareHacking/RF & SDR"]}' | jq -c 'map(.id)')" = "[1]" ]
  run td_task_add "Bad" "a//b" med "" "" ""
  [ "$status" -eq 2 ]
}

@test "registry: add creates parents, is idempotent, keeps empty projects" {
  td_project_add "Hacking/RF & SDR"
  [ "$TD_RESULT" = 1 ]
  td_project_add "Hacking"
  [ "$TD_RESULT" = 0 ]
  [ "$(td_projects_registered | xargs -d '\n' printf '%s|')" = "Hacking|Hacking/RF & SDR|" ]
  run td_projects_tree
  [ "$(jq -c 'map([.path, .depth, .total])' <<<"$output")" = '[["Hacking",0,0],["Hacking/RF & SDR",1,0]]' ]
}

@test "tree: counts include subprojects; inbox first; alphabetical" {
  td_task_add "A" "zeta" med "" "" ""
  td_task_add "B" "Alpha/Sub" med "" "" ""
  td_task_add "C" "Alpha" med "" "" ""
  td_task_add "D" "inbox" med "" "" ""
  td_task_set_status DONE 0 "" 2
  run td_projects_tree
  [ "$(jq -c 'map(.path)' <<<"$output")" = '["inbox","Alpha","Alpha/Sub","zeta"]' ]
  [ "$(jq -c '.[1] | [.open, .done, .total]' <<<"$output")" = "[1,1,2]" ]
}

@test "remove: refused while tasks use the project, then removes the subtree" {
  td_project_add "Hacking/Fault"
  td_task_add "T" "Hacking/Fault" med "" "" ""
  run td_project_remove "Hacking"
  [ "$status" -eq 4 ]
  td_task_delete 0 1
  run td_project_remove "Hacking"
  [ "$status" -eq 4 ]
  [[ $output == *"in trash"* ]]
  td_task_purge
  td_project_remove "Hacking"
  [ -z "$(td_projects_registered)" ]
  run td_project_remove "Nope"
  [ "$status" -eq 3 ]
}

@test "CLI: project add / projects / list p:parent / remove" {
  run todosh project add "HardwareHacking/RF & SDR"
  [ "$output" = "Created project HardwareHacking/RF & SDR" ]
  todosh add Learn fundamentals "p:HardwareHacking/RF & SDR" >/dev/null
  todosh add ChipWhisperer --project "HardwareHacking/Fault Injection" >/dev/null
  run todosh projects
  [[ ${lines[0]} == "HardwareHacking"*"2 open"* ]]
  [[ ${lines[1]} == "↳ Fault Injection"* ]]
  [[ ${lines[2]} == "↳ RF & SDR"*"1 open"* ]]
  run todosh list p:HardwareHacking
  [ "${#lines[@]}" -eq 2 ]
  run todosh list --project "HardwareHacking/Fault Injection" --json
  [ "$(jq length <<<"$output")" -eq 1 ]
  run todosh project remove HardwareHacking
  [ "$status" -eq 4 ]
  run --separate-stderr todosh projects --json
  jq -e 'map(.path) | index("HardwareHacking/RF & SDR")' <<<"$output"
}

@test "config set / get, and the editor fallback" {
  run todosh config set editor "nano -w"
  [ "$output" = "editor = nano -w" ]
  run todosh config get editor
  [ "$output" = "nano -w" ]
  run todosh config set editor $'bad\x01'
  [ "$status" -eq 2 ]
  run todosh config get nope
  [ "$status" -eq 2 ]
  # Nothing configured: the first installed of nvim, vim, nano, vi.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/bin/vim"
  chmod +x "$BATS_TEST_TMPDIR/bin/vim"
  TD_CONF["editor"]="" VISUAL="" EDITOR="" PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  local -a cmd
  if ! command -v nvim >/dev/null; then
    td_editor_cmd cmd
    [ "${cmd[0]}" = vim ]
  fi
  EDITOR="code -w" td_editor_cmd cmd
  [ "${cmd[*]}" = "code -w" ]
}
