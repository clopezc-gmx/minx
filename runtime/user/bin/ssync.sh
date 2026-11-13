#!/usr/bin/env bash
#
# ssync.sh - synchronize one application (or all of them).
#
# Design notes:
#   * Each sync runs in its own child process ("--exec"), so `set -e` is
#     actually effective inside the sync functions. (Bash disables errexit
#     for anything called from an `if`/`||`/`&&` condition or a pipeline
#     that is itself in such a context.) Critical steps ALSO check their
#     exit status explicitly.
#   * Never enable `set -x`: it would write credentials to the log.
#   * PATH is taken from the environment (keepassmenu.sh must be on it).
set -euo pipefail

# shellcheck source=/dev/null
source /etc/profile.d/minx_profile.sh

# Refuse xtrace: it would leak secrets into the terminal and the log.
case "$-" in
*x*)
	printf '%s\n' "ssync.sh: refusing to run with xtrace enabled" >&2
	exit 1
	;;
esac

# Syncs can contain credentials and personal information.
# Keep newly-created state, lock and log files private.
umask 077

readonly SCRIPT_NAME="${0##*/}"
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SELF
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/minx"
readonly LOG_DIR="$STATE_DIR/logs"
readonly SYNC_LOCK_DIR="$STATE_DIR/locks"
readonly LOG_MAX_BYTES=$((1024 * 1024))
readonly ALL_SYNCS=(taskwarrior mail assets passwords documents calendar ta)

# Set by --dry-run; inherited by child processes.
DRY_RUN="${DRY_RUN:-0}"

# Taskwarrior tunnel state (used by the EXIT trap).
TW_TUNNEL_OWNED=0
TW_SOCK=""
TW_ALIAS=""

if ((EUID == 0)); then
	printf '%s: do not run as root\n' "$SCRIPT_NAME" >&2
	exit 1
fi

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

# Validate configuration lazily, so e.g. `calendar` does not depend on the
# variables that only `assets` needs. Fails on unset AND empty values.
_require_env() { # {{{
	local var

	for var in "$@"; do
		if [[ -z "${!var:-}" ]]; then
			printf '%s: required environment variable is unset or empty: %s\n' \
				"$SCRIPT_NAME" "$var" >&2
			return 1
		fi
	done
} # }}}

