# TODOSH

A fast, good-looking task manager for your terminal, written in pure Bash.

> **Status: early development (phase 4 of 6).** Full-screen interface and
> CLI both work: tasks, subtasks, comments, due dates, focus sessions, trash and
> themes. Next: search, stats, backups and shell completion.
> See [docs/PRD.md](docs/PRD.md) for the full plan.

## The interface

Run `todosh` (or `tdsh`) in a terminal. It is an application of its own, not a
view of the CLI: no syntax to remember.

- **Forms** to create and edit tasks (`n`, `N` for a subtask, `e`): type the
  title, pick the project from a list (or create one), choose the priority with
  ←/→, write a date in plain words (`fri`, `+3d`) with a live preview or pick a
  preset, choose tags, the parent task, notes (opens your editor), and whether to
  focus it right away. `Ctrl-S` saves, `Esc` cancels.
- **Quick keys**: `Space` done/reopen, `s`/`b`/`x` start, block, cancel, `f` focus,
  `c` comment, `p` priority, `m` move, `t` tags, `D` delete and `u` undo.
- **Search everything**: `/` filters as you type, `:` opens a searchable list of
  every action, `,` opens the settings (themes preview live), `?` the shortcuts.
- **Looks**: solid background like nvim, view tabs, colored badges, progress bars,
  subtask trees, an activity timeline and toast notifications. Themes: tokyonight,
  catppuccin, gruvbox, nord, or your terminal's (`todosh theme import kitty`).
  With `icons = nerd` (settings) it uses Nerd Font glyphs. Over SSH or in a basic
  terminal it falls back to 256/16 colors and ASCII.

### Projects and subprojects

Projects nest like paths, up to 4 levels:

```sh
tdsh project add 'HardwareHacking/RF & SDR'
tdsh add Learn the fundamentals 'p:HardwareHacking/RF & SDR'
tdsh add ChipWhisperer --project 'HardwareHacking/Fault Injection'
tdsh projects              # the tree, with counts
tdsh list p:HardwareHacking   # includes every subproject
```

In the interface they are a collapsible tree; `P` creates a subproject of the
selected project.

### Banner and logo

When there is room, the details panel shows a banner at the bottom: title art,
your logo and a tagline. Settings (`,` in the interface, or `todosh config set`):
`banner` (auto, big, small, none, or a text file with your art), `logo` (a text
file, or an image such as `~/logo.png` rendered with the optional
[chafa](https://hpjansson.org/chafa/)), and `tagline`.

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

The editor (notes, `edit`, comments) is the `editor` setting, else `$VISUAL`,
`$EDITOR`, or the first installed of nvim, vim, nano, vi:
`todosh config set editor nvim`.

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
