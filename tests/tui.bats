#!/usr/bin/env bats
# The interface: frame layout and helpers without a terminal, plus a smoke
# test in a pseudo-terminal when `script` is available.

load test_helper

setup() {
  td_test_setup
  todosh add Review firewall rules p:infra pri:high +network due:tomorrow \
    --description "Check inbound rules on fw01 and fw02." >/dev/null
  todosh add Export current rules ^1 >/dev/null
  todosh add Rotate certs p:infra pri:urgent due:2020-01-01 >/dev/null
  todosh add Update README p:docs >/dev/null
  todosh "done" 2 >/dev/null
  todosh comment 1 "Unexpected rule on 8080" >/dev/null
  todosh focus 1 >/dev/null
  td_load_lib
  td_paths_init
  td_config_load
  TD_OPT_COLOR=never
  # Unicode symbols whatever the locale of the machine running the tests.
  LC_ALL=C.UTF-8 td_term_init
  _tui_theme_init
}

# frame ROWS COLS — render without colors.
frame() {
  TUI_ROWS=$1 TUI_COLS=$2
  _tui_reload
  _tui_frame | sed 's/\x1b\[[0-9;]*m//g'
}

@test "every frame line has exactly the terminal width" {
  local size r c
  for size in "24 100" "16 60" "40 160" "10 40"; do
    read -r r c <<<"$size"
    run frame "$r" "$c"
    [ "${#lines[@]}" -eq "$r" ]
    local line
    for line in "${lines[@]}"; do
      [ "${#line}" -eq "$c" ] || {
        echo "size $size, width ${#line}: $line"
        return 1
      }
    done
  done
}

@test "frame shows groups, focus, warnings and hints" {
  run frame 24 100
  [[ ${lines[0]} == "╭─ TODOSH ─"*"◉ #1 Review firewall rules · "*"─╮" ]]
  [[ ${lines[1]} == *"View: active"*"⚠ 1 overdue"* ]]
  [[ $output == *"▾ docs"* && $output == *"▾ infra"* ]]
  [[ $output == *"◐ H #1 ◉ Review firewall rules"*"1/1 tomorrow"* ]]
  [[ $output == *"  ✓ M #2 Export current rules"* ]]
  [[ $output == *"○ U #3 Rotate certs"*"d late"* ]]
  [[ ${lines[22]} == *"n new"*"q quit"* ]]
}

@test "detail panel of the selected task" {
  _tui_reload
  local i
  for i in "${!U_ID[@]}"; do [[ ${U_ID[i]} == 1 ]] && TUI_SEL=$i; done
  run frame 30 120
  [[ $output == *"│ #1 Review firewall rules"* ]]
  [[ $output == *"IN_PROGRESS · high · infra"* ]]
  [[ $output == *"Due "*"(tomorrow)"* ]]
  [[ $output == *"◉ in focus for"* ]]
  [[ $output == *"Check inbound rules on fw01 and fw02."* ]]
  [[ $output == *"Subtasks 1/1"* ]]
  [[ $output == *"» now  Unexpected rule on 8080"* ]]
}

@test "narrow terminals get a single panel; tiny ones a notice" {
  run frame 20 60
  [[ ${lines[2]} != *"┬"* ]]
  run frame 8 30
  [[ $output == "Terminal too small"* ]]
}

@test "collapsed groups hide their tasks" {
  TUI_COLLAPSED["infra"]=1
  run frame 24 100
  [[ $output == *"▸ infra"* ]]
  [[ $output != *"Rotate certs"* ]]
}

@test "views: all shows closed tasks, overdue and blocked filter" {
  TUI_VIEW=overdue
  run frame 24 100
  [[ $output == *"Rotate certs"* && $output != *"Update README"* ]]
  TUI_VIEW=blocked
  run frame 24 100
  [[ $output == *"No tasks here"* ]]
  TUI_VIEW=active TUI_FILTER=readme
  run frame 24 100
  [[ $output == *"Update README"* && $output != *"Rotate certs"* ]]
}

@test "ASCII frame without Unicode" {
  LC_ALL=C td_term_init
  run frame 20 80
  [[ ${lines[0]} == "+- TODOSH -"* ]]
  [[ $output == *"[~] H #1 @ Review"* ]]
}

@test "_tui_split honors quotes and escapes, never evaluates" {
  _tui_split $'add "Fix the  bug" p:x it\\\'s \'$(touch nope)\''
  [ "${#TUI_WORDS[@]}" -eq 5 ]
  [ "${TUI_WORDS[1]}" = "Fix the  bug" ]
  [ "${TUI_WORDS[3]}" = "it's" ]
  # shellcheck disable=SC2016 # the literal text, never expanded
  [ "${TUI_WORDS[4]}" = '$(touch nope)' ]
  [ ! -e nope ]
  _tui_split '   '
  [ "${#TUI_WORDS[@]}" -eq 0 ]
  _tui_split '""'
  [ "${#TUI_WORDS[@]}" -eq 1 ]
}

@test "_tui_wrap wraps words and splits very long ones" {
  run _tui_wrap 10 "one two three four"
  [ "$output" = $'one two\nthree four' ]
  run _tui_wrap 4 "abcdefghij"
  [ "$output" = $'abcd\nefgh\nij' ]
  run _tui_wrap 20 $'para one\n\npara two'
  [ "$output" = $'para one\n\npara two' ]
}

@test "the interface refuses to start without a terminal" {
  run todosh tui </dev/null
  [ "$status" -eq 2 ]
  [[ $output == *"interactive terminal"* ]]
}

@test "smoke: drive the interface in a pseudo-terminal" {
  command -v script >/dev/null || skip "script(1) not available"
  local log="$BATS_TEST_TMPDIR/tui.log"
  (
    sleep 1
    printf 'n'
    sleep 0.5
    printf 'Made in the TUI +tui\r'
    sleep 1
    printf 'q'
  ) | TERM=xterm-256color timeout 20 script -qec "stty cols 100 rows 24; todosh" "$log" >/dev/null
  run todosh list +tui
  [[ $output == *"Made in the TUI"* ]]
  # The terminal was restored: alternate screen left, cursor shown.
  grep -q $'\e\[?1049l' "$log"
  grep -q $'\e\[?25h' "$log"
}

@test "smoke: Ctrl-C cancels a prompt and the interface keeps running" {
  command -v script >/dev/null || skip "script(1) not available"
  (
    sleep 1
    printf 'n'
    sleep 0.5
    printf 'cancelled task'
    sleep 0.3
    printf '\003'
    sleep 0.6
    printf 'n'
    sleep 0.5
    printf 'kept task\r'
    sleep 1
    printf 'q'
  ) | TERM=xterm-256color timeout 20 script -qec "stty cols 100 rows 24; todosh" /dev/null >/dev/null
  run todosh list --all
  [[ $output == *"kept task"* ]]
  [[ $output != *"cancelled task"* ]]
}
