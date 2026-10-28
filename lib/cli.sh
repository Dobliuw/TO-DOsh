# shellcheck shell=bash disable=SC2034
# cli.sh — argument parsing, command dispatch and CLI presentation.
#
# Commands are functions named td_cmd_<name>, registered with td_register_cmd so
# that help output and dispatch stay in sync. Each command may define
# td_help_<name> for `todosh <name> --help`. Task commands live in commands.sh.

declare -ga TD_CMD_ORDER=()
declare -gA TD_CMD_SUMMARY=() TD_CMD_GROUP=()
# Order of the groups in `todosh help`.
readonly TD_CMD_GROUPS=(Tasks Status History Trash General)

# Global output options, set by td_main. These globals are read by other
# modules (SC2034 is disabled for this file because of that).
TD_OPT_JSON=0
TD_OPT_COLOR=auto
# Name of the command being run, for usage messages.
TD_CMD=""

# td_register_cmd NAME GROUP SUMMARY
td_register_cmd() {
  TD_CMD_ORDER+=("$1")
  TD_CMD_GROUP[$1]=$2
  TD_CMD_SUMMARY[$1]=$3
}

# td_usage_err CMD MESSAGE — report invalid usage of CMD.
td_usage_err() {
  td_err "$2"
  printf "Try 'todosh %s--help'.\n" "${1:+$1 }" >&2
  return "$TD_E_USAGE"
}

# td_main ARG... — program entry point; returns the process exit status.
td_main() {
  # Global flags may appear anywhere before `--`; everything after `--` is literal.
  local -a args=()
  local arg literal=0
  for arg in "$@"; do
    if ((literal)); then
      args+=("$arg")
      continue
    fi
    case $arg in
      --json) TD_OPT_JSON=1 ;;
      --no-color) TD_OPT_COLOR=never ;;
      --)
        literal=1
        args+=("$arg")
        ;;
      *) args+=("$arg") ;;
    esac
  done
  set -- "${args[@]}"
  [[ -n ${NO_COLOR:-} ]] && TD_OPT_COLOR=never

  # Bare `todosh` lists tasks; on an interactive terminal it will open the
  # TUI once that exists (phase 4).
  local cmd=list
  if (($#)); then
    cmd=$1
    shift
  fi
  case $cmd in
    -h | --help) cmd=help ;;
    -V | --version) cmd=version ;;
    -*) td_usage_err "" "unknown option: $cmd" || return ;;
  esac
  if [[ ! -v TD_CMD_SUMMARY[$cmd] ]]; then
    td_usage_err "" "unknown command: $cmd" || return
  fi

  TD_CMD=$cmd
  if [[ $cmd != help && $cmd != version ]]; then
    td_require_cmds jq || return
    td_paths_init || return
    td_config_load
    td_term_init
  fi
  "td_cmd_$cmd" "$@"
}

# td_wants_help ARG... — succeed if the first argument asks for help.
td_wants_help() {
  [[ ${1:-} == -h || ${1:-} == --help ]]
}

# --- help ------------------------------------------------------------------

