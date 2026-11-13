_myservices_autocomplete() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	local prev="${COMP_WORDS[COMP_CWORD - 1]}"

	local actions=(
		enable
		disable
		start
		stop
		restart
		status
		logs
		follow
	)

	local services=(
		languagetool.service
		ssync-assets.service
		ssync-documents.service
		ssync-ta.service
		wikiviewer.service
		ssync-calendar.service
		ssync-mail.service
		ssync-passwords.service
		ssync-taskwarrior.service
		update_feeds.service
	)

	if ((COMP_CWORD == 1)); then
		mapfile -t COMPREPLY < <(
			compgen -W "${actions[*]}" -- "$cur"
		)
		return
	fi

	case "$prev" in
	enable | disable | start | stop | restart | status | logs | follow)
		mapfile -t COMPREPLY < <(
			compgen -W "${services[*]}" -- "$cur"
		)
		;;
	esac
}

complete -F _myservices_autocomplete myservices.sh
