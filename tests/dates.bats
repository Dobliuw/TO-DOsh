#!/usr/bin/env bats
# Due dates and time formatting (lib/dates.sh).

load test_helper

setup() {
  td_test_setup
  td_load_lib
}

# parse INPUT — print the normalized due date.
parse() {
  local out
  td_due_parse out "$1" || return
  printf '%s\n' "$out"
}

@test "relative and named dates" {
  [ "$(parse today)" = "$(date +%F)" ]
  [ "$(parse tod)" = "$(date +%F)" ]
  [ "$(parse tomorrow)" = "$(date -d tomorrow +%F)" ]
  [ "$(parse TOM)" = "$(date -d tomorrow +%F)" ]
  [ "$(parse +3d)" = "$(date -d '+3 days' +%F)" ]
  [ "$(parse +2w)" = "$(date -d '+2 weeks' +%F)" ]
  [ "$(parse +1m)" = "$(date -d '+1 month' +%F)" ]
  [ "$(parse fri)" = "$(LC_ALL=C date -d fri +%F)" ]
  [ "$(parse 'next monday')" = "$(LC_ALL=C date -d 'next monday' +%F)" ]
  [ "$(parse 2026-11-03)" = 2026-11-03 ]
  [ "$(parse '  2026-11-03 ')" = 2026-11-03 ]
}

@test "weekday names work whatever the user's locale" {
  local loc
  loc=$(locale -a 2>/dev/null | grep -Eiv '^(c|posix|en_)' | grep -i utf | head -n 1)
  [ -n "$loc" ] || skip "no non-English locale installed"
  [ "$(LC_ALL=$loc parse friday)" = "$(LC_ALL=C date -d friday +%F)" ]
}

@test "none and empty clear the date" {
  [ -z "$(parse none)" ]
  [ -z "$(parse '')" ]
}

@test "garbage, bare numbers and option-like input are rejected" {
  for input in someday 42 -d +3x 2026-13-01 "$(printf 'x\033')"; do
    run td_due_parse out "$input"
    [ "$status" -eq 2 ] || {
      echo "accepted: '$input'"
      return 1
    }
  done
}

@test "td_due_valid checks real calendar dates" {
  td_due_valid 2028-02-29
  refute td_due_valid 2027-02-29
  refute td_due_valid 2026-1-1
  refute td_due_valid tomorrow
}

@test "durations and ages" {
  [ "$(td_fmt_duration 42)" = 42s ]
  [ "$(td_fmt_duration 125)" = 2m ]
  [ "$(td_fmt_duration 3900)" = 1h05m ]
  [ "$(td_fmt_duration 97200)" = 1d3h ]
  [ "$(td_fmt_ago 10)" = "just now" ]
  [ "$(td_fmt_ago 300)" = "5m ago" ]
  [ "$(td_fmt_ago 7300)" = "2h ago" ]
  [ "$(td_fmt_ago 200000)" = "2d ago" ]
}

@test "due_info labels relative to today" {
  local today=2026-10-28 # a Wednesday
  info() {
    LC_TIME=C jq -rn --arg today "$today" --arg due "$1" --arg st "${2:-TODO}" "$TD_JQ_DUE"'
      {due: $due, status: $st} | due_info | "\(.text)|\(.state)"'
  }
  [ "$(info 2026-10-26)" = "2d late|overdue" ]
  [ "$(info 2026-10-28)" = "today|today" ]
  [ "$(info 2026-10-29)" = "tomorrow|soon" ]
  [ "$(info 2026-10-30)" = "fri|soon" ]
  [ "$(info 2026-11-12)" = "Nov 12|later" ]
  [ "$(info 2027-01-05)" = "2027-01-05|later" ]
  [ "$(info 2026-10-26 DONE)" = "2026-10-26|later" ]
}
