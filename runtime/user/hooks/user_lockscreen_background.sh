#!/usr/bin/env bash

# user_lockscreen_background.sh

set -euo pipefail
# set -x

# =============================================================================
# Configuration
# =============================================================================

: "${_TBL_FILE:?Variable not set}"

readonly SYNC_TIMEOUT="${SYNC_TIMEOUT:-60}"

readonly STATE_DIR="${XDG_STATE_HOME:-"$HOME/.local/state"}/minx"
readonly LOG_DIR="$STATE_DIR/logs"
readonly TA_LOG="$LOG_DIR/ta_stop.log"

readonly TA_STOP_ANNOTATION="${1:-"--lockscreen-bgs-no-annotation-passed"}"

# shellcheck disable=2034 # passed as argument to a function
readonly -a REQUIRED_COMMANDS=(
	git
	task
	pass
	gpg-connect-agent
	lsof
	ssh
	mbsync
	notmuch
	flock
	rsync
	vdirsyncer
	timew
	ta
	timeout
	ssync.sh
)

# =============================================================================
# Helpers
# =============================================================================

_commands_exist() {
	local -n commands=$1
	local command

	for command in "${commands[@]}"; do
		if ! command -v "$command" >/dev/null 2>&1; then
			printf '%s is not available\n' "$command" >&2
			return 1
		fi
	done
}

_write_process_table() {
	local -n _pids=$1
	local -n _logs=$2
	local tmp
	local name

	mkdir -p "$(dirname -- "$_TBL_FILE")"

	tmp="$(mktemp "${_TBL_FILE}.XXXXXX")"

	{
		for name in "${!_pids[@]}"; do
			printf '%s %s %s\n' \
				"$name" \
				"${_pids[$name]}" \
				"${_logs[$name]}"
		done
	} >"$tmp"

	mv -- "$tmp" "$_TBL_FILE"

	rm -f -- "$tmp"
}

_start_ta_stop() {
	local log="$1"

	mkdir -p "$(dirname -- "$log")"

	: >"$log"

	ta stop now @@ "$TA_STOP_ANNOTATION" \
		>"$log" \
		2>&1 &
	STARTED_PID=$!
}

_start_sync() {
	local name="$1"
	local logfile="$2"
	timeout --kill-after=5 "$SYNC_TIMEOUT" ssync.sh "$name" >"$logfile" 2>&1 &
	STARTED_PID=$!
}

# =============================================================================
# Main
# =============================================================================

# shellcheck disable=2034 # passed as argument to a function
main() {
	_commands_exist REQUIRED_COMMANDS

	mkdir -p "$LOG_DIR"
	chmod 700 "$LOG_DIR"

	local -A pids=()
	local -A logs=()

	# -------------------------------------------------------------------------
	# Stop active time tracking
	# -------------------------------------------------------------------------

	logs[ta_stop]="$TA_LOG"

	_start_ta_stop "${logs[ta_stop]}"
	pids[ta_stop]="$STARTED_PID"

	# -------------------------------------------------------------------------
	# Start synchronizations in parallel
	# -------------------------------------------------------------------------

	local apps=(pass taskwarrior mail calendar ta)

	for name in "${apps[@]}"; do
		logs[$name]="$LOG_DIR/ls_$name.log"
		_start_sync "$name" "${logs[$name]}"
		pids[$name]="$STARTED_PID"
	done

	# -------------------------------------------------------------------------
	# Publish the table only after every process has been started.
	# The caller is responsible for waiting.
	# -------------------------------------------------------------------------

	_write_process_table pids logs
}

main "$@"
