#!/bin/bash
# user_launcher_targets.sh
#
# shellcheck disable=SC1091 # path is resolved at runtime.
# shellcheck disable=SC2034 # variables used by sourced scripts.

# set -x

# =============================================================================
# configuration
# =============================================================================

readonly LNCHR_GEOMETRY_LAPTOP="140x38+200+30"
readonly LNCHR_ORGANIZER_GEOMETRY_LAPTOP="160x35+77+40"
readonly LNCHR_NOTES_DIR="$MINX_USER_DOCUMENTS_DIR/notes"
readonly LNCHR_REFERENCE_FILE="$MINX_USER_REFERENCE_FILE"

export LNCHR_NOTES_DIR

readonly USE_THUNDERBIRD=${USE_THUNDERBIRD:-0}
readonly USE_CALIX=${USE_CALIX:-0}

# =============================================================================
# helpers
# =============================================================================

_tmux_cmds_cpp_project() { # {{{
	local session_name="$1"
	local proj_path="$2"
	local q_proj_path
	local setup_cmd

	printf -v q_proj_path '%q' "$proj_path"

	setup_cmd="
		source $HOME/.bashrc
		export TMUX_CPP=1 ROOT=$q_proj_path
		alias root='cd $q_proj_path'
		alias src='cd $q_proj_path/src'
		cd $q_proj_path
		clear
	"

	tmux rename-window \
		-t "$session_name:1" \
		editor

	tmux send-keys \
		-t "$session_name:1.0" \
		"$setup_cmd cd src 2>/dev/null || true" \
		C-m

	tmux new-window \
		-t "$session_name:2" \
		-n build \
		"bash -ic '$setup_cmd date'"

	tmux new-window \
		-t "$session_name:3" \
		-n shell \
		"bash -ic '$setup_cmd date'"
} # }}}

#
# launchers
#

_launch_cpp_project() { # {{{
	local projects_list="$MINX_USER_CPP_PROJECT_LIST"
	local choices
	local selection
	local proj_path
	local proj_name
	local session_name

	mkdir -p -- "$(dirname "$projects_list")"

	while true; do
		if [[ -r "$projects_list" ]]; then
			choices="$(
				grep -vE '^[[:space:]]*($|#)' "$projects_list" || true
			)"
		else
			choices="$(
				find "$HOME/repos" \
					-mindepth 1 \
					-maxdepth 4 \
					-type d \
					-name .git \
					-prune \
					-print |
					sed 's|/\.git$||' |
					sort -u
			)"
		fi

		selection="$(
			printf '%s\n' "$choices" edit-list |
				rofi -dmenu -i -p "cpp project"
		)"

		[[ -n "$selection" ]] || return 1

		if [[ "$selection" == edit-list ]]; then
			minx_run_or_raise_st \
				"cpp-projects" \
				"120x24+300+140" \
				_launch_cpp_project_list
			continue
		fi

		if [[ -d "$selection" ]]; then
			break
		fi

		rofi -e "Not a directory: $selection"
		return 1
	done

	proj_path="$selection"
	proj_name="$(_slugify_path "$proj_path")"
	session_name="cpp-$proj_name"

	local -a tmux_focus_cmd=(
		tmux
		select-window
		-t "$session_name:1"
	)

	minx_launch_st_tmux_session \
		"$session_name" \
		_tmux_cmds_cpp_project \
		tmux_focus_cmd \
		"$proj_path"
} # }}}

_launch_cpp_project_list() { # {{{
	vim "$MINX_USER_CPP_PROJECT_LIST"
} # }}}

_launch_librewolf() { # {{{
	librewolf
} # }}}

_launch_reference_file() { # {{{
	local reference_file="$1"
	vim "$reference_file"
} # }}}

_launch_notes_dir() { # {{{
	ranger "$LNCHR_NOTES_DIR"
} # }}}

_launch_maps() { # {{{
	qb.sh -p _default_ -o "https://www.google.com/maps/"
} # }}}

_launch_calendar() { # {{{
	if [[ "$USE_THUNDERBIRD" == 1 ]]; then
		thunderbird -calendar
	elif [[ "$USE_CALIX" == 1 ]]; then
		calix
	else
		minx_run_or_raise_st \
			"calendar" \
			"140x38+200+30" \
			ikhal "$@"
	fi

} # }}}

_connect_ssh_server() { # {{{
	ssh "$MINX_REMOTE_SSH_SERVER"
} # }}}

_launch_mail() { # {{{
	local account_type="${1:-notmuch}"
	local account_name="${2:-gmail}"
	shift 2

	env TASK_SHELL=1 bash -ic "MAIL_ACCOUNT=$account_name-$account_type neomutt -F $HOME/.config/neomutt/neomuttrc-$account_type $*"
} # }}}

_launch_tt() { # {{{
	env TASK_SHELL=1 bash -i
} # }}}

# =============================================================================
# browser
# =============================================================================

user_launcher_qb_profiles() { # {{{
	qb.sh >/dev/null
} # }}}

user_launcher_qb_profile1() { # {{{
	qb.sh -p "_default_" >/dev/null
} # }}}

user_launcher_qb_profile2() { # {{{
	qb.sh -p "_personal_" >/dev/null
} # }}}

user_launcher_qb_profile3() { # {{{
	qb.sh -p "_jobsearch_" >/dev/null
} # }}}

user_launcher_qb_profile4() { # {{{
	local class_name="librewolf"

	minx_run_or_raise \
		--class "$class_name" \
		_launch_librewolf
} # }}}

user_launcher_custom1() { # {{{
	printf '' | xclip -selection clipboard
	printf '' | xclip -selection primary
	notify-send "Clipboard" "cleared"
} # }}}

user_launcher_custom2() { # {{{
	# _launch_cpp_project
	passmenu.sh --select-password
} # }}}

user_launcher_calendar() { # {{{
	local class_name="calendar"
	minx_run_or_raise \
		--class "$class_name" \
		_launch_calendar
} # }}}

user_launcher_mail() { # {{{
	if [[ "$USE_THUNDERBIRD" == 1 ]]; then
		thunderbird -mail
	else
		minx_run_or_raise_st \
			"mail" \
			"140x38+200+30" \
			_launch_mail "$@"
	fi
} # }}}

user_launcher_tt_shell() { # {{{
	minx_run_or_raise_st \
		"tt_shell" \
		"80x20+1000+50" \
		_launch_tt
} # }}}

user_launcher_reference() { # {{{
	minx_run_or_raise_st \
		"reference" \
		"$LNCHR_GEOMETRY_LAPTOP" \
		_launch_reference_file \
		"$LNCHR_REFERENCE_FILE"
} # }}}

user_launcher_notes() { # {{{
	minx_run_or_raise_st \
		"notes" \
		"$LNCHR_GEOMETRY_LAPTOP" \
		_launch_notes_dir
} # }}}

user_launcher_maps() { # {{{
	local class_name="maps"

	minx_run_or_raise \
		--class "$class_name" \
		_launch_maps
} # }}}

user_launcher_remote1() { # {{{
	minx_run_or_raise_st \
		"ssh-server" \
		"$LNCHR_GEOMETRY_LAPTOP" \
		_connect_ssh_server
} # }}}

user_launcher_remote2() { # {{{
	notify-send \
		-u critical \
		"user_launcher_remote2" \
		"not implemented yet"
} # }}}

user_launcher_passmenu() { # {{{
	keepassmenu.sh --select-password
} # }}}

user_launcher_otpmenu() { # {{{
	keepassmenu.sh --select-otp
} # }}}
