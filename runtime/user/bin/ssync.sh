#!/usr/bin/env bash
set -euo pipefail
# set -x

readonly SCRIPT_NAME="${0##*/}"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/minx"
readonly LOG_DIR="$STATE_DIR/logs"
readonly SYNC_LOCK_DIR="$STATE_DIR/locks"

readonly FILES_SRC="$MINX_USER_FILES_DIR"
readonly FILES_DST="$MINX_REMOTE_SSH_SERVER:$MINX_REMOTE_FILES_DIR"
readonly NOTES_DIR="$MINX_USER_NOTES_DIR"

if ((EUID == 0)); then
	printf '%s\n' "=> Run \"$name\" as a NON-ROOT." >&2
	return 1
fi

# Syncs can contain credentials and personal information.
# Keep newly-created state, lock and log files private.
umask 077

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

_die() { # {{{
	printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
} # }}}

_require_commands() { # {{{
	local command

	for command in "$@"; do
		if ! command -v "$command" >/dev/null 2>&1; then
			printf '%s: required command not found: %s\n' \
				"$SCRIPT_NAME" "$command" >&2
			return 1
		fi
	done
} # }}}

_init_state() { # {{{
	mkdir -p \
		"$STATE_DIR" \
		"$LOG_DIR" \
		"$SYNC_LOCK_DIR"

	chmod 700 \
		"$STATE_DIR" \
		"$LOG_DIR" \
		"$SYNC_LOCK_DIR"
} # }}}

_log() { # {{{
	local log="$1"
	shift

	printf '[%s] %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" \
		"$*" | tee -a "$log" >&2
} # }}}

_git_sync() { # {{{
	local repo="$1"

	[[ -d "$repo/.git" ]] ||
		_die "Not a Git working tree: $repo"

	# Intentional: this sync is bidirectional.
	# A successful pull is required before pushing local changes.
	git -C "$repo" pull
	git -C "$repo" push
} # }}}

# ---------------------------------------------------------------------------
# Notes
# ---------------------------------------------------------------------------

_sync_notes() { # {{{
	_require_commands git || return 1

	_git_sync "$NOTES_DIR"
} # }}}

# ---------------------------------------------------------------------------
# Taskwarrior
# ---------------------------------------------------------------------------

_taskwarrior_tunnel_running() { # {{{
	local port="$1"

	lsof -nP -i "TCP:$port" -sTCP:LISTEN >/dev/null 2>&1
} # }}}

_taskwarrior_start_tunnel() { # {{{
	local ssh_alias="$1"
	local local_port="$2"
	local remote_port="$3"

	if _taskwarrior_tunnel_running "$local_port"; then
		printf 'SSH tunnel already running on port %s\n' \
			"$local_port" >&2
		return 0
	fi

	printf 'Starting SSH tunnel %s:%s -> localhost:%s\n' \
		"$ssh_alias" \
		"$local_port" \
		"$remote_port" >&2

	# Host-key verification remains enabled. Do not add StrictHostKeyChecking=no.
	ssh \
		-f \
		-N \
		-L "${local_port}:localhost:${remote_port}" \
		"$ssh_alias"
} # }}}

_sync_taskwarrior() { # {{{
	local ssh_alias="$MINX_REMOTE_SSH_SERVER"
	local local_port=8080
	local remote_port=8080
	local client_id
	local secret
	local pass_output

	_require_commands \
		task \
		pass \
		gpg-connect-agent \
		lsof \
		ssh || return 1

	gpg-connect-agent /bye >/dev/null 2>&1 || true

	_taskwarrior_start_tunnel \
		"$ssh_alias" \
		"$local_port" \
		"$remote_port"

	if ! pass_output="$(pass show personal/taskwarrior)"; then
		printf 'Unable to read Taskwarrior credentials from pass\n' >&2
		return 1
	fi

	mapfile -t taskchampion_data <<<"$pass_output"

	client_id=${taskchampion_data[0]}
	secret=${taskchampion_data[1]}

	if [[ -z "$secret" ]]; then
		printf 'Empty Taskwarrior secret\n' >&2
		return 1
	fi

	TASK_CLIENT_ID="$client_id" \
		TASK_SECRET="$secret" \
		task sync
} # }}}

# ---------------------------------------------------------------------------
# Mail
# ---------------------------------------------------------------------------

