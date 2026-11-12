#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
#
# minx_control.sh
#
# Core functionality for minx-control.
#
# Avoid "set -e": explicit error handling keeps control flow predictable.
# Avoid "set -o pipefail": pipeline status is handled explicitly where needed.
#
# Settings (MINX_AUDIO_BACKEND, MINX_TERMINAL) live in minx_variables.sh.

[[ -n "${__MINX_CONTROL_LOADED:-}" ]] && return
__MINX_CONTROL_LOADED=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1

source "$SCRIPT_DIR/minx_core.sh" || return 1
source "$SCRIPT_DIR/minx_variables.sh" || return 1

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

_update_xsetroot() { # {{{
	if minx_has_display && [[ -x "$HOME/.xsetroot.sh" ]]; then
		"$HOME/.xsetroot.sh" "$1"
	else
		return 0
	fi
} # }}}

_list_control_options() { # {{{
	local group="${1:-__root}"
	local options="${MINX_CONTROL_OPTIONS[$group]-}"

	[[ -n "$options" ]] && tr -s ' ' '\n' <<<"$options"
} # }}}

# _require cmd...: notify and fail if a command is missing.
_require() { # {{{
	local cmd

	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 && continue
		minx_notify "[ERROR] ${FUNCNAME[1]}" "$cmd is not installed."
		return 1
	done
} # }}}

# _choose group [prompt]: rofi menu; fails (quietly) on cancel.
_choose() { # {{{

	if ! minx_has_display; then
		printf '%s\n' "No display available to launch rofi. Use autocompletion instead." >&2
		return 1
	fi

	local choice

	choice=$(
		_list_control_options "$1" |
			rofi -dmenu -p "${2:-$1}"
	) || return 1

	[[ -n "$choice" ]] || return 1
	printf '%s\n' "$choice"
} # }}}

# _is_valid_option group value
_is_valid_option() { # {{{
	local option

	while IFS= read -r option; do
		[[ "$option" == "$2" ]] && return 0
	done < <(_list_control_options "$1")

	return 1
} # }}}

# _usage group: show valid arguments (terminal -> stderr, otherwise notify).
_usage() { # {{{
	local msg

	msg=$(
		printf '%s\n' "Valid arguments:"
		_list_control_options "$1"
	)

	if [[ -t 2 ]]; then
		printf '\n%s\n' "$msg" >&2
	else
		minx_notify "[ERROR] ${FUNCNAME[1]}" "$msg"
	fi

	return 1
} # }}}

_touchpad_id() { # {{{
	xinput list 2>/dev/null |
		sed -n '/[Tt]ouch[Pp]ad/s/.*id=\([0-9]\+\).*/\1/p' |
		head -n 1
} # }}}

# Prints: alsa | wpctl | pactl
_audio_backend() { # {{{
	case "$MINX_AUDIO_BACKEND" in
	alsamixer) printf '%s\n' alsa ;;
	pulseaudio) printf '%s\n' pactl ;;
	pipewire) printf '%s\n' wpctl ;;
	*) printf '%s\n' pactl ;;
	esac
} # }}}

# Run a TUI program in a terminal (keybindings have no tty).
_run_in_terminal() { # {{{
	local term="$MINX_TERMINAL"

	_require "$term" || return 1
	"$term" -e "$@"
} # }}}

# -----------------------------------------------------------------------------
# Controls
# -----------------------------------------------------------------------------

