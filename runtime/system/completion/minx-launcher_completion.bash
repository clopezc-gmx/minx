#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.
#
# minx_launcher_autocomplete.bash
#

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 0
source "$SCRIPT_DIR/../lib/minx_variables.sh"

_minx_launcher_autocomplete() {
	local cur
	local root
	local options

	COMPREPLY=()

	cur="${COMP_WORDS[COMP_CWORD]}"

	# First argument: top-level commands.
	if ((COMP_CWORD == 1)); then
		options="${MINX_LAUNCHER_OPTIONS[__root]}"
		mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
		return 0
	fi

	root="${COMP_WORDS[1]}"

	# Unknown top-level command.
	[[ -v "MINX_LAUNCHER_OPTIONS[$root]" ]] || return 0

	options="${MINX_LAUNCHER_OPTIONS[$root]}"

	# Commands without subcommands do not need further completion.
	[[ -n "$options" ]] || return 0

	mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
}

complete -F _minx_launcher_autocomplete minx-launcher
