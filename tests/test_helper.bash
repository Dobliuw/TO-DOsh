# shellcheck shell=bash
# Shared setup: every test gets a private HOME (with a space in its path) so
# the user's real configuration and tasks are never touched.

TD_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)

td_test_setup() {
  export HOME="$BATS_TEST_TMPDIR/home dir"
  mkdir -p -- "$HOME"
  unset XDG_CONFIG_HOME XDG_DATA_HOME TODOSH_CONFIG_DIR TODOSH_DATA_DIR NO_COLOR
  export PATH="$TD_ROOT/bin:$PATH"
}

# td_load_lib — source the library into the test shell, as bin/todosh does.
td_load_lib() {
  shopt -s extglob
  local module
  for module in "$TD_ROOT"/lib/*.sh; do
    # shellcheck source=/dev/null
    source "$module"
  done
}

# td_write_config LINE... — write the config file for the test HOME.
td_write_config() {
  mkdir -p -- "$HOME/.config/todosh"
  printf '%s\n' "$@" >"$HOME/.config/todosh/config"
}

# refute CMD... — fail the test if CMD succeeds. (`! cmd` does not fail a
# bats test: errexit ignores negated commands.)
refute() {
  if "$@"; then
    printf 'expected failure, but succeeded: %s\n' "$*" >&2
    return 1
  fi
}
