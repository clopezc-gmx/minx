#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail
# set -x

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
source "$SCRIPT_DIR/lib/utils.sh"

if ((EUID != 0)); then
	printf '%s\n' "=> Run this script as root." >&2
	exit 1
fi

if ! minx_is_desktop_install; then
	minx_log_server_skip "Does not include \"sucklesstools\""
	exit 0
fi

main() {

	local action="${1:-"--help"}"

	local -A actions=()
	actions+=(
		["--dwm"]=dwm
		["--st"]=st
		["--sent"]=sent
		["--slock"]=slock
	)

	local -a options=()
	options+=(
		--dwm
		--st
		--sent
		--slock
	)

	if [[ -z ${actions["$action"]:-} ]]; then
		printf 'Try with a valid argument:\n'
		printf '  %s\n' "${options[@]}"
		return 0
	fi

	"$SCRIPT_DIR/installer.sh" --install "${actions["$action"]}" || exit 1
}

main "$@"
