#!/usr/bin/env bats
# Themes, color tiers and kitty import (lib/theme.sh), plus `todosh theme`.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  td_test_setup
  td_load_lib
  td_paths_init
  td_config_load
}

@test "built-in themes are listed; user themes override them" {
  run td_theme_list
  [[ $output == *$'tokyonight\tbuilt-in'* ]]
  [[ $output == *$'nord\tbuilt-in'* ]]
  mkdir -p "$TD_CONFIG_DIR/themes"
  printf 'fg = #ffffff\n' >"$TD_CONFIG_DIR/themes/nord.theme"
  run td_theme_list
  [[ $output == *$'nord\tuser'* ]]
  [[ $output != *$'nord\tbuilt-in'* ]]
}

@test "loading a theme: values, defaults for missing keys, warnings" {
  mkdir -p "$TD_CONFIG_DIR/themes"
  printf '# mine\nfg = #FFFFFF\nbogus = #000000\nred = not-a-color\n' >"$TD_CONFIG_DIR/themes/mine.theme"
  run td_theme_load mine
  [[ $output == *"unknown key 'bogus'"* ]]
  [[ $output == *"line 4: expected"* ]]
  td_theme_load mine 2>/dev/null
  [ "${TD_THEME[fg]}" = "#ffffff" ]
  [ "${TD_THEME[red]}" = "${TD_THEME_DEFAULTS[red]}" ]
  run td_theme_load missing
  [ "$status" -eq 3 ]
  run td_theme_load "../etc"
  [ "$status" -eq 2 ]
}

@test "SGR sequences per color tier" {
  td_theme_load tokyonight
  TD_TIER=3 td_theme_sgr
  [ "${TD_TC[fg]}" = $'\e[38;2;192;202;245m' ]
  [ "${TD_TC[sel]}" = $'\e[48;2;40;52;88m' ]
  TD_TIER=2
  td_theme_sgr
  [[ ${TD_TC[fg]} =~ ^$'\e'\[38\;5\;[0-9]+m$ ]]
  TD_TIER=1
  td_theme_sgr
  [ "${TD_TC[red]}" = $'\e[31m' ]
  [ "${TD_TC[sel]}" = $'\e[7m' ]
  TD_TIER=0
  td_theme_sgr
  [ -z "${TD_TC[red]}" ]
  [ "${TD_TC[sel]}" = $'\e[7m' ]
}

@test "hex to xterm-256" {
  [ "$(td_hex_to_256 '#000000')" = 16 ]
  [ "$(td_hex_to_256 '#ffffff')" = 231 ]
  [ "$(td_hex_to_256 '#ff0000')" = 196 ]
  [ "$(td_hex_to_256 '#5f87af')" = 67 ]
}

@test "color tier detection" {
  COLORTERM=truecolor td_color_tier
  [ "$TD_TIER" = 3 ]
  TERM=xterm-kitty COLORTERM='' td_color_tier
  [ "$TD_TIER" = 3 ]
  TD_OPT_COLOR=never COLORTERM=truecolor td_color_tier
  [ "$TD_TIER" = 0 ]
  TERM=dumb COLORTERM='' td_color_tier
  [ "$TD_TIER" = 0 ]
}

@test "kitty import follows includes and maps the palette" {
  local k="$BATS_TEST_TMPDIR/kitty"
  mkdir -p "$k"
  printf 'font_size 13\ninclude colors.ini\nforeground #ABCDEF\n' >"$k/kitty.conf"
  printf 'color1 #f7768e\ncolor4 #7aa2f7\ncolor8 #414868\nselection_background #28344a\nurl_color #61afef\n' \
    >"$k/colors.ini"
  td_theme_import_kitty "$k/kitty.conf"
  [ "$TD_RESULT" = "$TD_CONFIG_DIR/themes/kitty.theme" ]
  td_theme_load kitty
  [ "${TD_THEME[fg]}" = "#abcdef" ]
  [ "${TD_THEME[red]}" = "#f7768e" ]
  [ "${TD_THEME[accent]}" = "#7aa2f7" ]
  [ "${TD_THEME[muted]}" = "#414868" ]
  [ "${TD_THEME[selection]}" = "#28344a" ]
  # Missing roles keep the defaults.
  [ "${TD_THEME[green]}" = "${TD_THEME_DEFAULTS[green]}" ]
}

@test "kitty import errors" {
  run td_theme_import_kitty "$BATS_TEST_TMPDIR/none.conf"
  [ "$status" -eq 3 ]
  printf 'font_size 13\n' >"$BATS_TEST_TMPDIR/k.conf"
  run td_theme_import_kitty "$BATS_TEST_TMPDIR/k.conf"
  [ "$status" -eq 3 ]
  [[ $output == *"no colors found"* ]]
}

@test "td_config_set replaces the key and keeps comments and other lines" {
  td_write_config "# my settings" "theme = nord   " "archive_after_days = 3"
  td_config_set theme gruvbox
  [ "$(cat "$HOME/.config/todosh/config")" = $'# my settings\ntheme = gruvbox\narchive_after_days = 3' ]
  td_config_set icons ascii
  [[ $(tail -n 1 "$HOME/.config/todosh/config") == "icons = ascii" ]]
  run td_config_set theme "bad name"
  [ "$status" -eq 2 ]
  run td_config_set nope x
  [ "$status" -eq 2 ]
}

@test "theme command: list, show, set, import" {
  run todosh theme
  [[ $output == *"* tokyonight"* ]]
  run todosh theme set gruvbox
  [ "$output" = "Theme set to gruvbox" ]
  run todosh theme list
  [[ $output == *"* gruvbox"* ]]
  run --separate-stderr todosh theme show nord --json
  jq -e '.name == "nord" and .colors.fg == "#d8dee9"' <<<"$output"
  run todosh theme set nope
  [ "$status" -eq 3 ]
  local k="$BATS_TEST_TMPDIR/kitty.conf"
  printf 'foreground #c0caf5\ncolor4 #7aa2f7\n' >"$k"
  run todosh theme import kitty "$k"
  [ "$status" -eq 0 ]
  [[ $output == *"Theme set to kitty"* ]]
  run todosh theme import alacritty
  [ "$status" -eq 2 ]
}

@test "painted backgrounds never equal the theme color exactly (kitty transparency)" {
  td_theme_load tokyonight
  TD_TIER=3 td_theme_sgr
  # #1a1b26 is also kitty's background: painted as #1a1b27 to stay opaque.
  [ "${TD_TB[bg]}" = $'\e[48;2;26;27;39m' ]
  # Foregrounds keep the exact theme colors.
  [ "${TD_TC[bg]}" = $'\e[38;2;26;27;38m' ]
  [ "$(_td_rgb_opaque '#0000ff')" = "0;0;254" ]
}

@test "background = terminal keeps the terminal background in the main area" {
  td_theme_load tokyonight
  TD_TIER=3 td_theme_sgr
  TD_CONF["background"]=terminal
  _tui_colors
  [[ ${TUI_B[main]} != *"48;2"* ]]
  [[ ${TUI_B[modal]} == *"48;2"* ]]
  TD_CONF["background"]=solid
  _tui_colors
  [[ ${TUI_B[main]} == *$'\e[48;2;26;27;39m'* ]]
}
