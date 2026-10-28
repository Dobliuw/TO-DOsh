# TODOSH — Product Requirements Document (MVP)

Status: **approved** (2026-10-28). This document is the reference for scope.
Changes to consequential decisions must be recorded in the changelog at the end.

## 1. Summary

**TODOSH** (`todosh`, short alias `tdsh`) is a personal task manager for Linux,
written in pure Bash. The **TUI is the primary experience**; the CLI offers full
parity. Tasks are organized in projects, tags and one level of subtasks. A single
task can hold the **focus**, with time tracking. Data lives in readable local
JSON files. Default theme is Tokyo Night; the interface adapts to the terminal
(truecolor + Nerd Font in modern terminals, degraded but complete over SSH/TTY).

Target user: one person, one machine, no accounts, no network. Expected scale:
up to ~400 tasks.

## 2. Domain model

| Concept | Decision |
|---|---|
| Statuses | `TODO`, `IN_PROGRESS`, `BLOCKED`, `DONE`, `CANCELLED`. Open tasks move freely; closed tasks only go back to `TODO` (`reopen`) |
| Priorities | `urgent`, `high`, `med`, `low` |
| Projects | Every task belongs to one project; default `inbox` |
| Tags | Zero or more per task |
| Subtasks | Full tasks (own status, priority, history) with a `parent`; **one level only**. Parent shows progress (`3/5`) |
| Due date | Optional. Relative input accepted (`due:fri`, `due:+3d`, `due:tomorrow`) |
| History | Per task, chronological. Distinguishes **comments** (user-written) from **events** (automatic: status, priority, focus…) |
| Focus | Exactly zero or one focused task. Focus records **time sessions** |
| Archive | `DONE`/`CANCELLED` auto-archived after N days (default 7); viewable dimmed |
| Deletion | Soft delete to trash; `purge` deletes permanently after confirmation |

### Focus rules

- `focus <id>`: sets focus; if the task is `TODO` it becomes `IN_PROGRESS`. A previously
  focused task loses focus (its session is closed) but keeps its status.
- `focus` (no args): shows the *memory card* (status, subtasks, last comment, time).
- Completing, cancelling or deleting the focused task releases focus and closes the session.
- Focus may target a subtask; the card then also shows the parent.
- `prompt`: short line (e.g. `◉ #42 firewall`) for the zsh prompt or kitty bar.

## 3. Interfaces

### TUI (primary)

Master–detail layout: grouped task list on the left, detail/history panel on the
right, focus bar on top, key hints at the bottom. Extra screens: full detail,
add/edit form, command palette (`:`), help (`?`), stats, archived toggle.

Keys: arrows **and** `hjkl`, mnemonic letters (`n` new, `e` edit, `c` comment,
`f` focus, `d` done…), `/` search, `:` palette, `?` help.

Status is never communicated by color alone (symbol + color). Rendering tiers:

1. truecolor + Unicode + Nerd Font glyphs
2. 256 colors + Unicode
3. 16 colors / no color + ASCII borders and markers

Themes: predefined (`tokyonight` default, `catppuccin`, `gruvbox`, `nord`) and
`theme import kitty` from the user's kitty configuration.

### CLI (full parity)

| Group | Commands |
|---|---|
| General | `todosh` (TUI on interactive terminal; `list` otherwise), `help`, `<cmd> --help`, `version` |
| Create/read | `add "title" [p:proj +tag pri:prio due:x ^parent]`, `list`, `show`, `search` |
| Edit | `edit <id>` (opens `$EDITOR`), `edit <id> --title … --priority … --due none` |
| Status | `start`, `block`, `done`, `cancel`, `reopen` |
| History | `comment <id> "text"`, `log <id> [--comments\|--events]` |
| Focus | `focus [<id>]`, `unfocus`, `prompt` |
| Organization | `projects`, `tags`, `archive`, `unarchive` |
| Deletion | `delete`, `undelete`, `trash`, `purge` |
| Data | `backup`, `backup list`, `backup restore <name>` |
| Look/config | `theme list\|set\|import kitty`, `config show\|edit`, `completion zsh\|bash` |
| Global flags | `--json` (only valid JSON on stdout), `--no-color`, `NO_COLOR` env |

Inline capture shorthand complements long options (`--project`, `--tag`,
`--priority`, `--due`, `--parent`): `p:NAME`, `+TAG`, `pri:LEVEL`, `^ID` (or
`parent:ID`), `due:WHEN`. Only whole arguments are tokens; quoted phrases stay
literal. `#tag` is not used (the shell treats it as a comment) and `!prio` is
only a quoted alternative (zsh and interactive Bash expand `!` from history).

