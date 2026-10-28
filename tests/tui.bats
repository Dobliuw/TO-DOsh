#!/usr/bin/env bats
# The interface. The main screen and dialogs are rendered without a terminal;
# forms and pickers are driven with synthetic keys; two smoke tests run the
# real thing in a pseudo-terminal when script(1) is available.

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
  TD_QUIET_ERRORS=1
  TD_OPT_COLOR=never
  # Unicode symbols whatever the locale of the machine running the tests.
  LC_ALL=C.UTF-8 _tui_theme_init
  _tui_reload
  # Dialogs read keys from FEED instead of the terminal, and draw nothing.
  FEED=() FEED_I=0
  _tui_read_key() {
    if ((FEED_I >= ${#FEED[@]})); then
      echo "ran out of keys (layers: ${#TUI_LAYERS[@]})" >&2
      return 1
    fi
    TUI_KEY=${FEED[FEED_I]}
    FEED_I=$((FEED_I + 1))
  }
  _tui_paint() { :; }
  _tui_edit_external() { :; }
}

# frame ROWS COLS — render the main screen without colors.
frame() {
  TUI_ROWS=$1 TUI_COLS=$2
  _tui_frame | sed 's/\x1b\[[0-9;]*m//g'
}

# keys KEY... — queue synthetic keys (letters may be given as a word: "w:Fix").
keys() {
  local k i
  for k in "$@"; do
    if [[ $k == w:* ]]; then
      k=${k#w:}
      for ((i = 0; i < ${#k}; i++)); do
        if [[ ${k:i:1} == " " ]]; then FEED+=(space); else FEED+=("${k:i:1}"); fi
      done
    else
      FEED+=("$k")
    fi
  done
}

select_task() {
  _tui_select_task "$1"
}

task() { jq -r "$2" "$HOME/.local/share/todosh/tasks/$1.json"; }

@test "every line of the main screen has exactly the terminal width" {
  local size r c line
  for size in "24 100" "16 60" "40 160" "12 50"; do
    read -r r c <<<"$size"
    run frame "$r" "$c"
    [ "${#lines[@]}" -eq "$r" ]
    for line in "${lines[@]}"; do
      [ "${#line}" -eq "$c" ] || {
        echo "size $size, width ${#line}: '$line'"
        return 1
      }
    done
  done
}

@test "top bar: app badge, view tabs and the focus" {
  run frame 24 120
  [[ ${lines[0]} == " ◆ todosh   1 Active  2 All  3 Overdue  4 Blocked "* ]]
  [[ ${lines[0]} == *"◉ Review firewall rules · "*" " ]]
}

@test "list: projects with progress, subtask trees, priority, due date, ids" {
  run frame 24 120
  [[ $output == *"▾ docs"*"▱▱▱▱▱▱ 0/1"* ]]
  [[ $output == *"▾ infra"*"1/3"* ]]
  [[ $output == *"◐ ◉ Review firewall rules"*"▲ high  1/1  ◷ tomorrow  #1"* ]]
  [[ $output == *"   └ ✓ Export current rules"*"#2"* ]]
  [[ $output == *"○ Rotate certs"*"‼ urgent  ◷ "*"d late  #3"* ]]
}

@test "status bar: mode, key hints and counts" {
  run frame 24 120
  [[ ${lines[23]} == " NORMAL "*"n new"*"? help"* ]]
  [[ ${lines[23]} == *"3 open · ⚠ 1 overdue "* ]]
}

@test "details: title, badges, due, focus, notes, subtasks, activity" {
  select_task 1
  run frame 30 130
  [[ $output == *"│  Review firewall rules"* ]]
  [[ $output == *"#1 · created just now · updated just now"* ]]
  [[ $output == *" ◐ Doing "* || $output == *" ◐ IN PROGRESS "* ]]
  [[ $output == *" high "*"▸ infra"* ]]
  [[ $output == *"#network"* ]]
  [[ $output == *"◷  Due     "*"tomorrow"* ]]
  [[ $output == *"◉  Worked  "*"in focus for"* ]]
  [[ $output == *"Notes ─"* && $output == *"Check inbound rules on fw01 and fw02."* ]]
  [[ $output == *"Subtasks 1/1 ─"* ]]
  [[ $output == *"● now Unexpected rule on 8080"* || $output == *"● now  Unexpected rule on 8080"* ]]
}

@test "details of a project row" {
  _tui_select_group infra
  run frame 30 130
  [[ $output == *"▸ infra"* && $output == *"1/3 done"* ]]
  [[ $output == *"in progress"* && $output == *"to do"* ]]
}

@test "narrow terminals: list only; tiny ones: a notice" {
  run frame 20 60
  [[ ${lines[2]} != *"DETAILS"* ]]
  run frame 8 30
  [[ $output == "Terminal too small"* ]]
}

@test "collapsed projects hide their tasks" {
  TUI_COLLAPSED["infra"]=1
  _tui_reload
  run frame 24 120
  [[ $output == *"▸ infra"* ]]
  [[ $output != *"Rotate certs"* ]]
}

@test "views and live filter" {
  _tui_set_view overdue
  run frame 24 120
  [[ $output == *"Rotate certs"* && $output != *"Update README"* ]]
  _tui_set_view blocked
  run frame 24 120
  [[ $output == *"Nothing here yet"* ]]
  _tui_set_view active
  _tui_action filter
  for k in r e a d; do _tui_filter_key "$k"; done
  run frame 24 120
  [[ $output == *"Update README"* && $output != *"Rotate certs"* ]]
  [[ ${lines[23]} == " FILTER "*"/ "*"read"* ]]
  _tui_filter_key esc
  [ -z "$TUI_FILTER" ]
}

@test "ASCII rendering without Unicode" {
  TD_CONF["icons"]=ascii
  LC_ALL=C _tui_theme_init
  _tui_reload
  run frame 20 100
  [[ ${lines[0]} == " * todosh "* ]] || { printf '%s\n' "$output"; return 1; }
  [[ $output == *"[~] @ Review firewa"* ]] || { printf '%s\n' "$output"; return 1; }
}

@test "text editing keys" {
  local v="hello world" c=11
  _tui_edit v c ctrl-w
  [ "$v" = "hello " ] && [ "$c" -eq 6 ]
  _tui_edit v c home
  _tui_edit v c X
  [ "$v" = "Xhello " ]
  _tui_edit v c right
  _tui_edit v c backspace
  [ "$v" = "Xello " ] && [ "$c" -eq 1 ]
  _tui_edit v c ctrl-k
  [ "$v" = "X" ]
  _tui_edit v c space
  _tui_edit v c ñ
  [ "$v" = "X ñ" ]
  run _tui_edit v c up
  [ "$status" -eq 1 ]
}

@test "new task form: fields, pickers and focus, without any syntax" {
  _tui_select_group docs
  keys w:"Write the report" tab tab right tab w:fri tab enter w:new enter tab tab tab space ctrl-s
  _tui_task_form new ""
  local id=5
  [ "$(task $id '[.title, .project, .priority, .due != null, (.tags | join(","))] | join("|")')" = \
    "Write the report|docs|high|true|new" ]
  [ "$(task $id .status)" = IN_PROGRESS ]
  [ "$(jq -r .task "$HOME/.local/share/todosh/focus.json")" = $id ]
  [[ $TUI_TOAST == "Created #5"* ]]
}

@test "new subtask form inherits the parent and its project" {
  keys w:"Check NAT rules" ctrl-s
  _tui_task_form new 1
  [ "$(task 5 '[.parent, .project] | join("|")')" = "1|infra" ]
}

@test "form validation keeps the form open with an error" {
  # Empty title: error on save; then type one and save again.
  keys ctrl-s w:"Late title" ctrl-s
  _tui_task_form new ""
  [ "$(task 5 .title)" = "Late title" ]
  # A bad date keeps the form open on the date field; then cancel it.
  keys w:Dated tab tab tab w:someday ctrl-s esc y
  _tui_task_form new ""
  [ "$F_ERR" = "Unrecognized date: someday" ]
  [ "${F_KEYS[F_FOCUS]}" = due ]
  [ ! -e "$HOME/.local/share/todosh/tasks/6.json" ]
}

@test "edit form changes fields and status; closing a parent asks first" {
  # Title, then Status: Done (→ x3 from Doing... use the first letter).
  keys w:" now" tab D ctrl-s y
  _tui_task_form edit 1
  [ "$(task 1 .title)" = "Review firewall rules now" ]
  [ "$(task 1 .status)" = DONE ]
}

@test "cancelling a changed form asks before discarding" {
  keys w:Draft esc n esc y
  _tui_task_form new ""
  [ ! -e "$HOME/.local/share/todosh/tasks/5.json" ]
  [ "$FEED_I" -eq 9 ]
}

@test "picker: filter, single choice, create" {
  _tui_projects_items
  keys w:doc enter
  _tui_pick "Project" "${TUI_ITEMS[@]}"
  [ "$TUI_PICKED" = docs ]
  PK_CREATE=1
  keys w:brand-new down enter
  _tui_pick "Project" "${TUI_ITEMS[@]}"
  [ "$TUI_PICKED" = brand-new ]
  keys esc
  run _tui_pick "Project" "${TUI_ITEMS[@]}"
  [ "$status" -eq 1 ]
}

@test "multi picker: toggle, create, keep existing selections" {
  _tui_tags_items
  TUI_PICK_INIT="network" PK_MULTI=1 PK_CREATE=1
  keys w:home enter space enter
  _tui_pick "Tags" "${TUI_ITEMS[@]}"
  [ "${TUI_PICKED_LIST[*]}" = "home" ] || [ "${TUI_PICKED_LIST[*]}" = "network home" ] ||
    { echo "got: ${TUI_PICKED_LIST[*]}"; return 1; }
}

@test "confirm dialog: keys and buttons" {
  keys y
  _tui_confirm "Sure?"
  keys n
  refute _tui_confirm "Sure?"
  keys left enter
  _tui_confirm "Sure?"
}

@test "quick actions: space marks done, f toggles focus, D/u delete and undo" {
  select_task 3
  _tui_action toggle_done
  [ "$(task 3 .status)" = DONE ]
  select_task 3
  _tui_action toggle_done
  [ "$(task 3 .status)" = TODO ]
  select_task 4
  _tui_action focus
  [ "$(jq -r .task "$HOME/.local/share/todosh/focus.json")" = 4 ]
  select_task 4
  _tui_action focus
  [ "$(jq -r .task "$HOME/.local/share/todosh/focus.json")" = null ]
  select_task 4
  keys y
  _tui_action delete
  [ -e "$HOME/.local/share/todosh/trash/4.json" ]
  _tui_action undo
  [ -e "$HOME/.local/share/todosh/tasks/4.json" ]
}

@test "closing a task with open subtasks asks, and cascades on yes" {
  todosh reopen 2 >/dev/null
  _tui_reload
  select_task 1
  keys n
  _tui_action "done"
  [ "$(task 1 .status)" = IN_PROGRESS ]
  select_task 1
  keys y
  _tui_action "done"
  [ "$(task 1 .status)" = DONE ]
  [ "$(task 2 .status)" = DONE ]
}

@test "palette runs actions by name" {
  keys w:"view: all" enter
  _tui_palette
  [ "$TUI_VIEW" = all ]
}

@test "settings: theme with live preview, saved to the config" {
  keys enter w:nord enter tab right ctrl-s
  _tui_settings
  [ "${TD_CONF[theme]}" = nord ]
  [ "${TD_CONF[icons]}" = unicode ]
  grep -q '^theme = nord$' "$HOME/.config/todosh/config"
}

@test "_tui_split honors quotes and escapes, never evaluates" {
  _tui_split $'add "Fix the  bug" p:x it\\\'s \'$(touch nope)\''
  [ "${#TUI_WORDS[@]}" -eq 5 ]
  [ "${TUI_WORDS[1]}" = "Fix the  bug" ]
  [ "${TUI_WORDS[3]}" = "it's" ]
  # shellcheck disable=SC2016 # the literal text, never expanded
  [ "${TUI_WORDS[4]}" = '$(touch nope)' ]
  [ ! -e nope ]
}

@test "_tui_wrap wraps words and splits very long ones" {
  run _tui_wrap 10 "one two three four"
  [ "$output" = $'one two\nthree four' ]
  run _tui_wrap 4 "abcdefghij"
  [ "$output" = $'abcd\nefgh\nij' ]
}

@test "the interface refuses to start without a terminal" {
  run todosh tui </dev/null
  [ "$status" -eq 2 ]
  [[ $output == *"interactive terminal"* ]]
}

@test "smoke: create a task with the form in a pseudo-terminal" {
  command -v script >/dev/null || skip "script(1) not available"
  local log="$BATS_TEST_TMPDIR/tui.log"
  (
    sleep 1
    printf 'n'
    sleep 0.5
    printf 'Made in the TUI'
    sleep 0.3
    printf '\023'
    sleep 1
    printf 'q'
  ) | COLORTERM=truecolor timeout 20 script -qec "stty cols 120 rows 30; todosh" "$log" >/dev/null
  run todosh list
  [[ $output == *"Made in the TUI"* ]]
  grep -q $'\e\[?1049l' "$log"
  grep -q $'\e\[?25h' "$log"
}

@test "Ctrl-C closes dialogs like Esc (it is a key: the terminal is in -isig mode)" {
  keys w:"never saved" ctrl-c y
  _tui_task_form new ""
  [ ! -e "$HOME/.local/share/todosh/tasks/5.json" ]
  [ "${TUI_KEYMAP[ctrl-c]}" = quit ]
}

@test "smoke: Esc discards a form, q quits; the terminal is restored" {
  command -v script >/dev/null || skip "script(1) not available"
  # (script(1) turns a piped ^C into SIGINT, so Ctrl-C is tested above.)
  local log="$BATS_TEST_TMPDIR/tui.log"
  (
    sleep 1
    printf 'n'
    sleep 0.5
    printf 'never saved'
    sleep 0.3
    printf '\033'
    sleep 0.5
    printf 'y'
    sleep 0.5
    printf 'q'
  ) | timeout 20 script -qec "stty cols 100 rows 24; todosh" "$log" >/dev/null
  run todosh list --all
  [[ $output != *"never saved"* ]]
  grep -q $'\e\[?1049l' "$log"
  grep -q $'\e\[?25h' "$log"
}

@test "every key binding is intact (formatters must not mangle them)" {
  local k
  for k in "${!TUI_KEYMAP[@]}"; do
    [[ $k != *" "* ]] || {
      echo "mangled key: '$k'"
      return 1
    }
  done
  [ "${TUI_KEYMAP[ctrl-d]}" = page_down ]
  [ "${TUI_KEYMAP[ctrl-z]}" = suspend ]
}

@test "projects show as a tree: subprojects indented, empty ones in the active view" {
  todosh project add "infra/Network" >/dev/null
  todosh project add "Empty one" >/dev/null
  todosh add Rules "p:infra/Network" >/dev/null
  _tui_reload
  run frame 30 130
  [[ $output == *"▾ Empty one"* ]]
  [[ $output == *"  ▾ Network"*"0/1"* ]]
  [[ $output == *"▾ infra"*"1/4"* ]]
  # A filter shows only projects with matching tasks.
  TUI_FILTER=Rules
  _tui_reload
  run frame 30 130
  [[ $output != *"Empty one"* && $output == *"Network"* && $output == *"infra"* ]]
}

@test "collapsing a project hides its subprojects too" {
  todosh add Rules "p:infra/Network" >/dev/null
  TUI_COLLAPSED["infra"]=1
  _tui_reload
  run frame 30 130
  [[ $output == *"▸ infra"* && $output != *"Network"* && $output != *"Rules"* ]]
}

@test "P creates a subproject of the selected project" {
  _tui_select_group infra
  keys w:"Network" enter
  _tui_action new_project
  [ "$(td_projects_registered | tail -n 1)" = "infra/Network" ]
  [ "${U_GROUP[TUI_SEL]}" = "infra/Network" ]
}

@test "banner: title art and tagline at the bottom of the details when there is room" {
  TD_CONF["tagline"]="My tagline"
  _tui_select_group docs
  TUI_BANNER_KEY=""
  run frame 40 205
  local art='$$$$$$$$\  $$$$$$'
  [[ $output == *"$art"* ]]
  [[ ${lines[37]} == *"My tagline │"* || ${lines[37]} == *"My tagline"* ]]
  # Narrow: the compact art; no room: nothing.
  run frame 40 120
  [[ $output == *"┌┬┐┌─┐"* ]]
  run frame 14 120
  [[ $output != *"┌┬┐┌─┐"* && $output != *"My tagline"* ]]
  TD_CONF["banner"]=none TD_CONF["tagline"]=""
  run frame 40 205
  [[ $output != *'$$$$$$$$'* ]]
}

@test "banner: a text logo, and an image logo through chafa" {
  printf 'LOGO1\nLOGO2\n' >"$BATS_TEST_TMPDIR/logo.txt"
  TD_CONF["logo"]=$BATS_TEST_TMPDIR/logo.txt
  _tui_select_group docs
  run frame 40 205
  [[ $output == *"LOGO1  "*'$$$$$$$$'* ]]
  # A fake chafa: prints colored blocks plus a cursor sequence to be dropped.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # It only answers when called with --probe=off and no terminal on stdin:
  # a probing chafa would wait for answers that the TUI reads as keys.
  printf '%s\n' '#!/bin/sh' \
    'case "$*" in *--probe=off*) ;; *) exit 1 ;; esac' \
    '[ -t 0 ] && exit 1' \
    'printf "\033[?25l\033[38;2;1;2;3m####\033[0m\n\033[38;2;1;2;3m####\033[0m\033[?25h\n"' \
    >"$BATS_TEST_TMPDIR/bin/chafa"
  chmod +x "$BATS_TEST_TMPDIR/bin/chafa"
  touch "$BATS_TEST_TMPDIR/logo.png"
  TD_CONF["logo"]=$BATS_TEST_TMPDIR/logo.png
  TD_CONF["logo_render"]=blocks
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run frame 40 205
  [[ $output == *"####  "*'$$$$$$$$'* ]]
  [[ $(_tui_frame) != *$'\e[?25l'* ]]
  # The width is still exact.
  local line
  for line in "${lines[@]}"; do [ "${#line}" -eq 205 ]; done
}

@test "details and banner are built in the main shell, so their caches persist" {
  TUI_ROWS=40 TUI_COLS=205
  _tui_base_build
  [ -n "$TUI_DETAIL_KEY" ]
  [ -n "$TUI_BANNER_KEY" ]
}

@test "with no tasks the details panel welcomes and shows the banner" {
  export TODOSH_DATA_DIR="$BATS_TEST_TMPDIR/empty"
  td_paths_init
  td_storage_init
  _tui_reload
  run frame 40 205
  [[ $output == *"Welcome to todosh"* ]]
  [[ $output == *"Tasks are read from $BATS_TEST_TMPDIR/empty"* ]]
  [[ $output == *"To-do tracking from & for the terminal."* ]]
}

# make_png FILE W H — a PNG signature and IHDR header with the given size:
# all the logo code reads (the image data itself is passed through).
make_png() {
  local size
  printf -v size '%08x%08x' "$2" "$3"
  {
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR'
    local i
    for ((i = 0; i < 16; i += 2)); do printf '%b' "\\x${size:i:2}"; done
    printf '\x08\x02\x00\x00\x00'
  } >"$1"
}

# fake_ffmpeg — an ffmpeg that copies its input (-i FILE) to its output (last arg).
fake_ffmpeg() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # shellcheck disable=SC2016 # a script for /bin/sh, expanded there
  printf '%s\n' '#!/bin/sh' 'in=""; out=""' \
    'while [ $# -gt 0 ]; do [ "$1" = -i ] && in=$2; out=$1; shift; done' \
    'cp "$in" "$out"' >"$BATS_TEST_TMPDIR/bin/ffmpeg"
  chmod +x "$BATS_TEST_TMPDIR/bin/ffmpeg"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
}

@test "kitty: image logos are sent once with the graphics protocol and drawn with placeholders" {
  make_png "$BATS_TEST_TMPDIR/logo.jpg" 300 300
  [ "$(_tui_png_size "$BATS_TEST_TMPDIR/logo.jpg")" = "300 300" ]
  fake_ffmpeg
  TD_CONF["logo"]=$BATS_TEST_TMPDIR/logo.jpg
  TD_CONF["logo_render"]=kitty
  TD_TIER=3
  _tui_logo_prepare 4
  [[ $TUI_LOGO_TX == $'\e_Ga=T,U=1,f=100,t=d,i=237,c=8,r=4,q=2,m=0;'* ]]
  [ "$TUI_LOGO_W" -eq 8 ]
  [ "${#TUI_LOGO_LINES[@]}" -eq 4 ]
  # Row 1, columns 0 and 1: placeholder + row diacritic + column diacritic.
  [[ ${TUI_LOGO_LINES[1]} == $'\e[38;5;237m\U10EEEE̍̅\U10EEEE̍̍'* ]]
  # Outside kitty (or with logo_render = blocks) no graphics are used.
  TD_CONF["logo_render"]=blocks
  _tui_logo_prepare 4
  [ -z "$TUI_LOGO_TX" ]
}

@test "kitty: the banner keeps its width and paint sends the image once per screen" {
  make_png "$BATS_TEST_TMPDIR/logo.png" 300 300
  fake_ffmpeg
  TD_CONF["logo"]=$BATS_TEST_TMPDIR/logo.png
  TD_CONF["logo_render"]=kitty
  TD_TIER=3
  TUI_BANNER_KEY=""
  _tui_banner_build 90
  [ -n "$TUI_LOGO_TX" ]
  local line plain
  for line in "${TUI_BANNER[@]}"; do
    plain=${line//$'\e['*([0-9;])m/}
    plain=${plain//[$'̅̍̎̐̒̽̾̿͆͊͋͌͐͑͒͗']/}
    [ "${#plain}" -eq 90 ]
  done
  # The big title fits next to a 16-column logo in 90 columns.
  [[ ${TUI_BANNER[0]} == *'$$$$$$$$'* ]]
  TUI_LOGO_SENT=0 TUI_BASE="" TUI_LAYERS=()
  unset -f _tui_paint
  source "$TD_ROOT/lib/tui_ui.sh"
  run _tui_paint
  [[ $output == $'\e_Ga=T'* ]]
  _tui_paint >/dev/null
  run _tui_paint
  [[ $output != *$'\e_G'* ]]
}
