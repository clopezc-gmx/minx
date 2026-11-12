#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

if [ -z "$DISPLAY" ]; then
	printf "%s\n" "=> ERROR: No display found. Please ensure you are running in a graphical environment."
	exit 1
fi

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
source "$SCRIPT_DIR/lib/list_dispatch_options.sh"

if ((EUID == 0)); then
	printf '%s\n' "=> Run this script as a non-root user." >&2
	exit 1
fi

main() {

	local action="${1:-"--help"}"
	case "$action" in
	"--ctags")
		selected_functions+=("ctags")
		;;

	"--taskwarrior")
		selected_functions+=("taskwarrior")
		;;

	"--timewarrior")
		selected_functions+=("timewarrior")
		;;

	"--vim")
		selected_functions+=("vim")
		;;

	"--pdfjs")
		selected_functions+=("pdfjs")
		;;
	"--languagetool")
		selected_functions+=("languagetool")
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
		"$SCRIPT_DIR/installer.sh" --build "$function" || exit 1
	done
}

main "$@"
