#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
# sleep_pre.sh
# Pre-suspend / pre-hibernate hook

set -euo pipefail

if ((EUID == 0)); then
	printf '%s\n' "=> Run $0 as a user." >&2
	exit 1
fi

#=================================================================================
# Configuration
#=================================================================================

source "/etc/profile.d/minx_profile.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hooks_helper.sh"

LOGS_DIR="$HOME/.local/state/minx/logs"
mkdir -p "$LOGS_DIR"

LOGFILE="$LOGS_DIR/sleep_pre.log"

#=================================================================================
# Helpers
#=================================================================================

_lockscreen() {
	hh_printmsg "=> Run lockscreen"

	minx-lockscreen || {
		hh_printmsg "=> Warning: lockscreen failed"
		return 0
	}
}

_actions() {
	_lockscreen
}

#=================================================================================
# Main
#=================================================================================

main() {
	local action="${1:-unknown}"

	hh_printmsg "=> Run actions pre $action"

	_actions "$action"

	hh_printmsg "=> Done"
}

hh_run_and_log "$LOGFILE" main "$@"
