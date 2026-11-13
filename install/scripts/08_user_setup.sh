#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
source "$SCRIPT_DIR/lib/list_dispatch_options.sh"

# shellcheck disable=SC2034 # variable used in the sourced files
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/setup.sh"

if ((EUID == 0)); then
	printf '%s\n' "=> Run this script as user." >&2
	exit 1
fi

main() {

	local is_server
	[ "${1:?variable not set use --server or --laptop}" == "--server" ] && is_server="yes" || is_server="no"

	local option="${2:---help}"

	case "$option" in
	"--clone-personal-repos")
		minx_clone_personal_repos "$is_server" || return 1
		;;

	"--install-tt")
		shift 2
		minx_install_tt "$@" || return 1
		;;

	"--install-wikiviewer")
		shift 2
		minx_install_wikiviewer "$@" || return 1
		;;

	"--restore-rc-files")
		minx_backup_user_rc_files "$is_server" || return 1
		minx_restore_user_rc_files "$is_server" || return 1
		;;

	"--install-mime-types")
		minx_install_mime_types "$is_server" || return 1
		;;

	"--init-mail")
		minx_init_mail "$is_server" || return 1
		;;

	"--install-services")
		minx_install_user_services "$is_server" || return 1
		;;

	"--get-vim-vundle")
		minx_get_vim_vundle "$is_server" || return 1
		;;

	"--help")
		minx_list_options "$0"
		;;
	*)
		printf '\n%s\n' "Try with a valid argument:" >&2
		minx_list_options "$0"
		return 1
		;;

	esac
}

main "$@"
