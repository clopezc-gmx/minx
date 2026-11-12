#!/usr/bin/env bash
#
# file:
# neomutt_helper.sh

set -euo pipefail
# set -x

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

help() {
	cat <<EOF
Usage: $(basename "$0") [OPTION]

Options:
	--open-html               Open HTML email content
	--open-file FILE          Open a PDF file or base64-encoded PDF
	--mail-to-task            Create a task from a email
	--open-task               Open the corresponding email from a task
	--restore-maildir-folders Restore local Maildir folders and sync accounts
	--get-sync-timestamp      Show the last synchronization timestamp
	-h, --help                Show this help message
EOF
}

_open_html() {
	local html_file

	if ! html_file=$(python3 "$LIB_DIR/mail_open_html.py"); then
		printf 'Error: could not retrieve HTML email content\n' >&2
		return 1
	fi

	if [[ -z "$html_file" || ! -f "$html_file" || ! -r "$html_file" ]]; then
		printf 'Error: HTML file is missing or unreadable: %s\n' "$html_file" >&2
		return 1
	fi

	if ! command -v qb.sh >/dev/null 2>&1; then
		printf 'Error: qb.sh is not installed or not in PATH\n' >&2
		return 1
	fi

	qb.sh -f "$html_file"
}

_open_pdf() {
	local pdf="${1:?Usage: neomutt_helper.sh --open-file FILE}"
	local tmpdir
	local tmpfile

	if ! command -v zathura >/dev/null 2>&1; then
		printf 'Error: zathura is not installed or not in PATH\n' >&2
		return 1
	fi

	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/neomutt-helper.XXXXXXXX") || {
		printf 'Error: could not create temporary directory\n' >&2
		return 1
	}

	tmpfile="$tmpdir/document.pdf"

	if [[ -f "$pdf" && -r "$pdf" ]]; then
		if ! cp -- "$pdf" "$tmpfile"; then
			rm -rf -- "$tmpdir"
			printf 'Error: could not copy PDF: %s\n' "$pdf" >&2
			return 1
		fi
	else
		# Preserve support for base64-encoded PDF input.
		if ! printf '%s' "$pdf" | base64 --decode >"$tmpfile"; then
			rm -rf -- "$tmpdir"
			printf 'Error: input is neither a readable file nor valid base64 data\n' >&2
			return 1
		fi
	fi

	# Confirm the decoded/copied content is a PDF.
	if ! head -c 5 "$tmpfile" | grep -q '^%PDF-'; then
		rm -rf -- "$tmpdir"
		printf 'Error: input does not appear to be a PDF\n' >&2
		return 1
	fi

	# Keep the temporary directory alive while the viewer uses the file.
	# The viewer process owns the cleanup operation.
	(
		trap 'rm -rf -- "$tmpdir"' EXIT
		exec zathura "$tmpfile"
	) >/dev/null 2>&1 &

	local viewer_pid=$!
	disown "$viewer_pid" 2>/dev/null || true
}

_cleanup_maildir_folders() {
	local mailroot="$HOME/.mail"
	local box
	local account
	local reply
	local -a mailboxes=()

	if [[ ! -d "$mailroot" ]]; then
		printf 'Error: mail root does not exist: %s\n' "$mailroot" >&2
		return 1
	fi

	mailboxes=(
		"$mailroot/gmail/[Gmail]"
		"$mailroot/gmail/[Gmail]/All Mail"
		"$mailroot/gmail/[Gmail]/Bin"
		"$mailroot/gmail/[Gmail]/Drafts"
		"$mailroot/gmail/[Gmail]/Sent Mail"
		"$mailroot/gmail/[Gmail]/Spam"
		"$mailroot/gmx/Entwürfe"
		"$mailroot/gmx/Gelöscht"
		"$mailroot/gmx/Gesendet"
		"$mailroot/gmx/INBOX"
		"$mailroot/gmx/Spamverdacht"
	)

	printf '==> Restoring local Maildir folders\n'

	for box in "${mailboxes[@]}"; do
		if ! mkdir -p -- "$box/cur" "$box/new" "$box/tmp"; then
			printf 'Error: could not restore Maildir: %s\n' "$box" >&2
			return 1
		fi

		printf 'restored %s\n' "$box"
	done

	printf '\n'
	printf '==> Selected .mbsyncstate files for removal\n'

	# Preview the exact targets before deleting synchronization state.
	find "$mailroot" -type f \
		\( -path '*/gmail/[Gmail]/Drafts/.mbsyncstate' \
		-o -path '*/gmail/[Gmail]/Sent Mail/.mbsyncstate' \
		-o -path '*/gmail/[Gmail]/Spam/.mbsyncstate' \
		-o -path '*/gmail/[Gmail]/Bin/.mbsyncstate' \
		-o -path '*/gmx/Entwürfe/.mbsyncstate' \) \
		-print

	printf '\n'
	printf 'Delete the listed synchronization state files? [y/N] '

	if ! IFS= read -r reply || [[ ! "$reply" =~ ^[Yy]$ ]]; then
		printf 'Skipping synchronization state cleanup\n'
	else
		find "$mailroot" -type f \
			\( -path '*/gmail/[Gmail]/Drafts/.mbsyncstate' \
			-o -path '*/gmail/[Gmail]/Sent Mail/.mbsyncstate' \
			-o -path '*/gmail/[Gmail]/Spam/.mbsyncstate' \
			-o -path '*/gmail/[Gmail]/Bin/.mbsyncstate' \
			-o -path '*/gmx/Entwürfe/.mbsyncstate' \) \
			-print -delete
	fi

	if ! command -v mbsync >/dev/null 2>&1; then
		printf 'Error: mbsync is not installed or not in PATH\n' >&2
		return 1
	fi

	for account in gmail gmx; do
		printf '\n==> Preparing additional folders for %s\n' "$account"

		mkdir -p -- "/tmp/$USER/neomutt/$account"
		mkdir -p -- "$HOME/.cache/neomutt/$account"

		printf '==> Running mbsync for %s\n' "$account"
		mbsync -V "$account"
	done

	printf '\nDone\n'
}

_get_sync_timestamp() {
	local account="${1:?Account not set}"
	local last_sync_file="$HOME/.local/state/minx/mail/last-sync-${account}"
	local last_sync="never"

	if [[ -r "$last_sync_file" ]]; then
		last_sync=$(<"$last_sync_file")
	fi

	printf '%s' "$last_sync"
}

_mail_to_task() {
	python3 "$LIB_DIR/mail_to_task.py" "$@"
}

_open_mail_from_task() {
	local taskid="${1:?--open-mail-from-task <taskid> : taskid not set}"
	"$LIB_DIR/open_mail_from_task.sh" "$taskid"
}

main() {
	local action="--help"

	if (($# > 0)); then
		action="$1"
		shift
	fi

	case "$action" in
	--open-html)
		_open_html "$@"
		;;

	--open-file)
		_open_pdf "$@"
		;;

	--get-sync-timestamp)
		_get_last_sync_timestamp "$@"
		;;

	--cleanup-maildir-folders)
		_cleanup_maildir_folders
		;;

	--mail-to-task)
		_mail_to_task "$@"
		;;

	--open-mail-from-task)
		_open_mail_from_task "$@"
		;;

	-h | --help)
		help
		;;
	*)
		printf 'Error: unknown option: %s\n\n' "$action" >&2
		help >&2
		return 2
		;;
	esac
}

main "$@"
