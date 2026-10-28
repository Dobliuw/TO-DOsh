#!/usr/bin/env bats
# Validators and shared utilities (lib/core.sh).

load test_helper

setup() {
  td_test_setup
  td_load_lib
}

@test "valid ids: positive integers without leading zeros" {
  for id in 1 9 42 100 999999999; do
    td_valid_id "$id"
  done
}

@test "invalid ids are rejected" {
  for id in "" 0 01 -1 1.5 abc "1 2" "../1" "1/2" 1234567890 $'4\n2' $'7\n'; do
    run td_valid_id "$id"
    [ "$status" -ne 0 ] || {
      echo "accepted: '$id'"
      return 1
    }
  done
}

@test "status and priority validators" {
  td_valid_status TODO
  td_valid_status CANCELLED
  refute td_valid_status todo
  refute td_valid_status DOING
  td_valid_priority urgent
  td_valid_priority low
  refute td_valid_priority HIGH
  refute td_valid_priority ""
}

@test "names: short, no spaces or slashes" {
  td_valid_name inbox
  td_valid_name infra-2026.q4_x
  refute td_valid_name ""
  refute td_valid_name "-flag"
  refute td_valid_name "two words"
  refute td_valid_name "a/b"
  refute td_valid_name "$(printf 'a%.0s' {1..33})"
}

@test "titles: unicode and symbols accepted" {
  # shellcheck disable=SC2016 # literal on purpose: must never expand
  td_valid_title 'Revisar reglas del firewall — puerto 8080 ¿ok? $(rm -rf /) "x" & ;'
  td_valid_title "日本語 ✓"
}

@test "titles: empty, blank, multiline, control chars and too long rejected" {
  refute td_valid_title ""
  refute td_valid_title "   "
  refute td_valid_title "line one
line two"
  refute td_valid_title "$(printf 'bell\a')"
  refute td_valid_title "$(printf 'x%.0s' {1..201})"
  td_valid_title "$(printf 'x%.0s' {1..200})"
}

@test "free text allows newlines and tabs but not other control chars" {
  td_valid_text "first line
	second line, indented"
  refute td_valid_text "$(printf 'esc\033[31m')"
}

@test "td_now_utc produces an ISO 8601 UTC timestamp" {
  local now
  td_now_utc now
  [[ $now =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # Within a few seconds of the system clock.
  local diff=$(($(date -u +%s) - $(date -u -d "$now" +%s)))
  ((diff >= 0 && diff < 5))
}

@test "td_require_cmds reports missing commands" {
  run td_require_cmds bash definitely-not-a-command-xyz
  [ "$status" -eq 1 ]
  [[ $output == *definitely-not-a-command-xyz* ]]
}

@test "td_err records the last error and can be silenced" {
  # shellcheck disable=SC2034 # read by td_err from the sourced library
  TD_QUIET_ERRORS=1
  run td_err "boom"
  [ -z "$output" ]
  td_err "kept"
  [ "$TD_LAST_ERROR" = kept ]
}

@test "project validator lives next to the name validator" {
  td_valid_project "a/b c"
  refute td_valid_name "a/b c"
}
