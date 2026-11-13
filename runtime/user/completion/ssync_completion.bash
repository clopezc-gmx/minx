_ssync_autocomplete() {
	local cur="${COMP_WORDS[COMP_CWORD]}"

	local actions=(
		all
		calendar
		assets
		mail
		passwords
		documents
		ta
		taskwarrior
	)

	if ((COMP_CWORD == 1)); then
		mapfile -t COMPREPLY < <(
			compgen -W "${actions[*]}" -- "$cur"
		)
		return
	fi
}
complete -F _ssync_autocomplete ssync.sh
