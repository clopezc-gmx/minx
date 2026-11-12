#!/usr/bin/env bash
# shellcheck disable=SC1091 # Path is resolved at runtime.

# minx_launcher.sh

# =============================================================================
# core
# =============================================================================

_sanitize_name() { # {{{
	tr '[:upper:]' '[:lower:]' |
		sed -E '
	s/[^a-z0-9._-]+/_/g;
	s/_+/_/g;
	s/^_+//;
	s/_+$//
	'
} # }}}

_slugify_path() { # {{{
	local p="${1:?path not set}"
	p="${p%/}"
	printf '%s' "${p##*/}" | _sanitize_name
} # }}}

minx_run_or_raise() { # {{{
	local mode="${1:?mode not set}"
	local target="${2:?target not set}"
	local fallback_cmd="${3:?fallback command not set}"
	shift 3

	local wid=""
	local fallback_reason=""

	wid="$(
		xdotool search "$mode" "$target" 2>/dev/null |
			head -n1 ||
			true
	)"

	if [[ -n "$wid" ]]; then
		if xdotool windowactivate --sync "$wid"; then
			return 0
		fi

		fallback_reason="failed to activate window $wid"
	else
		fallback_reason="no window found for $mode $target"
	fi

	printf '=> Warning: %s. Launching fallback.\n' \
		"$fallback_reason" >&2

	# Support both Bash functions and external executables.
	if declare -F "$fallback_cmd" >/dev/null; then
		"$fallback_cmd" "$@"
	else
		"$fallback_cmd" "$@"
	fi
} # }}}

minx_require_user_function() { # {{{
	local option="${1:?option not set}"
	local function_name="user_launcher_$option"

	if ! declare -F "$function_name" >/dev/null; then
		printf '=> Error: function "%s" does not exist in "%s".\n' \
			"$function_name" "${MINX_USER_TARGETS_FILE:-unknown}" >&2

		notify-send \
			-u critical \
			"Launcher error" \
			"Function: \"$function_name\" does not exist in user file"

		return 1
	fi

	shift

	"$function_name" "$@"
} # }}}

# =============================================================================
# st
# =============================================================================

_run_st() { # {{{
	local session_name="${1:?session_name not set}"
	local class_name="${2:?class_name not set}"
	local geometry="${3:?geometry not set}"
	local command_name="${4:?command_name not set}"
	shift 4

	if declare -F "$command_name" >/dev/null; then
		# Export only actual Bash functions.
		# shellcheck disable=SC2163
		export -f "$command_name" || return $?

		ST_STANDALONE=1 st \
			-g "$geometry" \
			-c "$class_name" \
			-T "$session_name" \
			-e bash -c '"$@"' bash "$command_name" "$@"
	else
		ST_STANDALONE=1 st \
			-g "$geometry" \
			-c "$class_name" \
			-T "$session_name" \
			-e "$command_name" "$@"
	fi
} # }}}

__open_vim() { # {{{
	vim -n \
		-c 'set filetype=text' \
		-c 'if line("$") == 1 && col("$") == 1 && empty(getline(1)) | startinsert | else | normal! G$ | endif' \
		-- "$@"
} # }}}

_run_or_raise_st_vim() { # {{{
	local title_name="${1:?title_name not set}"
	local class_name="${2:?class_name not set}"
	local tmpfile="${3:?tmpfile not set}"
	local geometry="${4:?geometry not set}"

	local session_name="st-$title_name"

	minx_run_or_raise \
		--class "$class_name" \
		_run_st \
		"$session_name" \
		"$class_name" \
		"$geometry" \
		__open_vim \
		"$tmpfile"
} # }}}

