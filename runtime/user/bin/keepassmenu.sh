#!/usr/bin/env bash
#
# keepassmenu - rofi/fzf front end for KeePassXC (keepassxc-cli)

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"

# User-configurable (environment)
DATABASE="${KEEPASS_DATABASE:-$HOME/.password-store/passwords.kdbx}"
KEY_FILE="${KEEPASS_KEY_FILE:-}"
GROUP_FILTER="${KEEPASS_GROUP:-}"
USE_CACHE="${KEEPASS_CACHE:-1}"
CLEAR_DELAY="${CLEAR_DELAY:-15}"
BACKEND="${BACKEND:-rofi}"

# Command that prints the master password on stdout.
readonly PASSWORD_HELPER="passmenu.sh"

# Runtime state (filled in during initialization)
MENU_CMD=""
CLIP_BACKEND=""
MASTER_PASSWORD=""
WORK_DIR=""
ERR_FILE=""
ENTRY_CACHE_FILE=""
OTP_CACHE_FILE=""
CACHE_PREFIX=""
ENTRY_LIST=""
OTP_ENTRY_LIST=""

declare -a KP_EXTRA_ARGS=()

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# Remove the temporary working directory on exit.
_cleanup() {
	[[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
}

trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Common helpers
# ---------------------------------------------------------------------------

# Print an error to stderr, send a desktop notification and exit with 1.
_die() {
	printf 'Error: %s\n' "$*" >&2
	notify-send -u critical "KeePass" "$*" 2>/dev/null || true
	exit 1
}

# Abort unless the given command is available in PATH.
_require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		_die "Required command not found: $1"
}

# Print the help text.
_print_usage() {
	cat <<EOF
Usage:
    $SCRIPT_NAME --select-password
    $SCRIPT_NAME --select-otp
    $SCRIPT_NAME --get-password ENTRY
    $SCRIPT_NAME --get-username ENTRY
    $SCRIPT_NAME --get-metadata ENTRY
    $SCRIPT_NAME --update-cache

Commands:
    --select-password       Interactively select entry and field to copy
                            (only non-empty fields are listed; password first,
                            then the username, or 'no-user' if empty)
    --select-otp            Select an entry and copy its current OTP code
                            (lists only entries with an OTP once cached)
    --get-password          Print the password of ENTRY
    --get-username          Print the username of ENTRY
    --get-metadata          Print the notes of ENTRY
    --update-cache          Rebuild the entry and OTP lists (run at login or
                            when the database changes)
    --help                  Display this help

Environment:
    KEEPASS_DATABASE        KeePassXC database path
    KEEPASS_KEY_FILE        Optional key file
    KEEPASS_GROUP           Optional group restriction
    KEEPASS_CACHE           Cache entry list (default: 1)
    BACKEND                 Menu backend: rofi (default) or fzf
    CLEAR_DELAY             Clipboard clearing delay in seconds (default: 15)

Notes:
    - Entries are addressed by their full path.
    - Clipboard managers may retain copied secrets in their history.
    - The caches store titles and paths only, never credentials, and live in
      \$XDG_RUNTIME_DIR (cleared at logout).
    - Without a cached OTP list, --select-otp shows all entries.
    - Building the OTP list needs python3.
    - The --get-* commands work without X; the interactive commands need it
      (rofi) or a clipboard backend (fzf).
EOF
}

# ---------------------------------------------------------------------------
# Backends (menu, clipboard, notifications)
# ---------------------------------------------------------------------------

# Validate the menu backend and pick a clipboard backend for this environment.
_init_backends() {
	case "$BACKEND" in
	rofi | fzf)
		MENU_CMD="$BACKEND"
		;;
	*)
		_die "Unknown BACKEND '$BACKEND' (allowed: rofi, fzf)"
		;;
	esac

	# rofi cannot run without a display.
	if [[ "$MENU_CMD" == rofi && -z "${DISPLAY:-}" ]]; then
		_die "rofi backend requires X running (DISPLAY is not set)"
	fi

	_require_cmd "$MENU_CMD"

	# Clipboard tool is chosen by environment, independent of the menu.
	if [[ -n "${DISPLAY:-}" ]]; then
		CLIP_BACKEND="x11"
		_require_cmd xclip
	elif command -v termux-clipboard-set >/dev/null 2>&1; then
		CLIP_BACKEND="termux"
		_require_cmd termux-clipboard-get
	else
		_die "No clipboard backend found (X11 or Termux)"
	fi
}

