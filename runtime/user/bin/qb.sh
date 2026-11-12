#!/usr/bin/env bash
set -euo pipefail
# set -x

# =============================================
# qutebrowser_profile_launcher.sh
#
# Launches qutebrowser with a chosen profile.
# -o URL focuses an existing tab with the same
# hostname, or opens the URL in a new tab.
# Requires the open_or_focus command in config.py.
# =============================================

if [ -z "${DISPLAY:-}" ]; then
	printf '%s\n' "qb.sh requires X running." >&2
	exit 1
fi

if ! command -v qutebrowser >/dev/null 2>&1; then
	notify-send -u critical "qb.sh" "qutebrowser is not available"
	exit 1
fi

tb_symlink() { # {{{
	local source="$1"
	local destination="$2"

	mkdir -p -- "$(dirname -- "$destination")" || return 1

	if [[ -L "$destination" ]]; then
		# Replace an existing symlink.
		rm -f -- "$destination" || return 1
	elif [[ -e "$destination" ]]; then
		# Never silently delete a real file or directory.
		printf '%s\n' \
			"=> Error: destination already exists and is not a symlink: $destination" >&2
		return 1
	fi

	printf '%s\n' "=> Linking $destination -> $source"

	ln -s -- "$source" "$destination" || return 1

	if ! readlink -e -- "$destination" >/dev/null; then
		printf '%s\n' "=> Error: source does not exist: $source" >&2
		rm -f -- "$destination"
		return 1
	fi
} # }}}

BACKUP_PROFILE_DIR="$HOME/.config/tb/qutebrowser/profiles"
ACTIVE_PROFILE_DIR="$HOME/.local/share/qutebrowser/profiles"

