# Storage format

TODOSH keeps all data as plain JSON files in one directory:

```
${TODOSH_DATA_DIR:-${XDG_DATA_HOME:-~/.local/share}/todosh}/
├── meta.json        {"schema": 1, "next_id": 43, "created": "..."}
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

The task record format itself is documented here when the core commands land
(phase 2).
