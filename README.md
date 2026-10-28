# TODOSH

A fast, good-looking task manager for your terminal, written in pure Bash.

> **Status: early development (phase 4 of 6).** Full-screen interface and
> CLI both work: tasks, subtasks, comments, due dates, focus sessions, trash and
> themes. Next: search, stats, backups and shell completion.
> See [docs/PRD.md](docs/PRD.md) for the full plan.

## The interface

Run `todosh` (or `tdsh`) in a terminal:

```
╭─ TODOSH ──────────────────────────────── ◉ #1 Review firewall rules · 25m ─╮
│ View: active   Filter: —                                     ⚠ 1 overdue   │
├────────────────────────────────────────┬───────────────────────────────────┤
│  ▾ infra                          1/3  │ #1 Review firewall rules          │
│❯ ◐ H #1 ◉ Review firewall rules 1/2 fri│ IN_PROGRESS · high · infra        │
│    ✓ M #2 Export current rules         │ Due 2026-10-30 (fri)              │
│    ○ M #3 Audit rules          1d late │ ◉ in focus for 25m                │
├────────────────────────────────────────┴───────────────────────────────────┤
│ n new  e edit  c comment  f focus  s start  d done  / filter  ? help       │
╰────────────────────────────────────────────────────────────────────────────╯
```

`j`/`k` or arrows move, `n` adds (shorthand works: `p:infra pri:high due:fri`),
`f` focuses, `s`/`b`/`d`/`x`/`r` change the status, `c` comments, `e` opens your
editor, `:` runs any todosh command, `?` shows every key.

Themes: `todosh theme list`, `todosh theme set nord`, or use your terminal's
colors with `todosh theme import kitty`. The interface never paints the
background, so transparency is kept. Over SSH or in a basic terminal it falls
back to 256 or 16 colors and ASCII borders.

## Quick tour (CLI)

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