td_register_cmd help General "Show help for todosh or for one command"
td_cmd_help() {
  if (($# > 0)); then
    local name=$1
    if [[ ! -v TD_CMD_SUMMARY[$name] ]]; then
      td_usage_err "" "unknown command: $name"
      return
    fi
    if declare -F "td_help_$name" >/dev/null; then
      "td_help_$name"
    else
      printf 'Usage: todosh %s\n\n%s\n' "$name" "${TD_CMD_SUMMARY[$name]}"
    fi
    return 0
  fi

  local name group
  printf '%s\n' \
    "todosh — terminal task manager" \
    "" \
    "Usage:" \
    "  todosh                    List tasks (the TUI will open here)" \
    "  todosh <command> [args] [--json] [--no-color]"
  for group in "${TD_CMD_GROUPS[@]}"; do
    printf '\n%s:\n' "$group"
    for name in "${TD_CMD_ORDER[@]}"; do
      [[ ${TD_CMD_GROUP[$name]} == "$group" ]] || continue
      printf '  %-12s %s\n' "$name" "${TD_CMD_SUMMARY[$name]}"
    done
  done
  printf '%s\n' \
    "" \
    "Global options:" \
    "  --json       Machine-readable output (only JSON on stdout)" \
    "  --no-color   Disable colors (also honored: NO_COLOR=1)" \
    "  -h, --help   Show help;  todosh <command> --help for details" \
    "  -V, --version" \
    "" \
    "Environment:" \
    "  TODOSH_CONFIG_DIR   Config directory (default: \$XDG_CONFIG_HOME/todosh)" \
    "  TODOSH_DATA_DIR     Data directory   (default: \$XDG_DATA_HOME/todosh)" \
    "" \
    "Exit codes: 0 ok, 1 error, 2 usage, 3 not found, 4 conflict/locked"
}

# --- version ---------------------------------------------------------------

td_register_cmd version General "Print the todosh version"
td_cmd_version() {
  if ((TD_OPT_JSON)); then
    td_require_cmds jq || return
    jq -n --arg v "$TD_VERSION" '{version: $v}'
  else
    printf 'todosh %s\n' "$TD_VERSION"
  fi
}

# --- config ----------------------------------------------------------------

td_register_cmd config General "Show configuration and file locations"
td_help_config() {
  printf '%s\n' \
    "Usage: todosh config [show|path]" \
    "" \
    "  show   Print effective settings and directories (default)" \
    "  path   Print the config file path" \
    "" \
    "The config file holds 'key = value' lines; '#' starts a comment line." \
    "" \
    "Settings:" \
    "  theme               Color theme name (default: tokyonight)" \
    "  color               auto | always | never (default: auto)" \
    "  icons               auto | nerd | unicode | ascii (default: auto)" \
    "  default_project     Project for tasks added without one (default: inbox)" \
    "  archive_after_days  Days after which DONE/CANCELLED tasks leave the main" \
    "                      view; they stay searchable and restorable. 0 = never" \
    "                      (default: 7)" \
    "  editor              Command to edit descriptions (default: \$VISUAL," \
    "                      then \$EDITOR, then vi)" \
    "" \
    "Example:" \
    "  theme = tokyonight" \
    "  archive_after_days = 14"
}

td_cmd_config() {
  if td_wants_help "$@"; then
    td_help_config
    return 0
  fi
  local sub=${1:-show}
  (($#)) && shift
  if (($#)); then
    td_usage_err config "unexpected argument: $1"
    return
  fi
  case $sub in
    show) _td_config_show ;;
    path) printf '%s\n' "$TD_CONFIG_FILE" ;;
    *) td_usage_err config "unknown subcommand: $sub" ;;
  esac
}

_td_config_show() {
  local key exists=false
  [[ -f $TD_CONFIG_FILE ]] && exists=true

  if ((TD_OPT_JSON)); then
    local -a pairs=()
    for key in "${!TD_CONF[@]}"; do
      pairs+=(--arg "$key" "${TD_CONF[$key]}")
    done
    jq -n \
      --arg config_dir "$TD_CONFIG_DIR" --arg config_file "$TD_CONFIG_FILE" \
      --arg data_dir "$TD_DATA_DIR" --argjson exists "$exists" \
      --argjson settings "$(jq -nS '$ARGS.named | .archive_after_days |= tonumber' "${pairs[@]}")" \
      '{paths: {config_dir: $config_dir, config_file: $config_file,
                config_file_exists: $exists, data_dir: $data_dir},
        settings: $settings}'
    return
  fi

  local note=""
  [[ $exists == false ]] && note=" (not found, using defaults)"
  printf 'Config file  %s%s\n' "$TD_CONFIG_FILE" "$note"
  printf 'Data dir     %s\n\n' "$TD_DATA_DIR"
  while IFS= read -r key; do
    printf '%-20s = %s\n' "$key" "${TD_CONF[$key]}"
  done < <(td_config_keys)
}
