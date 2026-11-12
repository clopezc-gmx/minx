#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
#
# file: minx_core.sh
#
# Shared configuration and runtime status files.

[[ -n "${__MINX_CORE_LOADED:-}" ]] && return
__MINX_CORE_LOADED=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1

source "$SCRIPT_DIR/minx_variables.sh" || return 1

# True when an X display is set and the server answers.
minx_has_display() {
	[[ -n "${DISPLAY:-}" ]] || return 1
	command -v xset >/dev/null 2>&1 || return 0
	xset q >/dev/null 2>&1
}

# =============================================================================
# Status files
# =============================================================================

minx_init_status_file() { # {{{
	local file="$1"
	local default_value="$2"

	if [[ -e "$file" ]]; then
		[[ -f "$file" ]] || {
			printf 'ERROR: Status path is not a regular file: %s\n' "$file" >&2
			return 1
		}

		return 0
	fi

	if ! printf '%s\n' "$default_value" >"$file"; then
		printf 'ERROR: Cannot initialize status file: %s\n' "$file" >&2
		return 1
	fi
} # }}}

# =============================================================================
# CPU / memory
# =============================================================================

minx_read_cpu() { # {{{
	local user
	local nice
	local system
	local idle
	local iowait
	local irq
	local softirq
	local steal

	local idle_all
	local non_idle
	local total

	if ! read -r _ user nice system idle iowait irq softirq steal _ _ \
		</proc/stat; then
		return 1
	fi

	if ! [[ "$user" =~ ^[0-9]+$ &&
		"$nice" =~ ^[0-9]+$ &&
		"$system" =~ ^[0-9]+$ &&
		"$idle" =~ ^[0-9]+$ &&
		"$iowait" =~ ^[0-9]+$ &&
		"$irq" =~ ^[0-9]+$ &&
		"$softirq" =~ ^[0-9]+$ &&
		"$steal" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	idle_all=$((idle + iowait))
	non_idle=$((user + nice + system + irq + softirq + steal))
	total=$((idle_all + non_idle))

	printf '%s %s\n' "$total" "$idle_all"
} # }}}

minx_cpu_usage() { # {{{
	local total1
	local idle1
	local total2
	local idle2
	local dt
	local di

	if ! read -r total1 idle1 < <(minx_read_cpu); then
		printf '0\n'
		return 0
	fi

	sleep 0.5

	if ! read -r total2 idle2 < <(minx_read_cpu); then
		printf '0\n'
		return 0
	fi

	dt=$((total2 - total1))
	di=$((idle2 - idle1))

	if ((dt <= 0 || di < 0 || di > dt)); then
		printf '0\n'
		return 0
	fi

	printf '%s\n' "$((100 * (dt - di) / dt))"
} # }}}

minx_mem_usage_percent() { # {{{
	local total
	local available
	local used

	total=$(
		awk '/^MemTotal:/ {
			print $2
			exit
		}' /proc/meminfo
	)

	available=$(
		awk '/^MemAvailable:/ {
			print $2
			exit
		}' /proc/meminfo
	)

	if ! [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]]; then
		printf '0\n'
		return 0
	fi

	if ((total <= 0 || available < 0 || available > total)); then
		printf '0\n'
		return 0
	fi

	used=$((total - available))

	printf '%s\n' "$((100 * used / total))"
} # }}}

# =============================================================================
# Audio
# =============================================================================

minx_get_volume() { # {{{
	local volume='0'

	case "$MINX_AUDIO_BACKEND" in
	pipewire)
		if command -v wpctl >/dev/null 2>&1; then
			volume=$(
				wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null |
					awk '{printf "%d", $2 * 100 + 0.5}'
			)
		fi
		;;

	pulseaudio)
		if command -v pactl >/dev/null 2>&1; then
			volume=$(
				pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null |
					awk '
					NR == 1 {
						for (i = 1; i <= NF; i++) {
							if ($i ~ /^[0-9]+%$/) {
								gsub(/%/, "", $i)
								print $i
								exit
							}
						}
					}
					'
			)
		fi
		;;

	alsamixer)
		if command -v amixer >/dev/null 2>&1; then
			volume=$(
				amixer sget Master 2>/dev/null |
					awk -F'[][]' '
					/%/ {
						gsub(/%/, "", $2)
						if ($2 ~ /^[0-9]+$/) {
							print $2
							exit
						}
					}
					'
			)
		fi
		;;
	esac

	if ! [[ "$volume" =~ ^[0-9]+$ ]]; then
		volume=0
	fi

	((volume > 100)) && volume=100

	printf '%s\n' "$volume"
} # }}}

