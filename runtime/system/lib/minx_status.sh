#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
# shellcheck disable=SC2034 # used by sourced scripts.

# minx_status.sh

[[ -n "${__MINX_STATE_LOADED:-}" ]] && return
__MINX_STATE_LOADED=1

_MINX_STATUS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1
source "$_MINX_STATUS_DIR/minx_core.sh" || return 1
source "$_MINX_STATUS_DIR/minx_variables.sh" || return 1

_pick_color() { # {{{
	local value="$1"
	local warn="$2"
	local crit="$3"

	if ((USE_COLOR == 0)); then
		printf '%s' "$NOCOLOR"
	elif ((value >= crit)); then
		printf '%s' "$RED"
	elif ((value >= warn)); then
		printf '%s' "$ORANGE"
	else
		printf '%s' "$NOCOLOR"
	fi
} # }}}

_is_muted() { # {{{
	case "$MINX_AUDIO_BACKEND" in
	pipewire)
		wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null |
			grep -q 'MUTED'
		;;

	pulseaudio)
		pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null |
			grep -q 'yes'
		;;

	alsamixer)
		amixer sget Master 2>/dev/null |
			grep -q -m1 '\[off\]'
		;;

	*)
		return 1
		;;
	esac
} # }}}

minx_get_device_type() { # {{{
	local chassis_type

	if [[ ! -r /sys/class/dmi/id/chassis_type ]]; then
		printf 'not-portable\n'
		return
	fi

	chassis_type=$(</sys/class/dmi/id/chassis_type)

	if [[ "$chassis_type" =~ ^(8|9|10|14)$ ]]; then
		printf 'portable\n'
	else
		printf 'not-portable\n'
	fi
} # }}}

# Battery state file = next alert threshold (20 -> 10 -> 5 -> 2 -> 1).
# It is re-armed to 20 whenever the battery is not discharging.
minx_get_battery_status() { # {{{
	local dir
	local bat=""
	local status
	local level
	local notify=20
	local next
	local battery

	for dir in /sys/class/power_supply/BAT*; do
		[[ -r "$dir/capacity" && -r "$dir/status" ]] || continue
		bat="$dir"
		break
	done

	[[ -n "$bat" ]] || return 0

	level=$(<"$bat/capacity")
	status=$(<"$bat/status")
	status="${status:0:1}" # D(ischarging) C(harging) F(ull) N(ot charging)

	[[ "$level" =~ ^[0-9]+$ ]] || return 0

	if [[ -r "$MINX_STATE_BATTERY" ]]; then
		notify=$(<"$MINX_STATE_BATTERY")
		[[ "$notify" =~ ^[0-9]+$ ]] || notify=0
		((notify == 0)) && notify=20
	fi

	if [[ "$status" == D ]]; then
		# "<=" so a threshold is not missed between two polls.
		if ((level <= notify)); then
			if command -v notify-send >/dev/null 2>&1; then
				notify-send -t 3000 'Battery' "$status $level%" || true
			fi

			case "$notify" in
			20) next=10 ;;
			10) next=5 ;;
			5) next=2 ;;
			*) next=1 ;;
			esac

			printf '%s\n' "$next" >"$MINX_STATE_BATTERY"
		fi

		if ((level <= 20)); then
			if ((level <= 10)); then
				battery="${RED}${level}%"
			else
				battery="${YELLOW}${level}%"
			fi
		else
			battery="${level}%"
		fi
	else
		[[ "$notify" == 20 && "$(<"$MINX_STATE_BATTERY")" == 20 ]] ||
			printf '20\n' >"$MINX_STATE_BATTERY"
		battery="$status $level%"
	fi

	printf '%s\n' "|$battery${NOCOLOR}"
} # }}}

