# shellcheck shell=bash
# config.sh — XDG paths and the user configuration file.
#
# The config file is `key = value` lines. It is parsed as data, line by line:
# it is never sourced or eval'ed, so a value can never execute code.

declare -gA TD_CONF=()
declare -g TD_CONFIG_DIR="" TD_CONFIG_FILE="" TD_DATA_DIR=""

# Defaults; also the whitelist of known keys.
declare -grA TD_CONF_DEFAULTS=(
  [theme]=tokyonight
  [color]=auto
  [icons]=auto
  [default_project]=inbox
  [archive_after_days]=7
  [editor]=""
)

# td_config_valid KEY VALUE — succeed if VALUE is acceptable for KEY.
td_config_valid() {
  local key=$1 value=$2
  case $key in
    theme | default_project) td_valid_name "$value" ;;
    color) td_in_list "$value" auto always never ;;
    icons) td_in_list "$value" auto nerd unicode ascii ;;
    archive_after_days) [[ $value =~ ^(0|[1-9][0-9]{0,3})$ ]] ;;
    editor) [[ $value != *[[:cntrl:]]* ]] ;;
    *) return 1 ;;
  esac
}

# td_paths_init — resolve configuration and data directories.
# Precedence: TODOSH_*_DIR, then XDG_*_HOME, then the XDG defaults under $HOME.
td_paths_init() {
  local config_base data_base
  if [[ -z ${HOME:-} ]] \
    && [[ -z ${TODOSH_CONFIG_DIR:-}${XDG_CONFIG_HOME:-} || -z ${TODOSH_DATA_DIR:-}${XDG_DATA_HOME:-} ]]; then
    td_err "HOME is not set; set TODOSH_CONFIG_DIR and TODOSH_DATA_DIR"
    return "$TD_E_ERR"
  fi
  config_base=${XDG_CONFIG_HOME:-${HOME:-}/.config}
  data_base=${XDG_DATA_HOME:-${HOME:-}/.local/share}
  TD_CONFIG_DIR=${TODOSH_CONFIG_DIR:-$config_base/todosh}
  TD_DATA_DIR=${TODOSH_DATA_DIR:-$data_base/todosh}

  local dir
  for dir in "$TD_CONFIG_DIR" "$TD_DATA_DIR"; do
    if [[ $dir != /* ]]; then
      td_err "directory must be an absolute path: $dir"
      return "$TD_E_ERR"
    fi
  done
  # Normalize trailing slashes so later path checks compare cleanly.
  TD_CONFIG_DIR=${TD_CONFIG_DIR%%+(/)}
  TD_DATA_DIR=${TD_DATA_DIR%%+(/)}
  : "${TD_CONFIG_DIR:=/}" "${TD_DATA_DIR:=/}"
  TD_CONFIG_FILE=$TD_CONFIG_DIR/config
}

# td_config_load — fill TD_CONF from defaults, then from the config file if present.
# Problems in the file are warnings: a bad line never prevents the program from running.
td_config_load() {
  local key
  TD_CONF=()
  for key in "${!TD_CONF_DEFAULTS[@]}"; do
    TD_CONF[$key]=${TD_CONF_DEFAULTS[$key]}
  done
  [[ -e $TD_CONFIG_FILE ]] || return 0
  if [[ ! -f $TD_CONFIG_FILE || ! -r $TD_CONFIG_FILE ]]; then
    td_warn "cannot read config file: $TD_CONFIG_FILE (using defaults)"
    return 0
  fi

  local line value lineno=0
  local re='^([a-z_]+)[[:space:]]*=[[:space:]]*(.*)$'
  while IFS= read -r line || [[ -n $line ]]; do
    ((++lineno))
    line=${line%$'\r'}
    line=${line##+([[:space:]])}
    line=${line%%+([[:space:]])}
    [[ -z $line || $line == '#'* ]] && continue
    if [[ ! $line =~ $re ]]; then
      td_warn "config line $lineno: expected 'key = value'"
      continue
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    if [[ ! -v TD_CONF_DEFAULTS[$key] ]]; then
      td_warn "config line $lineno: unknown key '$key'"
    elif ! td_config_valid "$key" "$value"; then
      td_warn "config line $lineno: invalid value for '$key' (keeping '${TD_CONF[$key]}')"
    else
      TD_CONF[$key]=$value
    fi
  done <"$TD_CONFIG_FILE"
}

# td_config_keys — print known keys, sorted.
td_config_keys() {
  printf '%s\n' "${!TD_CONF_DEFAULTS[@]}" | LC_ALL=C sort
}
