# TODOSH

A fast, good-looking task manager for your terminal, written in pure Bash.

> **Status: early development (phase 1 of 6).** The storage foundation and the
> CLI skeleton exist; task commands and the TUI are not implemented yet.
> See [docs/PRD.md](docs/PRD.md) for the full plan.

## Planned highlights

- Full-screen TUI (master–detail, keyboard driven) **and** a CLI with full parity.
- Projects, tags, one level of subtasks, priorities, optional due dates.
- One **focused** task with time tracking and a "memory card" (`todosh focus`).
- Comments and automatic events kept in each task's history.
- Plain JSON files under `~/.local/share/todosh`, safe concurrent writes.
- Themes (Tokyo Night by default) and graceful fallback over SSH or in plain terminals.

## Requirements

Linux, Bash ≥ 4.4, `jq`, `flock` (util-linux), GNU coreutils, `tput` (ncurses).

## Install

```sh
git clone <repository-url> todosh && cd todosh
make install            # installs todosh and the tdsh alias into ~/.local/bin
```

Or run it straight from the clone: `./bin/todosh`.
`make uninstall` removes the program and never deletes your tasks.

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [docs/STORAGE.md](docs/STORAGE.md).

## License

MIT — see [LICENSE](LICENSE).
