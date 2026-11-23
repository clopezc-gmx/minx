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
		["--ctags"]=ctags
		["--vim"]=vim
	)

	local -a options=()
	options+=(
		--ctags
		--vim
	)

	if [[ "$MINX_INSTALLATION_TYPE" == "desktop" ]]; then
		actions+=(
			["--taskwarrior"]=taskwarrior
			["--timewarrior"]=timewarrior
			["--pdfjs"]=pdfjs
			["--languagetool"]=languagetool
		)

		options+=(
			--taskwarrior
			--timewarrior
			--pdfjs
			--languagetool
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
