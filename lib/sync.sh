# shellcheck shell=bash
# sync.sh — git-based bidirectional sync for the todosh data directory.
#
# todosh sync info         – explain the sync strategy and show setup steps
# todosh sync init REMOTE  – turn the data dir into a git repo linked to REMOTE
# todosh sync push [MSG]   – commit local changes and push to origin
# todosh sync pull         – pull from origin and auto-merge
# todosh sync status       – show ahead / behind / dirty state
#
# Each task carries a UUID so tasks created on separate machines never collide.
# A custom git merge driver (todosh-merge-tasks) resolves concurrent edits:
# it picks the field values from the more recently updated side and unions the
# history entries from both machines.

# _td_sync_git [ARG...] — run git inside the data directory.
_td_sync_git() {
  git -C "$TD_DATA_DIR" "$@"
}

# _td_sync_is_repo — succeed when the data directory is a git repository.
_td_sync_is_repo() {
  _td_sync_git rev-parse --git-dir >/dev/null 2>&1
}

# _td_sync_remote — print the URL of 'origin', or empty string.
_td_sync_remote() {
  _td_sync_git remote get-url origin 2>/dev/null || true
}

# _td_sync_find_driver — print the absolute path of todosh-merge-tasks.
_td_sync_find_driver() {
  local candidate="$TD_BIN_DIR/todosh-merge-tasks"
  if [[ -x $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  local found
  found=$(command -v todosh-merge-tasks 2>/dev/null) && {
    printf '%s\n' "$found"
    return 0
  }
  td_err "todosh-merge-tasks not found; is todosh properly installed?"
  return "$TD_E_ERR"
}

# _td_sync_register_driver DRIVER_PATH — write the merge driver into .git/config.
_td_sync_register_driver() {
  local driver=$1
  _td_sync_git config merge.todosh.name   "todosh data merge driver" || return
  _td_sync_git config merge.todosh.driver "$driver %P %O %A %B"      || return
}

# _td_sync_write_gitfiles — write .gitignore and .gitattributes into the data dir.
_td_sync_write_gitfiles() {
  printf '%s\n' \
    '.lock' '.tmp.*' 'focus.json' 'backups/' \
    > "$TD_DATA_DIR/.gitignore"
  printf '%s\n' \
    'tasks/*.json  merge=todosh' \
    'trash/*.json  merge=todosh' \
    'meta.json     merge=todosh' \
    'projects.json merge=todosh' \
    > "$TD_DATA_DIR/.gitattributes"
}

# --- command -----------------------------------------------------------------

td_register_cmd sync Sync "Push and pull tasks across machines via git"

td_help_sync() {
  printf '%s\n' \
    "Usage: todosh sync <subcommand> [options]" \
    "" \
    "Subcommands:" \
    "  info            Explain the sync strategy and show setup steps" \
    "  init REMOTE     Turn the data directory into a git repo linked to REMOTE" \
    "  push [MSG]      Commit local changes and push them to origin" \
    "  pull            Pull from origin (auto-merges concurrent edits)" \
    "  status          Show ahead / behind / dirty state" \
    "" \
    "Run 'todosh sync info' for a step-by-step setup guide."
}

td_cmd_sync() {
  if td_wants_help "$@"; then
    td_help_sync
    return 0
  fi
  local sub=${1:-info}
  (($#)) && shift
  case $sub in
    info)   _td_sync_cmd_info   "$@" ;;
    init)   _td_sync_cmd_init   "$@" ;;
    push)   _td_sync_cmd_push   "$@" ;;
    pull)   _td_sync_cmd_pull   "$@" ;;
    status) _td_sync_cmd_status "$@" ;;
    *) td_usage_err sync "unknown subcommand: $sub (info | init | push | pull | status)" ;;
  esac
}

# --- sync info ---------------------------------------------------------------

