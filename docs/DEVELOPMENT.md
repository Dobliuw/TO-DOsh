# Development guide

## Layout

| Path | Responsibility |
|---|---|
| `bin/todosh` | Entry point: Bash version check, shell options, loads `lib/` |
| `lib/core.sh` | Exit codes, diagnostics, validators, small utilities |
| `lib/config.sh` | XDG paths and the `key = value` config file |
| `lib/storage.sh` | Data directory, lock, atomic JSON writes, IDs |
| `lib/term.sh` | Terminal capabilities (color, Unicode), width, pager, confirm, editor |
| `lib/tasks.sh` | Business rules: create, edit, status, comments, trash, queries |
| `lib/cli.sh` | Global flags, command registry and dispatch, help/version/config |
| `lib/commands.sh` | Task commands: argument parsing and text/JSON presentation |
| `lib/dates.sh` | Due-date parsing, durations, jq helpers for relative dates |
| `lib/focus.sh` | The focused task and its work sessions |
| `lib/theme.sh` | Themes, terminal color tiers, kitty import |
| `lib/tui_ui.sh` | TUI building blocks: line composition, layers, keys, text editing, dialogs, pickers, forms |
| `lib/tui.sh` | The interface: screen, details, actions, task form, palette, settings |
| `themes/` | Built-in themes (`key = #rrggbb`) |
| `tests/` | bats test suites; `test_helper.bash` isolates each test |

The CLI and the TUI must only call business functions (`tasks.sh`, later
`focus.sh`); neither touches files directly. Business mutations report their
result in `TD_RESULT`; queries print JSON.

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
  (`td_now_utc now`) and assign through a nameref. **Their locals must be
  prefixed `_td_`**: a local with the same name as the caller's variable would
  capture the nameref and the result would silently go nowhere.
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
your real data. `tests/tui.bats` renders frames without a terminal (`_tui_frame`
is pure) and drives the real interface through `script(1)` for a smoke test.

Dialogs and forms never read the terminal themselves (only `_tui_read_key`
does), so `tests/tui.bats` drives them with synthetic keys. The library does
not run under `errexit`, but tests do: call handlers that return non-zero on
purpose in a conditional (`fn || rc=$?`). Quote associative-array keys with
dashes or symbols (`["ctrl-d"]`): shfmt rewrites `[ctrl-d]` as arithmetic.

TUI performance rule: nothing that runs per key press may fork. Use lookup
tables, `printf -v` and the `-v` form of helpers (`td_fmt_duration -v`); jq runs
only on reload and when the selected task changes. In bats, `! cmd` does not fail a test, so use `refute cmd`.
