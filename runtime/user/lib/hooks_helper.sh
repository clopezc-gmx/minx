#!/usr/bin/env bash

# shellcheck disable=SC2034 # # Used by sourced installer scripts.

hh_run_and_log() { # {{{
	local logfile="$1"
	shift

	if [[ -z "$logfile" || $# -eq 0 ]]; then
		printf '%s\n' \
			"Usage: _run_and_log <logfile> <command> [args...]" >&2
		return 1
	fi

	mkdir -p -- "$(dirname "$logfile")" || {
		printf '%s\n' \
			"Failed to create log directory: $(dirname "$logfile")" >&2
		return 1
	}

	"$@" 2>&1 | tee -a "$logfile"

	local cmd_status="${PIPESTATUS[0]}"
	return "$cmd_status"
} # }}}

hh_printmsg() { # {{{
	local message="$*"

	printf '[%s] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$message"
} # }}}
