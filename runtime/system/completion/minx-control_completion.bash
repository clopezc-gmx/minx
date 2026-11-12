#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
#
# minx_control_autocomplete.bash
#

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 0
source "$SCRIPT_DIR/../lib/minx_variables.sh"

_minx_control_autocomplete() {
	local cur
	local root
	local options

	COMPREPLY=()

	cur="${COMP_WORDS[COMP_CWORD]}"

	# First argument: top-level commands.
	if ((COMP_CWORD == 1)); then
		options="${MINX_CONTROL_OPTIONS[__root]}"
		mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
		return 0
	fi

	root="${COMP_WORDS[1]}"

	# Unknown top-level command.
	[[ -v "MINX_CONTROL_OPTIONS[$root]" ]] || return 0

	options="${MINX_CONTROL_OPTIONS[$root]}"

	# Commands without subcommands do not need further completion.
	[[ -n "$options" ]] || return 0

	# Complete the second argument from the selected command's options.
	if ((COMP_CWORD == 2)); then
		mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
		return 0
	fi

	# No further levels are currently defined by MINX_CONTROL_OPTIONS.
	return 0
}

complete -F _minx_control_autocomplete minx-control
