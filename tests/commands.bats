#!/usr/bin/env bats
# Task commands through the real CLI: parsing, output contract, exit codes.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  td_test_setup
}

task() { jq -r "$2" "$HOME/.local/share/todosh/tasks/$1.json"; }

@test "add: words, shorthand and options" {
  run todosh add Review firewall rules p:infra pri:h +network +audit
  [ "$status" -eq 0 ]
  [ "$output" = "Created #1 Review firewall rules" ]
  [ "$(task 1 '[.title, .project, .priority, (.tags | join(","))] | join("|")')" = \
    "Review firewall rules|infra|high|audit,network" ]
  todosh add Sub ^1 '!urgent' >/dev/null
  todosh add Other --parent=1 --priority low --tag x --project ops >/dev/null
  [ "$(task 2 '[.parent, .priority, .project] | join("|")')" = "1|urgent|infra" ]
  [ "$(task 3 '[.parent, .priority, .project, .tags[0]] | join("|")')" = "1|low|ops|x" ]
}

@test "add: quoted phrases and words after -- stay literal" {
  todosh add "Fix +1 bug in p:core" >/dev/null
  [ "$(task 1 '.title + "|" + .project')" = "Fix +1 bug in p:core|inbox" ]
  todosh add -- +1 for p:this idea >/dev/null
  [ "$(task 2 .title)" = "+1 for p:this idea" ]
}

@test "add: description from stdin and JSON output" {
  run --separate-stderr todosh add Notes --description - --json <<<$'line 1\nline 2'
  [ "$status" -eq 0 ]
  jq -e '.id == 1 and .description == "line 1\nline 2" and .status == "TODO"' <<<"$output"
}

@test "add: usage errors" {
  run todosh add
  [ "$status" -eq 2 ]
  run todosh add x --priority
  [ "$status" -eq 2 ]
  [[ $output == *"needs a value"* ]]
  run todosh add x --bogus
  [ "$status" -eq 2 ]
  run todosh add x due:friday
  [ "$status" -eq 2 ]
  run todosh add x pri:huge
  [ "$status" -eq 2 ]
  run todosh add x ^99
  [ "$status" -eq 3 ]
}

@test "list: table for pipes has no colors and indents subtasks" {
  todosh add Parent p:infra >/dev/null
  todosh add Child ^1 >/dev/null
  todosh add Other pri:urgent >/dev/null
  todosh "done" 2 >/dev/null
  run todosh list
  [ "$status" -eq 0 ]
  [[ $output != *$'\e'* ]]
  [ "${lines[0]:0:10}" = "○ U #3 Oth" ]
  [[ ${lines[1]} == "○ M #1 Parent"*"infra"*"1/1" ]]
  [[ ${lines[2]} == "  ✓ M #2 Child"* ]]
}

@test "list: ASCII markers without a UTF-8 locale" {
  todosh add Task >/dev/null
  LC_ALL=C LANG=C run todosh list
  [[ $output == "[ ] M #1 Task"* ]]
}

@test "list: filters and JSON" {
  todosh add A p:infra +net >/dev/null
  todosh add B p:docs >/dev/null
  todosh add C p:infra pri:high >/dev/null
  todosh block 3 >/dev/null
  run --separate-stderr todosh list p:infra --json
  [ "$(jq -c 'map(.id)' <<<"$output")" = "[3,1]" ]
  run todosh list --status todo,BLOCKED --project docs --project infra +net
  [ "${#lines[@]}" -eq 1 ]
  run --separate-stderr todosh list --priority h --json
  [ "$(jq -c 'map(.id)' <<<"$output")" = "[3]" ]
  run todosh list --status nope
  [ "$status" -eq 2 ]
  run todosh list surprise
  [ "$status" -eq 2 ]
}

@test "list: bare todosh lists; empty list prints nothing to a pipe" {
  run todosh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  todosh add Something >/dev/null
  run todosh
  [[ $output == *"#1 Something"* ]]
}

@test "show: details, subtasks, history and JSON" {
  todosh add Parent --description "Some *markdown*" >/dev/null
  todosh add Child ^1 >/dev/null
  todosh comment 1 "A remark" >/dev/null
  run todosh show 1
  [ "$status" -eq 0 ]
  [[ $output == "#1 Parent"* ]]
  [[ $output == *"Some *markdown*"* ]]
  [[ $output == *"#2 Child"* ]]
  [[ $output == *"» A remark"* ]]
  run --separate-stderr todosh show 1 --json
  jq -e '.task.id == 1 and (.subtasks | map(.id)) == [2] and .trashed == false' <<<"$output"
  run todosh show 7
  [ "$status" -eq 3 ]
  run todosh show 1 2
  [ "$status" -eq 2 ]
}