_init_state() { # {{{
	mkdir -p -- \
		"$STATE_DIR" \
		"$LOG_DIR" \
		"$SYNC_LOCK_DIR"

	chmod 700 -- \
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

# Keep one previous generation; the log would otherwise grow forever.
_rotate_log() { # {{{
	local log="$1"
	local size

	[[ -f "$log" ]] || return 0

	size="$(wc -c <"$log")" || return 0
	size="${size//[[:space:]]/}"

	if ((size > LOG_MAX_BYTES)); then
		mv -f -- "$log" "$log.1"
	fi
} # }}}

_cleanup() { # {{{
	# Close the Taskwarrior tunnel only if this process started it.
	if ((TW_TUNNEL_OWNED == 1)) && [[ -n "$TW_SOCK" ]]; then
		ssh -S "$TW_SOCK" -O exit "$TW_ALIAS" >/dev/null 2>&1 || true
	fi
} # }}}

_git_sync() { # {{{
	local repo="$1"

	git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
		_die "Not a Git working tree: $repo"

	# Never open an editor, never prompt, never create a merge commit.
	export GIT_TERMINAL_PROMPT=0
	export GIT_MERGE_AUTOEDIT=no

	# Intentional: this sync is bidirectional.
	# A successful fast-forward pull is required before pushing.
	git -C "$repo" pull --ff-only || return 1
	git -C "$repo" push || return 1
} # }}}

# ---------------------------------------------------------------------------
# Passwords
# ---------------------------------------------------------------------------

_sync_passwords() { # {{{
	_require_env MINX_USER_DOCUMENTS_DIR || return 1
	_require_commands git || return 1

	_git_sync "$HOME/.password-store/"
} # }}}

# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

_sync_documents() { # {{{
	_require_env MINX_USER_DOCUMENTS_DIR || return 1
	_require_commands git || return 1

	local repo="$MINX_USER_DOCUMENTS_DIR"

	git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
		_die "Not a Git working tree: $repo"

	if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
		local message="Documents synchronization skipped: working tree is dirty"

		printf '%s\n' "$message" >&2
		if command -v notify-send >/dev/null 2>&1; then
			notify-send -u critical "Synchronization" "$message" || true
		fi
		return 1
	fi

	_git_sync "$repo"
} # }}}

# ---------------------------------------------------------------------------
# Taskwarrior
# ---------------------------------------------------------------------------

# Start (or reuse) an SSH tunnel managed through a private control socket,
# so we only ever talk to a tunnel WE created, not to any process that
# happens to listen on the port.
_taskwarrior_start_tunnel() {
	local ssh_alias="$1"
	local local_port="$2"
	local remote_port="$3"

	# Reuse an existing SSH master managed by ~/.ssh/config.
	if ssh -O check "$ssh_alias" >/dev/null 2>&1; then
		printf 'Reusing existing SSH master connection\n' >&2
		TW_TUNNEL_OWNED=0
		return 0
	fi

	TW_SOCK="$STATE_DIR/tw-tunnel.sock"
	TW_ALIAS="$ssh_alias"

	# Refuse to use an unrelated listener.
	if lsof -nP -i "TCP:$local_port" -sTCP:LISTEN >/dev/null 2>&1; then
		printf 'Port %s is already used by another process\n' \
			"$local_port" >&2
		return 1
	fi

	printf 'Starting dedicated SSH tunnel 127.0.0.1:%s -> %s:%s\n' \
		"$local_port" "$ssh_alias" "$remote_port" >&2

	ssh \
		-M -S "$TW_SOCK" \
		-f -N \
		-o ControlMaster=yes \
		-o ExitOnForwardFailure=yes \
		-o BatchMode=yes \
		-o ClearAllForwardings=yes \
		-L "127.0.0.1:${local_port}:127.0.0.1:${remote_port}" \
		"$ssh_alias" 200>&- || return 1

	TW_TUNNEL_OWNED=1
}

_sync_taskwarrior() { # {{{
	_require_env MINX_REMOTE_SSH_SERVER || return 1
	_require_commands task ssh lsof keepassmenu.sh || return 1

	local ssh_alias="$MINX_REMOTE_SSH_SERVER"
	local local_port=8080
	local remote_port=8080
	local client_id=""
	local secret=""
	local status=0

	_taskwarrior_start_tunnel \
		"$ssh_alias" \
		"$local_port" \
		"$remote_port" || return 1

	client_id="$(keepassmenu.sh --get-username personal/taskwarrior)" ||
		return 1
	secret="$(keepassmenu.sh --get-password personal/taskwarrior)" ||
		return 1

	if [[ -z "$client_id" || -z "$secret" ]]; then
		printf 'Taskwarrior credentials are empty\n' >&2
		return 1
	fi

	if TASK_CLIENT_ID="$client_id" TASK_SECRET="$secret" task sync; then
		status=0
	else
		status=$?
	fi

	unset client_id secret
	return "$status"
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
			exit 75
		fi

		printf '%s: start\n' "$account" >&2

		if mbsync "$account"; then
			printf '%s: success\n' "$account" >&2
			exit 0
		else
			status=$?
			printf '%s: failed (exit %d)\n' "$account" "$status" >&2
			exit "$status"
		fi
	) 9>"$lockfile"
} # }}}

_sync_mail() { # {{{
	local requested="${1:-}"
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

	if [[ -z "$requested" ]]; then
		accounts+=(gmail gmx)
	else
		case "$requested" in
		gmail | gmx)
			accounts+=("$requested")
			;;
		*)
			printf 'ERROR: invalid account: %s\n' "$requested" >&2
			return 2
			;;
		esac
	fi

	_require_commands mbsync notmuch flock date mv rm || return 1

	mkdir -p -- "$lock_dir" || return 1
	chmod 700 -- "$state_dir" "$lock_dir" || return 1

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
} # }}}

# ---------------------------------------------------------------------------
# Assets
# ---------------------------------------------------------------------------

