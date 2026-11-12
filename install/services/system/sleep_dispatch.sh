#!/usr/bin/env bash
# sleep_dispatch.sh
# Installed to: /lib/systemd/system-sleep/sleep_dispatch.sh

set -euo pipefail

readonly LOGFILE="/var/log/minx/sleep_dispatch.log"

readonly TARGET_USER="@TARGET_USER@"
readonly TARGET_HOME="@TARGET_HOME@"
readonly HOOKS_DIR="/opt/minx/runtime/user/hooks"

_log() { # {{{
	local message="$*"

	printf '[%s] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$message"
} # }}}

_run_and_log() { # {{{
	local logfile="$1"
	shift

	local -a pipe_status

	"$@" 2>&1 | tee -a "$logfile"
	pipe_status=("${PIPESTATUS[@]}")

	return "${pipe_status[0]}"
} # }}}

_run_as_user() { # {{{
	local script="$1"
	local message="$2"
	shift 2

	_log "$message"

	if [[ ! -x "$script" ]]; then
		_log "Warning: script not executable: $script"
		return 0
	fi

	/usr/sbin/runuser -u "$TARGET_USER" -- \
		env -i \
		HOME="$TARGET_HOME" \
		USER="$TARGET_USER" \
		LOGNAME="$TARGET_USER" \
		PATH="$TARGET_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
		"$script" "$@"
} # }}}

main() { # {{{

	local phase="${1:-}"
	local action="${2:-unknown}"

	case "$phase" in

	pre)
		_run_as_user \
			"$HOOKS_DIR/system_sleep_pre.sh" \
			"Pre-$action" \
			"$action"
		;;

	post)
		_run_as_user \
			"$HOOKS_DIR/system_sleep_post.sh" \
			"Post-$action" \
			"$action"
		;;

	*)
		_log "Unknown sleep phase: ${phase:-unknown}"
		return 1
		;;

	esac
} # }}}

install -d -m 0755 -- "$(dirname "$LOGFILE")"

_run_and_log "$LOGFILE" main "$@"