minx_brightness() { # {{{
	local action="${1:-}"
	local value="${2:-5}"
	local device

	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		minx_notify "[ERROR] minx_brightness" \
			"Brightness value must be a non-negative integer."
		return 1
	fi

	if ((value > 100)); then
		minx_notify "[ERROR] minx_brightness" \
			"Brightness value must not exceed 100."
		return 1
	fi

	case "$action" in
	inc | dec | set) ;;
	*)
		_usage brightness
		return 1
		;;
	esac

	if command -v brightnessctl >/dev/null 2>&1 &&
		device=$(minx_get_backlight_device 2>/dev/null); then

		# -n: never go below the minimum value (avoids a black screen).
		case "$action" in
		inc) brightnessctl -d "$device" set "+${value}%" || return 1 ;;
		dec) brightnessctl -n -d "$device" set "${value}%-" || return 1 ;;
		set) brightnessctl -n -d "$device" set "${value}%" || return 1 ;;
		esac

	elif command -v xbacklight >/dev/null 2>&1; then
		case "$action" in
		inc) xbacklight -inc "$value" || return 1 ;;
		dec) xbacklight -dec "$value" || return 1 ;;
		set) xbacklight -set "$value" || return 1 ;;
		esac

	else
		minx_notify \
			"[ERROR] minx_brightness" \
			"No supported backlight controller found."
		return 1
	fi

	_update_xsetroot brightness
} # }}}

minx_bluetooth() { # {{{
	local option="${1:-}"

	[[ -n "$option" ]] || option=$(_choose bluetooth) || return 0

	case "$option" in
	on)
		_require bluetoothctl || return 1

		if ! { bluetoothctl power on >/dev/null; }; then
			minx_notify "[ERROR] bluetooth" "Could not enable Bluetooth."
			return 1
		fi
		;;

	off)
		_require bluetoothctl || return 1

		if ! { bluetoothctl power off >/dev/null; }; then
			minx_notify "[ERROR] bluetooth" "Could not disable Bluetooth."
			return 1
		fi
		;;

	manager)
		_require blueman-manager || return 1
		blueman-manager || return 1
		return 0
		;;

	*)
		_usage bluetooth
		return 1
		;;
	esac

	minx_notify "bluetooth" "$option"
	_update_xsetroot bluetooth
} # }}}