_sync_assets() { # {{{
	_require_env \
		MINX_USER_ASSETS_DIR \
		MINX_REMOTE_SSH_SERVER \
		MINX_REMOTE_ASSETS_BASEDIR || return 1
	_require_commands unison ssh ls || return 1

	local src="${MINX_USER_ASSETS_DIR%/}"
	local remote_dir="${MINX_REMOTE_ASSETS_BASEDIR%/}"
	local host="$MINX_REMOTE_SSH_SERVER"
	local base="${src##*/}"
	local max_backups="${MINX_SYNC_MAX_BACKUPS:-5}"
	local root_remote
	local status=0
	local -a opts=()

	# `/`, `.`, `~` or an empty value would make the remote root the filesystem root or the remote home directory.

	# shellcheck disable=SC2088 #Testing against symbols
	case "$MINX_REMOTE_ASSETS_BASEDIR" in / | . | ./ | '~' | '~/' | //)
		_die "Refusing dangerous remote directory: $MINX_REMOTE_ASSETS_BASEDIR"
		;;
	esac

	# The host ends up inside a URL, so keep it to plain host/alias characters.
	[[ "$host" =~ ^[A-Za-z0-9._@-]+$ ]] ||
		_die "Invalid SSH server name: $host"

	[[ "$max_backups" =~ ^[0-9]+$ ]] ||
		_die "MINX_SYNC_MAX_BACKUPS must be a number: $max_backups"

	[[ -n "$src" && -n "$base" && "$src" != -* ]] ||
		_die "Invalid assets source: ${MINX_USER_ASSETS_DIR}"

	[[ -d "$src" ]] ||
		_die "Assets source does not exist: $src"

	# An empty source (e.g. an unmounted volume) looks like "everything was
	# deleted". unison would also stop (-confirmbigdel), but fail early.
	[[ -n "$(ls -A -- "$src")" ]] ||
		_die "Assets source is empty, refusing to sync: $src"

	# Same layout as the old rsync call: <remote dir>/<basename of source>.
	# unison URL syntax: ssh://host/relative/path (relative to the remote
	# home) and ssh://host//absolute/path. Joining with "/" yields both.
	root_remote="ssh://$host/$remote_dir/$base"

	# This is a TWO-WAY sync (not a mirror): changes and deletions made on
	# either side are propagated to the other.
	#   * -batch              never ask questions; conflicts are skipped
	#                         (and reported through the exit status),
	#   * -confirmbigdel      in batch mode, abort if a whole replica or
	#                         top-level directory would be deleted,
	#   * -backup             keep up to $max_backups old versions of
	#                         changed/deleted files (in unison's central
	#                         backup dir on each machine); disable with
	#                         MINX_SYNC_BACKUP=0,
	#   * -sshargs            no password/host-key prompts, fail instead.
	opts=(
		-batch
		-ui text
		-times
		-confirmbigdel
		-sshargs "-o BatchMode=yes"
		-logfile "$LOG_DIR/unison.log"
	)

	if [[ "${MINX_SYNC_BACKUP:-1}" == 1 ]]; then
		opts+=(
			-backup 'Name *'
			-backuplocation central
			-maxbackups "$max_backups"
		)
	fi

	if [[ "$DRY_RUN" == 1 ]]; then
		# Block every propagation on both roots: unison only reports
		# what it WOULD do (as skipped items).
		opts+=(
			-noupdate "$src" -noupdate "$root_remote"
			-nocreation "$src" -nocreation "$root_remote"
			-nodeletion "$src" -nodeletion "$root_remote"
		)
		printf 'DRY RUN: no changes will be made\n' >&2
	fi

	unison "${opts[@]}" "$src" "$root_remote" || status=$?

	if ((status == 0)); then
		return 0
	fi

	# In a dry run every blocked action counts as skipped/failed.
	if [[ "$DRY_RUN" == 1 ]] && ((status < 3)); then
		printf 'DRY RUN finished (unison exit %d)\n' "$status" >&2
		return 0
	fi

	printf 'unison failed (exit %d: 1=files skipped, 2=non-fatal errors, 3=fatal)\n' \
		"$status" >&2
	return 1
} # }}}

# ---------------------------------------------------------------------------
# Calendar
# ---------------------------------------------------------------------------

_sync_calendar() { # {{{
	_require_commands vdirsyncer || return 1

	vdirsyncer sync || return 1
} # }}}

# ---------------------------------------------------------------------------
# ta
# ---------------------------------------------------------------------------

_sync_ta() { # {{{
	_require_commands timew ta || return 1

	local active

	active="$(timew get dom.active)" || return 1

	# String comparison: non-numeric output must not raise an arithmetic error.
	if [[ "$active" == "1" ]]; then
		printf 'Synchronization not started: tracking is active\n' >&2
		return 0
	fi

	ta sync || return 1
} # }}}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_sync_function() { # {{{
	case "${1:-}" in
	taskwarrior) printf '%s\n' "_sync_taskwarrior" ;;
	mail) printf '%s\n' "_sync_mail" ;;
	assets) printf '%s\n' "_sync_assets" ;;
	documents) printf '%s\n' "_sync_documents" ;;
	calendar) printf '%s\n' "_sync_calendar" ;;
	passwords) printf '%s\n' "_sync_passwords" ;;
	ta) printf '%s\n' "_sync_ta" ;;
	*) return 1 ;;
	esac
} # }}}

_print_help() { # {{{
	cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] SYNC [ARG]

Synchronize one application, or all of them.

Syncs:
		taskwarrior   Synchronize Taskwarrior
		mail [ACCT]   Synchronize mail (gmail, gmx; default both) and update the notmuch database
		assets         Two-way sync of secured assets (unison)
		passwords     Synchronize passwords
	documents         Synchronize secured documents
		calendar      Synchronize calendars
		ta            Synchronize time tracking
		all           Run every sync above, one after another

