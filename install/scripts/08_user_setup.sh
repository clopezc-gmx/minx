#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail
# set -x

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"

# shellcheck disable=SC2034 # variable used in the sourced files
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/setup.sh"

if ((EUID == 0)); then
	printf '%s\n' "=> Run this script as user." >&2
	exit 1
fi

main() {

	local action="${1:-"--help"}"

	local -A actions=(
		["--clone-personal-repos"]=minx_clone_personal_repos
		["--install-vim-vundle"]=minx_install_vim_vundle
		["--restore-rc-files"]=minx_restore_user_rc_files
	)

	local -a options=(
		--clone-personal-repos
		--install-vim-vundle
		--restore-rc-files
	)

	if [[ $MINX_INSTALLATION_TYPE == "desktop" ]]; then

		actions+=(
			["--install-wikiviewer"]=minx_install_wikiviewer
			["--install-tt"]=minx_install_tt
			["--install-mime-types"]=minx_install_mime_types
			["--install-services"]=minx_install_user_services
		)

		options+=(
			--install-wikiviewer
			--install-tt
			--install-mime-types
			--install-services
		)

	fi

	local function_name="${actions[$action]:-}"

	if [[ -z "$function_name" ]]; then
		printf 'Try with a valid argument:\n'

		local option
		for option in "${options[@]}"; do
			printf '  %s\n' "$option"
		done

		return 1
	fi

	"$function_name" "${@:2}"
}

main "$@"
