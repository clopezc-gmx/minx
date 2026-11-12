#!/usr/bin/env bash
set -euo pipefail
# set -x

DEBUG="${DEBUG:-0}"

if [[ "$DEBUG" != "0" && "$DEBUG" != "1" ]]; then
	printf '%s\n' "ERROR: DEBUG must be 0 or 1" >&2
	exit 2
fi

_log() {
	if [[ "$DEBUG" == "1" ]]; then
		printf '[task] %s\n' "$*" >&2
	fi
}

open_task_mail() {
	local task_id
	local json
	local desc
	local ma_token
	local mail_account
	local message_id
	local thread_raw
	local thread_id=""
	local query=""
	local q_enc
	local url
	local rc
	local out
	local err
	local nm_rc

	task_id="$1"

	_log "task_id=$task_id"

	# ------------------------------------------------------------------
	# Load and validate task JSON
	# ------------------------------------------------------------------

	if ! json="$(task "$task_id" export)"; then
		printf '%s\n' "ERROR: task export failed" >&2
		return 1
	fi

	if ! jq -e \
		'type == "array" and length > 0 and (.[0] | type == "object")' \
		>/dev/null <<<"$json"; then
		printf '%s\n' "ERROR: task export returned unexpected JSON" >&2
		return 1
	fi

	if ! desc="$(jq -er '.[0].description // "" | strings' <<<"$json")"; then
		printf '%s\n' "ERROR: Failed to read task description" >&2
		return 1
	fi

	_log "task export ok (bytes=${#json})"

	# ------------------------------------------------------------------
	# Extract ma_<account>
	# ------------------------------------------------------------------

	ma_token="$(
		printf '%s\n' "$desc" |
			grep -oE 'ma_[A-Za-z0-9_]+' |
			sed -n '1p' ||
			true
	)"

	if [[ -z "$ma_token" ]]; then
		printf '%s\n' \
			"ERROR: No account token (ma_<acct>) found in task description" >&2
		return 1
	else
		mail_account="${ma_token#ma_}"
	fi

	_log "mail_account=$mail_account"

	# ------------------------------------------------------------------
	# Extract mid:<...> annotation
	# ------------------------------------------------------------------

	if ! message_id="$(
		jq -r '
			.[0].annotations[]?.description // empty
			| select(startswith("mid:"))
			| ltrimstr("mid:")
			' <<<"$json" | sed -n '1p'
	)"; then
		printf '%s\n' "ERROR: Failed to read message ID annotation" >&2
		return 1
	fi

	_log "message_id_present=$([[ -n "$message_id" ]] && printf yes || printf no)"

	if [[ -z "$message_id" ]]; then
		if [[ "$DEBUG" == "1" ]]; then
			printf '%s\n' \
				"WARN: No mid:<...> annotation; falling back to inbox" >&2
			query="tag:inbox"
		else
			printf '%s\n' \
				"ERROR: No mid:<...> annotation found in task" >&2
			return 1
		fi
	fi

	# ------------------------------------------------------------------
	# Notmuch wrapper
	# ------------------------------------------------------------------

	_nm() {
		out="$(mktemp)" || return 1
		err="$(mktemp)" || {
			rm -f -- "$out"
			return 1
		}

		if notmuch "$@" >"$out" 2>"$err"; then
			nm_rc=0
		else
			nm_rc=$?
		fi

		if [[ "$DEBUG" == "1" ]]; then
			_log "notmuch exit status: $nm_rc"

			if [[ -s "$err" ]]; then
				sed 's/^/[notmuch stderr] /' "$err" >&2
			fi

			if [[ -s "$out" ]]; then
				head -n 5 "$out" |
					sed 's/^/[notmuch stdout] /' >&2
			fi
		fi

		if cat -- "$out"; then
			rc=0
		else
			rc=$?
		fi

		rm -f -- "$out" "$err"

		if ((rc != 0)); then
			return "$rc"
		fi

		return "$nm_rc"
	}

	# ------------------------------------------------------------------
	# Resolve message ID to thread
	# ------------------------------------------------------------------

	if [[ -n "$message_id" ]]; then
		# Normalize one pair of surrounding angle brackets.
		message_id="${message_id#<}"
		message_id="${message_id%>}"

		# Validate conventional email Message-ID syntax.
		# Keep the regular expression separate to avoid Bash parser issues.
		local message_id_re
		message_id_re="^[A-Za-z0-9.!#\$%&'*+/=?^_\`{|}~-]+@[A-Za-z0-9.-]+$"

		if [[ ! "$message_id" =~ $message_id_re ]]; then
			printf '%s\n' \
				"ERROR: Message ID has an unexpected format" >&2
			return 1
		fi

		# First try the normalized ID.
		if thread_raw="$(
			_nm search \
				--output=threads \
				--limit=1 \
				-- "id:\"$message_id\""
		)"; then
			:
		else
			printf '%s\n' "ERROR: Notmuch message search failed" >&2
			return 1
		fi

		thread_raw="$(printf '%s\n' "$thread_raw" | sed -n '1p')"

		# Some databases store IDs with angle brackets.
		if [[ -z "$thread_raw" ]]; then
			if thread_raw="$(
				_nm search \
					--output=threads \
					--limit=1 \
					-- "id:\"<$message_id>\""
			)"; then
				:
			else
				printf '%s\n' "ERROR: Notmuch fallback search failed" >&2
				return 1
			fi

			thread_raw="$(printf '%s\n' "$thread_raw" | sed -n '1p')"
		fi

		if [[ -n "$thread_raw" ]]; then
			if [[ "$thread_raw" == thread:* ]]; then
				thread_id="${thread_raw#thread:}"
				query="thread:$thread_id"
			else
				printf '%s\n' \
					"ERROR: Unexpected Notmuch thread result" >&2
				return 1
			fi
		else
			query="id:\"$message_id\""
		fi
	fi

	if [[ -z "$query" ]]; then
		query="tag:inbox"
	fi

	_log "final query=$query"

	# ------------------------------------------------------------------
	# URL-encode the query for NeoMutt
	# ------------------------------------------------------------------

	if ! q_enc="$(
		Q="$query" python3 - <<'PY'
import os
import urllib.parse

print(urllib.parse.quote(os.environ["Q"], safe=""))
PY
	)"; then
		printf '%s\n' "ERROR: Failed to encode Notmuch query" >&2
		return 1
	fi

	url="notmuch://?query=$q_enc"

	_log "opening NeoMutt (account=$mail_account)"

	# ------------------------------------------------------------------
	# Open in NeoMutt
	# ------------------------------------------------------------------

	minx-launcher mail "notmuch" "$mail_account" -f "$url"

	# MAIL_ACCOUNT="$mail_account" \
	# 	neomutt \
	# 	-F "$HOME/.config/neomutt/neomuttrc-notmuch" \
	# 	-f "$url"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
	printf 'Usage: %s <task_id>\n' "$0" >&2
	exit 2
fi

open_task_mail "$1"
