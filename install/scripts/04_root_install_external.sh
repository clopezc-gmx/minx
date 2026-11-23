#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"

if ((EUID != 0)); then
	printf '%s\n' "=> Run this script as root." >&2
	exit 1
fi

main() {

	local action="${1:-"--help"}"

	local -A actions=()
	actions+=(
		["--go"]=go
		["--qemu"]=qemu
	)

	local -a options=()
	options+=(
		--go
		--qemu
	)

	if [[ "$MINX_INSTALLATION_TYPE" == "desktop" ]]; then
		actions+=(
			["--jetbrains-mono"]=jetbrains_mono
			["--spotify"]=spotify
			["--librewolf"]=librewolf
			["--onlyoffice"]=onlyoffice
			["--qutebrowser"]=qutebrowser
		)

		options+=(
			--jetbrains-mono
			--spotify
			--librewolf
			--onlyoffice
			--qutebrowser
		)

	fi

	if [[ -z ${actions["$action"]:-} ]]; then
		printf 'Try with a valid argument:\n'
		printf '  %s\n' "${options[@]}"
		return 0
	fi

	"$SCRIPT_DIR/installer.sh" --install "${actions["$action"]}" || exit 1
}

main "$@"
