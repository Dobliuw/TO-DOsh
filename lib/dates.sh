# shellcheck shell=bash disable=SC2034
# dates.sh — due dates and human-friendly times.
#
# Due dates are calendar days in the user's local time, stored as YYYY-MM-DD.
# Instants (created, history...) are UTC timestamps; see core.sh.
# SC2034: TD_JQ_DUE is used by the presentation code in other modules.

# td_today VAR — store today's local date (YYYY-MM-DD) in VAR.
td_today() {
  local -n _td_day=$1
  printf -v _td_day '%(%F)T' -1
}

# td_due_valid DATE — a real calendar date in YYYY-MM-DD form.
td_due_valid() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [[ $(date -d "$1" +%F 2>/dev/null) == "$1" ]]
}

# td_due_parse VAR INPUT — normalize a due date given by the user into VAR
# (YYYY-MM-DD, or "" for none/clear). Accepts:
#   today, tomorrow, yesterday, mon..sun / monday..sunday (today counts),
#   +3d, +2w, +1m, YYYY-MM-DD, and other phrases GNU date understands
#   ("next friday", "nov 3").
td_due_parse() {
  local -n _td_due=$1
  local _td_input=${2,,} _td_expr
  _td_input=${_td_input##+([[:space:]])}
  _td_input=${_td_input%%+([[:space:]])}
  case $_td_input in
    "" | none | clear)
      _td_due=""
      return 0
      ;;
    tod) _td_input=today ;;
    tom) _td_input=tomorrow ;;
  esac
  if [[ $_td_input =~ ^\+([0-9]{1,3})([dwm])$ ]]; then
    local -A _td_units=([d]=days [w]=weeks [m]=months)
    _td_expr="+${BASH_REMATCH[1]} ${_td_units[${BASH_REMATCH[2]}]}"
  elif [[ $_td_input =~ ^[0-9]+$ || $_td_input == -* || $_td_input == *[[:cntrl:]]* ]]; then
    # Bare numbers mean a time of day to GNU date, not a date.
    _td_expr=""
  else
    _td_expr=$_td_input
  fi
  local _td_res=""
  [[ -n $_td_expr ]] && _td_res=$(LC_ALL=C date -d "$_td_expr" +%F 2>/dev/null)
  if [[ -z $_td_res ]]; then
    td_err "unrecognized date: '$2' (try: today, tomorrow, fri, +3d, 2026-11-03, none)"
    return "$TD_E_USAGE"
  fi
  _td_due=$_td_res
}

# td_fmt_duration [-v VAR] SECONDS — a compact duration: 45s, 12m, 1h05m,
# 2d3h. Printed, or stored in VAR with -v (no subshell: used per redraw).
td_fmt_duration() {
  local _td_v="" _td_s _td_r
  if [[ $1 == -v ]]; then
    _td_v=$2
    shift 2
  fi
  _td_s=$1
  if ((_td_s < 60)); then
    printf -v _td_r '%ss' "$_td_s"
  elif ((_td_s < 3600)); then
    printf -v _td_r '%sm' $((_td_s / 60))
  elif ((_td_s < 86400)); then
    printf -v _td_r '%sh%02dm' $((_td_s / 3600)) $((_td_s % 3600 / 60))
  else
    printf -v _td_r '%sd%sh' $((_td_s / 86400)) $((_td_s % 86400 / 3600))
  fi
  if [[ -n $_td_v ]]; then
    printf -v "$_td_v" '%s' "$_td_r"
  else
    printf '%s\n' "$_td_r"
  fi
}

# td_fmt_ago SECONDS — print how long ago: just now, 5m ago, 3h ago, 2d ago.
td_fmt_ago() {
  local s=$1
  if ((s < 60)); then
    printf 'just now\n'
  elif ((s < 3600)); then
    printf '%sm ago\n' $((s / 60))
  elif ((s < 86400)); then
    printf '%sh ago\n' $((s / 3600))
  else
    printf '%sd ago\n' $((s / 86400))
  fi
}

# jq definitions for due-date display; prepend to a jq program and pass
# --arg today YYYY-MM-DD. due_info gives {text, state} or null, where state is
# overdue | today | soon | later. Closed tasks are never "overdue".
# shellcheck disable=SC2016 # jq code: $today is a jq variable
readonly TD_JQ_DUE='
def _day: strptime("%Y-%m-%d") | mktime;
def due_days: if .due == null then null else ((.due | _day) - ($today | _day)) / 86400 | floor end;
def due_info:
  due_days as $d
  | if $d == null then null
    elif .status == "DONE" or .status == "CANCELLED" then {text: .due, state: "later"}
    elif $d < 0 then {text: "\(-$d)d late", state: "overdue"}
    elif $d == 0 then {text: "today", state: "today"}
    elif $d == 1 then {text: "tomorrow", state: "soon"}
    elif $d < 7 then {text: (.due | _day | strftime("%a") | ascii_downcase), state: "soon"}
    elif (.due[0:4]) == ($today[0:4]) then {text: (.due | _day | strftime("%b %-d")), state: "later"}
    else {text: .due, state: "later"}
    end;
'
