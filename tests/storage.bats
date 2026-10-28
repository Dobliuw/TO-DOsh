#!/usr/bin/env bats
# Data directory, locking, atomic writes and ID allocation (lib/storage.sh).

load test_helper

setup() {
  td_test_setup
  td_load_lib
  td_paths_init
}

# alloc_ids N — allocate N IDs in one locked section, printing each.
alloc_ids() {
  local i id
  for ((i = 0; i < $1; i++)); do
    td_next_id id
    printf '%s\n' "$id"
  done
}

@test "init creates a private layout and metadata" {
  td_storage_init
  for dir in "" /tasks /trash /backups; do
    [ -d "$TD_DATA_DIR$dir" ]
    [ "$(stat -c %a "$TD_DATA_DIR$dir")" = 700 ]
  done
  [ "$(stat -c %a "$TD_DATA_DIR/meta.json")" = 600 ]
  [ "$(jq -r .schema "$TD_DATA_DIR/meta.json")" = 1 ]
  [ "$(jq -r .next_id "$TD_DATA_DIR/meta.json")" = 1 ]
}

@test "init is idempotent and keeps existing metadata" {
  td_storage_init
  td_with_lock alloc_ids 3 >/dev/null
  td_storage_init
  [ "$(jq -r .next_id "$TD_DATA_DIR/meta.json")" = 4 ]
}

@test "works in a data path with spaces, unicode and shell metacharacters" {
  TD_DATA_DIR="$BATS_TEST_TMPDIR/dátos & más \$(x)"
  td_storage_init
  run td_with_lock alloc_ids 2
  [ "$output" = $'1\n2' ]
}

@test "IDs are sequential and require the lock" {
  td_storage_init
  run td_with_lock alloc_ids 3
  [ "$output" = $'1\n2\n3' ]
  run td_next_id id
  [ "$status" -eq 1 ]
  [[ $output == *"without lock"* ]]
}

@test "ID allocation skips IDs still present on disk" {
  td_storage_init
  printf '{"id":1}\n' >"$TD_DATA_DIR/tasks/1.json"
  printf '{"id":2}\n' >"$TD_DATA_DIR/trash/2.json"
  run td_with_lock alloc_ids 1
  [ "$output" = 3 ]
}

@test "concurrent processes never receive the same ID" {
  td_storage_init
  local script='
    shopt -s extglob
    for m in core config storage cli; do source "$1/lib/$m.sh"; done
    td_paths_init && td_storage_init || exit 1
    td_lock || exit 1
    td_next_id id || exit 1
    td_unlock
    printf "%s\n" "$id"'
  local i
  for ((i = 0; i < 20; i++)); do
    TODOSH_DATA_DIR=$TD_DATA_DIR bash -c "$script" _ "$TD_ROOT" >"$BATS_TEST_TMPDIR/out.$i" &
  done
  wait
  run bash -c 'cat "$1"/out.* | sort -n | uniq | wc -l' _ "$BATS_TEST_TMPDIR"
  [ "$output" -eq 20 ]
  [ "$(jq -r .next_id "$TD_DATA_DIR/meta.json")" = 21 ]
}

@test "a held lock makes writers fail with the conflict code" {
  td_storage_init
  flock "$TD_DATA_DIR/.lock" sleep 3 &
  sleep 0.3
  TD_LOCK_TIMEOUT=0 run td_lock
  [ "$status" -eq 4 ]
  [[ $output == *"locked by another"* ]]
  kill %1 2>/dev/null || true
}

@test "the lock is re-entrant within a process" {
  td_storage_init
  td_lock
  td_lock
  [ "$TD_LOCK_DEPTH" -eq 2 ]
  td_unlock
  [ -n "$TD_LOCK_FD" ]
  td_unlock
  [ -z "$TD_LOCK_FD" ]
  [ "$TD_LOCK_DEPTH" -eq 0 ]
}