minx_display() { # {{{
	local -a displays=()
	local -a xrandr_args=()
	local -a menu=()
	local selection
	local display
	local previous=""

	_require xrandr || return 1

	mapfile -t displays < <(
		xrandr 2>/dev/null |
			awk '$2 == "connected" {print $1}'
	)

	if ((${#displays[@]} == 0)); then
		minx_notify "[ERROR] minx_display" "No connected displays found."
		return 1
	fi

	if ((${#displays[@]} == 1)); then
		minx_notify "display" "Only one display connected: ${displays[0]}"
		return 0
	fi

	for display in "${displays[@]}"; do
		menu+=("only $display")
	done
	menu+=("extend" "mirror")

	selection=$(
		printf '%s\n' "${menu[@]}" |
			rofi -dmenu -p "display"
	) || return 0

	[[ -n "$selection" ]] || return 0

	case "$selection" in
	"only "*)
		display="${selection#only }"

		for selection in "${displays[@]}"; do
			if [[ "$selection" == "$display" ]]; then
				xrandr_args+=(--output "$selection" --auto)
			else
				xrandr_args+=(--output "$selection" --off)
			fi
		done
		selection="only $display"
		;;

	extend)
		for display in "${displays[@]}"; do
			if [[ -z "$previous" ]]; then
				xrandr_args+=(--output "$display" --auto)
			else
				xrandr_args+=(--output "$display" --auto --right-of "$previous")
			fi
			previous="$display"
		done
		;;

	mirror)
		for display in "${displays[@]}"; do
			if [[ -z "$previous" ]]; then
				xrandr_args+=(--output "$display" --auto)
				previous="$display"
			else
				xrandr_args+=(--output "$display" --auto --same-as "$previous")
			fi
		done
		;;

	*)
		minx_notify "[ERROR] minx_display" "Invalid selection: $selection"
		return 1
		;;
	esac

	if ! xrandr "${xrandr_args[@]}"; then
		minx_notify \
			"[ERROR] minx_display" \
			"Could not configure display: $selection"
		return 1
	fi

	minx_notify "display" "$selection"
	_update_xsetroot display
} # }}}

minx_favorites() { # {{{
	local favorites_dir="$MINX_USER_DIR/data/favorites"
	local file
	local selection
	local selected_path
	local -a options=()

	if [[ ! -d "$favorites_dir" ]]; then
		minx_notify \
			"[ERROR] minx_favorites" \
			"Directory not found: $favorites_dir"
		return 1
	fi

	while IFS= read -r -d '' file; do
		case "${file,,}" in
		*.pdf | *.md | *.jpg | *.jpeg | *.png | *.txt | *.log)
			options+=("${file##*/}")
			;;
		esac
	done < <(
		find "$favorites_dir" \
			-maxdepth 1 \
			-type f \
			-print0
	)

	if ((${#options[@]} == 0)); then
		minx_notify \
			"[ERROR] minx_favorites" \
			"No favorite files found."
		return 1
	fi

	selection=$(
		printf '%s\n' "${options[@]}" |
			sort -f |
			rofi -dmenu -i -p "favorites:"
	) || return 0

	[[ -n "$selection" ]] || return 0

	selected_path="$favorites_dir/$selection"

	if [[ ! -f "$selected_path" ]]; then
		minx_notify \
			"[ERROR] minx_favorites" \
			"Invalid selection: $selection"
		return 1
	fi

	case "${selection,,}" in
	*.pdf | *.jpg | *.jpeg | *.png)
		xdg-open "$selected_path" >/dev/null 2>&1 || {
			minx_notify \
				"[ERROR] minx_favorites" \
				"Could not open: $selection"
			return 1
		}
		;;

	*.md | *.txt | *.log)
		if command -v launcher.sh >/dev/null 2>&1; then
			launcher.sh editor "$selected_path" || return 1
		elif [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
			_run_in_terminal "$EDITOR" "$selected_path" || return 1
		else
			minx_notify \
				"[ERROR] minx_favorites" \
				"No editor available."
			return 1
		fi
		;;

	*)
		minx_notify \
			"[ERROR] minx_favorites" \
			"Invalid selection: $selection"
		return 1
		;;
	esac
} # }}}

minx_keyboard() { # {{{
	local option="${1:-}"

	[[ -n "$option" ]] || option=$(_choose keyboard) || return 0

	# Layouts are defined once, in MINX_CONTROL_OPTIONS[keyboard].
	if ! _is_valid_option keyboard "$option"; then
		_usage keyboard
		return 1
	fi

	_require setxkbmap || return 1

	if ! setxkbmap -layout "$option"; then
		minx_notify \
			"[ERROR] setxkbmap -layout $option" \
			"Could not be executed successfully."
		return 1
	fi

	if ! printf '%s\n' "$option" >"$MINX_STATE_KEYBOARD"; then
		minx_notify \
			"[ERROR] minx_keyboard" \
			"Cannot update $MINX_STATE_KEYBOARD"
		return 1
	fi

	minx_notify "keyboard" "$option"
	_update_xsetroot keyboard
} # }}}

# Note: "lock" only switches the display off (DPMS); it does not lock the
# session. For a real lock use slock or "loginctl lock-session".
minx_lockscreen() { # {{{
	local option="${1:-}"

	[[ -n "$option" ]] || option=$(_choose lockscreen) || return 0

	case "$option" in
	on | off)
		if ! printf '%s\n' "$option" >"$MINX_STATE_LOCKSCREEN"; then
			minx_notify \
				"[ERROR] minx_lockscreen" \
				"Cannot update $MINX_STATE_LOCKSCREEN"
			return 1
		fi
		;;

	lock)
		_require xset || return 1

		xset dpms force off >/dev/null 2>&1 || {
			minx_notify \
				"[ERROR] minx_lockscreen" \
				"Could not turn the display off."
			return 1
		}
		return 0
		;;

	*)
		_usage lockscreen
		return 1
		;;
	esac

	minx_notify "lockscreen" "$option"
	_update_xsetroot all
} # }}}

minx_media() { # {{{
	local option="${1:-}"

	[[ -n "$option" ]] || option=$(_choose media) || return 0

	_require playerctl || return 1

	case "$option" in
	play-pause | previous | next | stop)
		playerctl "$option" || return 1
		;;

	*)
		_usage media
		return 1
		;;
	esac

	_update_xsetroot media
} # }}}

