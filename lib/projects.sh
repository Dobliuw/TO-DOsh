# shellcheck shell=bash disable=SC2034
# projects.sh — projects and subprojects.
#
# A project is a path: "HardwareHacking/RF & SDR" is a subproject of
# "HardwareHacking". Tasks store the path in their `project` field. Projects
# exist while a task uses them; projects.json additionally keeps projects that
# were created explicitly (`todosh project add`), so an empty subproject does
# not disappear before its first task:
#   {"projects": ["HardwareHacking", "HardwareHacking/RF & SDR"]}
# (SC2034 is disabled for this file: TD_RESULT is read by callers elsewhere.)

# td_projects_registered — print registered project paths, one per line.
td_projects_registered() {
  local file=$TD_DATA_DIR/projects.json
  [[ -f $file ]] || return 0
  jq -r '.projects // [] | .[]' "$file" 2>/dev/null || td_warn "ignoring corrupted $file"
}

# td_project_add PATH — register PATH and its parents. TD_RESULT: 1 if new.
td_project_add() {
  TD_RESULT=""
  if ! td_valid_project "$1"; then
    td_err "invalid project: '$1' (up to 4 levels like a/b, 1-32 characters each)"
    return "$TD_E_USAGE"
  fi
  td_with_lock _td_project_add_locked "$1"
}

_td_project_add_locked() {
  local file=$TD_DATA_DIR/projects.json current new
  current='{"projects": []}'
  if [[ -f $file ]]; then
    current=$(jq -c . "$file" 2>/dev/null) || current='{"projects": []}'
  fi
  new=$(jq -c --arg p "$1" '
    ($p | split("/")) as $s
    | .projects = ((.projects // []) + [range(1; ($s | length) + 1) as $n | $s[:$n] | join("/")] | unique)' \
    <<<"$current") || return
  if [[ $new == "$current" ]]; then
    TD_RESULT=0
    return 0
  fi
  td_write_json "$file" "$new" || return
  TD_RESULT=1
}

# td_project_remove PATH — unregister PATH and its subprojects. Refused while
# a live task (or a trashed one) still belongs to the project or below it.
td_project_remove() {
  TD_RESULT=""
  if ! td_valid_project "$1"; then
    td_err "invalid project: '$1'"
    return "$TD_E_USAGE"
  fi
  td_with_lock _td_project_remove_locked "$1"
}

_td_project_remove_locked() {
  local p=$1 file=$TD_DATA_DIR/projects.json used area new
  for area in tasks trash; do
    used=$(td_tasks_load "$area" | jq -r --arg p "$p" \
      '[.[] | select(.project == $p or (.project | startswith($p + "/")))] | length') || return
    if ((used > 0)); then
      td_err "project '$p' still has $used task(s) in $area; move or delete them first"
      return "$TD_E_CONFLICT"
    fi
  done
  if [[ ! -f $file ]] || ! jq -e --arg p "$p" \
    '.projects // [] | any(. == $p or startswith($p + "/"))' "$file" >/dev/null 2>&1; then
    td_err "project not found: $p"
    return "$TD_E_NOTFOUND"
  fi
  new=$(jq -c --arg p "$p" '.projects |= map(select(. != $p and (startswith($p + "/") | not)))' "$file") || return
  td_write_json "$file" "$new" || return
  TD_RESULT=1
}

# td_projects_tree — print every project (registered, used by a live task, and
# their parents) in tree order (inbox first, then alphabetically by segment):
#   [{"path", "name", "depth", "open", "done", "total"}]
# Counts include subprojects; "total" leaves cancelled tasks out.
td_projects_tree() {
  local tasks
  local -a registered
  tasks=$(td_tasks_load) || return
  mapfile -t registered < <(td_projects_registered)
  jq -c '
    . as $tasks
    | ([$tasks[].project] + $ARGS.positional
       | map(split("/") as $s | range(1; ($s | length) + 1) as $n | $s[:$n] | join("/"))
       | unique) as $paths
    | [$paths[] as $p
       | ($tasks | map(select(.project == $p or (.project | startswith($p + "/"))))) as $in
       | {path: $p, name: ($p | split("/") | last), depth: ($p | split("/") | length - 1),
          open: ($in | map(select(.status | IN("TODO", "IN_PROGRESS", "BLOCKED"))) | length),
          done: ($in | map(select(.status == "DONE")) | length),
          total: ($in | map(select(.status != "CANCELLED")) | length)}]
    | sort_by(.path | split("/") | map(if . == "inbox" then "" else ascii_downcase end))' \
    --args "${registered[@]}" <<<"$tasks"
}