minx_get_brightness_status() { # {{{
	local device
	local brightness
	local max
	local percent

	device=$(minx_get_backlight_device 2>/dev/null || true)

	# sysfs first: no extra process on every bar update.
	if [[ -n "$device" &&
		-r "/sys/class/backlight/$device/brightness" &&
		-r "/sys/class/backlight/$device/max_brightness" ]]; then
		brightness=$(<"/sys/class/backlight/$device/brightness")
		max=$(<"/sys/class/backlight/$device/max_brightness")

		if [[ "$brightness" =~ ^[0-9]+$ &&
			"$max" =~ ^[0-9]+$ ]] && ((max > 0)); then
			printf '%s\n' "|B:$((brightness * 100 / max))"
			return
		fi
	fi

	if [[ -n "$device" ]] && command -v brightnessctl >/dev/null 2>&1; then
		brightness=$(brightnessctl -d "$device" get 2>/dev/null || true)
		max=$(brightnessctl -d "$device" max 2>/dev/null || true)

		if [[ "$brightness" =~ ^[0-9]+$ &&
			"$max" =~ ^[0-9]+$ ]] && ((max > 0)); then
			printf '%s\n' "|B:$((brightness * 100 / max))"
			return
		fi
	fi

	if command -v xbacklight >/dev/null 2>&1; then
		brightness=$(xbacklight -get 2>/dev/null || true)

		if [[ "$brightness" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
			printf '%s\n' "|B:${brightness%.*}"
			return
		fi
	fi

	printf '|B:--\n'
} # }}}

minx_get_volume_status() { # {{{
	local volume

	if _is_muted; then
		printf '|V:Ø\n'
		return
	fi

	volume=$(minx_get_volume)

	if ((volume > 70)); then
		printf '%s%s%s\n' \
			"$ORANGE" \
			"|V:${volume}" \
			"$NOCOLOR"
	else
		printf '%s\n' "|V:${volume}"
	fi
} # }}}

minx_get_microphone_status() { # {{{
	local state=""
	local mic_on='󰍬'
	local mic_off='󰍭'

	if command -v wpctl >/dev/null 2>&1; then
		state=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)

		if [[ "$state" == *MUTED* ]]; then
			state=muted
		elif [[ -n "$state" ]]; then
			state=open
		fi
	elif command -v pactl >/dev/null 2>&1; then
		case "$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null)" in
		*yes*) state=muted ;;
		*no*) state=open ;;
		esac
	fi

	case "$state" in
	open)
		# A live microphone is the state worth noticing.
		printf '%s\n' "|${ORANGE}$mic_on${NOCOLOR}"
		;;

	muted)
		# printf '%s\n' "|${NOCOLOR}$mic_off${NOCOLOR}"
		# Do nothing, default
		;;

	*)
		printf '%s\n' "|Mic:--"
		;;
	esac
} # }}}

minx_get_vpn_status() { # {{{
	local dir
	local name

	# Any tunnel interface that exists is an active VPN: wg-quick, openvpn,
	# tailscale, ppp, or NetworkManager (named after the connection) via the
	# WireGuard device type.
	for dir in /sys/class/net/*; do
		[[ -d "$dir" ]] || continue
		name="${dir##*/}"

		case "$name" in
		tun* | tap* | wg* | ppp* | tailscale* | proton* | mullvad*)
			printf '%s\n' "|${GREEN}VPN${NOCOLOR}"
			return
			;;
		esac

		if [[ -r "$dir/uevent" ]] &&
			grep -q '^DEVTYPE=wireguard$' "$dir/uevent" 2>/dev/null; then
			printf '%s\n' "|${GREEN}VPN${NOCOLOR}"
			return
		fi
	done
} # }}}

minx_get_network_status() { # {{{
	local interface
	local message

	local wifi_online="󰖩$NOCOLOR"
	local eth_online="󰈀$NOCOLOR"
	local no_net="$GRAY󰖪$NOCOLOR"

	interface=$(minx_get_default_interface || true)

	if [[ -z "$interface" ]]; then
		printf '%s\n' "|${no_net}"
		return
	fi

	case "$interface" in
	en* | eth*)
		message="$eth_online"
		;;

	*)
		if [[ -d "/sys/class/net/$interface/wireless" ]]; then
			message="$wifi_online"
		else
			message="$no_net"
		fi
		;;
	esac

	printf '%s\n' "|${message}"
} # }}}

minx_get_keyboard_status() { # {{{
	local layout

	layout=$(<"$MINX_STATE_KEYBOARD")

	if [[ "$layout" != us ]]; then
		layout="${GREEN}${layout}${NOCOLOR}"
	fi

	printf '%s\n' "|$layout"
} # }}}

minx_get_media_status() { # {{{
	local status

	command -v playerctl >/dev/null 2>&1 || return 0

	status=$(playerctl status 2>/dev/null || true)

	case "$status" in
	Playing)
		printf '|>\n'
		;;

	Paused)
		printf '|:\n'
		;;
	esac
} # }}}

