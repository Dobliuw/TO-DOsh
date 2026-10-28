# Development guide

## Layout

| Path | Responsibility |
|---|---|
| `bin/todosh` | Entry point: Bash version check, shell options, loads `lib/` |
| `lib/core.sh` | Exit codes, diagnostics, validators, small utilities |
| `lib/config.sh` | XDG paths and the `key = value` config file |
| `lib/storage.sh` | Data directory, lock, atomic JSON writes, IDs |
| `lib/cli.sh` | Argument parsing, command registry and dispatch, CLI output |
| `tests/` | bats test suites; `test_helper.bash` isolates each test |

The CLI and the TUI must only call business functions (`tasks.sh`, `focus.sh`,
from phase 2 on); neither touches files directly.

## Conventions

- Bash ≥ 4.4. `nounset`, `pipefail` and `extglob` are enabled by `bin/todosh`.
- **No `errexit`.** Its behavior inside functions, conditionals and command
  substitutions is too surprising for a library. Functions instead `return` one
  of `TD_E_OK`, `TD_E_ERR`, `TD_E_USAGE`, `TD_E_NOTFOUND`, `TD_E_CONFLICT` and
  callers propagate failures explicitly (`cmd || return`).
- Library functions never `exit`; `td_main`'s status becomes the exit code.
- Errors go through `td_err` (stderr + `TD_LAST_ERROR`), never to stdout.
- With `--json`, stdout carries exactly one JSON document.
- Never `eval` or `source` data. Build JSON with `jq --arg`, never by string
  interpolation. Quote every expansion; use arrays for argument lists; prefer
  `printf` over `echo`.
- Validate IDs and names before building paths.
- Names: public functions `td_*`, private helpers `_td_*`, globals `TD_*`.
- Functions that return a value without printing take an output variable name
  (`td_now_utc now`) and assign through a nameref.
- Format: `shfmt -i 2 -ci -bn`.

## Adding a command

```bash
td_register_cmd frob "One-line summary shown in todosh help"
td_help_frob() { printf '%s\n' "Usage: todosh frob <id>" ...; }
td_cmd_frob() {
  if td_wants_help "$@"; then td_help_frob; return 0; fi
  ...
}
```

## Tests and checks

```sh
make test     # bats tests/
make lint     # shellcheck
make check    # lint + format check + tests
```

Tooling on Arch: `sudo pacman -S bash-bats shellcheck shfmt`.

Each test runs with a private `HOME` whose path contains a space; nothing touches
your real data. In bats, `! cmd` does not fail a test, so use `refute cmd`.