_backup_profiles() { # {{{
	local dest="$BACKUP_PROFILE_DIR"
	local profiles_dir="$ACTIVE_PROFILE_DIR"
	local profile
	local profile_name

	mkdir -p -- "$dest"

	for profile in "$profiles_dir"/*; do
		[[ -e "$profile" ]] || continue

		profile_name="$(basename -- "$profile")"

		printf '%s\n' "=> Processing profile: $profile_name"

		if [[ -f "$profile/config/quickmarks" ]]; then
			mkdir -p -- "$dest/$profile_name/config"
			printf '%s\n' "=> Copying quickmarks..."
			rsync -av --progress \
				"$profile/config/quickmarks" \
				"$dest/$profile_name/config/"
		fi

		if [[ -f "$profile/bookmarks" ]]; then
			mkdir -p -- "$dest/$profile_name/config"
			printf '%s\n' "=> Copying bookmarks..."
			rsync -av --progress \
				"$profile/bookmarks" \
				"$dest/$profile_name/config/"
		fi
	done

	printf '%s\n' "=> All Qutebrowser profiles mirrored to $dest"
} # }}}

# shellcheck disable=SC2154 # opts is an associative-array nameref
_setup() { # {{{

	local -n opts="$1"

	opts[profiles]="$ACTIVE_PROFILE_DIR"
	opts[file_url]=""
	opts[command]=""
	opts[profile_name]=""
	opts[initialize]="0"

	mkdir -p -- "${opts[profiles]}"
} # }}}

_usage() { # {{{
	printf '%s\n' \
		"Usage: $0 [-f file] [-c command] [-n profile] [-o url] [-p profile] [-b]" \
		"  -f file     open file" \
		"  -c command  execute command inside qutebrowser" \
		"  -n profile  recreate and initialize profile" \
		"  -o url      focus matching hostname or open URL in a new tab" \
		"  -p profile  open selected profile" \
		"  -b          backup profiles"

	return 1
} # }}}

# shellcheck disable=SC2178 # opts is an associative-array nameref
_parse_args() { # {{{
	local -n opts="$1"

	shift

	while getopts ":f:c:p:n:o:b" opt; do
		case "$opt" in
		f)
			if [[ -f "$OPTARG" ]]; then
				opts[file_url]="file://$(realpath -- "$OPTARG")"
				printf '%s\n' \
					"=> File provided: $OPTARG -> ${opts[file_url]}"
			else
				printf '%s\n' \
					"=> Error: '$OPTARG' is not a valid file." >&2
				return 1
			fi
			;;

		c)
			opts[command]="$OPTARG"
			printf '%s\n' "=> Command: ${opts[command]}"
			;;

		p)
			opts[profile_name]="$OPTARG"
			printf '%s\n' "=> Profile specified: ${opts[profile_name]}"
			;;

		n)
			opts[initialize]="1"
			opts[profile_name]="$OPTARG"
			printf '%s\n' "=> Profile specified: ${opts[profile_name]}"
			;;

		o)
			# Use the custom command defined in config.py.
			opts[command]=":open-or-focus $OPTARG"
			printf '%s\n' "=> Open or focus: $OPTARG"
			;;

		b)
			_backup_profiles
			return $?
			;;

		*)
			_usage
			return 1
			;;
		esac
	done

	shift $((OPTIND - 1))

	if [[ $# -gt 0 ]]; then
		printf '%s\n' "=> Error: Unexpected argument(s) passed." >&2
		_usage
		return 1
	fi
} # }}}

# shellcheck disable=SC2178 # opts is an associative-array nameref
_prompt_profile() { # {{{
	local -n opts="$1"

	if [[ -z "${opts[profile_name]}" ]]; then
		opts[profile_name]=$(
			find "${opts[profiles]}" \
				-mindepth 1 \
				-maxdepth 1 \
				-type d \
				-printf '%f\n' 2>/dev/null |
				sort |
				rofi -dmenu -i -p "Select or type session name"
		)

		if [[ -z "${opts[profile_name]}" ]]; then
			printf '%s\n' "=> No profile name selected. Exiting."
			return 1
		fi
	fi

	printf '%s\n' "=> Selected profile: ${opts[profile_name]}"
} # }}}

_delete_profile() { # {{{
	local -n opts="$1"

	local profiles="${opts[profiles]}"
	local profile_name="${opts[profile_name]}"
	local profile_folder="$profiles/$profile_name"

	if [[ -d "$profile_folder" ]]; then
		printf '%s\n' "=> Deleting $profile_folder..."
		rm -rf -- "$profile_folder"
	fi
} # }}}

_init_profile() { # {{{
	local -n opts="$1"

	local profile_folder="${opts[profiles]}/${opts[profile_name]}"
	local session_file="$profile_folder/data/sessions/${opts[profile_name]}.yml"
	local profile_config="$profile_folder/config.py"
	local quickmarks_file="$BACKUP_PROFILE_DIR/${opts[profile_name]}/config/quickmarks"
	local bookmarks_file="$BACKUP_PROFILE_DIR/${opts[profile_name]}/config/bookmarks"

	printf '%s\n' "=> Profile folder: $profile_folder"
	printf '%s\n' "=> Session file:   $session_file"
	printf '%s\n' "=> Config path:    $profile_config"

	if [[ ! -d "$profile_folder" ]] ||
		[[ -z "$(ls -A "$profile_folder" 2>/dev/null)" ]] ||
		[[ ! -f "$profile_folder/profile_name.txt" ]]; then
		printf '%s\n' "=> Profile doesn't exist or is empty"

		if [[ "${opts[initialize]}" -eq 0 ]]; then
			notify-send \
				-u critical \
				"qb.sh" \
				"profile does not exist, run qb.sh -n ${opts[profile_name]}"
			return 1
		fi

		printf '%s\n' "=> Initializing..."

		mkdir -p \
			"$profile_folder/cache" \
			"$profile_folder/data" \
			"$profile_folder/localstore" \
			"$profile_folder/config" \
			"$profile_folder/runtime"

		tb_symlink "$HOME/.config/qutebrowser/config.py" "$profile_config" || return 1
		tb_symlink "$HOME/.config/qutebrowser/open_or_focus.py" "$profile_folder/open_or_focus.py" || return 1
		tb_symlink "/opt/minx/repos/qutebrowser_dracula_theme" "$profile_folder/dracula" || return 1

		if [[ -f "$quickmarks_file" ]]; then
			cp -- "$quickmarks_file" "$profile_folder/config/quickmarks"
		fi

		if [[ -f "$bookmarks_file" ]]; then
			cp -- "$bookmarks_file" "$profile_folder/config/bookmarks"
		fi

		printf '%s\n' "${opts[profile_name]}" \
			>"$profile_folder/profile_name.txt"

		printf '%s\n' \
			"=> Launching qutebrowser for initial profile setup..."

		qutebrowser \
			-B "$profile_folder" \
			-C "$profile_config" &

		sleep 5

		printf '%s\n' \
			"=> Initial launch complete. Close qutebrowser manually to save the session."
	else
		printf '%s\n' "=> Profile exists"
	fi
} # }}}

_detect_running_profile() { # {{{
	local profile_name="$1"

	xdotool search --name "$profile_name" 2>/dev/null |
		head -n1 ||
		true
} # }}}

_focus_window() { # {{{
	local win_id="$1"

	if [[ -n "$win_id" ]]; then
		printf '%s\n' "=> Focusing and raising window..."
		xdotool windowactivate "$win_id"
		xdotool windowraise "$win_id"
	fi
} # }}}

_launch_qutebrowser() { # {{{
	local -n opts="$1"
	local win_id="$2"

	local profile_folder="${opts[profiles]}/${opts[profile_name]}"
	local session_file="$profile_folder/data/sessions/${opts[profile_name]}.yml"
	local profile_config="$profile_folder/config.py"

	if [[ -n "$win_id" ]]; then
		printf '%s\n' "=> Profile is running"
		_focus_window "$win_id"

		if [[ -n "${opts[file_url]}" ]]; then
			printf '%s\n' "=> Opening file in new tab..."

			qutebrowser \
				-B "$profile_folder" \
				-C "$profile_config" \
				"${opts[file_url]}" &
		fi
	else
		printf '%s\n' \
			"=> Profile is not running. Launching qutebrowser..."

		if [[ -n "${opts[file_url]}" ]]; then
			printf '%s\n' \
				"=> Launching with file: ${opts[file_url]}"

			qutebrowser \
				-B "$profile_folder" \
				-C "$profile_config" \
				--qt-arg "name=${opts[profile_name]}" \
				"${opts[file_url]}" &

		elif [[ -f "$session_file" ]]; then
			printf '%s\n' \
				"=> Session file exists. Restoring session..."

			qutebrowser \
				-B "$profile_folder" \
				-C "$profile_config" \
				--qt-arg "name=${opts[profile_name]}" \
				--restore "$session_file" &

		else
			printf '%s\n' \
				"=> No session file found. Launching normally..."

			qutebrowser \
				-B "$profile_folder" \
				-C "$profile_config" &
		fi
	fi
} # }}}

_autofocus_window() { # {{{
	local profile_name="$1"
	local window_id=""

	printf '%s\n' \
		"=> Autofocus. Waiting for qutebrowser window to appear..."

	for i in {1..10}; do
		sleep 0.5

		window_id="$(_detect_running_profile "$profile_name")"

		printf '%s\n' "=> Attempt $i/10"

		if [[ -n "$window_id" ]]; then
			printf '%s\n' "=> Window detected! ID: $window_id"
			_focus_window "$window_id"
			break
		fi
	done
} # }}}

_execute_command() { # {{{
	local -n opts="$1"
	local command="${opts[command]}"
	local profile_folder="${opts[profiles]}/${opts[profile_name]}"
	local profile_config="$profile_folder/config.py"

	if [[ -n "$command" ]]; then
		printf '%s\n' "=> Executing command directly: $command"

		qutebrowser \
			-B "$profile_folder" \
			-C "$profile_config" \
			"$command" &
	fi
} # }}}

launch() { # {{{
	local -A _opts=()
	local window_id

	_setup _opts
	_parse_args _opts "$@" || return 1

	# -b performs the backup and returns from _parse_args.
	if [[ "$#" -gt 0 && "${1:-}" == "-b" ]]; then
		return 0
	fi

	_prompt_profile _opts || return 1

	if [[ "${_opts[initialize]}" -eq 1 ]]; then
		printf '%s\n' \
			"=> Checking if profile is already running (by window name)..."

		window_id="$(_detect_running_profile "${_opts[profile_name]}")"

		if [[ -n "$window_id" ]]; then
			printf '%s\n' \
				"=> Profile is running: killing window $window_id"

			xdotool windowkill "$window_id"
		fi

		_delete_profile _opts
	fi

	_init_profile _opts || return 1

	printf '%s\n' \
		"=> Checking if profile is already running (by window name)..."

	window_id="$(_detect_running_profile "${_opts[profile_name]}")"

	_launch_qutebrowser _opts "$window_id"

	_autofocus_window "${_opts[profile_name]}"

	# Re-detect after autofocus because the original window ID
	# may have been empty when qutebrowser was launched.
	window_id="$(_detect_running_profile "${_opts[profile_name]}")"

	_execute_command _opts

	printf '%s\n' "=> Done."
} # }}}

launch "$@"
