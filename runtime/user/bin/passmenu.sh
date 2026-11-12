#!/usr/bin/env bash

set -euo pipefail

unset HISTFILE

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------

SCRIPT_NAME="${0##*/}"
PASSWORD_STORE="${HOME}/.password-store"
CLEAR_DELAY="${CLEAR_DELAY:-15}"
DEVICE="${DEVICE:-pc}"

# Set by the device backend.
MENU_TOOL=${MENU_TOOL:-rofi}

# Set from the dispatched command.
CURRENT_COMMAND="${1:-unknown}"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

_cleanup() {
	unset password
	unset lines
	unset users
	unset selected_user
	unset choice
	unset entry
	unset entries
	unset secret
	unset metadata
	unset issuer
	unset account
	unset secret_key
}

trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Common helpers
# ---------------------------------------------------------------------------

_error() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

_usage() {
	printf '%s\n' \
		"Usage:" \
		"  ${SCRIPT_NAME} --select-password" \
		"  ${SCRIPT_NAME} --select-otp" \
		"  ${SCRIPT_NAME} --get-password ENTRY USERNAME" \
		"  ${SCRIPT_NAME} --get-metadata ENTRY USERNAME" \
		"  ${SCRIPT_NAME} --generate-otp-uri ISSUER ACCOUNT SECRET" \
		"" \
		"Commands:" \
		"  --select-password       Interactively select password/user/metadata" \
		"  --select-otp            Interactively select and copy an OTP" \
		"  --get-password          Get password for ENTRY and USERNAME" \
		"  --get-metadata          Get metadata for ENTRY and USERNAME" \
		"  --generate-otp-uri      Generate an otpauth:// URI" \
		"" \
		"Environment:" \
		"  DEVICE                  Backend device: pc (default) or phone" \
		"  CLEAR_DELAY             Clipboard clearing delay (default: 15s)" \
		"" \
		"Examples:" \
		"  ${SCRIPT_NAME} --select-password" \
		"  DEVICE=phone ${SCRIPT_NAME} --select-password" \
		"" \
		"  ${SCRIPT_NAME} --select-otp" \
		"  DEVICE=phone ${SCRIPT_NAME} --select-otp" \
		"" \
		"  ${SCRIPT_NAME} --get-password github user@example.com" \
		"  ${SCRIPT_NAME} --get-metadata github user@example.com"
}

# ---------------------------------------------------------------------------
# Device backend
# ---------------------------------------------------------------------------

_backend_init() {
	case "$DEVICE" in
	pc)

		if [ -z "${DISPLAY:-}" ]; then
			printf '%s\n' "passmenu.sh requires X running." >&2
			exit 1
		fi

		_clip() {
			xclip -selection clipboard
		}

		_notify() {
			if [ -z "${DISPLAY:-}" ]; then
				printf "%s\n%s\n" "$1" "$2"
			else
				notify-send -r 9999 "$1" "$2"
			fi
		}

		;;

	phone)
		MENU_TOOL="fzf"

		_clip() {
			termux-clipboard-set
		}

		_notify() {
			# termux-notification \
			#     --id "passmenu" \
			#     --title "$1" \
			#     --content "$2" \
			#     --priority high

			printf '%s: %s\n' "$1" "$2"
		}
		;;

	*)
		_error "Unknown DEVICE '$DEVICE' (allowed: pc, phone)"
		;;
	esac
}

# ---------------------------------------------------------------------------
# Menu selection
# ---------------------------------------------------------------------------

_menu_select() {
	local prompt="$1"
	shift

	local options=("$@")

	if ((${#options[@]} == 0)); then
		_notify "Error" "No options available for $prompt"
		exit 1
	fi

	case "$MENU_TOOL" in
	rofi)
		printf '%s\n' "${options[@]}" |
			rofi -dmenu -i -p "$prompt"
		;;

	fzf)
		printf '%s\n' "${options[@]}" |
			fzf \
				--prompt="$prompt: " \
				--layout=reverse \
				--border
		;;

	*)
		_error "Unknown menu tool: $MENU_TOOL"
		;;
	esac
}

# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------

_copy_to_clipboard() {
	local object="$1"
	local value="$2"

	if [[ -z "$value" ]]; then
		_notify "[$CURRENT_COMMAND] info" "$object is empty"
		exit 1
	fi

	(
		printf '%s' "$value" | _clip

		sleep "$CLEAR_DELAY"

		printf '' | _clip

		_notify "clipboard" "cleared"
	) &

	_notify \
		"[$CURRENT_COMMAND] clipboard" \
		"'$object' copied, will clear in $CLEAR_DELAY s"
}

# ---------------------------------------------------------------------------
# Password-store helpers
# ---------------------------------------------------------------------------

_password_store_exists() {
	[[ -d "$PASSWORD_STORE" ]]
}

# ---------------------------------------------------------------------------
# Entry field lookup
# ---------------------------------------------------------------------------
#
# Password entry format:
#
#   password
#   username
#   metadata
#
# repeated for each username.
#
# Example:
#
#   password1
#   user1@example.com
#   metadata1
#   password2
#   user2@example.com
#   metadata2
#