minx_microphone() { # {{{
	local backend
	local muted=""
	local state

	# ALSA has no usable default-source toggle here: use the sound server.
	backend=$(_audio_backend)
	[[ "$backend" == "alsa" ]] &&
		{ command -v wpctl >/dev/null 2>&1 && backend=wpctl || backend=pactl; }

	case "$backend" in
	wpctl)
		if ! wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle; then
			minx_notify \
				"[ERROR] minx_microphone" \
				"Could not toggle the default microphone."
			return 1
		fi

		state=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)
		if [[ "$state" == *MUTED* ]]; then
			muted=yes
		elif [[ -n "$state" ]]; then
			muted=no
		fi
		;;

	*)
		_require pactl || return 1

		if ! pactl set-source-mute @DEFAULT_SOURCE@ toggle; then
			minx_notify \
				"[ERROR] minx_microphone" \
				"Could not toggle the default microphone."
			return 1
		fi

		muted=$(
			pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null |
				awk '{print $2}'
		)
		;;
	esac

	case "$muted" in
	yes) minx_notify "microphone" "Muted" ;;
	no) minx_notify "microphone" "Open" ;;
	*)
		minx_notify \
			"[ERROR] minx_microphone" \
			"Could not determine microphone state."
		return 1
		;;
	esac

	_update_xsetroot microphone
} # }}}

minx_screenshot() { # {{{
	local screenshot_dir="$HOME/.screenshots"
	local file_name
	local file_path

	_require scrot || return 1

	file_name="scr_$(date +'%y%m%d_%H%M%S_%N')"
	file_path="$screenshot_dir/$file_name.png"

	mkdir -p "$screenshot_dir" || return 1

	if ! scrot -q 100 "$file_path"; then
		minx_notify \
			"[ERROR] minx_screenshot" \
			"Screenshot failed!"
		return 1
	fi

	if command -v notify-send >/dev/null 2>&1; then
		notify-send \
			-i "$file_path" \
			"Screenshot" \
			"$file_name.png" || true
	fi

	printf '%s\n' "$file_path"
} # }}}

