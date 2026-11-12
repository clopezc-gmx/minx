#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
# sleep_post.sh
# Post-suspend / post-hibernate hook

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

LOGFILE="$LOGS_DIR/sleep_post.log"

#=================================================================================
# Helpers
#=================================================================================

_cleanup() {
	hh_printmsg "=> Run cleanup"

	local mail_lock="$HOME/.cache/mail-update.lock"

	if [[ -d "$mail_lock" ]]; then
		rm -rf -- "$mail_lock"
		hh_printmsg "Removed $(basename "$mail_lock")"
	fi

	if [ -n "$DISPLAY" ]; then
		"$HOME/.xsetroot.sh" timew &
	fi

}

_actions() {
	_cleanup
}

#=================================================================================
# Main
#=================================================================================

main() {
	local action="${1:-unknown}"

	hh_printmsg "=> Run actions post $action"

	_actions

	hh_printmsg "=> Done"
}

hh_run_and_log "$LOGFILE" main "$@"