# =============================================================================
# Hardware / network
# =============================================================================

minx_get_cpu_vendor() { # {{{
	local vendor

	vendor=$(
		awk -F: '
		/^vendor_id/ {
			gsub(/^[ \t]+/, "", $2)
			print $2
			exit
		}
		' /proc/cpuinfo
	)

	case "$vendor" in
	AuthenticAMD | GenuineIntel)
		printf '%s\n' "$vendor"
		;;

	*)
		minx_notify "[ERROR] minx_get_cpu_vendor" "Unknown CPU vendor: ${vendor:-unknown}"
		return 1
		;;
	esac
} # }}}

minx_get_default_interface() { # {{{
	local interface

	interface=$(
		ip route get 1.1.1.1 2>/dev/null |
			awk '
			{
				for (i = 1; i <= NF; i++) {
					if ($i == "dev") {
						print $(i + 1)
						exit
					}
				}
			}'
	)

	[[ -n "$interface" ]] || return 1

	printf '%s\n' "$interface"
} # }}}

# First wireless interface, independent of the default route.
minx_get_wifi_interface() { # {{{
	local dir

	for dir in /sys/class/net/*/wireless; do
		[[ -d "$dir" ]] || continue

		dir="${dir%/wireless}"
		printf '%s\n' "${dir##*/}"
		return 0
	done

	return 1
} # }}}

# Prefer a "raw" backlight (intel_backlight, amdgpu_bl*, ...) over
# firmware/platform ones such as acpi_video0, which are often non-functional.
minx_get_backlight_device() { # {{{
	local device

	for device in /sys/class/backlight/*; do
		[[ -r "$device/type" && "$(<"$device/type")" == "raw" ]] || continue

		printf '%s\n' "${device##*/}"
		return 0
	done

	for device in /sys/class/backlight/*; do
		[[ -d "$device" ]] || continue

		printf '%s\n' "${device##*/}"
		return 0
	done

	return 1
} # }}}

# =============================================================================
# Helpers
# =============================================================================

# Popup when possible; stderr when run from a terminal or if the popup fails.
minx_notify() { # {{{

	if minx_has_display && command -v notify-send >/dev/null 2>&1; then
		if notify-send -- "$@" 2>/dev/null && [[ ! -t 2 ]]; then
			return 0
		fi
	fi

	printf '%s\n' "$*" >&2
} # }}}

minx_run_and_log() {
	local logfile="$1"
	shift

	if [[ -z "$logfile" || $# -eq 0 ]]; then
		printf '%s\n' \
			"Usage: minx_run_and_log <logfile> <command> [args...]" >&2
		return 1
	fi

	"$@" 2>&1 | tee -a "$logfile"

	local cmd_status="${PIPESTATUS[0]}"
	return "$cmd_status"
}

minx_printmsg() {
	printf '=> [%s] %s\n' "$(date +%Y%m%dT%H%M%S)" "$*"
}

# =============================================================================
# Setup
# =============================================================================

minx_init_status_file "$MINX_STATE_BATTERY" 0 || return 1
minx_init_status_file "$MINX_STATE_KEYBOARD" "us" || return 1
minx_init_status_file "$MINX_STATE_COUNTDOWN" 0 || return 1
minx_init_status_file "$MINX_STATE_LOCKSCREEN" 1 || return 1
minx_init_status_file "$MINX_STATE_TOUCHPAD" 0 || return 1
