#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"

if ((EUID == 0)); then
	printf '%s\n' "=> Run this script as a non-root user." >&2
	exit 1
fi

main() {
	local action="${1:-"--help"}"

	local -A actions=()
	actions+=(
		["--rust-and-cargo"]=rust_and_cargo
		["--nvm-and-nodejs"]=nvm_and_nodejs
		["--pipx-packages"]=pipx_packages
		["--go-packages"]=go_packages
		["--nodejs-packages"]=nodejs_packages
		["--invariant-repos"]=invariant_repos
	)
	local -a options=()

	options+=(
		--rust-and-cargo
		--nvm-and-nodejs
		--pipx-packages
		--go-packages
		--nodejs-packages
		--invariant-repos
	)

	if [[ "$MINX_INSTALLATION_TYPE" == "desktop" ]]; then
		actions+=(
			["--calix"]=calix
		)
		options+=(
			--calix
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