minx_sysinfo() { # {{{
	local input="${1:-all}"
	local key
	local value
	local output=""
	local prefix

	local touchpad
	local keyboard
	local wifi
	local bluetooth
	local lockscreen
	local cpu_usage
	local mem_usage

	local id
	local xkb
	local layout
	local variant
	local bandwidth
	local wifi_interface

	local volume
	local -a keys=(
		bluetooth
		lockscreen
		touchpad
		keyboard
		wifi
		volume
		system
	)

	local -A values=()

	[[ "$input" == "sysinfo" ]] && input="system" # old alias

	if [[ "$input" == "all" ]]; then
		input=""
	elif ! _is_valid_option sysinfo "$input"; then
		_usage sysinfo
		return 1
	fi

	# Touchpad ----------------------------------------------------------------

	id=$(_touchpad_id)
	touchpad=""

	if [[ -n "$id" ]]; then
		touchpad=$(
			xinput list-props "$id" 2>/dev/null |
				awk '/Device Enabled/ {print $NF; exit}'
		)
	fi

	case "$touchpad" in
	0) touchpad="off" ;;
	1) touchpad="on" ;;
	*) touchpad="not found" ;;
	esac

	# Keyboard ----------------------------------------------------------------

	layout=""
	variant=""

	if command -v setxkbmap >/dev/null 2>&1; then
		xkb=$(setxkbmap -query 2>/dev/null)
		layout=$(awk '/layout:/ {print $2}' <<<"$xkb")
		variant=$(awk '/variant:/ {print $2}' <<<"$xkb")
	fi

	if [[ -n "$layout" ]]; then
		keyboard="${layout}, ${variant:-none}"
	else
		keyboard="not found"
	fi

	# WiFi --------------------------------------------------------------------

	wifi="off"

	if command -v nmcli >/dev/null 2>&1 &&
		[[ "$(nmcli radio wifi 2>/dev/null)" == "enabled" ]]; then

		bandwidth=""
		wifi_interface=$(minx_get_wifi_interface 2>/dev/null || true)

		if [[ -n "$wifi_interface" ]] &&
			command -v vnstat >/dev/null 2>&1; then
			bandwidth=$(
				vnstat -i "$wifi_interface" --oneline 2>/dev/null |
					awk -F';' '{print $6}'
			)
		fi

		wifi="on  ${bandwidth:-no data}"
	fi

	# Bluetooth ---------------------------------------------------------------

	bluetooth="off"

	if command -v bluetoothctl >/dev/null 2>&1; then
		case "$(timeout 2 bluetoothctl show 2>/dev/null | awk '/Powered:/ {print $2}')" in
		yes) bluetooth="on" ;;
		no) bluetooth="off" ;;
		*) bluetooth="unknown" ;;
		esac
	fi

	# Lockscreen --------------------------------------------------------------

	if [[ ! -e "$MINX_STATE_LOCKSCREEN" ]]; then
		if ! printf '%s\n' on >"$MINX_STATE_LOCKSCREEN"; then
			minx_notify \
				"[ERROR] minx_sysinfo" \
				"Cannot initialize $MINX_STATE_LOCKSCREEN"
			return 1
		fi
	fi

	lockscreen="$(<"$MINX_STATE_LOCKSCREEN")"

	case "$lockscreen" in
	1) lockscreen="on" ;;
	0) lockscreen="off" ;;
	esac

	# CPU / memory ------------------------------------------------------------

	cpu_usage=$(minx_cpu_usage)
	mem_usage=$(minx_mem_usage_percent)

	volume=$(minx_get_volume)

	[[ "$cpu_usage" =~ ^[0-9]+$ ]] || cpu_usage=0
	[[ "$mem_usage" =~ ^[0-9]+$ ]] || mem_usage=0

	values=(
		[keyboard]="$keyboard"
		[touchpad]="$touchpad"
		[wifi]="$wifi"
		[bluetooth]="$bluetooth"
		[lockscreen]="$lockscreen"
		[volume]="${volume}%"
		[system]="$(printf 'cpu %2d%%   mem %2d%%' "$cpu_usage" "$mem_usage")"
	)

	# Output ------------------------------------------------------------------

	for key in "${keys[@]}"; do
		value="${values[$key]-}"
		[[ -n "$value" ]] || continue

		if [[ "$input" == "$key" ]]; then
			prefix="▶ "
		else
			prefix="  "
		fi

		printf -v value '%-12s %s' "$key" "$value"
		output+="${prefix}${value}"$'\n'
	done

	minx_notify "sysinfo" "$output"
} # }}}

minx_touchpad() { # {{{
	local option="${1:-}"
	local id

	_require xinput || return 1

	id=$(_touchpad_id)

	if [[ -z "$id" ]]; then
		minx_notify \
			"[ERROR] minx_touchpad" \
			"Touchpad device not found."
		return 1
	fi

	[[ -n "$option" ]] || option=$(_choose touchpad) || return 0

	case "$option" in
	on)
		if ! xinput enable "$id"; then
			minx_notify \
				"[ERROR] minx_touchpad" \
				"Could not enable touchpad."
			return 1
		fi
		;;

	off)
		if ! xinput disable "$id"; then
			minx_notify \
				"[ERROR] minx_touchpad" \
				"Could not disable touchpad."
			return 1
		fi
		;;

	*)
		_usage touchpad
		return 1
		;;
	esac

	if ! printf '%s\n' "$option" >"$MINX_STATE_TOUCHPAD"; then
		minx_notify \
			"[ERROR] minx_touchpad" \
			"Cannot update $MINX_STATE_TOUCHPAD"
		return 1
	fi

	minx_notify "touchpad" "$option"
	_update_xsetroot touchpad
} # }}}