Subtasks inherit their parent's project unless one is given.

Exit codes: `0` ok · `1` operational error · `2` usage error · `3` not found ·
`4` conflict / lock busy.

## 4. Technical decisions

| Topic | Decision |
|---|---|
| Language | Pure Bash ≥ 4.4, single shared business layer for CLI and TUI |
| Required deps | `jq`, `flock`, `tput`, GNU `date` |
| Optional deps | `fzf` (search), `notify-send` (future) |
| Platform | Linux only |
| Storage | One JSON file per task with embedded history; `meta.json`, `focus.json`, `trash/`, `backups/` |
| Writes | Advisory lock (`flock`) on the data dir; temp file + atomic `rename` |
| Description | Stored inside the task JSON; edited in `$EDITOR` as a temporary `.md` |
| Paths | XDG: config `~/.config/todosh/`, data `~/.local/share/todosh/`; override `TODOSH_CONFIG_DIR`, `TODOSH_DATA_DIR` |
| Config | `key = value` file parsed line by line, never `source`d nor `eval`ed |
| Install | `make install` to `~/.local` (no root); runnable from the clone |
| Uninstall | Removes program files only, never user data |
| Tests | bats-core, shellcheck, shfmt; isolated temp dirs |
| Notifications | In-app warnings only (overdue / due today) |
| License | MIT |

## 5. Scope

**MVP:** everything above, plus `$EDITOR` descriptions, fixed views (Focus/Today,
All, By project, Blocked, Overdue, Recently done), full-text search, basic stats,
backup/restore, `--json`, zsh/bash completion.

**Later:** Markdown/CSV export, recurring tasks, task dependencies, `scheduled`
start date, desktop notifications via systemd user timer, macOS support, UI
translations.

**Excluded:** sync, multi-user, database servers, background daemons, network access.

## 6. Phases

1. Foundations — skeleton, config, storage, validation, CLI parser, test/lint tooling.
2. Core — add/list/show/edit, statuses, subtasks, comments/events, trash, `--json`. *User checkpoint.*
3. Focus & dates — focus, sessions, memory card, `prompt`, relative dates, overdue warnings.
4. TUI — tiered renderer, master–detail, keys, forms, palette, help, resize, themes. *User checkpoint.*
5. Productivity — search, views, stats, auto-archive, backup/restore, completions.
6. Hardening — docs, install test, final review, GitHub publishing instructions (run by the user).

## 7. Changelog

- 2026-10-28 — Initial approved version.
- 2026-10-28 — Priority shorthand is `pri:LEVEL` instead of `!LEVEL` (history
  expansion in zsh/Bash); `parent:ID` added as an alternative to `^ID`; subtasks
  inherit the parent's project; closing a parent with open subtasks requires
  `--force` (which closes them too); reopening a subtask reopens its parent.
- 2026-10-28 — Phase 3: focusing a BLOCKED task keeps it BLOCKED (only TODO
  becomes IN_PROGRESS); `focus <id>` also shows the memory card; focus sessions
  are history entries `{"type": "focus", "at", "since", "seconds"}`; a weekday
  due date means the next such day, today included; due dates sort within the
  same status and priority; overdue/due-today warnings appear under `list` on a
  terminal.
- 2026-10-28 — Phase 4 (TUI): the interface never paints the background (keeps
  terminal transparency); typed input (`n`, `N`, `m`, `:`) goes through the CLI
  parser itself; `:` runs any todosh command on the normal screen; Enter and `?`
  use `less`; `D` deletes with confirmation and `u` undoes the last delete;
  closing a task with open subtasks asks before closing them too; views cycle
  active/all/overdue/blocked; projects are collapsible groups. Built-in themes:
  tokyonight, catppuccin (mocha), gruvbox (dark), nord; `theme import kitty`.
- 2026-10-28 — TUI redesign (user feedback: "a copy of the CLI, without soul"):
  the TUI is an application of its own. Forms and pickers replace command
  syntax (new/edit task, priority, project, tags, parent, dates with presets and
  live preview); searchable action palette; settings screen with live theme
  preview; confirm dialogs; toasts; dimmed background behind dialogs; solid
  theme background (new theme keys: bg, surface, overlay) instead of terminal
  transparency; view tabs, badges, progress bars, subtask trees, activity
  timeline; Nerd Font icon set (`icons = nerd`). Ctrl-C/Ctrl-Z are keys
  (terminal in -isig mode). The CLI is unchanged.
