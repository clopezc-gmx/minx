#!/usr/bin/env bash

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