# Write stdin to the clipboard.
_clipboard_write() {
	case "$CLIP_BACKEND" in
	wayland) wl-copy --type text/plain ;;
	x11) xclip -selection clipboard ;;
	termux) termux-clipboard-set ;;
	esac
}

# Print the current clipboard contents.
_clipboard_read() {
	case "$CLIP_BACKEND" in
	wayland) wl-paste --no-newline ;;
	x11) xclip -selection clipboard -o ;;
	termux) termux-clipboard-get ;;
	esac
}

# Empty the clipboard.
_clipboard_clear() {
	case "$CLIP_BACKEND" in
	wayland) wl-copy --clear ;;
	x11) xclip -selection clipboard -i /dev/null ;;
	termux) printf '' | termux-clipboard-set ;;
	esac
}

# Show a message: desktop notification with rofi, stderr with fzf (so it can
# never end up inside a captured $(...) value).
_notify() {
	local title="$1" message="$2"

	if [[ "$BACKEND" == rofi ]]; then
		notify-send -r 9999 "$title" "$message" 2>/dev/null || true
	else
		printf '%s: %s\n' "$title" "$message" >&2
	fi
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

# Check dependencies and inputs, create the work dir and compute cache paths.
_init_environment() {
	local required_cmd
	local base_dir
	local db_signature
	local config_hash
	local runtime_dir_ok=0

	for required_cmd in keepassxc-cli sed awk sort mktemp cksum stat; do
		_require_cmd "$required_cmd"
	done

	[[ -f "$DATABASE" && -r "$DATABASE" ]] ||
		_die "Database not found or not readable: $DATABASE"

	if [[ -n "$KEY_FILE" ]]; then
		[[ -f "$KEY_FILE" && -r "$KEY_FILE" ]] ||
			_die "Key file not found or not readable: $KEY_FILE"
		KP_EXTRA_ARGS+=(-k "$KEY_FILE")
	fi

	if [[ ! "$CLEAR_DELAY" =~ ^[0-9]+$ ]] || ((10#$CLEAR_DELAY < 1)); then
		_die "CLEAR_DELAY must be an integer >= 1"
	fi
	CLEAR_DELAY=$((10#$CLEAR_DELAY))

	base_dir="${XDG_RUNTIME_DIR:-}"
	if [[ -n "$base_dir" && -d "$base_dir" && -w "$base_dir" ]]; then
		runtime_dir_ok=1
	else
		# Termux has no writable /tmp; honour TMPDIR first.
		base_dir="${TMPDIR:-/tmp}"
	fi

	WORK_DIR=$(mktemp -d "$base_dir/keepassmenu.XXXXXX") ||
		_die "Could not create temporary directory"
	ERR_FILE="$WORK_DIR/err"
	: >"$ERR_FILE"

	# Only cache in a per-user runtime dir, never in a shared temp dir.
	if [[ "$USE_CACHE" == 1 && "$runtime_dir_ok" == 1 ]]; then
		db_signature=$(stat -c '%Y-%s' -- "$DATABASE") ||
			_die "Could not stat database"
		config_hash=$(printf '%s\0%s' "$DATABASE" "$GROUP_FILTER" | cksum)

		CACHE_PREFIX="$base_dir/keepassmenu-$UID-${config_hash%% *}"
		ENTRY_CACHE_FILE="$CACHE_PREFIX-$db_signature.cache"
		OTP_CACHE_FILE="$CACHE_PREFIX-otp-$db_signature.cache"
	fi
}

# ---------------------------------------------------------------------------
# Master password
# ---------------------------------------------------------------------------

# Fetch the master password via the helper into MASTER_PASSWORD (once).
# Must be called in the main shell, not inside $(...), otherwise the password
# is lost when the subshell exits and the user is prompted again.
_load_master_password() {
	[[ -z "$MASTER_PASSWORD" ]] || return 0

	_require_cmd "$PASSWORD_HELPER"
	gpg-connect-agent /bye >/dev/null 2>&1 || true

	MASTER_PASSWORD=$("$PASSWORD_HELPER" --get-password readme root) ||
		_die "Could not obtain the master password"

	[[ -n "$MASTER_PASSWORD" ]] || _die "Master password is empty"
}

# ---------------------------------------------------------------------------
# KeePassXC CLI
# ---------------------------------------------------------------------------

# Run a keepassxc-cli subcommand, feeding the master password on stdin.
_kp_cli() {
	local subcommand="$1"
	shift

	# The ${arr[@]+...} form keeps an empty array safe under `set -u`.
	printf '%s\n' "$MASTER_PASSWORD" |
		LC_ALL=C.UTF-8 keepassxc-cli "$subcommand" \
			${KP_EXTRA_ARGS[@]+"${KP_EXTRA_ARGS[@]}"} "$@"
}

# Print one field of an entry. TOTP must go through `show -t`, which prints
# the current code; `-a` would return the stored secret instead.
_fetch_field() {
	local entry_path="$1" attribute="$2"

	if [[ "$attribute" == TOTP ]]; then
		_kp_cli show -q -t -- "$DATABASE" "$entry_path"
	else
		_kp_cli show -q -a "$attribute" -- "$DATABASE" "$entry_path"
	fi
}

# ---------------------------------------------------------------------------
# Entry list and caches
# ---------------------------------------------------------------------------

# Succeed if the cache file is a non-empty regular file owned by us
# (not a symlink).
_cache_is_valid() {
	local cache_file="$1"

	[[ -n "$cache_file" &&
		-f "$cache_file" &&
		! -L "$cache_file" &&
		-O "$cache_file" &&
		-s "$cache_file" ]]
}

# Atomically write content to a cache file (no-op if caching is disabled).
_cache_write() {
	local cache_file="$1" content="$2" tmp_file

	[[ -n "$cache_file" ]] || return 0
	tmp_file="$cache_file.tmp.$$"

	if ! {
		printf '%s\n' "$content" >"$tmp_file" &&
			mv -f -- "$tmp_file" "$cache_file"
	}; then
		rm -f -- "$tmp_file"
	fi
}

# Load ENTRY_LIST from the cache, or build it from the database.
_load_entry_list() {
	local raw_listing

	if _cache_is_valid "$ENTRY_CACHE_FILE"; then
		ENTRY_LIST=$(<"$ENTRY_CACHE_FILE")
		return 0
	fi

	_load_master_password

	raw_listing=$(
		_kp_cli ls --quiet -R -f -- "$DATABASE" 2>"$ERR_FILE"
	) || _die "Could not list database entries: $(<"$ERR_FILE")"

	ENTRY_LIST=$(
		sed \
			-e 's/\r$//' \
			-e '/^Enter password to unlock /d' \
			-e '/^KeePassXC-Browser Passwords\//d' \
			-e '/^Recycle Bin\//d' \
			-e '/^\[empty\]$/d' \
			-e '/^[[:space:]]*$/d' \
			-e '/^[^[:space:]].*\/$/d' <<<"$raw_listing"
	)

	if [[ -n "$GROUP_FILTER" ]]; then
		ENTRY_LIST=$(
			group_prefix="${GROUP_FILTER%/}/" \
				awk 'index($0, ENVIRON["group_prefix"]) == 1' <<<"$ENTRY_LIST"
		)
	fi

	[[ -n "$ENTRY_LIST" ]] || _die "No entries found"

	# Sort case-insensitively by full path; the OTP list inherits this order.
	ENTRY_LIST=$(LC_ALL=C.UTF-8 sort -f <<<"$ENTRY_LIST")

	if [[ -n "$ENTRY_CACHE_FILE" ]]; then
		# Drop caches of older database versions (list and OTP list).
		rm -f -- "$CACHE_PREFIX"-*.cache
		_cache_write "$ENTRY_CACHE_FILE" "$ENTRY_LIST"
	fi
}

# Python snippet that reads a KeePass XML export on stdin and prints the
# paths of entries carrying an OTP. Written without any indented blocks on
# purpose, so the code survives editors/formatters that re-indent or strip
# whitespace inside the string.
readonly OTP_PATHS_PYTHON='
import sys
import xml.etree.ElementTree as ET
KEYS = ("otp", "TOTP Seed", "TimeOtp-Secret-Base32")
get = lambda e, k: next((s.findtext("Value") or "" for s in e.findall("String") if s.findtext("Key") == k), "")
has_otp = lambda e: any(get(e, k).strip() for k in KEYS)
name = lambda g: g.findtext("Name") or ""
entry = lambda e, p: ["/".join(p + [get(e, "Title")])] if has_otp(e) else []
walk = lambda g, p: [x for c in g for x in (entry(c, p) if c.tag == "Entry" else walk(c, p + [name(c)]) if c.tag == "Group" else [])]
root = ET.parse(sys.stdin).getroot().find("Root/Group")
print("\n".join(walk(root, []) if root is not None else []))
'

# Build OTP_ENTRY_LIST (entries with an OTP) and cache it. The database is
# exported once through a pipe straight into a parser that prints entry paths
# only; the exported secrets are never stored. The result is intersected with
# ENTRY_LIST so paths, group filter and Recycle Bin handling match the normal
# entry list. Slow (needs an unlock and a full export); only used by
# --update-cache.
_build_otp_list() {
	local otp_paths

	_require_cmd python3
	_load_entry_list
	_load_master_password

	otp_paths=$(
		_kp_cli export -q -f xml -- "$DATABASE" 2>"$ERR_FILE" |
			python3 -c "$OTP_PATHS_PYTHON" 2>>"$ERR_FILE"
	) || _die "Could not scan for OTP entries: $(<"$ERR_FILE")"

	OTP_ENTRY_LIST=$(
		grep -Fx -f <(printf '%s\n' "$otp_paths") <<<"$ENTRY_LIST" || true
	)

	[[ -n "$OTP_ENTRY_LIST" ]] || _die "No entries with an OTP found"

	_cache_write "$OTP_CACHE_FILE" "$OTP_ENTRY_LIST"
}

# Fast: only reads the OTP cache. OTP_ENTRY_LIST stays empty on a miss.
_load_otp_list_from_cache() {
	OTP_ENTRY_LIST=""

	if _cache_is_valid "$OTP_CACHE_FILE"; then
		OTP_ENTRY_LIST=$(<"$OTP_CACHE_FILE")
	fi
}

# Discard all caches and rebuild both the entry list and the OTP list.
_rebuild_caches() {
	[[ -n "$ENTRY_CACHE_FILE" ]] ||
		_die "Caching is disabled or no runtime directory is available"

	rm -f -- "$CACHE_PREFIX"-*.cache

	_build_otp_list
	_notify "KeePass" "Cache updated: $(wc -l <<<"$ENTRY_LIST") entries, $(wc -l <<<"$OTP_ENTRY_LIST") with OTP"
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

# Show a menu with the given options and print the selected one.
_show_menu() {
	local prompt="$1"
	shift

	local -a options=("$@")

	if ((${#options[@]} == 0)); then
		_notify "KeePass error" "No options available for $prompt"
		return 1
	fi

	case "$MENU_CMD" in
	rofi)
		printf '%s\n' "${options[@]}" |
			rofi -dmenu -i -no-custom -p "$prompt"
		;;
	fzf)
		printf '%s\n' "${options[@]}" |
			fzf --prompt="$prompt: " --layout=reverse --border
		;;
	esac
}

# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------

# Copy a value to the clipboard and clear it again after CLEAR_DELAY seconds,
# but only if it still holds that value.
# Usage: _copy_secret LABEL VALUE
_copy_secret() {
	local label="$1"
	local value="$2"

	[[ -n "$value" ]] || {
		_notify "KeePass info" "$label is empty"
		return 1
	}

	(
		local current_clipboard

		printf '%s' "$value" | _clipboard_write
		sleep "$CLEAR_DELAY"

		# Only clear if the clipboard still holds our secret, so we never
		# wipe something the user copied in the meantime.
		current_clipboard=$(_clipboard_read 2>/dev/null || true)
		if [[ "$current_clipboard" == "$value" ]]; then
			_clipboard_clear || true
			_notify "KeePass clipboard" "Clipboard cleared"
		fi
	) </dev/null >/dev/null 2>&1 &
	disown $! 2>/dev/null || true

	_notify \
		"KeePass clipboard" \
		"'$label' copied, will clear in $CLEAR_DELAY s"
}

# ---------------------------------------------------------------------------
# Interactive selection
# ---------------------------------------------------------------------------

# Let the user pick one entry from a newline-separated list.
# Usage: _choose_entry PROMPT NEWLINE_SEPARATED_ENTRIES
_choose_entry() {
	local prompt="$1" entry_list="$2"
	local -a entry_paths

	mapfile -t entry_paths <<<"$entry_list"

	_show_menu "$prompt" "${entry_paths[@]}"
}

# Print the menu lines for an entry, one per line, listing only fields that
# exist. A single `show` call without -s is enough: protected values print
# as "PROTECTED" (non-empty) and empty fields print nothing, so existence
# can be detected without ever holding a secret in a variable.
# The username is always listed (and shown), even when empty.
# Output line 1 is the position (0-based) of the username line within the
# menu that follows; it is consumed by _run_select_password and never shown.
# Call as menu=$(_build_field_menu ...) so a failure aborts the script.
_build_field_menu() {
	local entry_path="$1" entry_dump username

	entry_dump=$(_kp_cli show -q -- "$DATABASE" "$entry_path" 2>"$ERR_FILE") ||
		_die "Could not read entry: $(<"$ERR_FILE")"

	username=$(sed -n '/^UserName:/{s/^UserName:[[:space:]]*//;s/[[:space:]]*$//;p;q;}' <<<"$entry_dump")

	if grep -q '^Password: .' <<<"$entry_dump"; then
		echo 1
		echo "password"
	else
		echo 0
	fi

	printf '%s\n' "${username:-no-user}"

	if grep -q '^URL: .' <<<"$entry_dump"; then
		echo "URL"
	fi
	if grep -q '^Notes: .' <<<"$entry_dump"; then
		echo "notes"
	fi

	# TOTP: use the OTP cache if present, otherwise probe the entry.
	if [[ -n "$OTP_ENTRY_LIST" ]]; then
		if grep -Fxq -- "$entry_path" <<<"$OTP_ENTRY_LIST"; then
			echo "TOTP"
		fi
	elif _fetch_field "$entry_path" TOTP >/dev/null 2>&1; then
		echo "TOTP"
	fi
}

# Interactive flow: pick an entry, pick a field, copy it to the clipboard.
_run_select_password() {
	local selected_entry selected_action attribute secret menu_output username_index
	local -a menu_fields

	_load_entry_list
	_load_otp_list_from_cache
	selected_entry=$(_choose_entry "Password" "$ENTRY_LIST") || return 0
	[[ -n "$selected_entry" ]] || return 0

	_load_master_password
	menu_output=$(_build_field_menu "$selected_entry") || exit 1
	mapfile -t menu_fields <<<"$menu_output"
	username_index="${menu_fields[0]}"
	menu_fields=("${menu_fields[@]:1}")

	selected_action=$(_show_menu "Copy" "${menu_fields[@]}") || return 0
	[[ -n "$selected_action" ]] || return 0

	# The username line has no prefix; its position is given by
	# username_index. Checked before the case so it wins even if a username
	# equals a label.
	if [[ "$selected_action" == "${menu_fields[username_index]}" ]]; then
		attribute="UserName"
		selected_action="username"
	else
		case "$selected_action" in
		password) attribute="Password" ;;
		URL) attribute="URL" ;;
		TOTP) attribute="TOTP" ;;
		notes) attribute="Notes" ;;
		*)
			_die "Invalid selection: $selected_action"
			;;
		esac
	fi

	secret=$(_fetch_field "$selected_entry" "$attribute") ||
		_die "Could not retrieve $attribute"

	_copy_secret "$selected_action" "$secret"
}

# Interactive flow: pick an entry and copy its current OTP code.
_run_select_otp() {
	local selected_entry otp_code

	_load_entry_list
	_load_otp_list_from_cache

	if [[ -z "$OTP_ENTRY_LIST" ]]; then
		_notify "KeePass" "OTP list not cached, showing all entries"
		OTP_ENTRY_LIST="$ENTRY_LIST"
	fi

	selected_entry=$(_choose_entry "OTP" "$OTP_ENTRY_LIST") || return 0
	[[ -n "$selected_entry" ]] || return 0

	_load_master_password
	otp_code=$(_fetch_field "$selected_entry" TOTP) ||
		_die "Could not retrieve OTP: $selected_entry has no TOTP configured"

	_copy_secret "OTP" "$otp_code"
}

# ---------------------------------------------------------------------------
# Non-interactive retrieval
# ---------------------------------------------------------------------------

# Print a single field of an entry to stdout.
# Usage: _print_entry_field ENTRY ATTRIBUTE
_print_entry_field() {
	local entry_path="$1" attribute="$2"

	_load_master_password
	_fetch_field "$entry_path" "$attribute"
}

# Print the password of an entry.
_print_password() {
	_print_entry_field "$1" Password
}

# Print the username of an entry.
_print_username() {
	_print_entry_field "$1" UserName
}

# Print the notes of an entry.
_print_notes() {
	_print_entry_field "$1" Notes
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Parse the command line and run the requested command.
_main() {
	local subcommand="${1:-}"

	case "$subcommand" in
	--select-password)
		shift
		[[ $# -eq 0 ]] ||
			_die "--select-password does not accept arguments"
		_init_backends
		_init_environment
		_run_select_password
		;;

	--select-otp)
		shift
		[[ $# -eq 0 ]] ||
			_die "--select-otp does not accept arguments"
		_init_backends
		_init_environment
		_run_select_otp
		;;

	--get-password)
		shift
		[[ $# -eq 1 ]] ||
			_die "--get-password requires ENTRY"
		_init_environment
		_print_password "$1"
		;;

	--get-username)
		shift
		[[ $# -eq 1 ]] ||
			_die "--get-username requires ENTRY"
		_init_environment
		_print_username "$1"
		;;

	--get-metadata)
		shift
		[[ $# -eq 1 ]] ||
			_die "--get-metadata requires ENTRY"
		_init_environment
		_print_notes "$1"
		;;

	--update-cache)
		shift
		[[ $# -eq 0 ]] ||
			_die "--update-cache does not accept arguments"
		_init_environment
		_rebuild_caches
		;;

	--help | -h)
		_print_usage
		;;

	"")
		_print_usage >&2
		exit 1
		;;

	*)
		_die "Unknown argument: $subcommand"
		;;
	esac
}

_main "$@"
