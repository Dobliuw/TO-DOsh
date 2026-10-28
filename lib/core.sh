# shellcheck shell=bash disable=SC2034
# core.sh — exit codes, diagnostics, validation and small shared utilities.
#
# SC2034 is disabled file-wide: the constants and globals defined here are
# used by the other modules, which ShellCheck analyzes one file at a time.
#
# Error-handling convention (see docs/DEVELOPMENT.md): library functions never
# call `exit`. They report through td_err and `return` one of the TD_E_* codes;
# only the CLI layer turns a code into a process exit status.

readonly TD_VERSION="0.1.0-dev"

readonly TD_E_OK=0
readonly TD_E_ERR=1
readonly TD_E_USAGE=2
readonly TD_E_NOTFOUND=3
readonly TD_E_CONFLICT=4

readonly TD_STATUSES=(TODO IN_PROGRESS BLOCKED DONE CANCELLED)
readonly TD_PRIORITIES=(urgent high med low)

# Last error message, so the TUI can show it without reading stderr.
TD_LAST_ERROR=""
# When 1, td_err only records the message (used by the TUI).
TD_QUIET_ERRORS=${TD_QUIET_ERRORS:-0}

# td_err MESSAGE... — report an error on stderr.
td_err() {
  TD_LAST_ERROR="$*"
  if [[ $TD_QUIET_ERRORS != 1 ]]; then
    printf 'todosh: %s\n' "$*" >&2
  fi
}

# td_warn MESSAGE... — non-fatal diagnostic on stderr.
td_warn() {
  if [[ $TD_QUIET_ERRORS != 1 ]]; then
    printf 'todosh: warning: %s\n' "$*" >&2
  fi
}

# td_require_cmds CMD... — fail if any external command is missing.
td_require_cmds() {
  local cmd missing=()
  for cmd in "$@"; do
    command -v -- "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    td_err "missing required command(s): ${missing[*]}"
    return "$TD_E_ERR"
  fi
}

# td_now_utc VAR — store the current UTC time (ISO 8601, second precision) in VAR.
td_now_utc() {
  local -n _td_out=$1
  # printf %(...)T is a builtin: no fork, and TZ only affects this call.
  TZ=UTC0 printf -v _td_out '%(%Y-%m-%dT%H:%M:%SZ)T' -1
}

# td_in_list NEEDLE ITEM... — succeed if NEEDLE equals one of the items.
td_in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

# --- validation ------------------------------------------------------------
# Validators only test; callers decide how to report.

# Positive decimal without leading zeros, at most 9 digits.
td_valid_id() {
  [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]
}

td_valid_status() {
  td_in_list "$1" "${TD_STATUSES[@]}"
}

td_valid_priority() {
  td_in_list "$1" "${TD_PRIORITIES[@]}"
}

# Tag and theme names: short, shell- and filename-friendly.
td_valid_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]
}

# Projects are paths of up to 4 segments ("HardwareHacking/RF & SDR"). A
# segment: 1-32 characters, no "/", no control characters, no leading or
# trailing space, not "." or "..". Spaces and symbols are fine: names are
# never used as file names.
td_valid_project() {
  local path=$1 seg
  local -a segs
  [[ -n $path && $path != /* && $path != */ && $path != *//* ]] || return 1
  [[ $path != *[[:cntrl:]]* ]] || return 1
  IFS=/ read -ra segs <<<"$path"
  ((${#segs[@]} <= 4)) || return 1
  for seg in "${segs[@]}"; do
    ((${#seg} >= 1 && ${#seg} <= 32)) || return 1
    [[ $seg != " "* && $seg != *" " && $seg != . && $seg != .. ]] || return 1
  done
}

# Titles: non-empty, single line, no control characters, <= 200 characters.
td_valid_title() {
  local title=$1
  [[ -n ${title//[[:space:]]/} ]] || return 1
  ((${#title} <= 200)) || return 1
  [[ $title != *[[:cntrl:]]* ]]
}

# Free text (comments, descriptions): may span lines; no other control chars.
td_valid_text() {
  local text=${1//$'\n'/}
  text=${text//$'\t'/}
  [[ $text != *[[:cntrl:]]* ]]
}