_get_entry_field() {
	local entry="$1"
	local username="$2"
	local field="$3"

	[[ "$username" =~ ^[a-zA-Z0-9._%+-@]+$ ]] ||
		_error "Invalid username"

	mapfile -t lines < <(pass show "$entry")

	if ((${#lines[@]} % 3 != 0)); then
		_error "Invalid entry format: $entry"
	fi

	for ((i = 1; i < ${#lines[@]}; i += 3)); do
		if [[ "${lines[i]}" == "username: $username" ]]; then
			case "$field" in
			password)
				printf '%s\n' "${lines[i - 1]}"
				;;

			metadata)
				printf '%s\n' "${lines[i + 1]}"
				;;

			*)
				_error "Unknown field: $field"
				;;
			esac

			return 0
		fi
	done

	_error "No $field found for $username in $entry"
}

# ---------------------------------------------------------------------------
# Interactive password selection
# ---------------------------------------------------------------------------

_select_password() {
	_password_store_exists ||
		_error "Password store not found: $PASSWORD_STORE"

	mapfile -t entries < <(
		find -L "$PASSWORD_STORE" \
			-name '*.gpg' \
			! -path '*/otp/*' \
			-printf '%P\n' |
			sed 's/\.gpg$//' |
			sort
	)

	if ((${#entries[@]} == 0)); then
		_notify "Error" "No password entries found"
		exit 1
	fi

	entry=$(_menu_select "Select entry" "${entries[@]}")

	[[ -n "$entry" ]] || exit 1

	mapfile -t lines < <(pass show "$entry")

	if ((${#lines[@]} % 3 != 0)); then
		_notify "Error" "Invalid entry format: $entry"
		exit 1
	fi

	users=()

	for ((i = 1; i < ${#lines[@]}; i += 3)); do
		users+=("${lines[i]}")
	done

	selected_user=$(
		_menu_select "Select user" "${users[@]}"
	)

	[[ -n "$selected_user" ]] || exit 1

	for ((i = 1; i < ${#lines[@]}; i += 3)); do
		if [[ "${lines[i]}" == "$selected_user" ]]; then
			password="${lines[i - 1]}"
			metadata="${lines[i + 1]}"
			break
		fi
	done

	choice=$(
		_menu_select \
			"Copy" \
			"password" \
			"username" \
			"metadata"
	)

	[[ -n "$choice" ]] || exit 1

	case "$choice" in
	password)
		secret="$password"
		;;

	username)
		secret="$selected_user"
		;;

	metadata)
		secret="$metadata"
		;;

	*)
		_error "Invalid selection: $choice"
		;;
	esac

	_copy_to_clipboard "$choice" "$secret"
}

# ---------------------------------------------------------------------------
# Interactive OTP selection
# ---------------------------------------------------------------------------

_select_otp() {
	local otp_dir="${PASSWORD_STORE}/otp"

	if [[ ! -d "$otp_dir" ]]; then
		_notify "Error" "No OTP folder found"
		exit 1
	fi

	mapfile -t entries < <(
		find "$otp_dir" \
			-name '*.gpg' \
			-exec basename {} .gpg \; |
			sort
	)

	if ((${#entries[@]} == 0)); then
		_notify "Error" "No OTP entries found"
		exit 1
	fi

	entry=$(_menu_select "Select OTP entry" "${entries[@]}")

	[[ -n "$entry" ]] || exit 1

	secret=$(pass otp "otp/$entry")

	_copy_to_clipboard "code" "$secret"
}

# ---------------------------------------------------------------------------
# Password retrieval
# ---------------------------------------------------------------------------

_get_password() {
	local entry="$1"
	local username="$2"

	_get_entry_field "$entry" "$username" password
}

# ---------------------------------------------------------------------------
# Metadata retrieval
# ---------------------------------------------------------------------------

_get_metadata() {
	local entry="$1"
	local username="$2"

	_get_entry_field "$entry" "$username" metadata
}

# ---------------------------------------------------------------------------
# OTP URI generation
# ---------------------------------------------------------------------------

_urlencode() {
	local string="$1"

	python3 - "$string" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

_generate_otp_uri() {
	local issuer="$1"
	local account="$2"
	local secret_key="$3"

	local encoded_issuer
	local encoded_account

	encoded_issuer=$(_urlencode "$issuer")
	encoded_account=$(_urlencode "$account")

	printf \
		'otpauth://totp/%s:%s?secret=%s&issuer=%s\n' \
		"$encoded_issuer" \
		"$encoded_account" \
		"$secret_key" \
		"$encoded_issuer"
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_dispatch() {
	local command="${1:-}"

	case "$command" in
	--select-password)
		shift

		[[ $# -eq 0 ]] ||
			_error "--select-password does not accept arguments"

		_backend_init
		_select_password
		;;

	--select-otp)
		shift

		[[ $# -eq 0 ]] ||
			_error "--select-otp does not accept arguments"

		_backend_init
		_select_otp
		;;

	--get-password)
		shift

		[[ $# -eq 2 ]] ||
			_error "--get-password requires ENTRY USERNAME"

		_get_password "$1" "$2"
		;;

	--get-metadata)
		shift

		[[ $# -eq 2 ]] ||
			_error "--get-metadata requires ENTRY USERNAME"

		_get_metadata "$1" "$2"
		;;

	--generate-otp-uri)
		shift

		[[ $# -eq 3 ]] ||
			_error "--generate-otp-uri requires ISSUER ACCOUNT SECRET"

		_generate_otp_uri "$1" "$2" "$3"
		;;

	--help | -h)
		_usage
		;;

	"")
		_usage
		exit 1
		;;

	*)
		_error "Unknown dispatch argument: $command"
		;;
	esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

gpg-connect-agent /bye >/dev/null 2>&1 || true

_dispatch "$@"
