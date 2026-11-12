#!/usr/bin/env bash
set -euo pipefail
# set -x

if [[ $# -ne 1 || "$1" != mailto:* ]]; then
	echo "Error: Usage: $0 mailto:recipient@example.com" >&2
	exit 1
fi

recipient="${1#mailto:}"

if [[ -z "$recipient" ]]; then
	echo "Error: Recipient address is empty." >&2
	exit 1
fi

profile=$(printf 'gmail\ngmx' | rofi -dmenu -p 'Select profile:') || exit 0

config="$HOME/.config/neomutt/neomuttrc-notmuch"

case "$profile" in
gmail)
	export MAIL_ACCOUNT=gmail-notmuch
	;;
gmx)
	export MAIL_ACCOUNT=gmx-notmuch
	;;
*)
	exit 1
	;;
esac

args=(-- "$recipient")

# shellcheck disable=SC2016
exec st -e bash -c '
    config="$1"
    shift
    neomutt -F "$config" "$@" || exit 1
' bash "$config" "${args[@]}"

notmuch new
