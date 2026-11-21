#!/usr/bin/env bash

if [[ $MINX_INSTALLATION_TYPE != "desktop" ]]; then
	printf '\n%s\n' "=> [$MINX_INSTALLATION_TYPE installation] -- Does not include \"$(basename "$0")\""
	return 0
fi

_mailto_autocomplete() {
	local cur
	local -a contacts

	cur="${COMP_WORDS[COMP_CWORD]}"

	mapfile -t contacts < <(
		awk -F= '/^email=/ {print $2}' "$HOME/.abook/addressbook" |
			sort -u
	)

	COMPREPLY=()
	mapfile -t COMPREPLY < <(
		compgen -W "${contacts[*]}" -- "$cur"
	)
}

complete -F _mailto_autocomplete mailto.sh
