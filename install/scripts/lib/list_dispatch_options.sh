#!/usr/bin/env bash

if [[ -n "${LIST_DISPATCH_OPTIONS_DIR:-}" ]]; then
	return 0
fi

LIST_DISPATCH_OPTIONS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LIST_DISPATCH_OPTIONS_DIR

minx_list_options() {
	if (($# != 1)); then
		printf 'Usage: %s <bash-script>\n' "$0" >&2
		exit 1
	fi

	script="$1"

	[[ -f "$script" ]] || {
		printf 'Error: file does not exist: %s\n' "$script" >&2
		exit 1
	}

	sed -nE '
s/^[[:space:]]*"([^"]+)"\)[[:space:]]*$/\1/p
s/^[[:space:]]*([^"|()[:space:]][^"|()]*)\)[[:space:]]*$/\1/p
' "$script" |
		sed '/^[[:space:]]*$/d' |
		grep -vE '^[[:space:]]*\*$'
}

minx_build_all_options() {
	local -n _selected_functions="$2"
	local option
	local function_name

	printf '\n%s\n' "=> The following functions will be executed:"
	minx_list_options "$1" |
		while IFS= read -r option; do
			[[ -n "$option" ]] || continue
			[[ "$option" != "--all" ]] || continue
			printf '  %s\n' "$option"
		done

	printf '\nContinue? [y/N] '
	read -r answer

	[[ "$answer" =~ ^[Yy]$ ]] || return 1

	while IFS= read -r option; do
		[[ -n "$option" ]] || continue
		[[ "$option" != "--all" ]] || continue

		function_name="${option#--}"
		function_name="${function_name//-/_}"

		_selected_functions+=("$function_name")
	done < <(minx_list_options "$1")
}

minx_assert_is_root() { # {{{
	local name=${1:-variable not set}
	if ((EUID != 0)); then
		printf '%s\n' "=> Run \"$name\" as a ROOT." >&2
		return 1
	fi
} # }}}

minx_assert_is_non_root() { # {{{
	local name=${1:-variable not set}
	if ((EUID == 0)); then
		printf '%s\n' "=> Run \"$name\" as a NON-ROOT." >&2
		return 1
	fi
} # }}}

readonly __LIST_DISPATCH_OPTIONS
