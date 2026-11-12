#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables are used by sourced scripts.
# file: minx_variables.sh

if ((EUID == 0)); then
	printf '%s\n' "=> Run this as a non-root user." >&2
	# Return when sourced, exit when executed directly.
	# shellcheck disable=SC2317 # exit is reached when executed, not sourced.
	return 1 2>/dev/null || exit 1
fi

[[ -n "${__MINX_VARIABLES_LOADED:-}" ]] && return
__MINX_VARIABLES_LOADED=1

# declare -r already makes these read-only.
declare -Ar MINX_CONTROL_OPTIONS=(
	[__root]="brightness bluetooth display favorites keyboard lockscreen media microphone screenshot sysinfo touchpad volume wifi"

	[brightness]="inc dec set"
	[bluetooth]="manager on off"
	[display]=""
	[favorites]=""
	[keyboard]="us de"
	[lockscreen]="on off lock"
	[media]="play-pause previous next stop"
	[microphone]=""
	[screenshot]=""
	[sysinfo]="all bluetooth keyboard lockscreen system touchpad volume wifi"
	[touchpad]="on off"
	[volume]="inc dec set toggle-mute"
	[wifi]="manager reset on off"
)

declare -Ar MINX_LAUNCHER_OPTIONS=(
	[__root]="file_explorer terminal tmux_sessions txtclip inkscape tigervnc nmtui qb_profiles qb_profile1 qb_profile2 qb_profile3 qb_profile4 custom1 custom2 mail tt_shell calendar reference notes synchronize maps remote1 remote2 otpmenu passmenu"
)

MINX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/minx"

mkdir -p "$MINX_STATE_DIR" || {
	printf 'ERROR: Cannot create state directory: %s\n' "$MINX_STATE_DIR" >&2
	return 1
}

readonly MINX_STATE_DIR

MINX_STATE_BATTERY="$MINX_STATE_DIR/battery.state"
MINX_STATE_KEYBOARD="$MINX_STATE_DIR/keyboard.state"
MINX_STATE_COUNTDOWN="$MINX_STATE_DIR/countdown.state"
MINX_STATE_LOCKSCREEN="$MINX_STATE_DIR/lockscreen.state"
MINX_STATE_TOUCHPAD="$MINX_STATE_DIR/touchpad.state"

readonly MINX_STATE_BATTERY
readonly MINX_STATE_KEYBOARD
readonly MINX_STATE_COUNTDOWN
readonly MINX_STATE_LOCKSCREEN
readonly MINX_STATE_TOUCHPAD

# Supported values:
#   alsamixer   amixer (needs a "Master" control; with PipeWire this requires
#               pipewire-alsa)
#   pulseaudio  pactl
#   pipewire    wpctl (volume capped at 100%)
readonly MINX_AUDIO_BACKEND="${MINX_AUDIO_BACKEND:-pipewire}"

# Terminal used to run TUI programs from keybindings (nmtui, $EDITOR, ...).
readonly MINX_TERMINAL="${MINX_TERMINAL:-st}"

readonly MINX_USER_DIR="/opt/minx/runtime/user"
readonly MINX_USER_TARGETS_FILE="$MINX_USER_DIR/hooks/user_launcher_targets.sh"
readonly MINX_USER_LOCKSCREEN_BGS="$MINX_USER_DIR/hooks/user_lockscreen_background.sh"