@test "status commands: output, skips, messages and JSON" {
  todosh add A >/dev/null
  todosh add B >/dev/null
  run todosh start 1 2
  [ "$output" = $'#1 → IN_PROGRESS  A\n#2 → IN_PROGRESS  B' ]
  run --separate-stderr todosh start 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ $stderr == "#1 is already IN_PROGRESS" ]]
  run --separate-stderr todosh block 2 -m "waiting for VPN" --json
  jq -e '.[0].status == "BLOCKED" and .[0].history[-1].text == "waiting for VPN"' <<<"$output"
  run todosh "done" 1
  run todosh start 1
  [ "$status" -eq 4 ]
  run todosh reopen 1
  [ "$output" = "#1 → TODO  A" ]
  run todosh "done"
  [ "$status" -eq 2 ]
  run todosh "done" 99
  [ "$status" -eq 3 ]
}

@test "done --force closes open subtasks" {
  todosh add P >/dev/null
  todosh add C ^1 >/dev/null
  run todosh "done" 1
  [ "$status" -eq 4 ]
  [[ $output == *"--force"* ]]
  run todosh "done" 1 --force
  [ "$status" -eq 0 ]
  [ "$(task 2 .status)" = DONE ]
}

@test "comment: from arguments, from a pipe, and empty is refused" {
  todosh add T >/dev/null
  run todosh comment 1 Found an unexpected rule
  [ "$output" = "Comment added to #1 T" ]
  printf 'multi\nline\n' | todosh comment 1 >/dev/null
  [ "$(task 1 '[.history[] | select(.type == "comment") | .text] | join("|")')" = \
    $'Found an unexpected rule|multi\nline' ]
  run todosh comment 1 - <<<""
  [ "$status" -eq 2 ]
  run todosh comment x hi
  [ "$status" -eq 2 ]
}

@test "log: filters comments and events" {
  todosh add T >/dev/null
  todosh start 1 >/dev/null
  todosh comment 1 note >/dev/null
  run todosh log 1 --comments
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == *"» note" ]]
  run todosh log 1 --events
  [ "${#lines[@]}" -eq 2 ]
  run --separate-stderr todosh log 1 --json
  [ "$(jq length <<<"$output")" -eq 3 ]
}

@test "edit: options, shorthand, tag removal and no-op" {
  todosh add T +a +b >/dev/null
  run todosh edit 1 --title "New title" pri:urgent +c --untag a p:work
  [ "$output" = "Updated #1 New title" ]
  [ "$(task 1 '[.title, .priority, .project, (.tags | join(","))] | join("|")')" = \
    "New title|urgent|work|b,c" ]
  run todosh edit 1 --title "New title"
  [ "$output" = "No changes to #1" ]
  todosh edit 1 --description - <<<"from stdin" >/dev/null
  [ "$(task 1 .description)" = "from stdin" ]
  run todosh edit 1 stray words
  [ "$status" -eq 2 ]
}

@test "edit: the editor session sets title and description" {
  if ! { : </dev/tty; } 2>/dev/null; then
    # Without a controlling terminal the editor cannot run.
    todosh add T >/dev/null
    run todosh edit 1
    [ "$status" -eq 2 ]
    [[ $output == *"requires a terminal"* ]]
    return 0
  fi
  local editor="$BATS_TEST_TMPDIR/fake-editor"
  # shellcheck disable=SC2016 # the script expands $1 itself
  printf '#!/bin/sh\nprintf "Edited title\\n\\nNew body\\nsecond line\\n" >"$1"\n' >"$editor"
  chmod +x "$editor"
  todosh add T >/dev/null
  EDITOR=$editor VISUAL='' run todosh edit 1
  [ "$status" -eq 0 ]
  [ "$(task 1 .title)" = "Edited title" ]
  [ "$(task 1 .description)" = $'New body\nsecond line' ]
}

@test "trash: delete, list, undelete, purge" {
  todosh add P >/dev/null
  todosh add C ^1 >/dev/null
  run todosh delete 1
  [ "$status" -eq 4 ]
  run todosh delete 1 --force
  [ "${lines[0]}" = "Trashed #2 C" ]
  [ "${lines[1]}" = "Trashed #1 P" ]
  run todosh list
  [ -z "$output" ]
  run todosh trash
  [[ ${lines[0]} == *"#1 P"* ]]
  run todosh show 2
  [[ $output == *"in the trash"* ]]
  run todosh undelete 1
  [ "$output" = $'Restored #1 P\nRestored #2 C' ]
  todosh delete 2 >/dev/null
  run todosh purge
  [ "$status" -eq 2 ]
  [[ $output == *"--yes"* ]]
  run --separate-stderr todosh purge --yes --json
  [ "$output" = '{
  "purged": [
    2
  ]
}' ]
  run todosh purge --yes
  [ "$output" = "The trash is empty." ]
}

@test "concurrent adds from separate processes get unique IDs" {
  local i
  for ((i = 0; i < 10; i++)); do
    todosh add "Task $i" >/dev/null &
  done
  wait
  run bash -c 'ls "$1" | sort -n | xargs' _ "$HOME/.local/share/todosh/tasks"
  [ "$output" = "1.json 2.json 3.json 4.json 5.json 6.json 7.json 8.json 9.json 10.json" ]
}

@test "help lists commands by group" {
  run todosh help
  [[ $output == *$'Tasks:\n  add'* ]]
  [[ $output == *"Trash:"* ]]
  run todosh "done" --help
  [[ $output == "Usage: todosh done"* ]]
}
