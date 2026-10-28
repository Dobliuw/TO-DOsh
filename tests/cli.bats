#!/usr/bin/env bats
# Command-line contract: dispatch, help, exit codes and output streams.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  td_test_setup
}

@test "version, in text and JSON" {
  run todosh version
  [ "$status" -eq 0 ]
  [[ $output =~ ^todosh\ [0-9]+\.[0-9]+\.[0-9]+ ]]
  run todosh --version
  [[ $output == todosh* ]]
  run --separate-stderr todosh version --json
  [ "$status" -eq 0 ]
  jq -e '.version | type == "string"' <<<"$output"
}

@test "help lists the registered commands" {
  run todosh --help
  [ "$status" -eq 0 ]
  [[ $output == *"Commands:"* ]]
  [[ $output == *"config"* ]]
  [[ $output == *"Exit codes:"* ]]
}

@test "per-command help via --help and help <cmd>" {
  run todosh config --help
  [ "$status" -eq 0 ]
  [[ $output == "Usage: todosh config"* ]]
  run todosh help config
  [[ $output == "Usage: todosh config"* ]]
}

@test "unknown command or option is a usage error on stderr" {
  run --separate-stderr todosh frobnicate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ $stderr == *"unknown command: frobnicate"* ]]
  run --separate-stderr todosh --frob
  [ "$status" -eq 2 ]
  [[ $stderr == *"unknown option: --frob"* ]]
  run todosh help frobnicate
  [ "$status" -eq 2 ]
}

@test "config show reports paths and defaults" {
  run todosh config
  [ "$status" -eq 0 ]
  [[ $output == *"$HOME/.config/todosh/config (not found"* ]]
  [[ $output == *"theme                = tokyonight"* ]]
}

@test "config --json is valid JSON with typed values, and nothing else on stdout" {
  td_write_config "bogus = 1"
  run --separate-stderr todosh config show --json
  [ "$status" -eq 0 ]
  jq -e '.settings.archive_after_days == 7 and .paths.config_file_exists == true' <<<"$output"
  [[ $stderr == *"unknown key 'bogus'"* ]]
}

@test "global flags work before or after the command" {
  run --separate-stderr todosh --json config
  jq -e .settings <<<"$output"
  run --separate-stderr todosh config --json
  jq -e .settings <<<"$output"
}

@test "arguments after -- are not treated as global flags" {
  run --separate-stderr todosh config -- --json
  [ "$status" -eq 2 ]
}

@test "config subcommand errors" {
  run --separate-stderr todosh config explode
  [ "$status" -eq 2 ]
  [[ $stderr == *"unknown subcommand: explode"* ]]
  run todosh config path extra
  [ "$status" -eq 2 ]
}

@test "config path honors TODOSH_CONFIG_DIR" {
  TODOSH_CONFIG_DIR="$BATS_TEST_TMPDIR/my conf" run todosh config path
  [ "$output" = "$BATS_TEST_TMPDIR/my conf/config" ]
}

@test "read-only commands do not create the data directory" {
  run todosh config
  [ ! -e "$HOME/.local/share/todosh" ]
}

@test "works through a symlink, as after installation" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -s "$TD_ROOT/bin/todosh" "$BATS_TEST_TMPDIR/bin/tdsh"
  run "$BATS_TEST_TMPDIR/bin/tdsh" version
  [ "$status" -eq 0 ]
}