_mail_sync_account() { # {{{
	local account="$1"
	local lock_dir="$2"
	local lockfile="$lock_dir/$account.lock"
	local status

	(
		if ! flock -n 9; then
			printf '%s: synchronization already running\n' "$account" >&2
			return 75
		fi

		printf '%s: start\n' "$account" >&2

		mbsync "$account"
		status=$?

		if ((status == 0)); then
			printf '%s: success\n' "$account" >&2
		else
			printf '%s: failed (exit %d)\n' \
				"$account" "$status" >&2
		fi

		return "$status"
	) 9>"$lockfile"
} # }}}

_sync_mail() { # {{{
	local state_dir="$STATE_DIR/mail"
	local lock_dir="$state_dir/locks"
	local last_sync_file="$state_dir/last-sync"
	local tmp_file="$state_dir/last-sync.tmp"
	local account
	local pid
	local status
	local failed=0
	local -a accounts=()
	local -a pids=()

	if [ -z "$1" ]; then
		accounts+=(gmail gmx)
	else
		case "$1" in
		gmail | gmx)
			accounts+=("$1")
			;;
		*)
			printf 'ERROR: invalid account: %s\n' "$1" >&2
			return 2
			;;
		esac
	fi

	_require_commands mbsync notmuch flock date mv rm || return 1

	mkdir -p "$lock_dir" || return 1
	chmod 700 "$lock_dir" || return 1

	# Remove a stale temporary timestamp, if present.
	rm -f -- "$tmp_file" || return 1

	# Synchronize accounts in parallel.
	for account in "${accounts[@]}"; do
		_mail_sync_account "$account" "$lock_dir" &
		pids+=("$!")
	done

	# Every account must complete successfully in this run.
	for pid in "${pids[@]}"; do
		if wait "$pid"; then
			continue
		else
			status=$?
		fi

		if ((status == 75)); then
			printf 'Mail sync skipped: another process holds an account lock\n' >&2
		else
			printf 'Mail sync failed for a process (exit %d)\n' \
				"$status" >&2
		fi

		failed=1
	done

	if ((failed != 0)); then
		printf 'One or more mail accounts failed or were skipped\n' >&2
		return 1
	fi

	# Update the local notmuch database.
	printf 'notmuch: start\n' >&2

	if notmuch new; then
		printf 'notmuch: success\n' >&2
	else
		status=$?
		printf 'notmuch: failed (exit %d)\n' "$status" >&2
		return "$status"
	fi

	# Record completion only after every step succeeds.
	if ! date '+%Y%m%dT%H%M' >"$tmp_file"; then
		printf 'Failed to write synchronization timestamp\n' >&2
		rm -f -- "$tmp_file"
		return 1
	fi

	if ! mv -f -- "$tmp_file" "$last_sync_file"; then
		printf 'Failed to update synchronization timestamp\n' >&2
		rm -f -- "$tmp_file"
		return 1
	fi

	printf 'Mail synchronization completed at %s\n' \
		"$(<"$last_sync_file")" >&2

	return 0
} # }}}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

_sync_files() { # {{{
	_require_commands rsync ssh || return 1

	[[ -d "$FILES_SRC" ]] ||
		_die "Files source does not exist: $FILES_SRC"

	# Intentional and destructive:
	# files removed from the local source are removed from the remote
	# destination as well.
	rsync \
		-aHAX \
		--numeric-ids \
		--delete \
		--info=progress2 \
		-- \
		"$FILES_SRC" \
		"$FILES_DST"
} # }}}

# ---------------------------------------------------------------------------
# Calendar
# ---------------------------------------------------------------------------

_sync_calendar() { # {{{
	_require_commands vdirsyncer || return 1

	vdirsyncer sync
} # }}}

# ---------------------------------------------------------------------------
# ta
# ---------------------------------------------------------------------------

_sync_ta() { # {{{
	_require_commands timew ta || return 1

	if [[ "$(timew get dom.active)" -eq 1 ]]; then
		printf 'Synchronization not started: tracking is active\n' >&2
		return 0
	fi

	ta sync
} # }}}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_sync_function() { # {{{
	local name="$1"

	case "$name" in
	taskwarrior)
		printf '%s\n' "_sync_taskwarrior"
		;;
	mail)
		printf '%s\n' "_sync_mail"
		;;
	files)
		printf '%s\n' "_sync_files"
		;;
	notes)
		printf '%s\n' "_sync_notes"
		;;
	calendar)
		printf '%s\n' "_sync_calendar"
		;;
	ta)
		printf '%s\n' "_sync_ta"
		;;
	*)
		return 1
		;;
	esac
} # }}}