Options:
		-n, --dry-run Do not change anything (currently honoured by "assets")
		-h, --help    Show this help

Environment:
		MINX_USER_ASSETS_DIR, MINX_REMOTE_SSH_SERVER, MINX_REMOTE_ASSETS_BASEDIR
									needed by "assets" (and the SSH server by "taskwarrior")
		MINX_USER_DOCUMENTS_DIR
									needed by "documents"
		MINX_SYNC_BACKUP
									1 (default) keeps old versions of changed/deleted files in unison's backup dir;
									0 disables
		MINX_SYNC_MAX_BACKUPS
									versions to keep per file (default 5)

Examples:
		$SCRIPT_NAME calendar
		$SCRIPT_NAME mail gmail
		$SCRIPT_NAME --dry-run assets

Different syncs may run concurrently, but the same sync
cannot run concurrently with itself.

Output:
		stdout        Path to the application log
		stderr        Synchronization output and diagnostics

Logs:
		$LOG_DIR/ssync_<sync>.log
EOF
} # }}}

# Runs ONE sync function directly, in its own process (so `set -e` works).
_exec_sync() { # {{{
	local name="$1"
	local function_name

	shift

	function_name="$(_sync_function "$name")" ||
		_die "Unknown sync: $name"

	trap _cleanup EXIT

	"$function_name" "$@"
} # }}}

_run_and_log() { # {{{
	local name="$1"
	local logfile="$LOG_DIR/ssync_$name.log"
	local start
	local end
	local status

	shift

	_rotate_log "$logfile"

	{
		local marker="********************************************************************************"
		printf '\n%s' "$marker"
		printf '\n%s\n' "$(date)"
		cat /opt/minx/version 2>/dev/null || printf 'version unknown\n'
		printf '%s\n' "$marker"
	} >>"$logfile"

	_log "$logfile" "=> Start synchronization: $name"

	start="$(date +%s)"

	# The sync runs as a separate process; its output goes to stderr and is
	# appended to the log. stdout stays reserved for the final log path.
	"${BASH:-bash}" "$SELF" --exec "$name" "$@" 2>&1 |
		tee -a "$logfile" >&2 || status="${PIPESTATUS[0]}"
	status="${status:-0}"

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
	local name="$1"
	local logfile
	local lockfile
	local status

	shift

	# Validate BEFORE the name is used to build file paths.
	_sync_function "$name" >/dev/null || {
		printf 'Unknown sync: %s\n\n' "$name" >&2
		_print_help >&2
		return 2
	}

	logfile="$LOG_DIR/ssync_$name.log"
	lockfile="$SYNC_LOCK_DIR/ssync_$name.lock"

	# Each sync has its own lock. fd 200 is held until this process exits;
	# child processes that must not hold it close it explicitly (200>&-).
	exec 200>"$lockfile"

	if ! flock -n 200; then
		printf '%s: %s synchronization already running\n' \
			"$SCRIPT_NAME" "$name" >&2

		# The canonical log path is still returned.
		printf '%s\n' "$logfile"

		return 75
	fi

	if _run_and_log "$name" "$@"; then
		status=0
	else
		status=$?
	fi

	# stdout is deliberately reserved for the canonical log path.
	printf '%s\n' "$logfile"

	return "$status"
} # }}}

_run_all() { # {{{
	local app
	local status
	local failed=0
	local -a failed_apps=()

	printf '%s\n' "=> $SCRIPT_NAME all: start"

	for app in "${ALL_SYNCS[@]}"; do
		# One failing sync must not abort the remaining ones.
		if "${BASH:-bash}" "$SELF" "$app"; then
			:
		else
			status=$?
			failed=1
			failed_apps+=("$app(exit $status)")
		fi
		printf '********************************************************************************\n'
	done

	if ((failed != 0)); then
		printf '%s\n' "=> $SCRIPT_NAME all: done, FAILED: ${failed_apps[*]}"
		return 1
	fi

	printf '%s\n' "=> $SCRIPT_NAME all: done"
} # }}}

main() { # {{{
	# Internal entry point used by the dispatcher.
	if [[ "${1:-}" == "--exec" ]]; then
		shift
		_exec_sync "$@"
		return
	fi

	while (($#)); do
		case "$1" in
		-h | --help)
			_print_help
			return 0
			;;
		-n | --dry-run)
			DRY_RUN=1
			export DRY_RUN
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			printf 'Unknown option: %s\n\n' "$1" >&2
			_print_help >&2
			return 2
			;;
		*)
			break
			;;
		esac
	done

	if (($# == 0)); then
		_print_help >&2
		return 1
	fi

	_init_state

	if [[ "$1" == "all" ]]; then
		_run_all
	else
		_run_dispatch "$@"
	fi
} # }}}

main "$@"