minx_launch_txtclip() { # {{{
	local file_name="${1:?file_name not set}"
	local class_name="${2:?class_name not set}"
	local geometry="${3:?geometry not set}"
	local notify="${4:?notify not set}"

	local safe_file_name=""
	local tmpfile=""
	local is_temp=0
	local rc=0
	local clipboard_rc=0

	if [[ -f "$file_name" ]]; then
		[[ "$notify" == "--notify" ]] &&
			notify-send "It's a file: $file_name"

		tmpfile="$file_name"
		file_name="${file_name##*/}"
	else
		is_temp=1
		safe_file_name="$(printf '%s' "$file_name" | _sanitize_name)"

		tmpfile="$(
			mktemp "${TMPDIR:-/tmp}/${safe_file_name:-txtclip}.XXXXXX"
		)" || return $?
	fi

	_run_or_raise_st_vim \
		"$file_name" "$class_name" "$tmpfile" "$geometry" || rc=$?

	# An empty buffer does not replace the current clipboard.
	# Preserve nonempty content even if the editor exits with an error.
	if [[ -s "$tmpfile" ]]; then
		if xclip -selection clipboard <"$tmpfile"; then
			[[ "$notify" == "--notify" ]] &&
				notify-send \
					"Clipboard Updated" \
					"$file_name copied to clipboard."
		else
			printf '=> Error: failed to copy "%s" to the clipboard.\n' \
				"$file_name" >&2
			clipboard_rc=1
		fi
	fi

	if ((is_temp)); then
		if ! rm -f -- "$tmpfile"; then
			printf '=> Warning: failed to remove temporary file: %s\n' \
				"$tmpfile" >&2
			((rc != 0)) || rc=1
		fi
	fi

	if ((rc != 0)); then
		return "$rc"
	fi

	return "$clipboard_rc"
} # }}}

# =============================================================================
# tmux
# =============================================================================

_run_st_tmux_session() { # {{{
	local session_name="${1:?session_name not set}"
	local class_name="${2:?class_name not set}"
	local title_name="${3:?title_name not set}"
	local geometry="${4:?geometry not set}"

	ST_STANDALONE=0 st \
		-g "$geometry" \
		-c "$class_name" \
		-T "$title_name" \
		-e tmux attach-session -t "$session_name"
} # }}}