_print_help() { # {{{
	cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] SYNC

Synchronize one application.

Syncs:
    taskwarrior   Synchronize Taskwarrior
    mail          Synchronize mail and update the notmuch database
    files         Synchronize secured files
    notes         Synchronize secured notes
    calendar      Synchronize calendars
    ta            Synchronize time tracking

Examples:
    $SCRIPT_NAME calendar
    $SCRIPT_NAME mail

Only one sync can be specified per invocation.

Different syncs may run concurrently, but the same sync
cannot run concurrently with itself.

Output:
    stdout        Path to the application log
    stderr        Synchronization output and diagnostics

Logs:
    $LOG_DIR/ssync_<sync>.log
EOF
} # }}}

_parse_args() { # {{{
	local -n selected="$1"
	local arg

	shift

	if [[ "$#" -eq 0 ]]; then
		_print_help >&2
		return 1
	fi

	# if [[ "$#" -ne 1 ]]; then
	# 	printf '%s: exactly one sync must be specified\n\n' \
	# 		"$SCRIPT_NAME" >&2
	# 	_print_help >&2
	# 	return 2
	# fi

	arg="$1"

	case "$arg" in
	-h | --help)
		_print_help
		exit 0
		;;
	taskwarrior | mail | files | notes | calendar | ta)

		# shellcheck disable=2034 # variable passed as reference
		selected=("$arg")
		;;
	*)
		printf 'Unknown sync: %s\n\n' "$arg" >&2
		_print_help >&2
		return 2
		;;
	esac
} # }}}

_run_and_log() { # {{{
	local name="$1"
	local logfile="$LOG_DIR/ssync_$name.log"
	local function_name
	local start
	local end
	local status

	function_name="$(_sync_function "$name")"

	# # Every invocation gets a fresh application log.
	# : >"$logfile"

	{
		local marker="********************************************************************************"
		printf "\n%s" "$marker"
		printf "\n%s\n" "$(date)"
		cat "/opt/minx/version"
		printf "%s\n" "$marker"
	} >>"$logfile"

	_log "$logfile" "=> Start synchronization: $name"

	start="$(date +%s)"

	# All command output goes to stderr and is appended to the log.
	# stdout remains reserved for the final log path.
	if "$function_name" "${*:2}" 2>&1 |
		tee -a "$logfile" >&2; then
		status=0
	else
		status="${PIPESTATUS[0]}"
	fi

	end="$(date +%s)"

	if ((status == 0)); then
		_log "$logfile" "=> Success ($((end - start))s)"
	else
		_log "$logfile" \
			"=> Failed (exit $status, $((end - start))s)"
	fi

	return "$status"
} # }}}

_run_dispatch() { # {{{
	local -a _selected=()
	local name
	local logfile
	local lockfile
	local status

	_parse_args _selected "$@"

	shift

	name="${_selected[0]}"
	args="$*"

	logfile="$LOG_DIR/ssync_$name.log"
	lockfile="$SYNC_LOCK_DIR/ssync_$name.lock"

	# Each sync has its own lock.

	exec 9>"$lockfile"

	if ! flock -n 9; then
		printf '%s: %s synchronization already running\n' \
			"$SCRIPT_NAME" "$name" >&2

		# The canonical log path is still returned.
		printf '%s\n' "$logfile"

		return 75
	fi

	if _run_and_log "$name" "$args"; then
		status=0
	else
		status=$?
	fi

	# stdout is deliberately reserved for the canonical log path.
	printf '%s\n' "$logfile"

	return "$status"
} # }}}

main() { # {{{
	local app=${1:-all}

	if [[ "$app" == "all" ]]; then
		printf "%s\n" "=> ssync.sh all: start"

		local -a apps=(
			taskwarrior
			mail
			files
			notes
			calendar
			ta
		)

		for app in "${apps[@]}"; do
			ssync.sh "$app"
			printf "********************************************************************************\n"
		done

		printf "%s\n" "=> ssync.sh all: done"
	else

		_init_state
		_run_dispatch "$@"

	fi

} # }}}

main "$@"