_td_sync_cmd_info() {
  if (($#)); then
    td_usage_err "sync info" "unexpected argument: $1"
    return
  fi

  local initialized="no" remote="(not set)"
  if _td_sync_is_repo 2>/dev/null; then
    initialized="yes"
    remote=$(_td_sync_remote)
    [[ -n $remote ]] || remote="(not set)"
  fi

  if ((TD_OPT_JSON)); then
    jq -n \
      --arg data_dir "$TD_DATA_DIR" \
      --arg initialized "$initialized" \
      --arg remote "$remote" \
      '{data_dir: $data_dir, initialized: ($initialized == "yes"), remote: $remote}'
    return
  fi

  local b=${TD_SGR[bold]} g=${TD_SGR[gray]} r=${TD_SGR[reset]} \
        y=${TD_SGR[yellow]} c=${TD_SGR[cyan]} m=${TD_SGR[magenta]}

  printf '%s\n' \
    "" \
    "${b}todosh sync${r} — push and pull your tasks from any machine" \
    "" \
    "${b}HOW IT WORKS${r}" \
    "  Task data lives in plain JSON files in the data directory below." \
    "  'sync init' turns that directory into a git repository linked to a" \
    "  remote you control: a private GitHub/GitLab repo, a self-hosted" \
    "  Gitea instance, or a bare repo on any server reachable over SSH." \
    "  Any machine with todosh and access to that remote can push and pull." \
    "" \
    "  Each task carries a ${c}UUID${r} so tasks created on separate machines" \
    "  never collide. A custom git merge driver resolves concurrent edits:" \
    "  field values are taken from the more recently updated side, and" \
    "  history entries are always unioned from both machines." \
    "" \
    "${b}PREREQUISITES${r}" \
    "  - git  (verify with: git --version)" \
    "  - A git remote you control (choose one):" \
    "      ${c}GitHub / GitLab${r}   create a new ${y}private${r} repository (free tier works)" \
    "      ${c}Self-hosted${r}        git init --bare ~/todosh-data.git  on an SSH server" \
    "      ${c}Local backup${r}       file:///path/to/bare-repo.git" \
    "" \
    "${b}SETUP — first machine${r}" \
    "  1. Create your private remote repository." \
    "  2. Initialize sync (replace the URL with your own):" \
    "       ${m}todosh sync init git@github.com:YOU/todosh-data.git${r}" \
    "     This initializes the data directory as a git repo, writes" \
    "     .gitignore and .gitattributes, makes an initial commit, and" \
    "     adds the remote. Nothing is pushed yet." \
    "  3. Push your tasks for the first time:" \
    "       ${m}todosh sync push${r}" \
    "" \
    "${b}SETUP — additional machines${r}" \
    "  1. Install todosh on the new machine." \
    "  2. Clone your data directly into the todosh data directory:" \
    "       ${m}git clone git@github.com:YOU/todosh-data.git \\${r}" \
    "       ${m}    \"$TD_DATA_DIR\"${r}" \
    "     (The directory must not exist yet, or be empty.)" \
    "  3. Register the merge driver:" \
    "       ${m}todosh sync init git@github.com:YOU/todosh-data.git${r}" \
    "     todosh detects the repo is already cloned and only registers" \
    "     the merge driver — no new commit is made." \
    "" \
    "${b}DAILY USE${r}" \
    "  After working on machine A, push:" \
    "    ${m}todosh sync push${r}" \
    "  Before starting on machine B, pull:" \
    "    ${m}todosh sync pull${r}" \
    "  Check what is pending:" \
    "    ${m}todosh sync status${r}" \
    "" \
    "${b}CONFLICTS${r}" \
    "  The merge driver resolves most concurrent edits automatically." \
    "  If an unresolvable conflict remains, inspect the data directory:" \
    "    ${g}git -C \"$TD_DATA_DIR\" diff${r}" \
    "  Resolve the conflicting files, then push the fix:" \
    "    ${m}todosh sync push \"resolve merge conflict\"${r}" \
    "" \
    "${b}DATA DIRECTORY${r}   ${g}$TD_DATA_DIR${r}" \
    "  Git initialized:  $initialized" \
    "  Remote (origin):  $remote" \
    ""
}

# --- sync init ---------------------------------------------------------------

_td_sync_cmd_init() {
  if td_wants_help "$@"; then
    printf '%s\n' \
      "Usage: todosh sync init REMOTE" \
      "" \
      "Turns the data directory into a git repository linked to REMOTE." \
      "If the directory is already a git repo (e.g. you cloned it from" \
      "another machine), todosh only registers the merge driver and verifies" \
      "the remote — no new commit is created." \
      "" \
      "REMOTE examples:" \
      "  git@github.com:YOU/todosh-data.git" \
      "  https://github.com/YOU/todosh-data.git" \
      "  git@gitea.example.com:YOU/todosh-data.git" \
      "  file:///home/you/backup/todosh.git"
    return 0
  fi

  td_require_cmds git || return

  local remote=${1:-}
  if [[ -z $remote ]]; then
    td_usage_err "sync init" "remote URL required (run 'todosh sync info' for examples)"
    return
  fi
  if (($# > 1)); then
    td_usage_err "sync init" "unexpected argument: $2"
    return
  fi

  local driver
  driver=$(_td_sync_find_driver) || return

  if _td_sync_is_repo 2>/dev/null; then
    # Already a git repo (user cloned it from another machine).
    # Just register the merge driver and ensure the remote is set correctly.
    _td_sync_register_driver "$driver" || return
    local existing_remote
    existing_remote=$(_td_sync_remote)
    if [[ -n $existing_remote && $existing_remote != "$remote" ]]; then
      _td_sync_git remote set-url origin "$remote" || return
    elif [[ -z $existing_remote ]]; then
      _td_sync_git remote add origin "$remote" || return
    fi
    if ((TD_OPT_JSON)); then
      jq -n --arg dir "$TD_DATA_DIR" --arg remote "$remote" \
        '{initialized: false, driver_registered: true, remote: $remote, data_dir: $dir}'
    else
      printf '%s\n' \
        "Existing git repo detected (cloned from another machine)." \
        "Merge driver registered." \
        "Remote 'origin' → $remote" \
        "" \
        "Pull the latest tasks with: todosh sync pull"
    fi
    return 0
  fi

  # Fresh init: the data dir is not yet a git repo.
  td_storage_init || return

  _td_sync_git init -b main >/dev/null || {
    td_err "git init failed in: $TD_DATA_DIR"
    return "$TD_E_ERR"
  }
  _td_sync_write_gitfiles
  _td_sync_register_driver "$driver" || return
  _td_sync_git add -A >/dev/null || return
  _td_sync_git commit -m "init: todosh data" >/dev/null || {
    td_err "initial git commit failed"
    return "$TD_E_ERR"
  }
  _td_sync_git remote add origin "$remote" || {
    td_err "could not add remote: $remote"
    return "$TD_E_ERR"
  }

  if ((TD_OPT_JSON)); then
    jq -n --arg dir "$TD_DATA_DIR" --arg remote "$remote" \
      '{initialized: true, driver_registered: true, remote: $remote, data_dir: $dir}'
  else
    printf '%s\n' \
      "Git repo initialized in: $TD_DATA_DIR" \
      "Merge driver registered." \
      "Remote 'origin' → $remote" \
      "" \
      "Push your tasks with: todosh sync push"
  fi
}

# --- sync push ---------------------------------------------------------------

_td_sync_cmd_push() {
  if td_wants_help "$@"; then
    printf '%s\n' \
      "Usage: todosh sync push [MESSAGE]" \
      "" \
      "Stages all changes in the data directory, creates a git commit, and" \
      "pushes it to origin. MESSAGE is an optional commit summary; todosh" \
      "generates one automatically when omitted."
    return 0
  fi

  td_require_cmds git || return

  if ! _td_sync_is_repo 2>/dev/null; then
    td_err "sync is not initialized; run: todosh sync init <remote>"
    return "$TD_E_ERR"
  fi

  if [[ -z $(_td_sync_remote) ]]; then
    td_err "no remote 'origin' configured; set one with: git -C \"$TD_DATA_DIR\" remote add origin <url>"
    return "$TD_E_ERR"
  fi

  local message=${1:-}
  if (($# > 1)); then
    td_usage_err "sync push" "unexpected argument: $2 (quote the whole message)"
    return
  fi

  # Run the UUID migration so newly created tasks have UUIDs before pushing.
  td_storage_init || return

  _td_sync_git add -A || return

  if _td_sync_git diff --cached --quiet 2>/dev/null; then
    if ((TD_OPT_JSON)); then
      jq -n '{status: "nothing"}'
    else
      printf 'Nothing to push (data is already up to date).\n'
    fi
    return 0
  fi

  if [[ -z $message ]]; then
    local added modified deleted
    added=$(   _td_sync_git diff --cached --name-only --diff-filter=A 2>/dev/null \
               | grep -c '\.json$' || true)
    modified=$(  _td_sync_git diff --cached --name-only --diff-filter=M 2>/dev/null \
               | grep -c '\.json$' || true)
    deleted=$(   _td_sync_git diff --cached --name-only --diff-filter=D 2>/dev/null \
               | grep -c '\.json$' || true)
    local -a parts=()
    ((added    > 0)) && parts+=("$added added")
    ((modified > 0)) && parts+=("$modified updated")
    ((deleted  > 0)) && parts+=("$deleted deleted")
    if ((${#parts[@]} > 0)); then
      local IFS=', '
      message="sync: ${parts[*]}"
    else
      message="sync: update"
    fi
  fi

  _td_sync_git commit -m "$message" >/dev/null || {
    td_err "git commit failed"
    return "$TD_E_ERR"
  }

  local commit files_changed
  commit=$(_td_sync_git rev-parse --short HEAD 2>/dev/null) || commit="?"
  files_changed=$(_td_sync_git diff --name-only HEAD~1..HEAD 2>/dev/null \
    | wc -l | tr -d ' ') || files_changed=0

  if ! _td_sync_git push -u origin HEAD 2>/dev/null; then
    td_err "push failed; try manually: git -C \"$TD_DATA_DIR\" push -u origin HEAD"
    return "$TD_E_ERR"
  fi

  if ((TD_OPT_JSON)); then
    jq -n --arg status "pushed" --arg commit "$commit" \
       --arg message "$message" --argjson files "$files_changed" \
      '{status: $status, commit: $commit, message: $message, files_changed: $files}'
  else
    printf 'Pushed %s: %s\n' "$commit" "$message"
  fi
}

# --- sync pull ---------------------------------------------------------------

_td_sync_cmd_pull() {
  if td_wants_help "$@"; then
    printf '%s\n' \
      "Usage: todosh sync pull" \
      "" \
      "Fetches and merges changes from origin. The merge driver resolves" \
      "concurrent task edits automatically: field values are taken from the" \
      "more recently updated side; history entries are always unioned."
    return 0
  fi

  td_require_cmds git || return

  if ! _td_sync_is_repo 2>/dev/null; then
    td_err "sync is not initialized; run: todosh sync init <remote>"
    return "$TD_E_ERR"
  fi

  if [[ -z $(_td_sync_remote) ]]; then
    td_err "no remote 'origin' configured"
    return "$TD_E_ERR"
  fi

  if (($#)); then
    td_usage_err "sync pull" "unexpected argument: $1"
    return
  fi

  # Stash uncommitted local changes so pull can proceed cleanly.
  local had_stash=0
  if ! _td_sync_git diff --quiet 2>/dev/null \
     || ! _td_sync_git diff --cached --quiet 2>/dev/null; then
    _td_sync_git stash push -q -m "todosh-auto-stash" 2>/dev/null && had_stash=1
  fi

  local branch
  branch=$(_td_sync_git branch --show-current 2>/dev/null) || branch="main"

  local output rc=0
  output=$(_td_sync_git pull --no-edit --no-rebase origin "$branch" 2>&1) || rc=$?

  if ((had_stash)); then
    _td_sync_git stash pop -q 2>/dev/null || true
  fi

  if ((rc != 0)); then
    local conflicts
    conflicts=$(_td_sync_git diff --name-only --diff-filter=U 2>/dev/null) || conflicts=""
    if [[ -n $conflicts ]]; then
      if ((TD_OPT_JSON)); then
        local cf_arr
        cf_arr=$(printf '%s\n' "$conflicts" | jq -Rn '[inputs]')
        jq -n --argjson files "$cf_arr" '{status: "conflict", conflicting_files: $files}'
      else
        td_err "merge conflict; resolve these files and run 'todosh sync push':"
        printf '%s\n' "$conflicts" | sed 's/^/  /'
      fi
      return "$TD_E_CONFLICT"
    fi
    td_err "pull failed"
    printf '%s\n' "$output" >&2
    return "$TD_E_ERR"
  fi

  # Re-run UUID migration after pull (remote may have pre-UUID tasks).
  td_storage_init 2>/dev/null || true

  local status="updated"
  [[ $output == *"Already up to date"* ]] && status="up_to_date"

  if ((TD_OPT_JSON)); then
    jq -n --arg status "$status" '{status: $status}'
  else
    if [[ $status == up_to_date ]]; then
      printf 'Already up to date.\n'
    else
      printf 'Pulled and merged successfully.\n'
    fi
  fi
}

# --- sync status -------------------------------------------------------------

_td_sync_cmd_status() {
  if td_wants_help "$@"; then
    printf '%s\n' \
      "Usage: todosh sync status" \
      "" \
      "Shows the sync state: whether the data directory is a git repository," \
      "how many commits it is ahead of or behind the remote, and whether" \
      "there are uncommitted local changes."
    return 0
  fi

  td_require_cmds git || return

  if (($#)); then
    td_usage_err "sync status" "unexpected argument: $1"
    return
  fi

  if ! _td_sync_is_repo 2>/dev/null; then
    if ((TD_OPT_JSON)); then
      jq -n --arg dir "$TD_DATA_DIR" '{initialized: false, data_dir: $dir}'
    else
      printf '%s\n' \
        "Sync is not initialized." \
        "Run 'todosh sync info' for setup instructions." \
        "Run 'todosh sync init REMOTE' to initialize."
    fi
    return 0
  fi

  local remote branch ahead=0 behind=0
  remote=$(_td_sync_remote)
  branch=$(_td_sync_git branch --show-current 2>/dev/null) || branch="(detached)"

  if [[ -n $remote ]]; then
    _td_sync_git fetch -q origin 2>/dev/null || true
    local ab
    ab=$(_td_sync_git rev-list --count --left-right "HEAD...origin/$branch" 2>/dev/null) \
      || ab="0	0"
    ahead=${ab%%$'\t'*}
    behind=${ab##*$'\t'}
  fi

  local dirty=0 uncommitted=0 unstaged=0
  if ! _td_sync_git diff --cached --quiet 2>/dev/null; then
    dirty=1
    uncommitted=$(_td_sync_git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  fi
  if ! _td_sync_git diff --quiet 2>/dev/null; then
    dirty=1
    unstaged=$(_td_sync_git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  fi

  if ((TD_OPT_JSON)); then
    jq -n \
      --arg dir "$TD_DATA_DIR" --arg remote "${remote:-}" --arg branch "$branch" \
      --argjson ahead "$ahead" --argjson behind "$behind" \
      --argjson dirty "$dirty" \
      --argjson uncommitted "$uncommitted" --argjson unstaged "$unstaged" \
      '{initialized: true, data_dir: $dir, remote: $remote, branch: $branch,
        ahead: $ahead, behind: $behind, dirty: ($dirty == 1),
        uncommitted: $uncommitted, unstaged: $unstaged}'
    return
  fi

  local b=${TD_SGR[bold]} g=${TD_SGR[gray]} r=${TD_SGR[reset]} \
        y=${TD_SGR[yellow]} c=${TD_SGR[cyan]} red=${TD_SGR[red]}

  printf '%sData dir%s    %s\n' "$g" "$r" "$TD_DATA_DIR"
  printf '%sBranch%s      %s%s%s\n'   "$g" "$r" "$c" "$branch" "$r"
  if [[ -n $remote ]]; then
    printf '%sRemote%s      %s\n' "$g" "$r" "$remote"
    if ((ahead > 0 || behind > 0)); then
      local ab_str=""
      ((ahead  > 0)) && ab_str+="${b}${y}↑ $ahead to push${r}  "
      ((behind > 0)) && ab_str+="${b}${red}↓ $behind to pull${r}"
      printf '%sSync%s        %s\n' "$g" "$r" "${ab_str%  }"
    else
      printf '%sSync%s        %sup to date%s\n' "$g" "$r" "$c" "$r"
    fi
  else
    printf '%sRemote%s      %s(not set — run: todosh sync init REMOTE)%s\n' \
      "$g" "$r" "$y" "$r"
  fi
  if ((dirty)); then
    local changes=""
    ((uncommitted > 0)) && changes+="${uncommitted} staged"
    ((unstaged    > 0)) && changes+="${changes:+, }${unstaged} unstaged"
    printf '%sChanges%s     %s%s — run: todosh sync push%s\n' \
      "$g" "$r" "$y" "$changes" "$r"
  else
    printf '%sChanges%s     %snone%s\n' "$g" "$r" "$g" "$r"
  fi
}