minx_launch_st_tmux_session() { # {{{
	local session_name="${1:?session_name not set}"
	local tmux_cmd_fn="${2:?tmux_cmd_fn not set}"
	local focus_array_name="${3:-}"
	local geometry="${4:-80x24}"

	local class_name="st-tmux-$session_name"
	local title_name="$session_name"
	local wid=""
	local st_pid=""
	local created=0
	local array_decl=""

	# ----------------------------------------------------------------------
	# Validate the callback and focus array.
	# ----------------------------------------------------------------------

	if ! declare -F "$tmux_cmd_fn" >/dev/null; then
		printf '=> Error: tmux callback "%s" does not exist.\n' \
			"$tmux_cmd_fn" >&2
		return 2
	fi

	if [[ -n "$focus_array_name" ]]; then
		if [[ ! "$focus_array_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
			printf '=> Error: invalid focus array name: %s\n' \
				"$focus_array_name" >&2
			return 2
		fi

		array_decl="$(declare -p "$focus_array_name" 2>/dev/null)" || {
			printf '=> Error: focus command array "%s" is not defined.\n' \
				"$focus_array_name" >&2
			return 2
		}

		if [[ ! "$array_decl" =~ ^declare\ -[^[:space:]]*a[[:space:]] ]]; then
			printf '=> Error: focus command "%s" must be an indexed array.\n' \
				"$focus_array_name" >&2
			return 2
		fi

		local -n tmux_focus="$focus_array_name"

		if ((${#tmux_focus[@]} == 0)); then
			printf '%s\n' '=> Error: tmux focus command array is empty.' >&2
			return 2
		fi
	fi

	# ----------------------------------------------------------------------
	# Create the tmux session if necessary.
	# ----------------------------------------------------------------------

	if ! tmux has-session -t "$session_name" 2>/dev/null; then
		if tmux new-session \
			-d \
			-s "$session_name" \
			-n main \
			"bash -i"; then
			created=1
		elif ! tmux has-session -t "$session_name" 2>/dev/null; then
			printf '=> Error: failed to create tmux session "%s".\n' \
				"$session_name" >&2
			return 1
		fi
	fi

	# ----------------------------------------------------------------------
	# Initialize only sessions created by this invocation.
	# ----------------------------------------------------------------------

	if ((created)); then
		if ! tmux set-option \
			-t "$session_name" \
			default-command "bash -i"; then
			printf '=> Error: failed to configure tmux session "%s".\n' \
				"$session_name" >&2
			return 1
		fi

		if ! "$tmux_cmd_fn" "$session_name"; then
			printf '=> Error: tmux initialization callback failed for "%s".\n' \
				"$session_name" >&2
			return 1
		fi
	fi

	# ----------------------------------------------------------------------
	# Look for an existing st window.
	# ----------------------------------------------------------------------

	wid="$(
		xdotool search --class "$class_name" 2>/dev/null |
			head -n1 ||
			true
	)"

	if [[ -z "$wid" ]]; then
		printf '=> No window found for --class %s. Launching terminal.\n' \
			"$class_name" >&2

		ST_STANDALONE=0 st \
			-g "$geometry" \
			-c "$class_name" \
			-T "$title_name" \
			-e tmux attach-session -t "$session_name" &

		st_pid=$!

		# Wait for the X window to appear.
		for _ in {1..50}; do
			wid="$(
				xdotool search --class "$class_name" 2>/dev/null |
					head -n1 ||
					true
			)"

			if [[ -n "$wid" ]]; then
				break
			fi

			if ! kill -0 "$st_pid" 2>/dev/null; then
				wait "$st_pid" 2>/dev/null || true

				printf '%s\n' \
					'=> Error: st exited before its window appeared.' >&2
				return 1
			fi

			sleep 0.1
		done

		if [[ -z "$wid" ]]; then
			printf '=> Error: timed out waiting for window "%s".\n' \
				"$class_name" >&2

			if kill -0 "$st_pid" 2>/dev/null; then
				kill "$st_pid" 2>/dev/null || true
				wait "$st_pid" 2>/dev/null || true
			fi

			return 1
		fi
	fi

	# ----------------------------------------------------------------------
	# Focus the terminal window.
	# ----------------------------------------------------------------------

	if ! xdotool windowactivate --sync "$wid"; then
		printf '=> Error: failed to activate window %s.\n' "$wid" >&2
		return 1
	fi

	# ----------------------------------------------------------------------
	# Apply the requested tmux focus command.
	# ----------------------------------------------------------------------

	if [[ -n "$focus_array_name" ]]; then
		if "${tmux_focus[@]}"; then
			:
		else
			local rc=$?
			printf '=> Error: tmux focus command failed for "%s".\n' \
				"$session_name" >&2
			return "$rc"
		fi
	fi
} # }}}

minx_select_st_tmux() { # {{{
	local -a sessions=()
	local -a tmux_focus_cmd=()
	local choice=""
	local sname=""
	local window_target=""
	local geometry="${1:-80x24}"

	mapfile -t sessions < <(
		tmux list-sessions \
			-F '#{session_name}' \
			2>/dev/null |
			grep -vxF organize ||
			true
	)

	choice="$(
		printf '%s\n' "${sessions[@]}" |
			rofi -dmenu -i -p 'tmux sessions' ||
			true
	)"

	# Cancel is a normal outcome.
	[[ -n "$choice" ]] || return 0

	if printf '%s\n' "${sessions[@]}" | grep -Fxq -- "$choice"; then
		sname="$choice"
	else
		sname="$(printf '%s' "$choice" | _sanitize_name)"
		[[ -n "$sname" ]] || return 1
	fi

	# Prefer main when available; otherwise select the first existing
	# window. A newly created session will have a main window.
	if tmux has-session -t "$sname" 2>/dev/null; then
		if tmux list-windows \
			-t "$sname" \
			-F '#{window_name}' 2>/dev/null |
			grep -Fxq main; then
			window_target="main"
		else
			window_target="$(
				tmux list-windows \
					-t "$sname" \
					-F '#{window_index}' 2>/dev/null |
					head -n1
			)"
		fi
	else
		window_target="main"
	fi

	if [[ -z "$window_target" ]]; then
		printf '=> Error: could not determine a window for session "%s".\n' \
			"$sname" >&2
		return 1
	fi

	# Select the initial window by its name or index.
	# shellcheck disable=SC2034 # Passed by name to a nameref.
	tmux_focus_cmd=(
		tmux
		select-window
		-t
		"$sname:$window_target"
	)

	minx_launch_st_tmux_session \
		"$sname" \
		_tmux_cmds_noop \
		tmux_focus_cmd \
		"$geometry"
} # }}}

_tmux_cmds_noop() { # {{{
	true
} # }}}

minx_run_or_raise_st() { # {{{
	local session_name="${1:?session_name not set}"
	local geometry="${2:?geometry not set}"
	local bash_fn="${3:?bash_fn not set}"
	shift 3

	local class_name="st-solo-$session_name"

	minx_run_or_raise \
		--class \
		"$class_name" \
		_run_st \
		"$session_name" \
		"$class_name" \
		"$geometry" \
		"$bash_fn" \
		"$@"
} # }}}