@test "invalid JSON leaves the original file intact and no temp files" {
  td_storage_init
  td_lock
  td_task_write 5 '{"id":5,"title":"original"}'
  run td_task_write 5 '{"id":5,"title":'
  [ "$status" -eq 1 ]
  run td_task_write 5 '["not", "an", "object"]'
  [ "$status" -eq 1 ]
  td_unlock
  [ "$(jq -r .title "$TD_DATA_DIR/tasks/5.json")" = original ]
  run find "$TD_DATA_DIR" -name '.tmp.*'
  [ -z "$output" ]
}

@test "writes are refused without lock, outside the data dir, or onto symlinks" {
  td_storage_init
  run td_write_json "$TD_DATA_DIR/tasks/1.json" '{}'
  [[ $output == *"without lock"* ]]

  td_lock
  run td_write_json "$BATS_TEST_TMPDIR/elsewhere.json" '{}'
  [[ $output == *"outside data directory"* ]]
  run td_write_json "$TD_DATA_DIR/tasks/../../escape.json" '{}'
  [[ $output == *"outside data directory"* ]]

  local target="$BATS_TEST_TMPDIR/victim"
  printf 'keep\n' >"$target"
  ln -s "$target" "$TD_DATA_DIR/tasks/7.json"
  run td_task_write 7 '{"id":7}'
  [ "$status" -eq 1 ]
  [[ $output == *"symlink"* ]]
  td_unlock
  [ "$(cat "$target")" = keep ]
}

@test "init refuses symlinked storage directories" {
  mkdir -p "$TD_DATA_DIR" "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$TD_DATA_DIR/tasks"
  run td_storage_init
  [ "$status" -eq 1 ]
  [[ $output == *"symlinked directory"* ]]
}

@test "task paths reject invalid IDs" {
  td_storage_init
  for id in 0 01 -1 ../meta "1/2" abc ""; do
    run td_task_path "$id"
    [ "$status" -eq 2 ] || {
      echo "accepted: '$id'"
      return 1
    }
  done
  run td_task_path 3 trash
  [ "$output" = "$TD_DATA_DIR/trash/3.json" ]
}

@test "reading a missing task returns the not-found code" {
  td_storage_init
  run td_task_read 99
  [ "$status" -eq 3 ]
  [[ $output == *"#99 not found"* ]]
}

@test "loading tasks returns a numerically ordered array" {
  td_storage_init
  run td_tasks_load
  [ "$output" = "[]" ]
  td_lock
  td_task_write 10 '{"id":10}'
  td_task_write 9 '{"id":9}'
  td_unlock
  # Stray files are ignored.
  printf 'x\n' >"$TD_DATA_DIR/tasks/notes.json"
  run td_tasks_load
  [ "$(jq -c 'map(.id)' <<<"$output")" = "[9,10]" ]
}

@test "a corrupted task file is reported by name" {
  td_storage_init
  td_lock
  td_task_write 1 '{"id":1}'
  td_unlock
  printf '{"id": 2,' >"$TD_DATA_DIR/tasks/2.json"
  run td_tasks_load
  [ "$status" -eq 1 ]
  [[ $output == *"corrupted task file: $TD_DATA_DIR/tasks/2.json"* ]]
  run td_task_read 2
  [ "$status" -eq 1 ]
}

@test "metadata from a newer schema or corrupted metadata is refused" {
  td_storage_init
  printf '{"schema": 99, "next_id": 1}\n' >"$TD_DATA_DIR/meta.json"
  run td_storage_init
  [ "$status" -eq 1 ]
  [[ $output == *"newer than this todosh"* ]]
  printf 'garbage' >"$TD_DATA_DIR/meta.json"
  run td_storage_init
  [ "$status" -eq 1 ]
  [[ $output == *"corrupted or unreadable metadata"* ]]
}

@test "a file in place of the data directory is an error" {
  mkdir -p "${TD_DATA_DIR%/*}"
  printf 'x' >"$TD_DATA_DIR"
  run td_storage_init
  [ "$status" -eq 1 ]
  [[ $output == *"not a directory"* ]]
}
