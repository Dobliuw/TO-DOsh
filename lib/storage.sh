# shellcheck shell=bash
# storage.sh — on-disk layout, locking, atomic JSON writes and ID allocation.
#
# Layout (details in docs/STORAGE.md):
#   $TD_DATA_DIR/
#   ├── meta.json        schema version and next task ID
#   ├── tasks/<id>.json  one file per task, history embedded
#   ├── trash/<id>.json  soft-deleted tasks
#   ├── backups/
#   └── .lock            advisory lock file (flock)
#
# Every mutation happens while holding the lock, and every file is replaced by
# writing a temporary file in the same directory and renaming it over the old
# one, so readers see either the old or the new version, never a partial file.

readonly TD_SCHEMA_VERSION=1
readonly TD_STORAGE_AREAS=(tasks trash backups)

TD_LOCK_FD=""
TD_LOCK_DEPTH=0
TD_LOCK_TIMEOUT=${TODOSH_LOCK_TIMEOUT:-5}

# td_gen_uuid VAR — generate a random UUID v4 and store it in VAR.
# Tries uuidgen, then /proc/sys/kernel/random/uuid, then /dev/urandom.
td_gen_uuid() {
  local -n _td_uuid=$1
  if command -v uuidgen >/dev/null 2>&1; then
    _td_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    return 0
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    _td_uuid=$(</proc/sys/kernel/random/uuid)
    return 0
  fi
  local h d
  if h=$(od -N 16 -A n -t x1 /dev/urandom 2>/dev/null | tr -d ' \n') \
     && (( ${#h} >= 32 )); then
    printf -v d '%02x' "$(( (16#${h:16:2} & 0x3f) | 0x80 ))"
    _td_uuid="${h:0:8}-${h:8:4}-4${h:13:3}-${d}${h:18:2}-${h:20:12}"
    return 0
  fi
  td_err "cannot generate a UUID (install uuidgen or ensure /dev/urandom is readable)"
  return "$TD_E_ERR"
}

# td_storage_init — create the data directory if needed and check its schema.
td_storage_init() {
  td_require_cmds jq flock mktemp || return
  # Task data is private to the user.
  umask 077

  local dir area
  local -a dirs=()
  if [[ -e $TD_DATA_DIR && ! -d $TD_DATA_DIR ]]; then
    td_err "data path exists but is not a directory: $TD_DATA_DIR"
    return "$TD_E_ERR"
  fi
  for area in "${TD_STORAGE_AREAS[@]}"; do
    dir=$TD_DATA_DIR/$area
    if [[ -L $dir ]]; then
      td_err "refusing to use symlinked directory: $dir"
      return "$TD_E_ERR"
    fi
    if [[ -e $dir && ! -d $dir ]]; then
      td_err "not a directory: $dir"
      return "$TD_E_ERR"
    fi
    dirs+=("$dir")
  done
  if ! mkdir -p -- "${dirs[@]}"; then
    td_err "cannot create data directory: $TD_DATA_DIR"
    return "$TD_E_ERR"
  fi

  if [[ ! -e $TD_DATA_DIR/meta.json ]]; then
    td_with_lock _td_meta_create || return
  fi
  td_storage_check_schema || return
  # Compatible migration: add 'uuid' to tasks that pre-date this feature.
  # Schema version stays at 1 (adding a field is always compatible).
  _td_migrate_uuids
}

_td_meta_create() {
  # Re-check under the lock: another process may have won the race.
  [[ -e $TD_DATA_DIR/meta.json ]] && return 0
  local now
  td_now_utc now
  td_write_json "$TD_DATA_DIR/meta.json" "$(jq -n \
    --argjson schema "$TD_SCHEMA_VERSION" --arg now "$now" \
    '{schema: $schema, next_id: 1, created: $now}')"
}

# td_storage_check_schema — refuse data written by an incompatible version.
td_storage_check_schema() {
  local meta=$TD_DATA_DIR/meta.json schema
  if ! schema=$(jq -er '.schema | select(type == "number")' "$meta" 2>/dev/null); then
    td_err "corrupted or unreadable metadata: $meta"
    return "$TD_E_ERR"
  fi
  if ((schema > TD_SCHEMA_VERSION)); then
    td_err "data schema v$schema is newer than this todosh supports (v$TD_SCHEMA_VERSION); upgrade todosh"
    return "$TD_E_ERR"
  fi
  if ((schema < TD_SCHEMA_VERSION)); then
    # No older schema exists yet; migrations will hook in here.
    td_err "data schema v$schema needs migration, which is not available"
    return "$TD_E_ERR"
  fi
}

# --- locking ---------------------------------------------------------------

# td_lock — take the exclusive data lock (re-entrant within one process).
td_lock() {
  if ((TD_LOCK_DEPTH > 0)); then
    TD_LOCK_DEPTH=$((TD_LOCK_DEPTH + 1))
    return 0
  fi
  local lockfile=$TD_DATA_DIR/.lock
  if [[ -L $lockfile ]]; then
    td_err "refusing symlinked lock file: $lockfile"
    return "$TD_E_ERR"
  fi
  if ! exec {TD_LOCK_FD}>>"$lockfile"; then
    td_err "cannot open lock file: $lockfile"
    return "$TD_E_ERR"
  fi
  if ! flock -w "$TD_LOCK_TIMEOUT" "$TD_LOCK_FD"; then
    exec {TD_LOCK_FD}>&-
    TD_LOCK_FD=""
    td_err "data is locked by another todosh process (waited ${TD_LOCK_TIMEOUT}s)"
    return "$TD_E_CONFLICT"
  fi
  TD_LOCK_DEPTH=1
}

# td_unlock — release one level of the lock; the last level closes it.
td_unlock() {
  ((TD_LOCK_DEPTH > 0)) || return 0
  TD_LOCK_DEPTH=$((TD_LOCK_DEPTH - 1))
  if ((TD_LOCK_DEPTH == 0)); then
    exec {TD_LOCK_FD}>&-
    TD_LOCK_FD=""
  fi
}

# td_with_lock CMD [ARG...] — run CMD holding the lock; returns CMD's status.
td_with_lock() {
  local rc=0
  td_lock || return
  "$@" || rc=$?
  td_unlock
  return "$rc"
}

# --- files -----------------------------------------------------------------

# td_write_json PATH JSON — validate JSON (must be an object) and atomically
# replace PATH with it. Requires the lock and a PATH inside the data directory.
td_write_json() {
  local path=$1 json=$2 tmp
  if ((TD_LOCK_DEPTH == 0)); then
    td_err "internal error: write without lock: $path"
    return "$TD_E_ERR"
  fi
  if [[ $path != "$TD_DATA_DIR"/* || $path == *'/../'* ]]; then
    td_err "internal error: write outside data directory: $path"
    return "$TD_E_ERR"
  fi
  if [[ -L $path ]]; then
    td_err "refusing to overwrite symlink: $path"
    return "$TD_E_ERR"
  fi
  if ! tmp=$(mktemp -- "${path%/*}/.tmp.XXXXXXXX"); then
    td_err "cannot create temporary file next to $path"
    return "$TD_E_ERR"
  fi
  if ! jq 'if type == "object" then . else error("not a JSON object") end' \
    <<<"$json" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    td_err "internal error: refusing to write invalid JSON to $path"
    return "$TD_E_ERR"
  fi
  # Flush data before the rename; rename alone does not guarantee durability.
  if ! sync --data -- "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    td_err "cannot write $path"
    return "$TD_E_ERR"
  fi
}

# td_task_path ID [AREA] — print the file path of a task (AREA: tasks|trash).
td_task_path() {
  local id=$1 area=${2:-tasks}
  if ! td_valid_id "$id"; then
    td_err "invalid task id: '$id'"
    return "$TD_E_USAGE"
  fi
  if [[ $area != tasks && $area != trash ]]; then
    td_err "internal error: unknown storage area: $area"
    return "$TD_E_ERR"
  fi
  printf '%s\n' "$TD_DATA_DIR/$area/$id.json"
}

# td_task_read ID [AREA] — print the task JSON.
td_task_read() {
  local path
  path=$(td_task_path "$@") || return
  if [[ ! -f $path ]]; then
    td_err "task #$1 not found"
    return "$TD_E_NOTFOUND"
  fi
  if ! jq -c . "$path" 2>/dev/null; then
    td_err "corrupted task file: $path"
    return "$TD_E_ERR"
  fi
}

# td_task_write ID JSON [AREA] — store a task (requires the lock).
td_task_write() {
  local path
  path=$(td_task_path "$1" "${3:-tasks}") || return
  td_write_json "$path" "$2"
}

# td_task_move ID FROM TO — move a task file between areas (requires the lock).
# Both areas live in the same directory tree, so this is an atomic rename.
td_task_move() {
  local src dst
  if ((TD_LOCK_DEPTH == 0)); then
    td_err "internal error: move without lock: #$1"
    return "$TD_E_ERR"
  fi
  src=$(td_task_path "$1" "$2") || return
  dst=$(td_task_path "$1" "$3") || return
  if [[ ! -f $src || -L $src ]]; then
    td_err "task #$1 not found in $2"
    return "$TD_E_NOTFOUND"
  fi
  if [[ -e $dst || -L $dst ]]; then
    td_err "cannot move task #$1: it already exists in $3"
    return "$TD_E_CONFLICT"
  fi
  if ! mv -- "$src" "$dst"; then
    td_err "cannot move task #$1 from $2 to $3"
    return "$TD_E_ERR"
  fi
}

# td_task_remove ID AREA — permanently delete a task file (requires the lock).
td_task_remove() {
  local path
  if ((TD_LOCK_DEPTH == 0)); then
    td_err "internal error: remove without lock: #$1"
    return "$TD_E_ERR"
  fi
  path=$(td_task_path "$1" "$2") || return
  if [[ ! -f $path || -L $path ]]; then
    td_err "task #$1 not found in $2"
    return "$TD_E_NOTFOUND"
  fi
  rm -f -- "$path"
}

# td_task_ids [AREA] — print stored task IDs in ascending order.
td_task_ids() {
  local area=${1:-tasks} file id
  for file in "$TD_DATA_DIR/$area"/*.json; do
    [[ -f $file ]] || continue
    id=${file##*/}
    id=${id%.json}
    td_valid_id "$id" && printf '%s\n' "$id"
  done | sort -n
}

# td_tasks_load [AREA] — print every task in AREA as one JSON array.
td_tasks_load() {
  local area=${1:-tasks} id file
  local -a files=()
  while IFS= read -r id; do
    files+=("$TD_DATA_DIR/$area/$id.json")
  done < <(td_task_ids "$area")
  if ((${#files[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  # jq -s reads all inputs before printing, so a bad file produces no output.
  jq -cs . "${files[@]}" 2>/dev/null && return 0
  for file in "${files[@]}"; do
    jq empty "$file" 2>/dev/null || td_err "corrupted task file: $file"
  done
  return "$TD_E_ERR"
}

# td_next_id VAR — allocate a new task ID into VAR (requires the lock).
td_next_id() {
  local -n _td_id=$1
  local _td_meta=$TD_DATA_DIR/meta.json _td_next
  if ((TD_LOCK_DEPTH == 0)); then
    td_err "internal error: ID allocation without lock"
    return "$TD_E_ERR"
  fi
  if ! _td_next=$(jq -er '.next_id' "$_td_meta" 2>/dev/null) || ! td_valid_id "$_td_next"; then
    td_err "corrupted metadata (next_id): $_td_meta"
    return "$TD_E_ERR"
  fi
  # Never reuse an ID that is still on disk (e.g. after restoring a backup).
  while [[ -e $TD_DATA_DIR/tasks/$_td_next.json || -e $TD_DATA_DIR/trash/$_td_next.json ]]; do
    _td_next=$((_td_next + 1))
  done
  td_write_json "$_td_meta" "$(jq --argjson n $((_td_next + 1)) '.next_id = $n' "$_td_meta")" || return
  _td_id=$_td_next
}

# --- uuid migration ---------------------------------------------------------

# _td_migrate_uuids — add a 'uuid' field to any task that was created before
# this feature existed. Non-fatal: a failure to generate a UUID is skipped.
_td_migrate_uuids() {
  local area file needs=0
  for area in tasks trash; do
    for file in "$TD_DATA_DIR/$area"/*.json; do
      [[ -f $file ]] || continue
      jq -e '.uuid // empty' "$file" >/dev/null 2>&1 || { needs=1; break 2; }
    done
  done
  (( needs )) || return 0
  td_with_lock _td_migrate_uuids_locked
}

_td_migrate_uuids_locked() {
  local area file uuid json
  for area in tasks trash; do
    for file in "$TD_DATA_DIR/$area"/*.json; do
      [[ -f $file ]] || continue
      jq -e '.uuid // empty' "$file" >/dev/null 2>&1 && continue
      td_gen_uuid uuid 2>/dev/null || continue
      [[ -n $uuid ]] || continue
      json=$(jq -c --arg uuid "$uuid" '. + {uuid: $uuid}' "$file") || continue
      td_write_json "$file" "$json" || return
    done
  done
}
