#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"

# shellcheck disable=SC2034 # variable used in the sourced files
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/setup.sh"

if ((EUID != 0)); then
	printf '%s\n' "=> Run this script as root." >&2
	exit 1
fi

main() {

	local action="${1:-"--help"}"

	local -A actions=()
	actions+=(
		["--restore-rc-files"]=minx_restore_root_rc_files
		["--install-services"]=minx_install_system_services
	)

	local -a options=()
	options+=(
		--restore-rc-files
		--installl-services
	)

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
