# Storage format

TODOSH keeps all data as plain JSON files in one directory:

```
${TODOSH_DATA_DIR:-${XDG_DATA_HOME:-~/.local/share}/todosh}/
├── meta.json        {"schema": 1, "next_id": 43, "created": "..."}
├── projects.json    {"projects": ["HardwareHacking", "HardwareHacking/RF & SDR"]}
├── focus.json       {"task": 42, "since": "..."}
├── tasks/42.json    one file per task
├── trash/17.json    soft-deleted tasks (same format)
├── backups/
└── .lock            empty file used for advisory locking
```

Directories are created `0700` and files `0600`.

## Schema version

`meta.json.schema` is the format version (currently **1**). A todosh that finds
a newer schema refuses to touch the data instead of guessing. When the format
changes, a migration will run explicitly and leave a backup first.

## Task IDs

IDs are positive integers allocated from `meta.json.next_id` under the lock. An
ID is never reused: allocation skips any ID still present in `tasks/` or
`trash/` (for example after restoring a backup).

## Write safety

- **Lock:** every read-modify-write takes an exclusive `flock` on `.lock`, so the
  TUI and a CLI command in another terminal cannot overwrite each other.
  A process that cannot get the lock within 5 s (`TODOSH_LOCK_TIMEOUT`) fails
  with exit code 4.
- **Atomic replace:** a file is written to a temporary file in the same
  directory, validated with `jq`, flushed (`sync --data`) and renamed over the
  old file. Readers see the old or the new content, never a partial file.
- **Limits:** the parent directory is not fsync'ed, so after a sudden power loss
  the most recent change may be lost, but files are never left half-written.
  An operation touching two files (for example a task and its parent) is not one
  transaction; such operations are ordered so an interruption leaves valid data.
- Writes outside the data directory and writes onto symlinks are refused.

## Inspecting data by hand

The files are meant to be readable:

```sh
jq . ~/.local/share/todosh/tasks/42.json
jq -s 'map(select(.status == "BLOCKED")) | .[].title' ~/.local/share/todosh/tasks/*.json
```

Avoid editing files while todosh is running. If you edit one, keep it valid JSON:
a corrupted file is reported by name rather than silently skipped.

## Task record (`tasks/<id>.json`)

```json
{
  "id": 42,
  "title": "Review firewall rules",
  "description": "Markdown text, may span lines",
  "status": "IN_PROGRESS",
  "priority": "high",
  "project": "infra",
  "tags": ["network"],
  "parent": null,
  "due": null,
  "created": "2026-10-28T10:21:00Z",
  "updated": "2026-10-28T11:02:13Z",
  "closed": null,
  "history": [
    {"type": "event", "at": "...", "event": "created"},
    {"type": "event", "at": "...", "event": "status", "from": "TODO", "to": "IN_PROGRESS"},
    {"type": "event", "at": "...", "event": "edit", "field": "priority", "from": "med", "to": "high"},
    {"type": "event", "at": "...", "event": "edit", "field": "description"},
    {"type": "comment", "at": "...", "text": "Found an unexpected rule on 8080"},
    {"type": "focus", "at": "...", "since": "...", "seconds": 5400}
  ]
}
```

| Field | Values |
|---|---|
| `status` | `TODO`, `IN_PROGRESS`, `BLOCKED`, `DONE`, `CANCELLED` |
| `priority` | `urgent`, `high`, `med`, `low` |
| `project` | A path of up to 4 segments, e.g. `HardwareHacking/RF & SDR` (subprojects). Segments: 1-32 characters, no `/` or control characters |
| `tags[]` | `[A-Za-z0-9][A-Za-z0-9._-]{0,31}`; kept sorted and unique |
| `parent` | ID of the parent task, or `null`. Subtasks are one level deep |
| `due` | Local calendar date `YYYY-MM-DD`, or `null` |
| `closed` | When the task became `DONE`/`CANCELLED`; `null` while open |
| timestamps | UTC, ISO 8601 (`YYYY-MM-DDTHH:MM:SSZ`) |

History entries are append-only and `at` is always when the entry was recorded.
`type` is `comment` (written by the user), `focus` (a finished work session:
`since` = start, `seconds` = length) or `event` (recorded automatically):
`created`, `status` (`from`/`to`), `edit` (`field`, plus `from`/`to` except for
`description`), `deleted`, `restored`.

## Projects (`projects.json`)

A project exists while a task uses it. `projects.json` also lists projects
created explicitly (`todosh project add`), so empty ones are kept; adding a
subproject registers its parents too. Removing a project is refused while any
task (live or trashed) belongs to it or to a subproject.

## Focus (`focus.json`)

`{"task": 42, "since": "2026-10-28T10:00:00Z"}` while a task is in focus,
`{"task": null, "since": null}` otherwise. The running session is written to
the task history when the focus moves, is released, or the task is closed or
deleted.

Rules enforced by todosh (hand edits should respect them too):

- a subtask's parent exists, is live (not in the trash) and is not a subtask;
- a `DONE`/`CANCELLED` task has no open subtasks;
- trashed tasks keep their record; `purge` removes the file for good.

Adding a field is a compatible change and does not bump the schema version;
readers treat missing fields as their defaults. Renaming or changing the meaning
of a field requires a new schema version and a migration.
