_make_autocomplete() {
	local makefile

	for makefile in Makefile makefile; do
		[[ -f "$makefile" ]] || continue

		grep -oE '^[a-zA-Z0-9_-]+:([^=]|$)' "$makefile" |
			sed 's/[^a-zA-Z0-9_-]*$//'

		return
	done
}

_make_targets_autocomplete() {
	local cur
	local -a targets

	cur="${COMP_WORDS[COMP_CWORD]}"

	mapfile -t targets < <(_make_autocomplete)

	COMPREPLY=()
	mapfile -t COMPREPLY < <(
		compgen -W "${targets[*]}" -- "$cur"
	)
}

complete -F _make_targets_autocomplete make
