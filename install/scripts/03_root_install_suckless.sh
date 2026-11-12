#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail
# set -x

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
source "$SCRIPT_DIR/lib/list_dispatch_options.sh"

if ((EUID != 0)); then
	printf '%s\n' "=> Run this script as root." >&2
	exit 1
fi

main() {

	local action="${1:-"--help"}"
	case "$action" in
	"--dwm")
		selected_functions+=("dwm")
		;;
	"--st")
		selected_functions+=("st")
		;;
	"--sent")
		selected_functions+=("sent")
		;;
	"--slock")
		selected_functions+=("slock")
		;;
	"--all")
		minx_build_all_options "$0" selected_functions
		;;
	*)
		printf '\n%s\n' "Try with a valid argument:"
		minx_list_options "$0"
		return 1
		;;
	esac

	for function in "${selected_functions[@]}"; do
		"$SCRIPT_DIR/installer.sh" --install "$function" || exit 1
	done
}

main "$@"