minx_get_system_status() { # {{{
	local cpu
	local mem

	local cpu_color
	local mem_color

	local cpu_warn=70
	local cpu_crit=90
	local mem_warn=70
	local mem_crit=90

	cpu=$(minx_cpu_usage)
	mem=$(minx_mem_usage_percent)

	cpu_color=$(_pick_color "$cpu" "$cpu_warn" "$cpu_crit")
	mem_color=$(_pick_color "$mem" "$mem_warn" "$mem_crit")

	printf '%sC%2d%%%s,%sM%2d%%%s|\n' \
		"$cpu_color" \
		"$cpu" \
		"$NOCOLOR" \
		"$mem_color" \
		"$mem" \
		"$NOCOLOR"
} # }}}

minx_get_timer_status() { # {{{
	local timer_start
	local now
	local remaining

	local hours
	local minutes
	local timer

	timer_start=$(<"$MINX_STATE_COUNTDOWN")

	if ! [[ "$timer_start" =~ ^[0-9]+$ ]]; then
		printf '0\n' >"$MINX_STATE_COUNTDOWN"
		return
	fi

	if ((timer_start == 0)); then
		printf '\n'
		return
	fi

	now=$EPOCHSECONDS

	if ((timer_start > now)); then
		remaining=$((timer_start - now))

		hours=$((remaining / 3600))
		minutes=$(((remaining % 3600) / 60))

		timer=$(printf '%02d:%02d' "$hours" "$minutes")

		printf '%s\n' "|${GREEN}$timer${NOCOLOR}"
		return
	fi

	printf '0\n' >"$MINX_STATE_COUNTDOWN"

	if command -v sent >/dev/null 2>&1; then
		printf '%s' 'Timer is up' | DISPLAY=:0 sent || true
	else
		notify-send 'Timer' 'Timer is up' || true
	fi

	printf '\n'
} # }}}

minx_get_timew_status() { # {{{
	local active
	local t_duration
	local t_d_h
	local t_d_m
	local t_count
	local t_tag
	local t_project=""
	local i

	command -v timew >/dev/null 2>&1 || return 0

	active=$(timew get dom.active 2>/dev/null || printf '0')

	if [[ "$active" == 1 ]]; then
		t_duration=$(timew get dom.active.duration 2>/dev/null || true)

		t_d_h=$(grep -oP '\d+(?=H)' <<<"$t_duration" || true)
		t_d_m=$(grep -oP '\d+(?=M)' <<<"$t_duration" || true)

		[[ "$t_d_h" =~ ^[0-9]+$ ]] || t_d_h=0
		[[ "$t_d_m" =~ ^[0-9]+$ ]] || t_d_m=0

		# Project tag: the first active tag of the form +name:
		t_count=$(timew get dom.active.tag.count 2>/dev/null || printf '0')
		[[ "$t_count" =~ ^[0-9]+$ ]] || t_count=0

		for ((i = 1; i <= t_count; i++)); do
			t_tag=$(timew get "dom.active.tag.$i" 2>/dev/null || true)
			if [[ "$t_tag" =~ ^\+.+:$ ]]; then
				t_project="$t_tag"
				break
			fi
		done

		printf '|%s%s(%02d:%02d)%s\n' \
			"$NOCOLOR" \
			"$t_project" \
			"$t_d_h" \
			"$t_d_m" \
			"$NOCOLOR"

		return
	fi

	printf '|%sNoTrack%s\n' "$YELLOW" "$NOCOLOR"
} # }}}

minx_get_datetime() { # {{{
	# printf %()T is a bash builtin: no date(1) processes.
	printf '|%(%d.%m-%a)T%s%(%H:%M)T\n' -1 "$ORANGE" -1
} # }}}

minx_get_lockscreen_status() { # {{{
	local lock

	lock=$(<"$MINX_STATE_LOCKSCREEN")

	if [[ "$lock" == "off" ]]; then
		printf '|%s󰍂%s\n' "$ORANGE" "$NOCOLOR"
	fi
} # }}}

# =============================================================================
# Variables
# =============================================================================

readonly USE_COLOR=1
readonly NOCOLOR=$'\x01'
readonly ORANGE=$'\x02'
readonly YELLOW=$'\x03'
readonly RED=$'\x04'
readonly GREEN=$'\x05'
readonly GRAY=$'\x07'

MINX_DEVICE_TYPE="$(minx_get_device_type)"
readonly MINX_DEVICE_TYPE
