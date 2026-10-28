# TODOSH

A fast, good-looking task manager for your terminal, written in pure Bash.

> **Status: early development (phase 3 of 6).** The CLI manages tasks,
> subtasks, comments, due dates, focus sessions and the trash. The TUI is next.
> See [docs/PRD.md](docs/PRD.md) for the full plan.

## Quick tour

```sh
tdsh add Review firewall rules p:infra pri:high +network due:fri   # Created #1
tdsh add Export current rules ^1                                   # subtask of #1
tdsh focus 1                    # start working on it: shows the memory card
tdsh comment 1 Found an unexpected inbound rule on 8080
tdsh focus                      # later: what was I doing? status, subtasks, notes
tdsh list                       # open + recently closed, subtasks indented
tdsh show 1                     # details, time worked, subtasks and history
tdsh done 2 && tdsh done 1      # closing the focused task ends the session
tdsh list --overdue --json | jq -r '.[].title'
```

Show the focused task in your prompt (zsh):

```sh
setopt PROMPT_SUBST
RPROMPT='$(tdsh prompt --time)'   # ◉ #1 Review firewall rules · 25m
```

Run `todosh help` for every command and `todosh <command> --help` for details.

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
