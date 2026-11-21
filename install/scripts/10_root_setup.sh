#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
source "$SCRIPT_DIR/lib/list_dispatch_options.sh"

# shellcheck disable=SC2034 # variable used in the sourced files
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/setup.sh"

if ((EUID != 0)); then
	printf '%s\n' "=> Run this script as root." >&2
	exit 1
fi

main() {

	local option="${1:-"--help"}"

	case $option in
	"--restore-rc-files")
		minx_backup_root_rc_files || return 1
		minx_restore_root_rc_files || return 1
		;;
	"--install-services")
		minx_install_system_services || return 1
		;;
	"--all")
		minxbuild_all_options "$0" selected_functions
		;;
	*)
		printf '\n%s\n' "Try with a valid argument:"
		minx_list_options "$0"
		return 1
		;;

	esac
}

main "$@"
