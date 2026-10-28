#!/usr/bin/env bats
# Paths and configuration parsing (lib/config.sh).

load test_helper

setup() {
  td_test_setup
  td_load_lib
}

@test "XDG defaults under HOME" {
  td_paths_init
  [ "$TD_CONFIG_DIR" = "$HOME/.config/todosh" ]
  [ "$TD_DATA_DIR" = "$HOME/.local/share/todosh" ]
  [ "$TD_CONFIG_FILE" = "$HOME/.config/todosh/config" ]
}

@test "XDG variables are honored; empty ones fall back to defaults" {
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg" XDG_DATA_HOME="" td_paths_init
  [ "$TD_CONFIG_DIR" = "$BATS_TEST_TMPDIR/cfg/todosh" ]
  [ "$TD_DATA_DIR" = "$HOME/.local/share/todosh" ]
}

@test "TODOSH_* overrides win and trailing slashes are trimmed" {
  TODOSH_CONFIG_DIR="$BATS_TEST_TMPDIR/c//" TODOSH_DATA_DIR="$BATS_TEST_TMPDIR/d/" td_paths_init
  [ "$TD_CONFIG_DIR" = "$BATS_TEST_TMPDIR/c" ]
  [ "$TD_DATA_DIR" = "$BATS_TEST_TMPDIR/d" ]
}

@test "relative directories are rejected" {
  TODOSH_DATA_DIR="relative/dir" run td_paths_init
  [ "$status" -eq 1 ]
  [[ $output == *"absolute path"* ]]
}

@test "missing HOME without overrides is an error" {
  HOME="" run td_paths_init
  [ "$status" -eq 1 ]
  [[ $output == *"HOME is not set"* ]]
}

@test "defaults apply when there is no config file" {
  td_paths_init
  td_config_load
  [ "${TD_CONF[theme]}" = tokyonight ]
  [ "${TD_CONF[archive_after_days]}" = 7 ]
  [ "${TD_CONF[default_project]}" = inbox ]
}

@test "parses spacing, quotes, comments and CRLF line endings" {
  td_write_config \
    "# a comment" \
    "" \
    "   theme=nord   " \
    "default_project = \"work\"" \
    "archive_after_days = '30'" \
    $'icons = ascii\r' \
    "editor = nvim -p"
  # Last line without a trailing newline must still be read.
  printf 'color = never' >>"$HOME/.config/todosh/config"
  td_paths_init
  td_config_load
  [ "${TD_CONF[theme]}" = nord ]
  [ "${TD_CONF[default_project]}" = work ]
  [ "${TD_CONF[archive_after_days]}" = 30 ]
  [ "${TD_CONF[icons]}" = ascii ]
  [ "${TD_CONF[editor]}" = "nvim -p" ]
  [ "${TD_CONF[color]}" = never ]
}

@test "invalid values warn and keep the default" {
  td_write_config "archive_after_days = soon" "color = rainbow"
  td_paths_init
  run td_config_load
  [ "$status" -eq 0 ]
  [[ $output == *"line 1: invalid value for 'archive_after_days'"* ]]
  [[ $output == *"line 2: invalid value for 'color'"* ]]
  td_config_load 2>/dev/null
  [ "${TD_CONF[archive_after_days]}" = 7 ]
  [ "${TD_CONF[color]}" = auto ]
}

@test "unknown keys and malformed lines only warn" {
  td_write_config "colour = never" "this is not valid" "theme = nord"
  td_paths_init
  run td_config_load
  [ "$status" -eq 0 ]
  [[ $output == *"unknown key 'colour'"* ]]
  [[ $output == *"line 2: expected 'key = value'"* ]]
}

@test "config values are never executed" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  td_write_config \
    "theme = \$(touch '$marker')" \
    "editor = \$(touch '$marker'); \`touch '$marker'\`"
  td_paths_init
  td_config_load 2>/dev/null
  [ ! -e "$marker" ]
  # The editor value is kept verbatim as data.
  # shellcheck disable=SC2016 # matching the literal text
  [[ ${TD_CONF[editor]} == *'$(touch'* ]]
  [ "${TD_CONF[theme]}" = tokyonight ]
}

@test "unreadable config path only warns" {
  mkdir -p "$HOME/.config/todosh/config"
  td_paths_init
  run td_config_load
  [ "$status" -eq 0 ]
  [[ $output == *"cannot read config file"* ]]
}
