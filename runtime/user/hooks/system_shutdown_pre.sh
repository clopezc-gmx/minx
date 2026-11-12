#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
# shutdown_pre.sh
# Pre-shutdown / pre-reboot hook

set -euo pipefail

if ((EUID == 0)); then
	printf '%s\n' "=> Run $0 as a user." >&2
	exit 1
fi

#=================================================================================
# Configuration
#=================================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hooks_helper.sh"

LOGS_DIR="$HOME/.local/state/minx/logs"
mkdir -p "$LOGS_DIR"

LOGFILE="$LOGS_DIR/shutdown_pre.log"

#=================================================================================
# Helpers
#=================================================================================

_stop_time_tracking() {
	local action="$1"

	hh_printmsg "=> Stop tracking"

	TT_TTY="/dev/stderr" ta stop_before_system_shutdown "now" @@ " -- system-$action"
}

_actions() {
	local action="$1"

	_stop_time_tracking "$action"
}

#=================================================================================
# Main
#=================================================================================

main() {
	local action="${1:-shutdown}"

	hh_printmsg "=> Run actions pre $action"

	case "$action" in
	shutdown | reboot | poweroff | halt)
		_actions "$action"
		;;

	*)
		hh_printmsg "=> Warning: unknown shutdown action: $action"
		return 1
		;;
	esac

	hh_printmsg "=> Done"
}

hh_run_and_log "$LOGFILE" main "$@"
