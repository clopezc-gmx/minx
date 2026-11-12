_ssync_autocomplete() {
	local cur="${COMP_WORDS[COMP_CWORD]}"

	local actions=(
		all
		calendar
		files
		mail
		notes
		pass
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