minx_volume() { # {{{
	local action="${1:-}"
	local value="${2:-2}"
	local backend
	local volume

	case "$action" in
	inc | dec | set | toggle-mute) ;;
	*)
		_usage volume
		return 1
		;;
	esac

	if [[ "$action" != "toggle-mute" ]]; then
		if ! [[ "$value" =~ ^[0-9]+$ ]]; then
			minx_notify "[ERROR] minx_volume" \
				"Volume value must be a non-negative integer."
			return 1
		fi
		((value > 100)) && value=100
	fi

	backend=$(_audio_backend)

	case "$backend" in
	alsa)
		_require amixer || return 1

		if [[ "$action" == "toggle-mute" ]]; then
			amixer sset Master toggle >/dev/null || return 1
		else
			if [[ "$action" == "inc" || "$action" == "dec" ]]; then
				amixer sset Master unmute >/dev/null || return 1
			fi

			volume=$(minx_get_volume)
			[[ "$volume" =~ ^[0-9]+$ ]] || volume=0

			case "$action" in
			inc) volume=$((volume + value)) ;;
			dec) volume=$((volume - value)) ;;
			set) volume="$value" ;;
			esac

			((volume > 100)) && volume=100
			((volume < 0)) && volume=0

			if ! amixer sset Master "${volume}%" >/dev/null; then
				minx_notify \
					"[ERROR] minx_volume" \
					"Could not change volume."
				return 1
			fi
		fi
		;;

	wpctl)
		_require wpctl || return 1

		case "$action" in
		inc | dec)
			wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 || return 1

			if [[ "$action" == "inc" ]]; then
				wpctl set-volume -l 1.0 \
					@DEFAULT_AUDIO_SINK@ "${value}%+" || return 1
			else
				wpctl set-volume @DEFAULT_AUDIO_SINK@ \
					"${value}%-" || return 1
			fi
			;;
		set)
			wpctl set-volume -l 1.0 \
				@DEFAULT_AUDIO_SINK@ "${value}%" || return 1
			;;
		toggle-mute)
			wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle || return 1
			;;
		esac
		;;

	pactl)
		_require pactl || return 1

		if [[ "$action" == "toggle-mute" ]]; then
			pactl set-sink-mute @DEFAULT_SINK@ toggle || return 1
		else
			if [[ "$action" == "inc" || "$action" == "dec" ]]; then
				pactl set-sink-mute @DEFAULT_SINK@ 0 || return 1
			fi

			volume=$(minx_get_volume)
			[[ "$volume" =~ ^[0-9]+$ ]] || volume=0

			case "$action" in
			inc) volume=$((volume + value)) ;;
			dec) volume=$((volume - value)) ;;
			set) volume="$value" ;;
			esac

			((volume > 100)) && volume=100
			((volume < 0)) && volume=0

			pactl set-sink-volume @DEFAULT_SINK@ \
				"${volume}%" || return 1
		fi
		;;
	esac

	_update_xsetroot volume
} # }}}

minx_wifi() { # {{{
	local option="${1:-}"

	[[ -n "$option" ]] || option=$(_choose wifi) || return 0

	case "$option" in
	on | off)
		_require nmcli || return 1

		if ! nmcli radio wifi "$option"; then
			minx_notify "[ERROR] minx_wifi" "Could not switch WiFi $option."
			return 1
		fi
		;;

	manager)
		_run_in_terminal nmtui-connect || return 1
		return 0
		;;

	reset)
		_require nmcli || return 1

		if ! nmcli radio wifi off; then
			minx_notify "[ERROR] minx_wifi" "Could not disable WiFi for reset."
			return 1
		fi

		rm -f "$HOME"/.ssh/master-* 2>/dev/null || true

		if ! nmcli radio wifi on; then
			minx_notify "[ERROR] minx_wifi" "Could not re-enable WiFi."
			return 1
		fi
		;;

	*)
		_usage wifi
		return 1
		;;
	esac

	minx_notify "wifi" "$option"
	_update_xsetroot wifi
} # }}}
